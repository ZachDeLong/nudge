import Foundation

/// Where Nudge keeps its port, token, prefs, patterns, and session files:
/// `~/.config/nudge`, unless `NUDGE_CONFIG_DIR` points somewhere else.
///
/// The override exists so the end-to-end harness (`make e2e`) can run a second,
/// fully isolated Nudge next to the user's real one — its own port, token,
/// patterns, and prefs — with hooks pointed at it by the same variable. The
/// app and every helper resolve paths through here, so they always agree.
public enum ConfigDir {
    public static let environmentKey = "NUDGE_CONFIG_DIR"

    public static var url: URL {
        if let override = overridePath {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/nudge", isDirectory: true)
    }

    /// True when `NUDGE_CONFIG_DIR` is set, i.e. this process belongs to a
    /// harness-managed instance rather than the user's install.
    public static var isOverridden: Bool { overridePath != nil }

    private static var overridePath: String? {
        guard let raw = ProcessInfo.processInfo.environment[environmentKey],
              !raw.isEmpty else { return nil }
        return (raw as NSString).expandingTildeInPath
    }
}
