import Foundation

/// In-memory allow list for "Allow this session" decisions. Reset on app quit.
///
/// Keyed on tool *and* command. The command string alone is ambiguous across
/// families — `Bash` carries a shell command while `Edit`/`Write` carry a file
/// path — so a bare string key lets an allow granted for one tool satisfy a
/// prompt from another. Collisions are unlikely in practice; scoping the key
/// costs nothing and removes the question.
@MainActor
final class SessionAllowList {
    private struct Key: Hashable {
        let tool: String
        let command: String
    }

    private var allowed: Set<Key> = []

    func add(tool: String, command: String) {
        allowed.insert(Key(tool: tool, command: command))
    }

    func contains(tool: String, command: String) -> Bool {
        allowed.contains(Key(tool: tool, command: command))
    }

    func clear() {
        allowed.removeAll()
    }
}

/// Promotes a permission rule to ~/.claude/settings.json's permissions.allow
/// array so Claude Code natively skips the permission flow for it on
/// subsequent runs.
enum PersistentAllowList {
    enum WriteError: Error {
        case settingsMissing
        case malformedJSON
    }

    enum WriteResult {
        case added
        case alreadyPresent
        case skippedEmpty
    }

    /// Adds the given permission rule (e.g. `Bash(git push:*)`) to
    /// permissions.allow. Pass the full rule string — caller is responsible
    /// for ensuring it's a valid Claude Code permission rule.
    ///
    /// Note this reserializes the whole file, so key order and indentation get
    /// normalized. `.sortedKeys` is deliberate: without it Swift's dictionary
    /// ordering is arbitrary and every write would shuffle the file differently.
    /// Sorted at least makes the rewrite stable and diffable. The backup below
    /// is the real safety net — it also covers the read-modify-write race with
    /// a concurrent Claude Code write, which this can't otherwise detect.
    @discardableResult
    static func addRule(_ rule: String, at url: URL = defaultSettingsURL) throws -> WriteResult {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .skippedEmpty }

        guard let data = try? Data(contentsOf: url) else {
            throw WriteError.settingsMissing
        }
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WriteError.malformedJSON
        }

        var permissions = root["permissions"] as? [String: Any] ?? [:]
        var allow = permissions["allow"] as? [String] ?? []

        // Nothing to change — don't churn the file or spend a backup slot.
        if allow.contains(trimmed) { return .alreadyPresent }
        allow.append(trimmed)
        permissions["allow"] = allow
        root["permissions"] = permissions

        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        backUp(original: data, for: url)
        try out.write(to: url, options: .atomic)
        return .added
    }

    static var defaultSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /// Snapshots the pre-write bytes next to the file, matching the
    /// `settings.json.bak.<epoch>` convention `scripts/install-hook.sh` uses —
    /// including its keep-the-5-newest pruning, so the two writers don't
    /// accumulate backups against each other.
    ///
    /// Best-effort by design: failing to back up shouldn't block the write the
    /// user actually asked for.
    private static func backUp(original: Data, for url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = url.appendingPathExtension("bak.\(stamp)")
        guard (try? original.write(to: backup, options: .atomic)) != nil else { return }

        let prefix = url.lastPathComponent + ".bak."
        let dir = url.deletingLastPathComponent()
        guard let siblings = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

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
    }
}
