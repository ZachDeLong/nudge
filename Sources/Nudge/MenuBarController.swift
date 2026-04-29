import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private let queue: PromptQueue
    private let statusItem: NSStatusItem
    private let panel: PromptPanel
    private var currentPrompt: Prompt?
    private var queueDepth: Int = 0
    private var pulseTimer: Timer?
    private var keyMonitor: Any?

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
        panel.show(content: PopoverView(
            prompt: currentPrompt,
            queueDepth: queueDepth,
            onAllow: { [weak self] in self?.resolve(.allow) },
            onDeny:  { [weak self] in self?.resolve(.deny) }
        ))
    }

    private func subscribeToQueue() async {
        await queue.setOnHeadChange { [weak self] prompt, depth in
            DispatchQueue.main.async {
                self?.handleHead(prompt: prompt, depth: depth)
            }
        }
    }

    private func handleHead(prompt: Prompt?, depth: Int) {
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
            panel.hide()
        }
    }

    private func resolve(_ decision: Decision) {
        Task { await queue.resolveHead(with: decision) }
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
}

// MARK: - PromptPanel

/// A floating panel that always appears in the top-right corner of the active screen.
/// Doesn't anchor to the menu bar icon — solves the "popover appears in random places"
/// issue when the menu bar icon is hidden behind active app menus.
@MainActor
final class PromptPanel {
    private let panel: NSPanel
    private let hosting: NSHostingController<AnyView>

    var isVisible: Bool { panel.isVisible }

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

    func show(content: PopoverView) {
        hosting.rootView = AnyView(
            content
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.clear)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
        positionInTopRight()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func positionInTopRight() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
              ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let margin: CGFloat = 12
        let originX = visible.maxX - size.width - margin
        let originY = visible.maxY - size.height - margin
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }
}
