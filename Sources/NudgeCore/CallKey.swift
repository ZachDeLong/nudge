import CryptoKit
import Foundation

/// Names one tool call across Claude Code's hook events.
///
/// PreToolUse, PermissionRequest and PostToolUse all carry the same
/// `session_id`, `tool_name` and `tool_input` for a call (checked against
/// Claude Code 2.1.283), but PermissionRequest has no `tool_use_id`. So the
/// join key is a digest of those three, with the input's keys sorted so their
/// order in the JSON can't matter.
///
/// AskUserQuestion is the exception: PostToolUse's input also carries the
/// `answers` (and `annotations`) it was answered with, so those are left out.
public enum CallKey {
    public static func make(sessionID: String, toolName: String, toolInput: Any?) -> String {
        var toolInput = toolInput
        if toolName == "AskUserQuestion", var fields = toolInput as? [String: Any] {
            fields["answers"] = nil
            fields["annotations"] = nil
            toolInput = fields
        }
        let input = toolInput.flatMap {
            try? JSONSerialization.data(
                withJSONObject: $0,
                options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
            )
        } ?? Data("null".utf8)
        var hasher = SHA256()
        hasher.update(data: Data(sessionID.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(toolName.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: input)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Pattern prompts allowed in the last few seconds, by call key.
///
/// A PreToolUse allow doesn't get past an ask rule: Claude Code still asks,
/// and fires PermissionRequest for the same call right after. Without this,
/// allowing a pattern prompt in Nudge would be followed by a second popover
/// for the same command. Each entry answers one PermissionRequest and then
/// goes, and entries expire, so a later identical call asks again.
public struct RecentAllows {
    public let ttl: TimeInterval
    private var entries: [String: Date] = [:]

    public init(ttl: TimeInterval = 30) {
        self.ttl = ttl
    }

    public mutating func record(_ key: String, at now: Date = Date()) {
        prune(now)
        entries[key] = now
    }

    /// True (and forgets the entry) if `key` was allowed within the TTL.
    public mutating func consume(_ key: String, at now: Date = Date()) -> Bool {
        prune(now)
        return entries.removeValue(forKey: key) != nil
    }

    private mutating func prune(_ now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value) <= ttl }
    }
}
