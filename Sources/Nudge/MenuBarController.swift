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
            panel.hide()
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
            startClickMonitor()
            renderAndShow()
        } else {
            stopPulse()
            stopKeyMonitor()
            stopClickMonitor()
            panel.hide()
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
            // If the click is outside the panel, deny.
            let panelFrame = self.panel.windowFrame
            let mouseLocation = NSEvent.mouseLocation
            // Also ignore clicks on the menu bar icon itself.
            let buttonScreenFrame = self.statusItem.button?.window?.frame ?? .zero
            if !panelFrame.contains(mouseLocation) && !buttonScreenFrame.contains(mouseLocation) {
                DispatchQueue.main.async { self.resolve(.deny) }
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

    func show(content: PopoverView, anchorTo button: NSStatusBarButton?) {
        hosting.rootView = AnyView(
            content
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )

        let finalOrigin = computeOrigin(anchorTo: button)
        // Slide-in: start 18px above and at 0 alpha, animate to final.
        var startOrigin = finalOrigin
        startOrigin.y += 18
        panel.alphaValue = 0
        panel.setFrameOrigin(startOrigin)
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(finalOrigin)
        })
    }

    func hide() {
        guard panel.isVisible else { return }
        let currentOrigin = panel.frame.origin
        var endOrigin = currentOrigin
        endOrigin.y += 12
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
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

        let originY = screen.visibleFrame.maxY - size.height - 4
        return NSPoint(x: originX, y: originY)
    }

    private func originTopRight() -> NSPoint {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
              ?? NSScreen.main else { return .zero }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let margin: CGFloat = 12
        return NSPoint(x: visible.maxX - size.width - margin,
                       y: visible.maxY - size.height - margin)
    }
}
