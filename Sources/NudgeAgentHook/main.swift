import Foundation
import NudgeCore

let inputData = FileHandle.standardInput.readDataToEndOfFile()
guard let inputJSON = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any] else {
    exit(0)
}

let env = ProcessInfo.processInfo.environment
let eventName = string(inputJSON["hook_event_name"]) ?? "Unknown"
let toolInput = inputJSON["tool_input"] as? [String: Any]

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
    error: string(inputJSON["error"]) ?? string(inputJSON["error_details"])
)

guard let port = NudgeClient.locatePort() else {
    exit(0)
}

do {
    try NudgeClient.postAgentEvent(event, port: port)
} catch {
    // Observability hook only: never block or perturb Claude Code.
}

exit(0)

private func string(_ value: Any?) -> String? {
    switch value {
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
