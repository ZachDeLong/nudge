import AppKit
import NudgeCore

/// Brings a session's own window to the front: the exact tab where the
/// terminal can say which one runs it, otherwise just the app. Terminal and
/// iTerm2 name each tab's tty. Ghostty (1.3) doesn't, so its terminals are
/// matched by working directory, and when several share it, by briefly
/// titling the session's tty and looking for that title.
///
/// Talking to another app over Apple Events asks you once (Automation in
/// Privacy & Security). If that's refused or anything fails, the app is
/// still brought forward.
@MainActor
enum SessionJump {
    /// The session's app for display ("Ghostty"), or nil when Nudge can't
    /// tell which app it is.
    static func appName(for prompt: Prompt) -> String? {
        guard let id = hostApp(for: prompt),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func go(to prompt: Prompt) {
        guard let app = hostApp(for: prompt) else { return }
        let focused: Bool
        switch app {
        case "com.apple.Terminal":     focused = prompt.tty.map(terminalApp) ?? false
        case "com.googlecode.iterm2":  focused = prompt.tty.map(iTerm) ?? false
        case "com.mitchellh.ghostty":  focused = ghostty(cwd: prompt.cwd, tty: prompt.tty)
        default:                       focused = false
        }
        if !focused {
            NSRunningApplication.runningApplications(withBundleIdentifier: app).first?.activate()
        }
    }

    /// Where the session lives: the app that launched it, or for a Claude
    /// app session with no bundle id recorded, the Claude app.
    private static func hostApp(for prompt: Prompt) -> String? {
        if let app = prompt.hostApp, !app.isEmpty { return app }
        return prompt.entrypoint == "claude-desktop" ? "com.anthropic.claudefordesktop" : nil
    }

    // MARK: - Terminal, iTerm2

    private static func terminalApp(tty: String) -> Bool {
        run("""
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(escaped(tty))" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """)?.booleanValue ?? false
    }

    private static func iTerm(tty: String) -> Bool {
        run("""
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(escaped(tty))" then
                            select w
                            tell t to select
                            tell s to select
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """)?.booleanValue ?? false
    }

    // MARK: - Ghostty

    private static func ghostty(cwd: String, tty: String?) -> Bool {
        // One terminal in the session's folder: that's it.
        let count = run("""
        tell application "Ghostty"
            set hits to every terminal whose working directory is "\(escaped(cwd))"
            if (count of hits) is 1 then
                focus (item 1 of hits)
                activate
            end if
            return count of hits
        end tell
        """)?.int32Value ?? 0
        if count == 1 { return true }
        guard let tty else { return false }

        // Several (or a folder Ghostty reports differently): title the
        // session's tty with a marker, find the terminal showing it, then
        // put its old title back.
        guard let before = run("""
        tell application "Ghostty" to get {id, name} of every terminal
        """), before.numberOfItems == 2,
              let ids = before.atIndex(1), let names = before.atIndex(2) else { return false }
        var oldTitles: [String: String] = [:]
        if ids.numberOfItems > 0 {
            for i in 1...ids.numberOfItems {
                if let id = ids.atIndex(i)?.stringValue { oldTitles[id] = names.atIndex(i)?.stringValue ?? "" }
            }
        }
        let marker = "nudge-jump-" + UUID().uuidString.prefix(8)
        guard setTitle(marker, tty: tty) else { return false }
        var found: String?
        for _ in 0..<10 where found == nil {
            usleep(50_000)
            found = run("""
            tell application "Ghostty"
                set hits to every terminal whose name is "\(marker)"
                if (count of hits) is 0 then return ""
                focus (item 1 of hits)
                activate
                return id of (item 1 of hits)
            end tell
            """)?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        }
        _ = setTitle(found.flatMap { oldTitles[$0] } ?? "", tty: tty)
        return found != nil
    }

    /// Sets the terminal title on `tty` (OSC 2). The session's own program
    /// owns the screen; a title sequence doesn't touch what's on it.
    private static func setTitle(_ title: String, tty: String) -> Bool {
        guard tty.hasPrefix("/dev/tty") else { return false }
        let fd = open(tty, O_WRONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let clean = title.filter { $0 != "\u{07}" && $0 != "\u{1B}" }
        let bytes = Array("\u{1B}]2;\(clean)\u{07}".utf8)
        return write(fd, bytes, bytes.count) == bytes.count
    }

    // MARK: - AppleScript

    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("Nudge: session jump script failed: \(error)") }
        return error == nil ? result : nil
    }

    private static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
