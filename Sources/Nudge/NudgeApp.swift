import SwiftUI
import AppKit
import NudgeCore

@main
struct NudgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let queue = PromptQueue()
    private var server: PromptServer?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        Task { @MainActor in
            self.menuBar = MenuBarController(queue: queue)
        }

        Task {
            do {
                try await self.bringUpServer(port: 19283)
            } catch {
                NSLog("Nudge: port 19283 unavailable, falling back to random port. \(error)")
                do {
                    try await self.bringUpServer(port: 0)
                } catch {
                    NSLog("Nudge: server failed to start at all. \(error)")
                }
            }
        }
    }

    private func bringUpServer(port: UInt16) async throws {
        let token = try TokenFile.readOrCreate()
        let server = PromptServer(queue: queue, port: port, authToken: token)
        try await server.start()
        let bound = await server.boundPort
        try PortFile.write(port: bound)
        self.server = server
        NSLog("Nudge: server listening on \(bound)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { await server?.stop() }
        try? FileManager.default.removeItem(at: PortFile.defaultURL)
    }
}
