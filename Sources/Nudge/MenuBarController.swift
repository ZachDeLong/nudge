import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private let queue: PromptQueue
    private let statusItem: NSStatusItem
    private let panel: PromptPanel
    private let sessionAllow = SessionAllowList()
    private var currentPrompt: Prompt?
    private var queueDepth: Int = 0
    private var pulseTimer: Timer?
    private var keyMonitor: Any?
    private var clickMonitor: Any?

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
            button.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Nudge")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(toggleManually(_:))
        }
    }

    @objc private func toggleManually(_ sender: AnyObject?) {
        if panel.isVisible {
            dismissPanel()
        } else {
            renderAndShow()
        }
    }

    private func renderAndShow() {
        panel.show(
            content: PopoverView(
                prompt: currentPrompt,
                queueDepth: queueDepth,
                onAllow: { [weak self] in self?.resolve(.allow) },
                onDeny:  { [weak self] in self?.resolve(.deny) },
                onAlwaysAllow: { [weak self] in self?.alwaysAllowCurrent() },
                onSessionAllow: { [weak self] in self?.sessionAllowCurrent() }
            ),
            anchorTo: statusItem.button
        )
        // Click-outside dismiss applies to every visible state of the panel,
        // including the idle "Nudge is ready" view. The handler decides whether
        // to deny (live prompt) or just hide (idle).
        startClickMonitor()
    }

    private func dismissPanel() {
        stopClickMonitor()
        panel.hide()
    }

    private func subscribeToQueue() async {
        await queue.setOnHeadChange { [weak self] prompt, depth in
            DispatchQueue.main.async {
                self?.handleHead(prompt: prompt, depth: depth)
            }
        }
    }

    private func handleHead(prompt: Prompt?, depth: Int) {
        // Auto-resolve via session allow list before any UI.
        if let prompt = prompt, sessionAllow.contains(command: prompt.command) {
            Task { await queue.resolveHead(with: .allow) }
            return
        }

        self.currentPrompt = prompt
        self.queueDepth = depth

        let img = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Nudge")
        img?.isTemplate = (prompt == nil)
        statusItem.button?.image = img
        statusItem.button?.contentTintColor = (prompt == nil) ? nil : NSColor.systemRed

        if prompt != nil {
            startPulse()
            startKeyMonitor()
            renderAndShow()
        } else {
            stopPulse()
            stopKeyMonitor()
            dismissPanel()
        }
    }

    // MARK: - Decision handlers

    private func resolve(_ decision: Decision) {
        Task { await queue.resolveHead(with: decision) }
    }

    private func alwaysAllowCurrent() {
        guard let prompt = currentPrompt else { return }
        do {
            _ = try PersistentAllowList.add(command: prompt.command)
        } catch {
            NSLog("Nudge: failed to write Always Allow: \(error)")
        }
        // Also session-allow so this current session benefits immediately
        // (Claude Code may cache settings.json at session start).
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
                if self.currentPrompt != nil {
                    self.resolve(.deny)
                } else {
                    self.dismissPanel()
                }
            }
        }
    }

    private func stopClickMonitor() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }
}

// MARK: - PromptPanel

@MainActor
final class PromptPanel {
    private let panel: NSPanel
    private let hosting: NSHostingController<AnyView>

    var isVisible: Bool { panel.isVisible }
    var windowFrame: NSRect { panel.frame }

    init() {
        self.hosting = NSHostingController(rootView: AnyView(EmptyView()))
        let size = NSSize(width: 380, height: 200)
        self.panel = NSPanel(
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
    /// Width matches PopoverView's `.frame(width: 380)`. Height is generous;
    /// the real height comes from `hosting.view.fittingSize` in show().
    private static let fallbackContentSize = NSSize(width: 380, height: 200)

    func show(content: PopoverView, anchorTo button: NSStatusBarButton?) {
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
        panel.orderFrontRegardless()

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
