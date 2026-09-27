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

    /// Bundle IDs of the app showing this session's own approval prompt. When
    /// it's in front, the prompt is already on screen, so Nudge stays out of
    /// the way the same way it does for terminals.
    public func hostAppBundleIDs(environment: [String: String]) -> Set<String> {
        switch self {
        // Claude Code in a terminal is covered by the terminal list. The
        // Claude app only counts for sessions running in it: a terminal
        // session's prompt isn't on screen just because the app is in front.
        case .claude:
            return environment["CLAUDE_CODE_ENTRYPOINT"] == "claude-desktop"
                ? ["com.anthropic.claudefordesktop"] : []
        case .codex:
            return ["com.openai.codex", "com.openai.chat"]
        }
    }

    /// How long the hook holds the agent before handing the request back.
    ///
    /// Claude Code shows its own dialog while the hook runs, so a prompt left
    /// in Nudge blocks nothing: no bound here, and the app's 5-minute timeout
    /// applies. Codex shows nothing until the hook returns (0.155), so a
    /// prompt forgotten in the menu bar would hold Codex for the full
    /// 5 minutes. After two, Nudge gives up and Codex asks in its own UI.
    public var maxWait: TimeInterval? {
        switch self {
        case .claude: return nil
        case .codex:  return 120
        }
    }
}

/// Seconds the hook waits for an answer before giving up, or nil to wait for
/// the app. The e2e harness shortens it with `NUDGE_HOOK_MAX_WAIT`, honored
/// only when the hook runs against a harness config dir (`harness`), so a
/// stray variable can't change a real install.
public func hookMaxWait(agent: HookAgent, environment: [String: String], harness: Bool) -> TimeInterval? {
    if harness, let raw = environment["NUDGE_HOOK_MAX_WAIT"], let seconds = TimeInterval(raw), seconds > 0 {
        return seconds
    }
    return agent.maxWait
}

