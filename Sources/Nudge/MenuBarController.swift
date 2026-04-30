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
    @Published var error: String?
}

@MainActor
final class MenuBarController: NSObject {
    private let queue: PromptQueue
    private let statusItem: NSStatusItem
    private let panel: PromptPanel
    private let sessionAllow = SessionAllowList()
    private var currentPrompt: Prompt?
    private var queueDepth: Int = 0
    private var pulseTimer: Timer?
    private var agentRefreshTimer: Timer?
    private var agentRefreshTask: Task<Void, Never>?
    private var agentRefreshInFlight = false
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var settings: Prefs = .load()
    private let agentChat = AgentChatStore()

    init(queue: PromptQueue) {
        self.queue = queue
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.panel = PromptPanel()
        super.init()
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

    /// Updates the menu bar icon based on enabled state and current prompt.
    private func refreshIcon() {
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
        refreshIcon()
        // If Nudge was paused while a prompt was up, resolve it so callers
        // unblock instead of waiting on a popover that won't appear.
        if !settings.enabled, currentPrompt != nil {
            resolve(currentPrompt?.resolvedKind == .ask ? .cancel : .deny)
        }
        // Re-render the popover so the idle UI reflects the new state.
        if panel.isVisible, currentPrompt == nil {
            renderAndShow()
        }
    }

    private func toggleSkipTerminalAndRefresh() {
        settings.skipWhenTerminalFocused.toggle()
        settings.save()
        if panel.isVisible, currentPrompt == nil {
            renderAndShow()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func buildPopoverView() -> PopoverView {
        PopoverView(
            prompt: currentPrompt,
            queueDepth: queueDepth,
            prefs: settings,
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
        let isAsk = currentPrompt?.resolvedKind == .ask
        let hasChat = currentPrompt == nil && agentChat.detail != nil
        panel.show(
            content: buildPopoverView(),
            anchorTo: statusItem.button,
            makeKey: isAsk || hasChat
        )
        // Click-outside dismiss applies to every visible state of the panel.
        startClickMonitor()
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
        stopPulse()
        stopAgentRefresh()
        panel.hide()
    }

    private func startAgentRefresh() {
        stopAgentRefresh()
        agentRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAgentSessions(selecting: self?.agentChat.detail?.id, isPolling: true)
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
           sessionAllow.contains(command: prompt.command) {
            Task { await queue.resolveHead(with: .allow) }
            return
        }

        self.currentPrompt = prompt
        self.queueDepth = depth
        refreshIcon()

        if let prompt = prompt {
            // Global Enter/Esc shortcuts only make sense for permission
            // prompts. For asks, the popover is key (TextEditor receives
            // keystrokes) and dismissal is via the in-popover buttons.
            if prompt.resolvedKind == .permission {
                startKeyMonitor()
            } else {
                stopKeyMonitor()
            }
            // Pulse is now driven by popover visibility, not prompt presence
            // — see renderAndShow / dismissPanel.
            renderAndShow()
        } else {
            stopKeyMonitor()
            dismissPanel()
        }
    }

    // MARK: - Decision handlers

    private func resolve(_ decision: Decision) {
        Task { await queue.resolveHead(with: decision) }
    }

    private func submitAskText(_ text: String) {
        let response = DecisionResponse(decision: .text, text: text)
        Task { await queue.resolveHead(with: response) }
    }

    private func alwaysAllowCurrent() {
        guard let prompt = currentPrompt else { return }
        // Prefer the matched pattern (e.g. `Bash(git push:*)`) so Claude auto-
        // allows the whole class of commands going forward, not just this exact
        // string. Fall back to `Bash(<exact>)` if no matched pattern was sent
        // (older hook builds, or direct test-popup posts without one).
        let rule = prompt.matchedPattern ?? "Bash(\(prompt.command))"
        do {
            _ = try PersistentAllowList.addRule(rule)
        } catch {
            NSLog("Nudge: failed to write Always Allow: \(error)")
        }
        // Also session-allow this exact command so it doesn't re-prompt within
        // the same Claude Code session (Claude caches settings.json at start).
        sessionAllow.add(command: prompt.command)
        resolve(.allow)
    }

    private func sessionAllowCurrent() {
        guard let prompt = currentPrompt else { return }
        sessionAllow.add(command: prompt.command)
        resolve(.allow)
    }

    // MARK: - Pulse

    private func startPulse() {
        stopPulse()
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] _ in
            guard let button = self?.statusItem.button else { return }
            let now = Date().timeIntervalSinceReferenceDate
            let phase = (sin(now * 4.2) + 1) / 2
            button.alphaValue = 0.55 + phase * 0.45
        }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
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

    /// User-initiated refreshes (button clicks, picker selection, end, rename)
    /// cancel any in-flight refresh so they win the race against polling.
    /// Polling refreshes (`isPolling: true`) skip if a refresh is already
    /// running — otherwise back-to-back polling ticks could keep cancelling
    /// each other on a slow tmux capture and the store would never update.
    ///
    /// Failure handling is intentionally conservative: a transient
    /// `backend.detail` error (which happens for a few hundred ms after tmux
    /// state changes — kill, rename, etc.) shouldn't blank the chat UI. We
    /// keep the prior detail in place and let the next successful refresh
    /// replace it.
    private func refreshAgentSessions(selecting sessionID: String? = nil, isPolling: Bool = false) {
        if isPolling {
            if agentRefreshInFlight { return }
        } else {
            agentRefreshTask?.cancel()
        }
        agentRefreshInFlight = true
        agentRefreshTask = Task { [weak self] in
            let result = await Task.detached { () async -> Result<([AgentSessionSummary], AgentSessionDetail?), Error> in
                do {
                    let backend = TmuxAgentBackend()
                    let sessions = try backend.listSessions()
                    let selected = sessionID.flatMap { id in sessions.first(where: { $0.id == id }) }
                        ?? sessions.first
                    var detail: AgentSessionDetail? = nil
                    if let selected {
                        // Soft-fail on detail: a transient capture-pane miss
                        // shouldn't propagate up as a full-failure.
                        detail = try? backend.detail(for: selected)
                    }
                    return .success((sessions, detail))
                } catch {
                    return .failure(error)
                }
            }.value

            if Task.isCancelled {
                await MainActor.run { self?.agentRefreshInFlight = false }
                return
            }
            await MainActor.run {
                guard let self else { return }
                self.agentRefreshInFlight = false
                switch result {
                case .success(let payload):
                    self.agentChat.sessions = payload.0
                    // Only overwrite detail when we actually have one. Keeping
                    // the prior detail prevents the transcript from blanking
                    // mid-rename or mid-end while the next poll catches up.
                    if let detail = payload.1 {
                        self.agentChat.detail = detail
                    } else if !payload.0.contains(where: { $0.id == self.agentChat.detail?.id }) {
                        // Selected session is no longer in the list; clear it.
                        self.agentChat.detail = nil
                    }
                    self.agentChat.error = nil
                case .failure(let error):
                    // listSessions itself failed (rare). Keep the stale UI;
                    // surface the error so the user can see what happened.
                    self.agentChat.error = String(describing: error)
                }
            }
        }
    }

    private func sendAgentMessage(_ text: String, to sessionID: String) {
        Task { [weak self] in
            let result = await Task.detached { () async -> Result<AgentSessionDetail, Error> in
                do {
                    let backend = TmuxAgentBackend()
                    let sessions = try backend.listSessions()
                    guard let session = sessions.first(where: { $0.id == sessionID }) else {
                        throw TmuxAgentError.sessionMissing(sessionID)
                    }
                    try backend.send(text, to: session)
                    // Brief settle so a fast Claude reply lands in the first
                    // snapshot. The polling timer picks up everything after.
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    return .success(try backend.detail(for: session))
                } catch {
                    return .failure(error)
                }
            }.value

            await MainActor.run {
                guard let self else { return }
                switch result {
                case .success(let detail):
                    self.agentChat.detail = detail
                    self.agentChat.error = nil
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
    var windowFrame: NSRect { panel.frame }

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

    /// Swaps the SwiftUI root view without re-running positioning or the
    /// drop-in animation. Used when the popover content changes mid-display
    /// (e.g., chat-mirror auto-refresh) so the panel doesn't re-animate.
    func updateContent(_ content: PopoverView) {
        guard panel.isVisible else { return }
        hosting.rootView = AnyView(
            content
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
    }

    func show(content: PopoverView, anchorTo button: NSStatusBarButton?, makeKey: Bool = false) {
        hosting.rootView = AnyView(
            content
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )

        // Ask SwiftUI for the actual intrinsic size after layout. Using
        // fittingSize keeps the panel matched to the rendered content (so
        // centering math is honest) and lets the height adapt to whether a
        // command box / queue badge is showing.
        hosting.view.layoutSubtreeIfNeeded()
        let intrinsic = hosting.view.fittingSize
        let size = NSSize(
            width: intrinsic.width  > 1 ? intrinsic.width  : Self.fallbackContentSize.width,
            height: intrinsic.height > 1 ? intrinsic.height : Self.fallbackContentSize.height
        )
        panel.setContentSize(size)

        let finalOrigin = computeOrigin(anchorTo: button)
        logPositioning(button: button, finalOrigin: finalOrigin)

        // Drop-in: start 12px above the resting position and 0 alpha, then
        // snap into place with a back-out (light overshoot). Kept short so the
        // animation stays clear of the menu bar region throughout.
        var startOrigin = finalOrigin
        startOrigin.y += 12
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
            ctx.duration = 0.26
            // Ease-out-back: slight overshoot at the end for a "drop" feel.
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(finalOrigin)
        })
    }

    func hide() {
        guard panel.isVisible else { return }
        let currentOrigin = panel.frame.origin
        var endOrigin = currentOrigin
        endOrigin.y += 14
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
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
        guard let button = button,
              let buttonWindow = button.window else { return nil }
        let buttonFrame = buttonWindow.frame
        guard buttonFrame.width > 1, buttonFrame.height > 1 else { return nil }
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(buttonFrame) })
              ?? NSScreen.main else { return nil }

        let size = panel.frame.size
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
