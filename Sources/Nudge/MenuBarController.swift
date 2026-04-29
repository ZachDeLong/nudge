import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private let queue: PromptQueue
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var currentPrompt: Prompt?
    private var queueDepth: Int = 0
    private var pulseTimer: Timer?
    private var keyMonitor: Any?

    init(queue: PromptQueue) {
        self.queue = queue
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()
        configureStatusItem()
        configurePopover()
        Task { await self.subscribeToQueue() }
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Nudge")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 200)
        renderPopoverContent()
    }

    private func renderPopoverContent() {
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                prompt: currentPrompt,
                queueDepth: queueDepth,
                onAllow: { [weak self] in self?.resolve(.allow) },
                onDeny:  { [weak self] in self?.resolve(.deny) }
            )
        )
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
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

        renderPopoverContent()

        if prompt != nil {
            startPulse()
            startKeyMonitor()
            if !popover.isShown, let button = statusItem.button {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        } else {
            stopPulse()
            stopKeyMonitor()
            if popover.isShown { popover.performClose(nil) }
        }
    }

    private func resolve(_ decision: Decision) {
        Task { await queue.resolveHead(with: decision) }
    }

    // MARK: - Pulse animation

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
            guard self?.popover.isShown == true else { return }
            if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
                DispatchQueue.main.async { self?.resolve(.allow) }
            } else if event.keyCode == 53 { // Escape
                DispatchQueue.main.async { self?.resolve(.deny) }
            }
        }
    }

    private func stopKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}
