import AppKit
import SwiftUI
import NudgeCore

/// SwiftUI source-of-truth for the chat panel. Living in an ObservableObject
/// (rather than `let` props on PopoverView) means polling can update the
/// transcript without remounting the AgentSessionsPanel — so the TextField's
/// `@State` survives auto-refresh cycles.
@MainActor
final class AgentChatStore: ObservableObject {
    @Published var sessions: [AgentSessionSummary] = []
    @Published var detail: AgentSessionDetail?
    @Published var activities: [AgentActivitySnapshot] = []
    @Published var error: String?
}

@MainActor
final class MenuBarController: NSObject {
    private let queue: PromptQueue
    private let activityStore: AgentActivityStore
    private let statusItem: NSStatusItem
    private let panel: PromptPanel
    private let sessionAllow = SessionAllowList()
    private let store = PromptStore()
    private var currentPrompt: Prompt? { store.prompt }
    private var queueDepth: Int { store.queueDepth }
    private var noticeTask: Task<Void, Never>?
    private var deferredHead: (prompt: Prompt?, depth: Int)?
    /// The panel is fading out with its last content; queue changes wait for
    /// the fade to finish. See `closePanel()`.
    private var isClosing = false
    /// A prompt dismissed from the panel (Dismiss, Cancel), which puts up no
    /// notice. Its leaving the queue is our doing, not a withdrawal.
    private var dismissedID: String?
    private var agentRefreshTimer: Timer?
    private var agentRefreshSequence: Int = 0
    private var keyMonitor: Any?
    private var appSwitchObserver: NSObjectProtocol?
    /// When global ⏎/esc may answer. See `armKeys()`.
    private var answerKeys = AnswerKeys()
    private var clickMonitor: Any?
    private var idleKeyMonitor: Any?
    private var settings: Prefs = .load()
    private let agentChat = AgentChatStore()

    init(queue: PromptQueue, activityStore: AgentActivityStore) {
        self.queue = queue
        self.activityStore = activityStore
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.panel = PromptPanel()
        super.init()
        store.prefs = settings
        configureStatusItem()
        observeAppSwitches()
        Task { await self.subscribeToQueue() }
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            // Receive both left and right mouse-up so we can route them
            // differently: left toggles the popover, right shows the menu.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        refreshIcon()
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The status bar places SF Symbol images by their baseline, which put
    /// `hand.tap` (raised finger) 2.75pt above the system icons (measured on
    /// a Retina menu bar: centre row 27px vs 32.5px). Redrawn into a plain
    /// image of the same size, it's centred like they are (32.5px).
    private static func opticallyCentered(_ image: NSImage, template: Bool) -> NSImage {
        let size = image.size
        let canvas = NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
        canvas.isTemplate = template
        canvas.accessibilityDescription = image.accessibilityDescription
        return canvas
    }

    /// Updates the menu bar icon based on enabled state and current prompt.
    /// `arrived` = a new prompt just landed: bounce the glyph so the eye goes
    /// to the menu bar even from another app.
    private func refreshIcon(arrived: Bool = false) {
        guard let button = statusItem.button else { return }
        let symbol: String
        let color: NSColor?  // nil = adaptive (template), non-nil = baked color
        if !settings.enabled {
            symbol = "hand.tap"
            color = NSColor.tertiaryLabelColor
        } else if currentPrompt != nil {
            symbol = "hand.tap.fill"
            color = NSColor.systemRed
        } else {
            symbol = "hand.tap"
            color = nil
        }

        guard let baseImg = NSImage(systemSymbolName: symbol, accessibilityDescription: "Nudge") else {
            button.image = nil
            return
        }

        // Crossfade the glyph swap (outline ↔ filled red) instead of snapping.
        if !reduceMotion, button.image != nil {
            button.wantsLayer = true
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.18
            button.layer?.add(fade, forKey: "glyph")
        }

        if let color = color {
            // Bake the color into the SF Symbol via hierarchicalColor. Status
            // bar buttons sometimes ignore `contentTintColor`, so applying the
            // color as a SymbolConfiguration is more reliable.
            let config = NSImage.SymbolConfiguration(hierarchicalColor: color)
            let tinted = baseImg.withSymbolConfiguration(config) ?? baseImg
            button.image = Self.opticallyCentered(tinted, template: false)
            button.contentTintColor = nil
        } else {
            // Adaptive: let the menu bar tint based on appearance.
            button.image = Self.opticallyCentered(baseImg, template: true)
            button.contentTintColor = nil
        }

        // A single pending prompt is the red icon. Two or more get a count
        // beside it, so a backlog is visible without opening the popover.
        if settings.enabled, currentPrompt != nil, queueDepth > 1 {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.systemRed,
                .baselineOffset: 0.5,
            ]
            button.attributedTitle = NSAttributedString(string: " \(queueDepth)", attributes: attrs)
            button.imagePosition = .imageLeading
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
        }

        if arrived { bounceIcon() }
    }

