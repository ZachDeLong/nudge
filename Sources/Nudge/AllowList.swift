import Foundation

/// In-memory allow list for "Allow this session" decisions. Reset on app quit.
@MainActor
final class SessionAllowList {
    private var commands: Set<String> = []

    func add(command: String) {
        commands.insert(command)
    }

    func contains(command: String) -> Bool {
        commands.contains(command)
    }

    func clear() {
        commands.removeAll()
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
    @discardableResult
    static func addRule(_ rule: String) throws -> WriteResult {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .skippedEmpty }

        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url) else {
            throw WriteError.settingsMissing
        }
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WriteError.malformedJSON
        }

        var permissions = root["permissions"] as? [String: Any] ?? [:]
        var allow = permissions["allow"] as? [String] ?? []

        if allow.contains(trimmed) { return .alreadyPresent }
        allow.append(trimmed)
        permissions["allow"] = allow
        root["permissions"] = permissions

        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url, options: .atomic)
        return .added
    }
}
