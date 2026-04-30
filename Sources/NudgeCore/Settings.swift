import Foundation

/// User preferences persisted at ~/.config/nudge/prefs.json. Both the menu
/// bar app and command-line helpers read this file, so toggles in the status
/// item menu apply to helper binaries on their next call.
public struct Prefs: Codable, Equatable {
    /// Master switch. When false, helpers fall back to Claude's native flow.
    public var enabled: Bool

    /// When true, helpers skip popping up if the frontmost macOS app is
    /// already a terminal/IDE.
    public var skipWhenTerminalFocused: Bool

    public static let `default` = Prefs(enabled: true, skipWhenTerminalFocused: true)

    public static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/nudge/prefs.json")
    }

    public init(enabled: Bool, skipWhenTerminalFocused: Bool) {
        self.enabled = enabled
        self.skipWhenTerminalFocused = skipWhenTerminalFocused
    }

    /// Loads from disk, falling back to defaults when the file is missing
    /// or malformed.
    public static func load(from url: URL = Self.url) -> Prefs {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(Prefs.self, from: data) else {
            return .default
        }
        return s
    }

    public func save(to url: URL = Self.url) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Bundle IDs of apps we consider "you're already at a terminal/IDE".
public enum FrontmostApp {
    public static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code.oss",
        "com.todesktop.230313mzl4w4u92",
        "com.todesktop.230313mzl4w4u92x",
    ]
}
