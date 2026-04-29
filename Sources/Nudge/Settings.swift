import Foundation

/// User preferences persisted at ~/.config/nudge/prefs.json. Both the menu
/// bar app and the nudge-hook binary read this file, so toggles in the
/// status item menu apply to the hook on its next call.
struct Prefs: Codable, Equatable {
    /// Master switch. When false, the hook exits silently — Claude falls
    /// back to its normal terminal prompt for everything.
    var enabled: Bool

    /// When true, the hook skips popping up if the frontmost macOS app is
    /// already a terminal/IDE (Ghostty, iTerm2, Terminal.app, VS Code, etc.).
    /// You're already there — Claude's native prompt is fine.
    var skipWhenTerminalFocused: Bool

    static let `default` = Prefs(enabled: true, skipWhenTerminalFocused: true)

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/nudge/prefs.json")
    }

    /// Loads from disk, falling back to defaults when the file is missing
    /// or malformed (so a fresh install just works).
    static func load() -> Prefs {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(Prefs.self, from: data) else {
            return .default
        }
        return s
    }

    func save() {
        let dir = Self.url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: Self.url, options: .atomic)
        }
    }
}

/// Bundle IDs of apps we consider "you're already at a terminal/IDE" — when
/// these are frontmost and skipWhenTerminalFocused is on, the hook lets
/// Claude's native prompt handle the request instead of popping over.
enum FrontmostApp {
    static let terminalBundleIDs: Set<String> = [
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
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.todesktop.230313mzl4w4u92x",
    ]
}
