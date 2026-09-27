import AppKit
import Foundation
import NudgeCore
import NudgeHookCore

// Master switch, same as nudge-hook. The activity side channel is still Nudge,
// so a paused Nudge shouldn't keep collecting. Checked before reading stdin to
// match nudge-hook's ordering.
//
// Deliberately does NOT honor `skipWhenTerminalFocused`: that toggle exists to
// suppress redundant popovers when you're already looking at the terminal, and
// this hook shows no UI. Skipping on it would just punch holes in the activity
// timeline the mirror panel reads from.
guard Prefs.load().enabled else { exit(0) }

let inputData = FileHandle.standardInput.readDataToEndOfFile()
guard let inputJSON = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any] else {
    exit(0)
}

let env = ProcessInfo.processInfo.environment
// Codex's hook entry passes `--agent codex`. Its only event here is Interrupt,
// which tells the app to drop a prompt Codex stopped waiting on.
let agent = HookAgent.from(arguments: CommandLine.arguments)
let eventName = string(inputJSON["hook_event_name"]) ?? "Unknown"
let toolInput = inputJSON["tool_input"] as? [String: Any]

// A finished tool call names the call the same way nudge-hook does, so the
// app can drop a PermissionRequest prompt you already answered in Claude.
let callKey: String? = {
    guard ["PostToolUse", "PostToolUseFailure"].contains(eventName),
          let session = inputJSON["session_id"] as? String,
          let tool = inputJSON["tool_name"] as? String else { return nil }
    return CallKey.make(sessionID: session, toolName: tool, toolInput: inputJSON["tool_input"])
}()

let event = AgentHookEvent(
    nudgeSessionID: env["NUDGE_AGENT_SESSION_ID"],
    claudeSessionID: string(inputJSON["session_id"]),
    eventName: eventName,
    cwd: string(inputJSON["cwd"]) ?? FileManager.default.currentDirectoryPath,
    transcriptPath: string(inputJSON["transcript_path"]),
    permissionMode: string(inputJSON["permission_mode"]),
    toolName: string(inputJSON["tool_name"]),
    toolSummary: summarizeTool(name: string(inputJSON["tool_name"]), input: toolInput),
    promptPreview: preview(string(inputJSON["prompt"])),
    message: string(inputJSON["message"]),
    error: string(inputJSON["error"]) ?? string(inputJSON["error_details"]),
    callKey: callKey,
    subagentID: string(inputJSON["agent_id"]),
    agent: agent == .claude ? nil : agent.rawValue
)

guard let port = NudgeClient.locatePort() else {
    exit(0)
}

do {
    try NudgeClient.postAgentEvent(event, port: port)
} catch {
    // Observability hook only: never block or perturb Claude Code.
}

// MARK: - "Claude finished" (Stop)

// When Claude finishes while you're off in another app, show its last message
// with a reply box, and hold this hook until you answer. A reply answers the
// Stop hook with "block", so Claude carries on with it; anything else lets
// Claude stop as usual. The app lets go of it as soon as you switch back to
// the session's terminal, and the queue gives up after five minutes.
let prefs = Prefs.load()
let entrypoint = env["CLAUDE_CODE_ENTRYPOINT"]
// The harness pins the front app, which is otherwise whatever is on the Mac
// running the tests. Only honored on a harness instance.
let frontmost = (ConfigDir.isOverridden ? env["NUDGE_TEST_FRONTMOST"] : nil)
    ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
let atSession = frontmost.map(FrontmostApp.sessionUIBundleIDs(entrypoint: entrypoint, agent: event.agent).contains) ?? false
guard prefs.finishedMessages,
      shouldOfferFinishedMessage(agent: agent, eventName: eventName, entrypoint: entrypoint,
                                 codexAncestors: agent == .codex ? ProcessTree.ancestorArguments() : [],
                                 isSubagent: event.subagentID != nil, userIsAtSession: atSession) else {
    exit(0)
}

let finished = Prompt(
    id: UUID().uuidString,
    kind: .finished,
    tool: "Stop",
    command: finishedMessageText(string(inputJSON["last_assistant_message"]), agentName: agent.displayName),
    cwd: event.cwd ?? FileManager.default.currentDirectoryPath,
    sessionId: event.claudeSessionID ?? "unknown",
    permissionMode: event.permissionMode,
    agent: event.agent,
    event: "Stop",
    entrypoint: entrypoint
)

// If Claude gives up on the hook (you quit it), stop holding the message.
CallerWatch.exitWhenCallerGone()

guard let reply = try? NudgeClient.postPrompt(finished, to: "/prompt", port: port),
      reply.decision == .text,
      let text = reply.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
    exit(0)
}
if let data = try? JSONSerialization.data(withJSONObject: stopReplyOutput(reply: text)) {
    FileHandle.standardOutput.write(data)
}
exit(0)

private func string(_ value: Any?) -> String? {
    switch value {
    case is NSNull:
        // A JSON `null`. NSNull is CustomStringConvertible, so without this
        // case it came back as the string "<null>" and beat every `??`
        // fallback (a null cwd grouped unrelated sessions under "<null>").
        return nil
    case let value as String:
        return value
    case let value as CustomStringConvertible:
        return value.description
    default:
        return nil
    }
}

private func preview(_ value: String?, limit: Int = 140) -> String? {
    guard let value else { return nil }
    let normalized = value
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .split(whereSeparator: \.isNewline)
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }
    if normalized.count <= limit { return normalized }
    return String(normalized.prefix(limit)) + "..."
}

private func summarizeTool(name: String?, input: [String: Any]?) -> String? {
    guard let name, let input else { return nil }
    switch name {
    case "Bash":
        return preview(string(input["command"]))
    case "Edit", "Write", "Read", "MultiEdit":
        return string(input["file_path"])
    case "NotebookEdit":
        return string(input["notebook_path"]) ?? string(input["file_path"])
    case "Task":
        return preview(string(input["description"]) ?? string(input["prompt"]))
    case "Glob":
        return string(input["pattern"])
    case "Grep":
        return string(input["pattern"])
    default:
        return nil
    }
}
