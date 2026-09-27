import Foundation

/// Edits to Claude Code's `~/.claude/settings.json`.
public enum ClaudeSettings {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// The hook command `scripts/install-hook.sh` writes.
    public static let nudgeHookCommand = "/Applications/Nudge.app/Contents/MacOS/nudge-hook"

    /// Snapshots the pre-write bytes next to the file, matching the
    /// `settings.json.bak.<epoch>` convention `scripts/install-hook.sh` uses,
    /// including its keep-the-5-newest pruning, so the writers don't pile up
    /// backups against each other. Best-effort: returns false if the snapshot
    /// couldn't be written.
    @discardableResult
    public static func backUp(original: Data, for url: URL) -> Bool {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = url.appendingPathExtension("bak.\(stamp)")
        guard (try? original.write(to: backup, options: .atomic)) != nil else { return false }

        let prefix = url.lastPathComponent + ".bak."
        let dir = url.deletingLastPathComponent()
        guard let siblings = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return true }

        let backups = siblings
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da > db
            }
        for stale in backups.dropFirst(5) {
            try? FileManager.default.removeItem(at: stale)
        }
        return true
    }

    public enum MigrationResult: Equatable {
        /// The PermissionRequest entry was added (after a backup).
        case added
        /// It was already there; nothing written.
        case alreadyPresent
        /// Done on an earlier launch; settings.json not read.
        case alreadyMigrated
        /// Nudge's PreToolUse hook isn't in settings.json (not installed, or
        /// uninstalled), so there's nothing to extend.
        case notInstalled
        case failed(String)
    }

    /// Adds Nudge's PermissionRequest hook to installs from before it
    /// existed. `nudge-update` swaps the app bundle but never touches
    /// settings.json, and the updater that runs is the old one, so the new
    /// app does this itself on launch.
    ///
    /// Only when Nudge's PreToolUse hook is already wired (so it never
    /// installs Nudge into a settings file that doesn't have it), and only
    /// once: `marker` records that it ran, so taking the entry out by hand
    /// sticks. Everything else in the file is kept; like "Always allow" it's
    /// rewritten with sorted keys, after a backup.
    public static func addPermissionRequestHook(settings link: URL = defaultURL, marker: URL) -> MigrationResult {
        let fm = FileManager.default
        if fm.fileExists(atPath: marker.path) { return .alreadyMigrated }
        // Write through a symlinked settings.json (dotfile repos) instead of
        // replacing the link with a plain file.
        let url = link.resolvingSymlinksInPath()
        guard let data = try? Data(contentsOf: url) else { return .notInstalled }
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failed("\(url.path) isn't a JSON object")
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        func runsNudgeHook(_ entries: Any?) -> Bool {
            guard let entries = entries as? [[String: Any]] else { return false }
            return entries.contains { entry in
                (entry["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == nudgeHookCommand }
            }
        }

        guard runsNudgeHook(hooks["PreToolUse"]) else { return .notInstalled }
        if runsNudgeHook(hooks["PermissionRequest"]) {
            writeMarker(marker)
            return .alreadyPresent
        }
        if hooks["PermissionRequest"] != nil, !(hooks["PermissionRequest"] is [[String: Any]]) {
            return .failed("hooks.PermissionRequest in \(url.path) isn't a list")
        }

        var entries = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        entries.append([
            "matcher": "*",
            "hooks": [["type": "command", "command": nudgeHookCommand]],
        ])
        hooks["PermissionRequest"] = entries
        root["hooks"] = hooks

        do {
            let out = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            guard backUp(original: data, for: url) else {
                return .failed("couldn't back up \(url.path); left it alone")
            }
            try out.write(to: url, options: .atomic)
        } catch {
            return .failed("couldn't write \(url.path): \(error)")
        }
        writeMarker(marker)
        return .added
    }

    private static func writeMarker(_ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("PermissionRequest hook checked \(Date())\n".utf8).write(to: url, options: .atomic)
    }
}
