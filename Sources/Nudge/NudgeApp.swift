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
    private let activityStore = AgentActivityStore()
    private var server: PromptServer?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Dev mode: render popover states to PNG and exit. Runs before the
        // server or status item exist, so it never disturbs a live Nudge.
        if let dir = PreviewRenderer.requestedDirectory() {
            Task { @MainActor in
                do {
                    try PreviewRenderer.renderAll(to: dir)
                    print("Wrote previews to \(dir.path)")
                    exit(0)
                } catch {
                    FileHandle.standardError.write("Preview render failed: \(error)\n".data(using: .utf8)!)
                    exit(1)
                }
            }
            return
        }

        // However we got here, Nudge is wanted again — clear any suppression
        // left behind by a previous Quit so hooks can auto-launch as normal.
        AutoLaunch.allow()

        Task { @MainActor in
            self.menuBar = MenuBarController(queue: queue, activityStore: activityStore)
        }

        Task {
            // An isolated instance (NUDGE_CONFIG_DIR set) leaves 19283 to the
            // user's real Nudge; hooks find it through its own port file.
            if ConfigDir.isOverridden {
                do {
                    try await self.bringUpServer(port: 0)
                } catch {
                    NSLog("Nudge: server failed to start at all. \(error)")
                }
                return
            }
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
        _ = try TokenFile.ensure()
        let testAPI = TestAPI.isEnabled
        if testAPI {
            NSLog("Nudge: e2e test API enabled (config dir \(ConfigDir.url.path))")
        }
        let server = PromptServer(queue: queue, activityStore: activityStore, port: port, testAPIEnabled: testAPI)
        try await server.start()
        let bound = await server.boundPort
        try PortFile.write(port: bound)
        self.server = server
        NSLog("Nudge: server listening on \(bound)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { await server?.stop() }
        try? FileManager.default.removeItem(at: PortFile.defaultURL)
        // Only reached on a deliberate quit — a crash or `pkill` skips this, so
        // unexpected exits still auto-recover on the next hook call.
        AutoLaunch.suppress()
    }
}

/// Gate for the server's `/test/*` endpoints, which read the queue and answer
/// prompts over HTTP for the e2e harness (`make e2e`). Answering without a
/// click is exactly what Nudge must never allow on a real install, so this
/// takes two things a normal launch never has: `NUDGE_TEST_API=1` *and* a
/// `NUDGE_CONFIG_DIR` override. The endpoints still require the bearer token,
/// and the harness's token lives in its own temp config dir.
enum TestAPI {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["NUDGE_TEST_API"] == "1" && ConfigDir.isOverridden
    }
}
