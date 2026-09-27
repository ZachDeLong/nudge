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

    /// When true (and Nudge has Accessibility access), ⏎ allows and esc
    /// denies a permission prompt from whatever app is in front.
    public var globalKeys: Bool

    /// When true, Nudge tells you when Claude finishes a turn while you're
    /// away from its terminal, with a box to reply and keep it going.
    public var finishedMessages: Bool

    public static let `default` = Prefs(enabled: true, skipWhenTerminalFocused: true)

    public static var url: URL {
        ConfigDir.url.appendingPathComponent("prefs.json")
    }

    public init(enabled: Bool, skipWhenTerminalFocused: Bool, globalKeys: Bool = true, finishedMessages: Bool = true) {
        self.enabled = enabled
        self.skipWhenTerminalFocused = skipWhenTerminalFocused
        self.globalKeys = globalKeys
        self.finishedMessages = finishedMessages
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, skipWhenTerminalFocused, globalKeys, finishedMessages
    }

    /// Keys added later are optional, so an older prefs.json keeps its
    /// other settings instead of failing to decode and resetting them all.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        skipWhenTerminalFocused = try c.decode(Bool.self, forKey: .skipWhenTerminalFocused)
        globalKeys = try c.decodeIfPresent(Bool.self, forKey: .globalKeys) ?? true
        finishedMessages = try c.decodeIfPresent(Bool.self, forKey: .finishedMessages) ?? true
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

    /// Apps where ⏎ and esc belong to an agent's own prompt: the terminals
    /// and IDEs above, Codex's desktop apps, and the Claude app (its prompt
    /// card answers to esc, and ⏎ sends a message). Nudge's global keys stand
    /// down while one is in front.
    /// Where a Claude Code session shows itself: any terminal or IDE, plus
    /// the Claude app for sessions running in it.
    public static func sessionUIBundleIDs(entrypoint: String?) -> Set<String> {
        entrypoint == "claude-desktop"
            ? terminalBundleIDs.union(["com.anthropic.claudefordesktop"])
            : terminalBundleIDs
    }

    public static let ownPromptBundleIDs: Set<String> =
        terminalBundleIDs.union(["com.openai.codex", "com.openai.chat", "com.anthropic.claudefordesktop"])
}
