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

/// Promotes a command to ~/.claude/settings.json's permissions.allow array
/// so Claude Code natively skips the permission flow for it on subsequent runs.
enum PersistentAllowList {
    enum WriteError: Error {
        case settingsMissing
        case malformedJSON
    }

    /// Adds `Bash(<exact command>)` to permissions.allow. Returns true if added,
    /// false if already present.
    @discardableResult
    static func add(command: String) throws -> Bool {
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

        let rule = "Bash(\(command))"
        if allow.contains(rule) {
            return false
        }
        allow.append(rule)
        permissions["allow"] = allow
        root["permissions"] = permissions

        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url, options: .atomic)
        return true
    }
}
