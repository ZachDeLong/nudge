import AppKit
import Foundation
import NudgeCore
import NudgeHookCore

// One binary answers both agents. `--agent codex` is added to the Codex hook
// entry; without it the caller is Claude Code.
let agent = HookAgent.from(arguments: CommandLine.arguments)

// Re-read prefs.json on every invocation so the menu bar app's toggles take
// effect immediately.
let settings = Prefs.load()

// Master switch: paused Nudge means the agent falls through to its own prompt.
guard settings.enabled else { exit(0) }

// MARK: - Read stdin

let inputData = FileHandle.standardInput.readDataToEndOfFile()
guard let inputJSON = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any] else {
    exit(0) // Malformed: fall back to the agent's own prompt.
}

let toolName = inputJSON["tool_name"] as? String ?? "Unknown"
let toolInput = inputJSON["tool_input"] as? [String: Any] ?? [:]
// Hook entries written before PermissionRequest support only ever received
// PreToolUse, and some payloads omit the name, so that's the default.
let event = HookEvent(rawValue: inputJSON["hook_event_name"] as? String ?? "") ?? .preToolUse
let cwd = inputJSON["cwd"] as? String ?? FileManager.default.currentDirectoryPath
let sessionId = inputJSON["session_id"] as? String ?? "unknown"
let permissionMode = inputJSON["permission_mode"] as? String ?? "default"

// MARK: - Skip when user is already at a terminal/IDE

// The agent's own app counts too: if you're looking at Codex in ChatGPT, its
// approval prompt is right there.
if settings.skipWhenTerminalFocused,
   let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
   FrontmostApp.terminalBundleIDs.contains(frontmost) || agent.hostAppBundleIDs.contains(frontmost) {
    exit(0)
}

// MARK: - Decide whether to ask

func loadPatterns() -> [String] {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/nudge/patterns.txt")
    guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return raw.split(whereSeparator: { $0.isNewline })
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

let matched: String?
let displayCommand: String

switch event {
case .preToolUse:
    // Fires on every tool call, so only a pattern match earns a popover.
    // The match target is the command, path, or (for MCP) the bare
    // `server__tool` name; the popover shows the full `mcp__` name so you
    // know exactly what you're approving.
    let target: String
    switch family(for: toolName) {
    case .bash: target = toolInput["command"] as? String ?? ""
    case .path: target = toolInput["file_path"] as? String ?? ""
    case .mcp: target = mcpMatchTarget(for: toolName) ?? ""
    case .unknown: exit(0)
    }
    guard let pattern = matchedPattern(toolName: toolName, target: target, patterns: loadPatterns()) else {
        exit(0)
    }
    matched = pattern
    displayCommand = family(for: toolName) == .mcp ? toolName : target

case .permissionRequest:
    // The agent was about to show its own approval prompt. Answer every one
    // of those, except workflow choices that aren't a plain yes/no.
    guard !toolsLeftToAgentUI.contains(toolName) else { exit(0) }
    matched = nil
    displayCommand = displayTarget(toolName: toolName, input: toolInput)
}

let detail = (toolInput["description"] as? String)?
    .trimmingCharacters(in: .whitespacesAndNewlines)

let prompt = Prompt(
    id: UUID().uuidString,
    tool: toolName,
    command: displayCommand,
    cwd: cwd,
    sessionId: sessionId,
    permissionMode: permissionMode,
    matchedPattern: matched,
    agent: agent.rawValue,
    detail: detail?.isEmpty == false ? detail : nil
)

guard let port = NudgeClient.locatePort() else {
    exit(0) // Nudge not available: fall back to the agent's own prompt.
}

// MARK: - POST and wait

let decision: DecisionResponse
do {
    decision = try NudgeClient.postPrompt(prompt, to: "/prompt", port: port)
} catch NudgeClientError.unauthorized {
    // Token mismatch — surface to stderr so it shows up in Console.app and
    // the agent's hook log. Silent fallback would mean the user has no idea why
    // their popovers stopped working.
    fputs("nudge-hook: auth failed (token mismatch). Try restarting Nudge.\n", stderr)
    exit(0)
} catch NudgeClientError.tokenMissing {
    fputs("nudge-hook: token file missing or invalid. Try restarting Nudge.\n", stderr)
    exit(0)
} catch {
    exit(0) // Anything else: fall back silently to the agent's own prompt.
}

guard decision.decision == .allow || decision.decision == .deny else {
    exit(0)
}

// MARK: - Answer the agent

let response = hookDecisionOutput(event: event, allow: decision.decision == .allow)
if let outputData = try? JSONSerialization.data(withJSONObject: response) {
    FileHandle.standardOutput.write(outputData)
}
exit(0)
