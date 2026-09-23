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
    private var agentRefreshTimer: Timer?
    private var agentRefreshSequence: Int = 0
    private var keyMonitor: Any?
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
            tinted.isTemplate = false
            button.image = tinted
            button.contentTintColor = nil
        } else {
            // Adaptive: let the menu bar tint based on appearance.
            baseImg.isTemplate = true
            button.image = baseImg
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

    /// A short scale bounce on the status item when a prompt lands — the
    /// literal nudge. Scales about the centre by composing translations into
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
        bounce.values = [1.0, 1.3, 0.92, 1.06, 1.0].map(scaled)
        bounce.keyTimes = [0, 0.3, 0.6, 0.82, 1]
        bounce.duration = 0.45
        bounce.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4)
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
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        pauseItem.target = self
        menu.addItem(pauseItem)

        let skipItem = NSMenuItem(
            title: "Skip when terminal is focused",
            action: #selector(toggleSkipWhenTerminalFocused),
            keyEquivalent: ""
        )
        skipItem.target = self
        skipItem.state = settings.skipWhenTerminalFocused ? .on : .off
        menu.addItem(skipItem)

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

    @objc private func toggleEnabled() {
        togglePauseAndRefresh()
    }

    @objc private func toggleSkipWhenTerminalFocused() {
        toggleSkipTerminalAndRefresh()
    }

    private func togglePauseAndRefresh() {
        settings.enabled.toggle()
        settings.save()
        // The store drives the idle UI, so the switch and subtitle animate in
        // place — no re-show, no replayed drop-in.
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            store.prefs = settings
        }
        refreshIcon()
        // If Nudge was paused while a prompt was up, resolve it so callers
        // unblock instead of waiting on a popover that won't appear.
        if !settings.enabled, currentPrompt != nil {
            resolve(currentPrompt?.resolvedKind == .ask ? .cancel : .deny)
        }
        if panel.isVisible, currentPrompt == nil {
            animatedRefit()
        }
    }

    private func toggleSkipTerminalAndRefresh() {
        settings.skipWhenTerminalFocused.toggle()
        settings.save()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            store.prefs = settings
        }
        if panel.isVisible, currentPrompt == nil {
            animatedRefit()
        }
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
            onTogglePause: { [weak self] in self?.togglePauseAndRefresh() },
            onToggleSkipTerminal: { [weak self] in self?.toggleSkipTerminalAndRefresh() },
            onQuit: { [weak self] in self?.quitApp() },
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

    private func renderAndShow() {
        // Permission popovers stay non-key (see KeyablePanel). Asks need key
        // for the text field; idle takes key too so its switches, the chat
        // composer and Esc-to-close all behave like a real menu bar extra.
        let isAsk = currentPrompt?.resolvedKind == .ask
        let isIdle = currentPrompt == nil
        panel.show(
            content: buildPopoverView(),
            anchorTo: statusItem.button,
            makeKey: isAsk || isIdle
        )
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

    private func dismissPanel() {
        stopClickMonitor()
        stopIdleKeyMonitor()
        stopPulse()
        stopAgentRefresh()
        statusItem.button?.highlight(false)
        panel.hide()
    }

    private func startAgentRefresh() {
        stopAgentRefresh()
        agentRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAgentSessions(selecting: self?.agentChat.detail?.id)
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
           sessionAllow.contains(tool: prompt.tool, command: prompt.command) {
            Task { await queue.resolve(id: prompt.id, with: .allow) }
            return
        }

        // A decision notice is on screen: hold the next state until it has
        // had its beat. Only the latest head matters when it ends.
        if store.notice != nil {
            deferredHead = (prompt, depth)
            return
        }
        applyHead(prompt: prompt, depth: depth)
    }

    private func applyHead(prompt: Prompt?, depth: Int) {
        let wasVisible = panel.isVisible
        let previousID = store.prompt?.id
        // Visible panel: cross-fade to the new content in place. Hidden: no
        // animation on the state — the drop-in in show() is the entrance.
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
        let isAsk = currentPrompt?.resolvedKind == .ask
        let isIdle = currentPrompt == nil
        panel.setKeyable(isAsk || isIdle)
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
        let makeKey = currentPrompt == nil || currentPrompt?.resolvedKind == .ask
        DispatchQueue.main.async { [weak self] in self?.refitNow(makeKey: makeKey) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refitNow(makeKey: makeKey) }
    }

    private func refitNow(makeKey: Bool) {
        guard panel.isVisible else { return }
        panel.refit(anchorTo: statusItem.button, makeKey: makeKey, animated: true)
    }

    // MARK: - Decision handlers

    /// Resolves the prompt currently on screen. The id is read here on the main
    /// actor and carried into the task, so a queue that moves on between the
    /// click and the hop can't redirect this decision at another prompt.
    /// While a notice is showing the decision has already gone out, so a
    /// second Enter or click is dropped rather than re-sent.
    private func resolve(_ decision: Decision) {
        guard store.notice == nil, let prompt = currentPrompt else { return }
        let id = prompt.id
        Task { await queue.resolve(id: id, with: decision) }
        if prompt.resolvedKind == .permission {
            showNotice(decision == .allow ? .allowed : .denied)
        }
    }

    private func submitAskText(_ text: String) {
        guard store.notice == nil, let id = currentPrompt?.id else { return }
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
        withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.25)) {
            store.notice = notice
        }
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 520_000_000)
            guard !Task.isCancelled else { return }
            self?.endNotice()
        }
    }

    private func endNotice() {
        noticeTask = nil
        store.notice = nil
        if let next = deferredHead {
            deferredHead = nil
            applyHead(prompt: next.prompt, depth: next.depth)
        }
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
        sessionAllow.add(tool: prompt.tool, command: prompt.command)
        resolve(.allow)
    }

    private func sessionAllowCurrent() {
        guard let prompt = currentPrompt else { return }
        sessionAllow.add(tool: prompt.tool, command: prompt.command)
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

    private func startKeyMonitor() {
        stopKeyMonitor()
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard self?.panel.isVisible == true else { return }
            if event.keyCode == 36 || event.keyCode == 76 {
                DispatchQueue.main.async { self?.resolve(.allow) }
            } else if event.keyCode == 53 {
                DispatchQueue.main.async { self?.resolve(.deny) }
            }
        }
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
            self.panel.refit(anchorTo: self.statusItem.button, makeKey: true, animated: true)
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
private final class KeyablePanel: NSPanel {
    var allowsKey: Bool = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PromptPanel {
    private let panel: NSPanel
    private let hosting: NSHostingController<AnyView>

    var isVisible: Bool { panel.isVisible }
    var isKey: Bool { panel.isKeyWindow }
    var windowFrame: NSRect { panel.frame }

    /// System-wide "Reduce motion" — swap the slide+overshoot for a plain fade.
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
        panel.contentViewController = hosting
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = false
    }

    /// Fallback content size if SwiftUI hasn't reported an intrinsic size yet.
    /// Width matches PopoverView's `.frame(width: 420)`. Height is generous;
    /// the real height comes from `hosting.view.fittingSize` in show().
    private static let fallbackContentSize = NSSize(width: 420, height: 200)

    /// Flips key-window eligibility for content that changed under a visible
    /// panel. Does not resign key — AppKit has no clean way to, and a panel
    /// that stays key until it hides is what happened before as well.
    func setKeyable(_ flag: Bool) {
        (panel as? KeyablePanel)?.allowsKey = flag
    }

    /// Re-measures SwiftUI content after ObservableObject changes. This keeps
    /// async chat-detail loads from being clipped by the shorter placeholder
    /// panel that was measured before tmux capture finished. `animated` eases
    /// the frame to the new size in step with the content's own transition.
    func refit(anchorTo button: NSStatusBarButton?, makeKey: Bool = false, animated: Bool = false) {
        guard panel.isVisible else { return }
        if let keyable = panel as? KeyablePanel {
            keyable.allowsKey = makeKey
        }

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
        if makeKey, !panel.isKeyWindow,
           !NSApp.windows.contains(where: { $0.isKeyWindow }) {
            panel.makeKey()
        }
    }

    func show(content: PopoverView, anchorTo button: NSStatusBarButton?, makeKey: Bool = false) {
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

        let finalOrigin = computeOrigin(anchorTo: button)
        logPositioning(button: button, finalOrigin: finalOrigin)

        // Drop-in: start 12px above the resting position and 0 alpha, then
        // snap into place with a back-out (light overshoot). Kept short so the
        // animation stays clear of the menu bar region throughout. With Reduce
        // Motion on, it is a fade in place.
        let reduceMotion = self.reduceMotion
        var startOrigin = finalOrigin
        if !reduceMotion { startOrigin.y += 12 }
        panel.alphaValue = 0
        panel.setFrameOrigin(startOrigin)
        // Gate key-window eligibility BEFORE ordering front. Permission
        // popovers stay non-keyable so SwiftUI Menu interactions can't
        // trigger a focus grab (which left Allow stuck in its blue
        // "default action keyed" appearance after the menu closed).
        if let keyable = panel as? KeyablePanel {
            keyable.allowsKey = makeKey
        }
        panel.orderFrontRegardless()
        if makeKey {
            panel.makeKey()
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            if reduceMotion {
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            } else {
                ctx.duration = 0.26
                // Ease-out-back: slight overshoot at the end for a "drop" feel.
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
            }
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(finalOrigin)
        })
    }

    private func fittingContentSize() -> NSSize {
        hosting.view.layoutSubtreeIfNeeded()
        let intrinsic = hosting.view.fittingSize
        return NSSize(
            width: intrinsic.width  > 1 ? intrinsic.width  : Self.fallbackContentSize.width,
            height: intrinsic.height > 1 ? intrinsic.height : Self.fallbackContentSize.height
        )
    }

    func hide() {
        guard panel.isVisible else { return }
        let reduceMotion = self.reduceMotion
        let currentOrigin = panel.frame.origin
        var endOrigin = currentOrigin
        if !reduceMotion { endOrigin.y += 14 }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotion ? 0.1 : 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrameOrigin(endOrigin)
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            self?.panel.alphaValue = 1
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
        // Sit close under the menu bar like macOS Control Center popovers do.
        let originY = menuBarBottomY - size.height - 14
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

    // MARK: - Diagnostic logging

    /// Writes a one-line summary of every show() call to /tmp/nudge-position.log.
    /// Helps debug why the panel ends up in different places.
    private func logPositioning(button: NSStatusBarButton?, finalOrigin: NSPoint) {
        let url = URL(fileURLWithPath: "/tmp/nudge-position.log")
        let ts = ISO8601DateFormatter().string(from: Date())
        var lines: [String] = ["=== \(ts) ==="]
        if let button = button {
            if let win = button.window {
                let f = win.frame
                lines.append("  button.window.frame = (x=\(f.origin.x), y=\(f.origin.y), w=\(f.width), h=\(f.height))")
                if let screen = win.screen {
                    lines.append("  button.window.screen.frame = (x=\(screen.frame.origin.x), y=\(screen.frame.origin.y), w=\(screen.frame.width), h=\(screen.frame.height))")
                    lines.append("  button.window.screen.visibleFrame.maxY = \(screen.visibleFrame.maxY)")
                } else {
                    lines.append("  button.window.screen = nil")
                }
            } else {
                lines.append("  button.window = nil  ← anchoring will fall back")
            }
        } else {
            lines.append("  button = nil")
        }
        if let main = NSScreen.main {
            lines.append("  NSScreen.main.frame = (x=\(main.frame.origin.x), y=\(main.frame.origin.y), w=\(main.frame.width), h=\(main.frame.height))")
        }
        lines.append("  panel.size = (w=\(panel.frame.width), h=\(panel.frame.height))")
        lines.append("  finalOrigin = (x=\(finalOrigin.x), y=\(finalOrigin.y))")
        let blob = lines.joined(separator: "\n") + "\n"
        if let data = blob.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: url)
            }
        }
    }
}
