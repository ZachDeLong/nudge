import Foundation

/// The coding agent calling the hook. Claude Code and Codex speak nearly the
/// same hook protocol (Codex adopted Claude's event names and JSON shapes);
/// the differences are collected here.
public enum HookAgent: String, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        }
    }

    /// Reads `--agent <name>` from the hook's arguments. Claude is the default,
    /// so hook entries written before Codex support keep working unchanged.
    public static func from(arguments: [String]) -> HookAgent {
        guard let i = arguments.firstIndex(of: "--agent"), i + 1 < arguments.count,
              let agent = HookAgent(rawValue: arguments[i + 1].lowercased()) else {
            return .claude
        }
        return agent
    }

    /// Bundle IDs of the agent's own desktop app. When it's in front, its own
    /// approval prompt is already on screen, so Nudge stays out of the way the
    /// same way it does for terminals.
    public var hostAppBundleIDs: Set<String> {
        switch self {
        case .claude: return ["com.anthropic.claudefordesktop"]
        case .codex:  return ["com.openai.codex", "com.openai.chat"]
        }
    }
}

/// The hook events Nudge answers.
///
/// - `preToolUse` fires on every tool call, before the agent decides whether
///   to ask. Nudge only acts on it when a pattern in patterns.txt matches:
///   the "always ask me about these" list, which applies even in auto mode.
/// - `permissionRequest` fires only when the agent is about to show its own
///   approval prompt. Nudge answers it in place of that prompt, so it covers
///   exactly what the agent would have asked, and stays silent while auto
///   mode (or an allow rule) is deciding.
public enum HookEvent: String, Sendable {
    case preToolUse = "PreToolUse"
    case permissionRequest = "PermissionRequest"
}

/// Tools whose approval dialog is a choice between workflows rather than a
/// yes/no permission (Claude's plan approval offers several ways to proceed).
/// Answering them with a bare Allow would pick one silently, so they stay in
/// the agent's own UI.
public let toolsLeftToAgentUI: Set<String> = ["ExitPlanMode", "AskUserQuestion"]

/// The JSON the hook prints to answer. Claude Code and Codex read the same
/// shape for each event.
public func hookDecisionOutput(event: HookEvent, allow: Bool) -> [String: Any] {
    switch event {
    case .preToolUse:
        return [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": allow ? "allow" : "deny",
            ]
        ]
    case .permissionRequest:
        var decision: [String: Any] = ["behavior": allow ? "allow" : "deny"]
        if !allow {
            // Shown to the agent, so it knows a person said no rather than a
            // policy, and doesn't retry the same thing a different way.
            decision["message"] = "The user denied this in Nudge."
        }
        return [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision,
            ]
        ]
    }
}

/// What the popover shows for a tool call: the shell command, file path,
/// patch, URL or tool name. Anything unrecognized falls back to its input as
/// compact JSON, so an unfamiliar tool is never approved blind.
public func displayTarget(toolName: String, input: [String: Any]) -> String {
    switch toolName {
    case "Bash":
        return input["command"] as? String ?? ""
    case "Edit", "Write", "Read", "MultiEdit":
        return input["file_path"] as? String ?? ""
    case "NotebookEdit":
        return input["notebook_path"] as? String ?? input["file_path"] as? String ?? ""
    case "apply_patch":
        // Codex sends the whole patch under `command`.
        return input["command"] as? String ?? input["patch"] as? String ?? ""
    case "WebFetch":
        return input["url"] as? String ?? ""
    case "WebSearch":
        return input["query"] as? String ?? ""
    default:
        if toolName.hasPrefix(mcpToolPrefix) { return toolName }
        var rest = input
        rest.removeValue(forKey: "description")
        guard !rest.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: rest, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json.count > 2000 ? String(json.prefix(2000)) + "…" : json
    }
}

/// The files a Codex `apply_patch` touches, in patch order. Reads the
/// `*** Add File:`, `*** Update File:` and `*** Delete File:` headers.
public func patchedFiles(_ patch: String) -> [String] {
    let headers = ["*** Add File: ", "*** Update File: ", "*** Delete File: "]
    var files: [String] = []
    for line in patch.split(whereSeparator: \.isNewline) {
        for header in headers where line.hasPrefix(header) {
            let path = line.dropFirst(header.count).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty, !files.contains(path) { files.append(path) }
        }
    }
    return files
}
