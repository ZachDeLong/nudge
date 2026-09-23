import Foundation
import NudgeCore

/// Shared rules for the "Always allow" promotion path so the popover's menu
/// label and the controller's settings.json write can never disagree about
/// what is going to be written.
enum Promotion {
    /// The Claude Code permission rule that "Always allow" will append to
    /// `permissions.allow`. Prefers the matched pattern (e.g. `Bash(git push:*)`)
    /// so the whole class of commands is allowed going forward; falls back to
    /// the exact command when no pattern was sent (older hooks, direct
    /// test-popup posts).
    ///
    /// MCP is the one translation: nudge matches on `Mcp(server__tool)` for
    /// consistency with the other families, but Claude Code's permissions
    /// format wants the bare `mcp__server__tool` form.
    static func rule(for prompt: Prompt) -> String {
        let raw = prompt.matchedPattern ?? "Bash(\(prompt.command))"
        guard raw.hasPrefix("Mcp("), raw.hasSuffix(")") else { return raw }
        let inner = String(raw.dropFirst(4).dropLast())
        return "mcp__\(inner)"
    }

    /// Whether the matched pattern can be promoted to a permanent allow rule.
    /// Infix Bash patterns (`Bash(*--force*)`) never are — they exist to catch
    /// dangerous flags, and allowing them forever defeats the point. MCP
    /// globs can't be expressed in Claude Code's allow list, so only exact
    /// MCP rules qualify.
    static func isPromotable(_ pattern: String?) -> Bool {
        guard let p = pattern, !p.isEmpty else { return false }

        if p.hasPrefix("Bash("), p.hasSuffix(")") {
            let inner = String(p.dropFirst(5).dropLast())
            return !(inner.hasPrefix("*") && inner.hasSuffix("*"))
        }

        let pathFamilies = ["Edit(", "Write(", "Read(", "MultiEdit(", "NotebookEdit("]
        if pathFamilies.contains(where: { p.hasPrefix($0) }) {
            return true
        }

        if p.hasPrefix("Mcp("), p.hasSuffix(")") {
            let inner = String(p.dropFirst(4).dropLast())
            return !inner.contains("*")
        }

        return false
    }

    /// Menu-friendly form of `rule(for:)` — long fallback rules built from a
    /// full shell command get middle-truncated so the menu stays one line.
    static func menuLabel(for prompt: Prompt) -> String {
        let r = rule(for: prompt)
        let limit = 44
        guard r.count > limit else { return r }
        let head = r.prefix(limit - 12)
        let tail = r.suffix(10)
        return "\(head)…\(tail)"
    }
}
