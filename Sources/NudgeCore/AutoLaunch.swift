import Foundation

/// Marker file that suppresses hook-driven auto-launch of Nudge.
///
/// Without it, quitting from the menu doesn't stick: the agent hook fires on
/// every tool call, and `NudgeClient.locatePort` would `open -ga Nudge` right
/// back into the menu bar before the user's hand left the trackpad.
///
/// Written on graceful quit, cleared whenever Nudge next starts. So Quit means
/// quit, and relaunching by any route — Spotlight, /Applications, `open -ga
/// Nudge`, `make install` — restores auto-launch without a separate toggle.
///
/// A crash or `pkill` never runs the quit path, so unexpected exits still
/// auto-recover on the next hook call. That asymmetry is the point: deliberate
/// quits are honored, accidental deaths are healed.
public enum AutoLaunch {
    public static var markerURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/nudge/no-autolaunch")
    }

    /// Called from `applicationWillTerminate`.
    public static func suppress(at url: URL = markerURL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data().write(to: url, options: .atomic)
    }

    /// Called from `applicationDidFinishLaunching`, however the app was started.
    public static func allow(at url: URL = markerURL) {
        try? FileManager.default.removeItem(at: url)
    }

    public static func isSuppressed(at url: URL = markerURL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