/// What the hook tells the user, through the agent, when it gives up waiting
/// and the agent's own prompt takes over.
public func handBackMessage(agent: HookAgent, waited seconds: TimeInterval) -> String {
    let whole = Int(seconds.rounded())
    let duration: String
    if whole >= 60, whole % 60 == 0 {
        duration = whole == 60 ? "a minute" : "\(whole / 60) minutes"
    } else {
        duration = whole == 1 ? "1 second" : "\(whole) seconds"
    }
    return "Nudge got no answer in \(duration), so \(agent.displayName) is asking here instead."
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

/// Whether Nudge asks for `event` in Claude Code's `permissionMode`.
///
/// - PermissionRequest: in every mode it fires in, so auto mode's rare
///   fallbacks (ask rules, the classifier giving up) still reach you. Not in
///   dontAsk: that mode denies anything not pre-approved instead of asking,
///   and a popover would contradict it. (Claude Code 2.1.283 doesn't fire
///   PermissionRequest in dontAsk at all; this holds if that changes.)
/// - PreToolUse (patterns): the "ask me even when Claude wouldn't" list, so
///   auto keeps them. Not in bypassPermissions (you turned checks off) or
///   dontAsk (you said never ask; a pattern there would stall a headless
///   run until Nudge's 5-minute timeout).
public func nudgeAsks(event: HookEvent, permissionMode: String) -> Bool {
    switch event {
    case .permissionRequest: return permissionMode != "dontAsk"
    case .preToolUse: return permissionMode != "bypassPermissions" && permissionMode != "dontAsk"
    }
}

/// Tools whose approval dialog is a choice between workflows rather than a
/// yes/no permission (Claude's plan approval offers several ways to proceed).
/// Answering them with a bare Allow would pick one silently, so they stay in
/// the agent's own UI.
public let toolsLeftToAgentUI: Set<String> = ["ExitPlanMode", "AskUserQuestion"]

// MARK: - Finished messages (Stop hook)

/// Sessions a person is driving: a terminal, the Claude app, VS Code. Scripted
/// runs (`claude -p` is "sdk-cli", SDK apps "sdk-ts"/"sdk-py") never get a
/// finished message, so Nudge can't hold up automation.
public let interactiveEntrypoints: Set<String> = ["cli", "claude-desktop", "claude-vscode"]

/// Whether a Stop should become a "finished" message: a session a person is
/// driving, the main thread, and you're not looking at the session already.
/// Claude says how it was started (`entrypoint`); Codex doesn't, so its hook's
/// ancestors (`codexAncestors`, nearest first) tell a `codex exec` run apart.
public func shouldOfferFinishedMessage(agent: HookAgent, eventName: String, entrypoint: String?,
                                       codexAncestors: [[String]] = [],
                                       isSubagent: Bool, userIsAtSession: Bool) -> Bool {
    guard eventName == "Stop", !isSubagent, !userIsAtSession else { return false }
    switch agent {
    case .claude: return interactiveEntrypoints.contains(entrypoint ?? "")
    case .codex:  return !codexRunIsScripted(ancestorArguments: codexAncestors)
    }
}

/// A `codex exec` run (alias `e`): scripted, nobody to tell. The TUI (`codex`)
/// and the ChatGPT app (`codex app-server`) have a person behind them. With
/// no Codex process in sight, assume a person.
public func codexRunIsScripted(ancestorArguments: [[String]]) -> Bool {
    guard let codex = ancestorArguments.first(where: {
        URL(fileURLWithPath: $0.first ?? "").lastPathComponent == "codex"
    }) else { return false }
    // Anywhere, not just first: options like `-c model=…` can come before it.
    let args = codex.dropFirst()
    return args.contains("exec") || args.contains("e")
}

/// What the popover shows: Claude's last message, trimmed and capped.
public func finishedMessageText(_ lastAssistantMessage: String?, agentName: String = "Claude") -> String {
    let text = (lastAssistantMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return "\(agentName) finished its turn." }
    return text.count > 4000 ? String(text.prefix(4000)) + "…" : text
}

/// Answers the Stop hook with your reply. "block" means Claude doesn't stop:
/// it reads the reason as its next instruction and carries on in the same
/// session (checked on Claude Code 2.1.283).
public func stopReplyOutput(reply: String) -> [String: Any] {
    ["decision": "block", "reason": "The user replied from Nudge: \(reply)"]
}

/// A pattern matched while you're looking at the agent's own UI: have Claude
/// ask there instead of Nudge. Staying silent would let the call run unasked,
/// which is the opposite of what a pattern is for.
public func askInAgentUIOutput(pattern: String) -> [String: Any] {
    [
        "hookSpecificOutput": [
            "hookEventName": "PreToolUse",
            "permissionDecision": "ask",
            "permissionDecisionReason": "Nudge: this matches \(pattern).",
        ]
    ]
}

/// The JSON the hook prints to answer. Claude Code and Codex read the same
/// shape for each event.
public func hookDecisionOutput(event: HookEvent, allow: Bool) -> [String: Any] {
    switch event {
    case .preToolUse:
        // Without a reason, Claude sees a denial as "hook error: Blocked by
        // hook". Claude Code shows the reason to Claude for deny and to the
        // user for allow.
        return [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": allow ? "allow" : "deny",
                "permissionDecisionReason": allow ? "Allowed in Nudge." : "The user denied this in Nudge.",
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
/// patch or URL. An MCP tool shows its name and then its arguments, since
/// that's where the call's meaning is (an SQL statement, a message body).
/// Anything unrecognized falls back to its input as compact JSON, so an
/// unfamiliar tool is never approved blind.
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
        if toolName.hasPrefix(mcpToolPrefix) {
            // Every argument, `description` included: for an MCP tool it's
            // data (an issue's body), not the agent explaining itself.
            guard let args = jsonText(input, pretty: true) else { return toolName }
            return toolName + "\n" + args
        }
        var rest = input
        rest.removeValue(forKey: "description")
        return jsonText(rest, pretty: false) ?? ""
    }
}

/// `object` as JSON with sorted keys, capped at 2000 characters. Nil when
/// it's empty.
private func jsonText(_ object: [String: Any], pretty: Bool) -> String? {
    var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
    if pretty { options.insert(.prettyPrinted) }
    guard !object.isEmpty,
          let data = try? JSONSerialization.data(withJSONObject: object, options: options),
          let json = String(data: data, encoding: .utf8) else {
        return nil
    }
    return json.count > 2000 ? String(json.prefix(2000)) + "…" : json
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
