import Foundation
import NudgeCore

/// In-memory allow list for "Allow this session" decisions. Reset on app quit.
///
/// Keyed on session, agent, tool *and* command. The session keeps an allow
/// from spilling into other sessions and projects that run the same command.
/// The command string alone is ambiguous across families — `Bash` carries a
/// shell command while `Edit`/`Write` carry a file path — so a bare string
/// key lets an allow granted for one tool satisfy a prompt from another. The
/// agent is in the key so allowing a command for Codex doesn't also allow it
/// for Claude, or the other way round.
@MainActor
final class SessionAllowList {
    private struct Key: Hashable {
        let session: String
        let agent: String
        let tool: String
        let command: String

        init(_ prompt: Prompt) {
            session = prompt.sessionId
            agent = prompt.agent ?? "claude"
            tool = prompt.tool
            command = prompt.command
        }
    }

    private var allowed: Set<Key> = []

    func add(_ prompt: Prompt) {
        allowed.insert(Key(prompt))
    }

    func contains(_ prompt: Prompt) -> Bool {
        allowed.contains(Key(prompt))
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
    static func addRule(_ rule: String, at link: URL = defaultSettingsURL) throws -> WriteResult {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .skippedEmpty }
        // Write through a symlinked settings.json (dotfile repos) instead of
        // replacing the link with a plain file.
        let url = link.resolvingSymlinksInPath()

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

    static var defaultSettingsURL: URL { ClaudeSettings.defaultURL }

    /// Best-effort by design: failing to back up shouldn't block the write the
    /// user actually asked for.
    private static func backUp(original: Data, for url: URL) {
        ClaudeSettings.backUp(original: original, for: url)
    }
}
