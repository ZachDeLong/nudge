import AppKit
import Foundation
import NudgeCore
import NudgeHookCore

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
    case .unknown:
        return ""
    }
}

let target = matchTarget(for: toolName, input: toolInput)

// MARK: - Pattern gate

guard family(for: toolName) != .unknown else { exit(0) }

let patternsURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/nudge/patterns.txt")

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
// shell command, for Edit/Write/Read it's the file path.
let prompt = Prompt(
    id: UUID().uuidString,
    tool: toolName,
    command: target,
    cwd: cwd,
    sessionId: sessionId,
    permissionMode: permissionMode,
    matchedPattern: matched
)

guard let port = NudgeClient.locatePort() else {
    exit(0) // Nudge not available: fall back to Claude's terminal prompt.
}

// MARK: - POST and wait

guard let decision = try? NudgeClient.postPrompt(prompt, to: "/prompt", port: port),
      decision.decision == .allow || decision.decision == .deny else {
    exit(0) // Anything goes wrong, fall back.
}

// MARK: - Write Claude Code hook output

let response: [String: Any] = [
    "hookSpecificOutput": [
        "hookEventName": "PreToolUse",
        "permissionDecision": decision.decision.rawValue,
    ]
]
if let outputData = try? JSONSerialization.data(withJSONObject: response) {
    FileHandle.standardOutput.write(outputData)
}
exit(0)
