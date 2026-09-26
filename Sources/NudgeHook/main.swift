import AppKit
import Foundation
import NudgeCore
import NudgeHookCore

// NUDGE_CONFIG_DIR is for the test harness. Left exported in a shell, it
// points the hook at a Nudge that isn't there and prompting silently stops;
// say so in Claude Code instead (systemMessage is shown to the user).
func exitWithConfigDirWarning(_ problem: String) -> Never {
    let message = "Nudge is off for this session: NUDGE_CONFIG_DIR is set to \(ConfigDir.url.path), \(problem). "
        + "It's only for Nudge's test harness; unset it to get Nudge prompts back."
    if let data = try? JSONSerialization.data(withJSONObject: ["systemMessage": message]) {
        FileHandle.standardOutput.write(data)
    }
    exit(0)
}

if ConfigDir.isOverridden, !FileManager.default.fileExists(atPath: ConfigDir.url.path) {
    exitWithConfigDirWarning("which doesn't exist")
}

// Re-read prefs.json on every invocation so the menu bar app's toggles take
// effect immediately.
let settings = Prefs.load()

// Master switch: paused Nudge means Claude falls through to its own prompt.
guard settings.enabled else { exit(0) }

// MARK: - Read stdin

let inputData = FileHandle.standardInput.readDataToEndOfFile()
guard let inputJSON = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any] else {
    exit(0) // Malformed: fall back to Claude's normal flow.
}

let toolName = inputJSON["tool_name"] as? String ?? "Unknown"
let toolInput = inputJSON["tool_input"] as? [String: Any] ?? [:]
let cwd = inputJSON["cwd"] as? String ?? FileManager.default.currentDirectoryPath
let sessionId = inputJSON["session_id"] as? String ?? "unknown"
let permissionMode = inputJSON["permission_mode"] as? String ?? "default"

// MARK: - Skip when user is already at a terminal/IDE

if settings.skipWhenTerminalFocused,
   let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
   FrontmostApp.terminalBundleIDs.contains(frontmost) {
    exit(0)
}

// MARK: - Tool dispatch

/// The string this tool matches against (and that we display in the popover).
func matchTarget(for tool: String, input: [String: Any]) -> String {
    switch family(for: tool) {
    case .bash:
        return (input["command"] as? String) ?? ""
    case .path:
        return (input["file_path"] as? String) ?? ""
    case .mcp:
        return mcpMatchTarget(for: tool) ?? ""
    case .unknown:
        return ""
    }
}

let target = matchTarget(for: toolName, input: toolInput)

// MARK: - Pattern gate

guard family(for: toolName) != .unknown else { exit(0) }

let patternsURL = ConfigDir.url.appendingPathComponent("patterns.txt")

func loadPatterns() -> [String] {
    guard let raw = try? String(contentsOf: patternsURL, encoding: .utf8) else { return [] }
    return raw.split(whereSeparator: { $0.isNewline })
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

guard let matched = matchedPattern(toolName: toolName, target: target, patterns: loadPatterns()) else {
    exit(0)
}

// `command` here is the display string for the popover: for Bash it's the
// shell command, for Edit/Write/Read it's the file path. For MCP tools we
// show the full tool name (with the `mcp__` prefix) so the user knows what
// they're approving — the bare `server__tool` form is for matching only.
let displayCommand: String = {
    switch family(for: toolName) {
    case .mcp: return toolName
    default: return target
    }
}()

let prompt = Prompt(
    id: UUID().uuidString,
    tool: toolName,
    command: displayCommand,
    cwd: cwd,
    sessionId: sessionId,
    permissionMode: permissionMode,
    matchedPattern: matched
)

guard let port = NudgeClient.locatePort() else {
    if ConfigDir.isOverridden { exitWithConfigDirWarning("but no Nudge is running there") }
    exit(0) // Nudge not available: fall back to Claude's terminal prompt.
}

// MARK: - POST and wait

// If Claude dies while we wait, stop holding the prompt open.
CallerWatch.exitWhenCallerGone()

let decision: DecisionResponse
do {
    decision = try NudgeClient.postPrompt(prompt, to: "/prompt", port: port)
} catch NudgeClientError.unauthorized {
    // Token mismatch — surface to stderr so it shows up in Console.app and
    // Claude's hook log. Silent fallback would mean the user has no idea why
    // their popovers stopped working.
    fputs("nudge-hook: auth failed (token mismatch). Try restarting Nudge.\n", stderr)
    exit(0)
} catch NudgeClientError.tokenMissing {
    fputs("nudge-hook: token file missing or invalid. Try restarting Nudge.\n", stderr)
    exit(0)
} catch {
    exit(0) // Anything else: fall back silently to Claude's normal flow.
}

guard decision.decision == .allow || decision.decision == .deny else {
    exit(0)
}

// MARK: - Write Claude Code hook output

// Without a reason, Claude sees a denial as "hook error: Blocked by hook".
// Claude Code shows the reason to Claude for deny and to the user for allow.
let response: [String: Any] = [
    "hookSpecificOutput": [
        "hookEventName": "PreToolUse",
        "permissionDecision": decision.decision.rawValue,
        "permissionDecisionReason": decision.decision == .deny
            ? "The user denied this in Nudge."
            : "Allowed in Nudge.",
    ]
]
if let outputData = try? JSONSerialization.data(withJSONObject: response) {
    FileHandle.standardOutput.write(outputData)
}
exit(0)