    /// A small scale pop on the status item when a prompt lands: the literal
    /// nudge. Scales about the centre by composing translations into
    /// the transform, so AppKit's ownership of the layer's anchorPoint and
    /// position is left alone.
    private func bounceIcon() {
        guard !reduceMotion, let button = statusItem.button else { return }
        button.wantsLayer = true
        guard let layer = button.layer else { return }
        let b = layer.bounds
        func scaled(_ s: CGFloat) -> NSValue {
            var t = CATransform3DMakeTranslation(b.midX, b.midY, 0)
            t = CATransform3DScale(t, s, s, 1)
            t = CATransform3DTranslate(t, -b.midX, -b.midY, 0)
            return NSValue(caTransform3D: t)
        }
        let bounce = CAKeyframeAnimation(keyPath: "transform")
        bounce.values = [1.0, 1.15, 1.0].map(scaled)
        bounce.keyTimes = [0, 0.4, 1]
        bounce.duration = 0.3
        bounce.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 2)
        layer.add(bounce, forKey: "bounce")
    }

    @objc private func handleClick(_ sender: AnyObject?) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRightClick {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if panel.isVisible {
            dismissPanel()
        } else {
            refreshAgentSessions()
            renderAndShow()
        }
    }

    /// Builds and displays the right-click menu with the on/off toggles.
    private func showContextMenu() {
        let menu = NSMenu()

        let pauseItem = NSMenuItem(
            title: settings.enabled ? "Pause Nudge" : "Resume Nudge",
            action: #selector(togglePause),
            keyEquivalent: ""
        )
        pauseItem.target = self
        menu.addItem(pauseItem)

        let skipItem = NSMenuItem(
            title: "Skip when terminal is focused",
            action: #selector(toggleSkipTerminal),
            keyEquivalent: ""
        )
        skipItem.target = self
        skipItem.state = settings.skipWhenTerminalFocused ? .on : .off
        menu.addItem(skipItem)

        let finishedItem = NSMenuItem(
            title: "Tell me when Claude finishes",
            action: #selector(toggleFinishedMessages),
            keyEquivalent: ""
        )
        finishedItem.target = self
        finishedItem.state = settings.finishedMessages ? .on : .off
        menu.addItem(finishedItem)

        if GlobalKeys.isAvailable {
            let keysItem = NSMenuItem(
                title: "Answer with ⏎ and esc",
                action: #selector(toggleGlobalKeys),
                keyEquivalent: ""
            )
            keysItem.target = self
            keysItem.state = settings.globalKeys ? .on : .off
            menu.addItem(keysItem)
        }

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Nudge",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        // Temporarily attach the menu so the status item opens it on this
        // click. Detach right after so future left-clicks fire our action
        // instead of the menu.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Flips one pref and saves it. The store drives the idle UI, so its
    /// switch animates in place: no re-show, no replayed fade-in.
    private func togglePref(_ key: WritableKeyPath<Prefs, Bool>) {
        settings[keyPath: key].toggle()
        settings.save()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            store.prefs = settings
        }
    }

    /// Hands waiting prompts back: .cancel makes the hook exit without an
    /// answer, and the agent carries on with its own flow.
    private func cancelPending(where matching: @escaping @Sendable (Prompt) -> Bool) {
        Task { [queue] in
            await queue.resolveAll(where: matching, with: DecisionResponse(decision: .cancel))
        }
    }

    @objc private func togglePause() {
        togglePref(\.enabled)
        refreshIcon()
        // Paused means Nudge steps aside, so hand every waiting prompt back
        // instead of denying it: the agent's own dialog (already up for its
        // own prompts) or its normal permission flow takes over. nudge-ask
        // exits as cancelled and Claude asks in the terminal.
        if !settings.enabled { cancelPending { _ in true } }
        if panel.isVisible, currentPrompt == nil { animatedRefit() }
    }

    @objc private func toggleSkipTerminal() {
        togglePref(\.skipWhenTerminalFocused)
        if panel.isVisible, currentPrompt == nil { animatedRefit() }
    }

    @objc private func toggleFinishedMessages() {
        togglePref(\.finishedMessages)
        // Off means off: let go of any session waiting on a reply.
        if !settings.finishedMessages { cancelPending { $0.resolvedKind == .finished } }
        if panel.isVisible, currentPrompt == nil { animatedRefit() }
    }

    /// One observer for app switches, all day:
    /// - A finished message holds its session (the Stop hook waits for your
    ///   reply), which is only fine while you're away from it. Switch to the
    ///   terminal or app showing that session and Nudge lets it go.
    /// - While ⏎/esc are listening: ⏎ right after a switch was meant for the
    ///   app you switched to, and the keycaps follow the app in front.
    private func observeAppSwitches() {
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let front = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.frontAppDidChange(front) }
        }
    }

    private func frontAppDidChange(_ front: String?) {
        if let front {
            cancelPending { $0.isFinishedMessage(shownBy: front) }
        }
        if keyMonitor != nil { answerKeys.typed(at: Date()) }
        setKeysStandDown(front.map(FrontmostApp.ownPromptBundleIDs.contains) ?? false)
    }

    @objc private func toggleGlobalKeys() {
        togglePref(\.globalKeys)
        // The right-click menu can flip this with a prompt up.
        if settings.globalKeys, currentPrompt?.resolvedKind == .permission {
            startKeyMonitor()
        } else if !settings.globalKeys {
            stopKeyMonitor()
        }
        if panel.isVisible { animatedRefit() }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func buildPopoverView() -> PopoverView {
        PopoverView(
            state: store,
            onAllow: { [weak self] in self?.resolve(.allow) },
            onDeny:  { [weak self] in self?.resolve(.deny) },
            onAlwaysAllow: { [weak self] in self?.alwaysAllowCurrent() },
            onSessionAllow: { [weak self] in self?.sessionAllowCurrent() },
            onSubmitText: { [weak self] text in self?.submitAskText(text) },
            onCancelAsk: { [weak self] in self?.resolve(.cancel) },
            onJumpToSession: { [weak self] in self?.jumpToSession() },
            onTogglePause: { [weak self] in self?.togglePause() },
            onToggleSkipTerminal: { [weak self] in self?.toggleSkipTerminal() },
            onToggleGlobalKeys: { [weak self] in self?.toggleGlobalKeys() },
            onToggleFinishedMessages: { [weak self] in self?.toggleFinishedMessages() },
            onQuit: { [weak self] in self?.quitApp() },
            onEnableGlobalKeys: { [weak self] in self?.enableGlobalKeys() },
            agentChat: agentChat,
            onRefreshAgentSessions: { [weak self] in self?.refreshAgentSessions() },
            onSelectAgentSession: { [weak self] id in self?.refreshAgentSessions(selecting: id) },
            onSendAgentMessage: { [weak self] id, text in self?.sendAgentMessage(text, to: id) },
            onEndAgentSession: { [weak self] id in self?.endAgentSession(id) },
            onRenameAgentSession: { [weak self] id, title in self?.renameAgentSession(id: id, title: title) }
        )
    }

    private func endAgentSession(_ id: String) {
        Task { [weak self] in
            await Task.detached {
                let backend = TmuxAgentBackend()
                if let session = (try? backend.listSessions())?.first(where: { $0.id == id }) {
                    backend.killSession(session)
                }
            }.value
            await MainActor.run {
                self?.refreshAgentSessions()
            }
        }
    }

    private func renameAgentSession(id: String, title: String?) {
        Task { [weak self] in
            await Task.detached {
                try? AgentSessionFiles.setCustomTitle(id: id, title: title)
            }.value
            await MainActor.run {
                self?.refreshAgentSessions(selecting: id)
            }
        }
    }

    /// How the panel treats the keyboard for what it's showing now.
    private var currentFocus: PanelFocus {
        switch currentPrompt?.resolvedKind {
        case nil, .ask?:    return .takesKey
        case .finished?:    return .onClick
        case .permission?:  return .never
        }
    }

    private func renderAndShow() {
        let isIdle = currentPrompt == nil
        panel.show(content: buildPopoverView(), anchorTo: statusItem.button, focus: currentFocus)
        armKeys()
        store.globalKeysAvailable = GlobalKeys.isAvailable
        // Menu bar extras show their icon pressed while their panel is open.
        statusItem.button?.highlight(true)
        // Click-outside dismiss applies to every visible state of the panel.
        startClickMonitor()
        if isIdle {
            startIdleKeyMonitor()
        } else {
            stopIdleKeyMonitor()
        }
        // Pulse the menu bar icon only while the popover is open with an
        // active permission prompt. Once dismissed, the icon stays red and
        // steady (refreshIcon) so it's still a clear "pending" indicator.
        if currentPrompt?.resolvedKind == .permission {
            startPulse()
        } else {
            stopPulse()
        }
        // Auto-refresh chat data while popover is open in idle/chat state. The
        // store-based architecture means @Published mutations re-render only
        // the transcript subtree; the TextField's @State (draft) survives.
        // Poll even when no session exists so a freshly started `nudge-claude`
        // shows up without close+reopen.
        if currentPrompt == nil {
            startAgentRefresh()
        } else {
            stopAgentRefresh()
        }
    }

    private func dismissPanel(then completion: (() -> Void)? = nil) {
        stopClickMonitor()
        stopIdleKeyMonitor()
        stopPulse()
        stopAgentRefresh()
        statusItem.button?.highlight(false)
        panel.hide(completion: completion)
    }

    /// Fades the panel out as it stands, notice and all, and applies whatever
    /// the queue moved to once it's gone. Changing the content first would
    /// show the old buttons, or the idle view, through the fade.
    private func closePanel() {
        isClosing = true
        stopKeyMonitor()
        dismissPanel { [weak self] in
            guard let self else { return }
            self.isClosing = false
            self.store.notice = nil
            if let next = self.deferredHead {
                self.deferredHead = nil
                self.applyHead(prompt: next.prompt, depth: next.depth)
            }
        }
    }

    private func startAgentRefresh() {
        stopAgentRefresh()
        agentRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAgentSessions(selecting: self?.agentChat.detail?.id)
                // Picks up an Accessibility grant made while the panel is open.
                self?.refreshGlobalKeysAvailability()
            }
        }
    }

    private func stopAgentRefresh() {
        agentRefreshTimer?.invalidate()
        agentRefreshTimer = nil
    }

    private func subscribeToQueue() async {
        await queue.setOnHeadChange { [weak self] prompt, depth in
            DispatchQueue.main.async {
                self?.handleHead(prompt: prompt, depth: depth)
            }
        }
    }

    private func handleHead(prompt: Prompt?, depth: Int) {
        // Auto-resolve via session allow list before any UI (permission only).
        if let prompt = prompt,
           prompt.resolvedKind == .permission,
           sessionAllow.contains(prompt) {
            Task { await queue.resolve(id: prompt.id, with: .allow) }
            return
        }

        // A decision notice is on screen, or the panel is fading out: hold
        // the next state until that's done. Only the latest head matters.
        if store.notice != nil || isClosing {
            deferredHead = (prompt, depth)
            // The notice's beat already ran out waiting for this.
            if !isClosing, noticeTask == nil { endNotice() }
            return
        }

        if panel.isVisible, let shown = store.prompt, shown.id != prompt?.id {
            // Dismissed from the panel: close, or move on to the next prompt.
            if shown.id == dismissedID {
                dismissedID = nil
                if prompt == nil {
                    deferredHead = (prompt, depth)
                    closePanel()
                    return
                }
            } else {
                // Our other answers put up a notice first (handled above), so
                // this one left without a click: its hook was killed or it
                // timed out. Say so instead of letting it vanish mid-read.
                deferredHead = (prompt, depth)
                showNotice(.withdrawn(agent: shown.agentName))
                return
            }
        }
        applyHead(prompt: prompt, depth: depth)
    }

    private func applyHead(prompt: Prompt?, depth: Int) {
        let wasVisible = panel.isVisible
        let previousID = store.prompt?.id

        // Same head, different depth: a prompt joined or left the line behind
        // it. Update the counts and nudge the icon on growth, but don't
        // re-show a panel the user dismissed.
        if let prompt, prompt.id == previousID {
            let grew = depth > store.queueDepth
            withAnimation((wasVisible && !reduceMotion) ? .easeInOut(duration: 0.2) : nil) {
                store.queueDepth = depth
            }
            refreshIcon(arrived: grew)
            return
        }

        // Visible panel: cross-fade to the new content in place. Hidden: no
        // animation on the state — the fade-in in show() is the entrance.
        withAnimation((wasVisible && !reduceMotion) ? .easeInOut(duration: 0.22) : nil) {
            store.prompt = prompt
            store.queueDepth = depth
        }
        refreshIcon(arrived: prompt != nil && prompt?.id != previousID)

        if let prompt = prompt {
            // Global Enter/Esc shortcuts only make sense for permission
            // prompts. For asks, the popover is key (TextEditor receives
            // keystrokes) and dismissal is via the in-popover buttons.
            if prompt.resolvedKind == .permission {
                startKeyMonitor()
            } else {
                stopKeyMonitor()
            }
            if wasVisible {
                refreshVisiblePanel()
            } else {
                renderAndShow()
            }
        } else {
            stopKeyMonitor()
            dismissPanel()
        }
    }

    /// Same bookkeeping as renderAndShow, for a panel that is already up: the
    /// content changed under it (next prompt, a toggle), so re-key, refit with
    /// animation, and re-arm the pulse / refresh timers for the new state.
    private func refreshVisiblePanel() {
        let isIdle = currentPrompt == nil
        panel.apply(currentFocus)
        armKeys()
        animatedRefit()
        if currentPrompt?.resolvedKind == .permission { startPulse() } else { stopPulse() }
        if isIdle {
            startAgentRefresh()
            startIdleKeyMonitor()
        } else {
            stopAgentRefresh()
            stopIdleKeyMonitor()
        }
    }

    /// SwiftUI commits the new layout on the next runloop turn, so measure
    /// then. The second pass after the cross-fade catches the case where the
    /// outgoing view was taller than the incoming one — the ZStack holds both
    /// until the removal transition ends.
    private func animatedRefit() {
        let focus = currentFocus
        DispatchQueue.main.async { [weak self] in self?.refitNow(focus) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refitNow(focus) }
    }

    private func refitNow(_ focus: PanelFocus) {
        guard panel.isVisible else { return }
        panel.refit(anchorTo: statusItem.button, focus: focus, animated: true)
    }

    // MARK: - Decision handlers

    /// Resolves the prompt currently on screen. The id is read here on the main
    /// actor and carried into the task, so a queue that moves on between the
    /// click and the hop can't redirect this decision at another prompt.
    /// While a notice is showing the decision has already gone out, so a
    /// second Enter or click is dropped rather than re-sent.
    private func resolve(_ decision: Decision) {
        guard store.notice == nil, !isClosing, let prompt = currentPrompt else { return }
        let id = prompt.id
        Task { await queue.resolve(id: id, with: decision) }
        if prompt.resolvedKind == .permission {
            showNotice(decision == .allow ? .allowed : .denied)
        } else {
            dismissedID = id
        }
    }

    /// Brings up the session's own window. Once it's in front, the app-switch
    /// observer lets the finished message go, so Claude stops as usual and
    /// you carry on there.
    private func jumpToSession() {
        guard let prompt = currentPrompt else { return }
        SessionJump.go(to: prompt)
    }

    private func submitAskText(_ text: String) {
        guard store.notice == nil, !isClosing, let id = currentPrompt?.id else { return }
        let response = DecisionResponse(decision: .text, text: text)
        Task { await queue.resolve(id: id, with: response) }
        showNotice(.sent)
    }

    /// Holds the panel for a beat with the decision acknowledged in place of
    /// the buttons, so the click visibly landed. The hook is already unblocked
    /// — only the UI lingers. Whatever the queue moved to (next prompt or
    /// empty) is applied when the beat ends.
    private func showNotice(_ notice: DecisionNotice) {
        guard panel.isVisible else { return }
        stopKeyMonitor()
        stopPulse()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            store.notice = notice
        }
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(notice.holdDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.endNotice()
        }
    }

    private func endNotice() {
        noticeTask = nil
        // The queue hasn't moved yet. Keep the notice up rather than flash
        // the answered prompt's buttons; handleHead ends it when it moves.
        guard let next = deferredHead else { return }
        // Nothing left to show: fade out on the notice.
        if next.prompt == nil, panel.isVisible {
            closePanel()
            return
        }
        deferredHead = nil
        store.notice = nil
        applyHead(prompt: next.prompt, depth: next.depth)
    }

    private func alwaysAllowCurrent() {
        guard let prompt = currentPrompt else { return }
        // The rule text is shared with the popover's menu label (Promotion),
        // so what the user clicked is exactly what lands in settings.json.
        let rule = Promotion.rule(for: prompt)
        do {
            _ = try PersistentAllowList.addRule(rule)
        } catch {
            NSLog("Nudge: failed to write Always Allow: \(error)")
        }
        // Also session-allow this exact command so it doesn't re-prompt within
        // the same Claude Code session (Claude caches settings.json at start).
        sessionAllow.add(prompt)
        resolve(.allow)
    }

    private func sessionAllowCurrent() {
        guard let prompt = currentPrompt else { return }
        sessionAllow.add(prompt)
        resolve(.allow)
    }

    // MARK: - Pulse

    /// Breathing opacity on the status item while the panel is up with a
    /// permission prompt. Core Animation runs it off the main thread, so it
    /// costs nothing per frame; with Reduce Motion the icon stays steady red.
    private func startPulse() {
        stopPulse()
        guard !reduceMotion, let button = statusItem.button else { return }
        button.wantsLayer = true
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.5
        pulse.duration = 0.75
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        button.layer?.add(pulse, forKey: "pulse")
    }

    private func stopPulse() {
        statusItem.button?.layer?.removeAnimation(forKey: "pulse")
        statusItem.button?.alphaValue = 1.0
    }

    // MARK: - Global keyboard

    /// Restarts the arming delay (see `AnswerKeys`). Called whenever a
    /// prompt appears or the panel's prompt changes. Typing from just before
    /// the monitor started counts too.
    private func armKeys() {
        let sinceLastKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let now = Date()
        answerKeys.promptShown(at: now, lastKeyDown: now.addingTimeInterval(-sinceLastKey))
    }

    /// Starts listening for ⏎/esc, or keeps listening if it already is (the
    /// next prompt only needs re-arming, which showing it does).
    private func startKeyMonitor() {
        guard settings.globalKeys, keyMonitor == nil else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        setKeysStandDown(front.map(FrontmostApp.ownPromptBundleIDs.contains) ?? false)
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible else { return }
            let isAllow = event.keyCode == 36 || event.keyCode == 76
            let isDeny = event.keyCode == 53
            // In a terminal or the agent's own app (keysStandDown, kept by the
            // app-switch observer), ⏎ and esc answer the agent's dialog there
            // (maybe another session's, maybe "No"), never Nudge's.
            guard isAllow || isDeny, Self.isBareKeyPress(event), !self.store.keysStandDown else {
                // Typing somewhere else: hold off until it stops.
                self.answerKeys.typed(at: Date())
                return
            }
            guard self.answerKeys.isArmed(at: Date()) else { return }
            DispatchQueue.main.async { self.resolve(isAllow ? .allow : .deny) }
        }
    }

    /// The keycaps only show when ⏎ and esc would reach Nudge.
    private func setKeysStandDown(_ standDown: Bool) {
        guard standDown != store.keysStandDown else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            store.keysStandDown = standDown
        }
    }

    /// A deliberate press: not auto-repeat from a held key, and no modifiers.
    /// ⇧⏎ and ⌘⏎ mean "newline" or "send" in chat apps, so they never answer
    /// a prompt behind your back.
    private nonisolated static func isBareKeyPress(_ event: NSEvent) -> Bool {
        !event.isARepeat
            && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }

    private func refreshGlobalKeysAvailability() {
        let available = GlobalKeys.isAvailable
        guard available != store.globalKeysAvailable else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            store.globalKeysAvailable = available
        }
        if panel.isVisible { animatedRefit() }
    }

    private func enableGlobalKeys() {
        GlobalKeys.requestAccess()
    }

    private func stopKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    // MARK: - Esc closes the idle popover

    private func startIdleKeyMonitor() {
        stopIdleKeyMonitor()
        idleKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible, self.panel.isKey,
                  self.currentPrompt == nil, event.keyCode == 53 else { return event }
            DispatchQueue.main.async { self.dismissPanel() }
            return nil
        }
    }

    private func stopIdleKeyMonitor() {
        if let m = idleKeyMonitor { NSEvent.removeMonitor(m); idleKeyMonitor = nil }
    }

    // MARK: - Click-outside-to-deny

    private func startClickMonitor() {
        stopClickMonitor()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.panel.isVisible else { return }
            let panelFrame = self.panel.windowFrame
            let mouseLocation = NSEvent.mouseLocation
            // Ignore clicks on the menu bar icon itself (toggleManually handles those).
            let buttonScreenFrame = self.statusItem.button?.window?.frame ?? .zero
            guard !panelFrame.contains(mouseLocation),
                  !buttonScreenFrame.contains(mouseLocation) else { return }

            DispatchQueue.main.async {
                // Click-outside hides the popover but does NOT resolve any
                // active prompt — user can come back to it via the icon.
                // Only explicit Deny / Cancel actions (or Esc) resolve.
                self.dismissPanel()
            }
        }
    }

    private func stopClickMonitor() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    // MARK: - Agent sessions

    /// Bumps a sequence number on entry; only the latest refresh writes to the
    /// store. That avoids the in-flight-flag race we had before (where a
    /// polling tick's flag wouldn't clear in time, blocking subsequent polls)
    /// and the cancel race (where a slow capture got cancelled by the next
    /// poll and never wrote anything). Multiple refreshes can be in flight
    /// simultaneously; only the most-recent one's result lands.
    ///
    /// Failure handling stays conservative: a transient `backend.detail`
    /// error shouldn't blank the chat UI. Keep the prior detail and let the
    /// next successful refresh replace it.
    private func refreshAgentSessions(selecting sessionID: String? = nil) {
        agentRefreshSequence += 1
        let mySeq = agentRefreshSequence
        Task { [weak self] in
            let activityStore = self?.activityStore
            let result = await Task.detached { () async -> Result<([AgentSessionSummary], AgentSessionDetail?, [AgentActivitySnapshot]), Error> in
                do {
                    let backend = TmuxAgentBackend()
                    let sessions = try backend.listSessions()
                    let selected = sessionID.flatMap { id in sessions.first(where: { $0.id == id }) }
                        ?? sessions.first
                    var detail: AgentSessionDetail? = nil
                    if let selected {
                        detail = try? backend.detail(for: selected)
                    }
                    let activities = await activityStore?.snapshots() ?? []
                    return .success((sessions, detail, activities))
                } catch {
                    return .failure(error)
                }
            }.value

            await MainActor.run {
                guard let self else { return }
                // A newer refresh has started since we kicked off; let it win.
                guard mySeq == self.agentRefreshSequence else { return }
                switch result {
                case .success(let payload):
                    self.agentChat.sessions = payload.0
                    self.agentChat.activities = payload.2
                    if let detail = payload.1 {
                        self.agentChat.detail = detail
                    } else if !payload.0.contains(where: { $0.id == self.agentChat.detail?.id }) {
                        self.agentChat.detail = nil
                    }
                    self.agentChat.error = nil
                    self.refitAgentPanelAfterStoreUpdate()
                case .failure(let error):
                    self.agentChat.error = String(describing: error)
                }
            }
        }
    }

    private func refitAgentPanelAfterStoreUpdate() {
        guard panel.isVisible, currentPrompt == nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, self.currentPrompt == nil else { return }
            self.panel.refit(anchorTo: self.statusItem.button, focus: .takesKey, animated: true)
        }
    }

    private func sendAgentMessage(_ text: String, to sessionID: String) {
        Task { [weak self] in
            let result = await Task.detached { () async -> Result<Void, Error> in
                do {
                    let backend = TmuxAgentBackend()
                    let sessions = try backend.listSessions()
                    guard let session = sessions.first(where: { $0.id == sessionID }) else {
                        throw TmuxAgentError.sessionMissing(sessionID)
                    }
                    try backend.send(text, to: session)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value

            await MainActor.run {
                guard let self else { return }
                switch result {
                case .success:
                    self.agentChat.error = nil
                    self.refreshAgentSessions(selecting: sessionID)
                case .failure(let error):
                    self.agentChat.error = String(describing: error)
                }
            }
        }
    }
}

// MARK: - PromptPanel

/// NSPanel subclass that conditionally allows becoming key window. We flip
/// the flag on for ask popovers (TextField needs keystrokes) and off for
/// permission popovers (otherwise interacting with the SwiftUI Menu lets
/// the panel grab focus, which paints the Allow button blue and leaves it
/// stuck in the keyed look).
/// How the panel treats the keyboard for what it's showing.
enum PanelFocus {
    /// Takes key as it appears: idle (switches, the chat composer, esc to
    /// close) and asks (you type an answer).
    case takesKey
    /// Key only once you click it: a finished message can pop up
    /// mid-sentence in another app, so it never grabs the keyboard.
    case onClick
    /// Never key: permission prompts answer with clicks or the guarded
    /// global ⏎/esc, so SwiftUI Menu clicks can't grab focus either.
    case never
}

private final class KeyablePanel: NSPanel {
    var allowsKey: Bool = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PromptPanel {
    private let panel: NSPanel
    private let hosting: NSHostingController<AnyView>
    /// Bumped by every show(), so a fade-out that a show() interrupted
    /// doesn't order the re-shown panel out when it completes.
    private var showCount = 0

    var isVisible: Bool { panel.isVisible }
    var isKey: Bool { panel.isKeyWindow }
    var windowFrame: NSRect { panel.frame }

    /// System-wide "Reduce motion": no animated resizing.
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    init() {
        self.hosting = NSHostingController(rootView: AnyView(EmptyView()))
        let size = NSSize(width: 380, height: 200)
        self.panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // SwiftUI goes in a plain container rather than in as the window's
        // content view. As the content view, NSHostingView resizes the window
        // itself from windowDidLayout (updateAnimatedWindowSize) while refit()
        // sets the frame too, and AppKit aborts when a layout pass asks for
        // another one mid-display ("_postWindowNeedsLayout" crashes, Sep 22 and
        // 26). Only Nudge sizes the panel now; SwiftUI just reports its size.
        hosting.sizingOptions = [.intrinsicContentSize]
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        hosting.view.translatesAutoresizingMaskIntoConstraints = true
        hosting.view.autoresizingMask = [.width, .height]
        hosting.view.frame = container.bounds
        container.addSubview(hosting.view)
        panel.contentView = container
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = false
    }

    /// Fallback content size if SwiftUI hasn't reported an intrinsic size yet.
    /// Width matches PopoverView's `.frame(width: 420)`. Height is generous;
    /// the real height comes from the hosting view's intrinsic size in show().
    private static let fallbackContentSize = NSSize(width: 420, height: 200)

    /// Applies `focus` to content that changed under a visible panel. Anything
    /// that doesn't take key right away also gives up key if the panel has it
    /// (a permission prompt or a finished message replacing a chat or an ask),
    /// or your next ⏎ would land in the new content. Keystrokes go back to the
    /// app you were in, where only the guarded global monitor hears them.
    func apply(_ focus: PanelFocus) {
        (panel as? KeyablePanel)?.allowsKey = focus != .never
        if focus != .takesKey { resignKey() }
    }

    /// Gives the keyboard back to the app you were in. AppKit has no direct
    /// way to resign, but ordering a key window out does it; whether it can
    /// take key again when clicked is up to `allowsKey`.
    private func resignKey() {
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    /// Re-measures SwiftUI content after ObservableObject changes. This keeps
    /// async chat-detail loads from being clipped by the shorter placeholder
    /// panel that was measured before tmux capture finished. `animated` eases
    /// the frame to the new size in step with the content's own transition.
    func refit(anchorTo button: NSStatusBarButton?, focus: PanelFocus, animated: Bool = false) {
        guard panel.isVisible else { return }
        (panel as? KeyablePanel)?.allowsKey = focus != .never

        hosting.view.layoutSubtreeIfNeeded()
        let newSize = fittingContentSize()
        if let button, let newOrigin = originUnder(button: button, size: newSize) {
            // Atomic: avoid the gap-flicker that comes from setContentSize
            // (which keeps top-left fixed and drops origin.y) followed by
            // setFrameOrigin a moment later.
            let target = NSRect(origin: newOrigin, size: newSize)
            if animated, !reduceMotion, target != panel.frame {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.22
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    panel.animator().setFrame(target, display: true)
                }
            } else {
                panel.setFrame(target, display: true, animate: false)
            }
        } else {
            panel.setContentSize(newSize)
        }
        if focus == .takesKey, !panel.isKeyWindow,
           !NSApp.windows.contains(where: { $0.isKeyWindow }) {
            panel.makeKey()
        }
    }

    func show(content: PopoverView, anchorTo button: NSStatusBarButton?, focus: PanelFocus) {
        hosting.rootView = AnyView(
            content
                .clipShape(RoundedRectangle(cornerRadius: PopoverView.cornerRadius, style: .continuous))
        )

        // Ask SwiftUI for the actual intrinsic size after layout. Using
        // fittingSize keeps the panel matched to the rendered content (so
        // centering math is honest) and lets the height adapt to whether a
        // command box / queue badge is showing.
        let size = fittingContentSize()
        panel.setContentSize(size)
        showCount += 1

        let finalOrigin = computeOrigin(anchorTo: button)

        // A quick fade in place, like Control Center and other menu bar
        // panels. No slide: a moving Liquid Glass window reads as lag.
        panel.alphaValue = 0
        panel.setFrameOrigin(finalOrigin)
        // Gate key-window eligibility BEFORE ordering front. Permission
        // popovers stay non-keyable so SwiftUI Menu interactions can't
        // trigger a focus grab (which left Allow stuck in its blue
        // "default action keyed" appearance after the menu closed).
        (panel as? KeyablePanel)?.allowsKey = focus != .never
        panel.orderFrontRegardless()
        if focus == .takesKey {
            panel.makeKey()
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func fittingContentSize() -> NSSize {
        hosting.view.layoutSubtreeIfNeeded()
        let intrinsic = hosting.view.intrinsicContentSize
        return NSSize(
            width: intrinsic.width  > 1 ? intrinsic.width  : Self.fallbackContentSize.width,
            height: intrinsic.height > 1 ? intrinsic.height : Self.fallbackContentSize.height
        )
    }

    /// Fades the panel out. `completion` runs once it's gone (right away if it
    /// already was), which is when content can change without being seen.
    func hide(completion: (() -> Void)? = nil) {
        guard panel.isVisible else { completion?(); return }
        let shown = showCount
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.showCount == shown {
                    self.panel.orderOut(nil)
                    self.panel.alphaValue = 1
                }
                completion?()
            }
        })
    }

    // MARK: - Positioning

    private func computeOrigin(anchorTo button: NSStatusBarButton?) -> NSPoint {
        if let pt = originUnder(button: button) { return pt }
        return originTopRight()
    }

    private func originUnder(button: NSStatusBarButton?) -> NSPoint? {
        return originUnder(button: button, size: panel.frame.size)
    }

    /// Variant that takes the target size explicitly. Call this before mutating
    /// the panel size so origin and size apply atomically — `setContentSize`
    /// followed by `setFrameOrigin` leaves a brief window where the panel has
    /// the new height but the old origin, which on the agent chat panel was
    /// large enough to push the top below the menu bar before snapping back.
    private func originUnder(button: NSStatusBarButton?, size: NSSize) -> NSPoint? {
        guard let button = button,
              let buttonWindow = button.window else { return nil }
        let buttonFrame = buttonWindow.frame
        guard buttonFrame.width > 1, buttonFrame.height > 1 else { return nil }
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(buttonFrame) })
              ?? NSScreen.main else { return nil }

        let buttonCenterX = buttonFrame.midX
        var originX = buttonCenterX - size.width / 2

        let leftEdge = screen.frame.minX + 8
        let rightEdge = screen.frame.maxX - size.width - 8
        originX = min(max(originX, leftEdge), rightEdge)

        // Compute the bottom edge of where the menu bar lives. With auto-hide
        // enabled, visibleFrame.maxY can equal screen.frame.maxY (full height),
        // which puts the popover behind the bar when it later reappears. So we
        // reserve menu-bar height even when it's currently hidden.
        let buttonAtTopEdge = buttonFrame.minY >= screen.frame.maxY - 1
        let menuBarBottomY: CGFloat
        if !buttonAtTopEdge {
            menuBarBottomY = buttonFrame.minY
        } else {
            let reserve = max(NSStatusBar.system.thickness, 32)
            menuBarBottomY = screen.frame.maxY - reserve
        }
        // Flush under the menu bar like the system's own menu bar panels
        // (Wi-Fi and Bluetooth start 0.5pt below it; measured on macOS 27).
        let originY = menuBarBottomY - size.height - 0.5
        return NSPoint(x: originX, y: originY)
    }

    private func originTopRight() -> NSPoint {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
              ?? NSScreen.main else { return .zero }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let margin: CGFloat = 14
        return NSPoint(x: visible.maxX - size.width - margin,
                       y: visible.maxY - size.height - margin)
    }
}

extension Prompt {
    /// A finished message whose session shows itself in app `front` (its
    /// terminal, or the agent's own app), so you're looking at it already.
    func isFinishedMessage(shownBy front: String) -> Bool {
        resolvedKind == .finished
            && FrontmostApp.sessionUIBundleIDs(entrypoint: entrypoint, agent: agent).contains(front)
    }
}
