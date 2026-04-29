import Foundation
import Darwin
import AppKit

// MARK: - Settings (mirrored from Nudge target)
//
// We re-read prefs.json on every invocation so the menu bar app's toggles
// take effect immediately. Both targets agree on the schema.

struct HookSettings: Codable {
    var enabled: Bool
    var skipWhenTerminalFocused: Bool
    static let `default` = HookSettings(enabled: true, skipWhenTerminalFocused: true)
}

let prefsURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/nudge/prefs.json")
let settings: HookSettings = {
    if let data = try? Data(contentsOf: prefsURL),
       let s = try? JSONDecoder().decode(HookSettings.self, from: data) {
        return s
    }
    return .default
}()

// Master switch — paused Nudge means Claude falls through to its own prompt.
guard settings.enabled else { exit(0) }

// MARK: - Read stdin

let inputData = FileHandle.standardInput.readDataToEndOfFile()
guard let inputJSON = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any] else {
    exit(0) // Malformed — fall back to Claude's normal flow.
}

let toolName = inputJSON["tool_name"] as? String ?? "Unknown"
let toolInput = inputJSON["tool_input"] as? [String: Any] ?? [:]
let cwd = inputJSON["cwd"] as? String ?? FileManager.default.currentDirectoryPath
let sessionId = inputJSON["session_id"] as? String ?? "unknown"
let permissionMode = inputJSON["permission_mode"] as? String ?? "default"

// MARK: - Skip when user is already at a terminal/IDE
//
// If the frontmost app is one Claude likely lives in, the user is already
// looking at it — Claude's native prompt is fine. Saves a popover trip.

let terminalBundleIDs: Set<String> = [
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "com.mitchellh.ghostty",
    "dev.warp.Warp-Stable",
    "dev.warp.Warp",
    "com.github.wez.wezterm",
    "co.zeit.hyper",
    "com.microsoft.VSCode",
    "com.microsoft.VSCodeInsiders",
    "com.visualstudio.code.oss",
    "com.todesktop.230313mzl4w4u92",
]
if settings.skipWhenTerminalFocused,
   let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
   terminalBundleIDs.contains(frontmost) {
    exit(0)
}

// MARK: - Tool dispatch

/// Tool families we know how to match. Other tools fall through (exit silently).
enum ToolFamily {
    case bash       // matches against tool_input.command
    case path       // matches against tool_input.file_path with glob
    case unknown
}

func family(for tool: String) -> ToolFamily {
    switch tool {
    case "Bash": return .bash
    case "Edit", "Write", "Read", "MultiEdit", "NotebookEdit": return .path
    default: return .unknown
    }
}

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
//
// We only popover for tool calls matching a user-defined pattern in
// ~/.config/nudge/patterns.txt. The hook's `matcher` field filters by tool
// name only, so this binary does the value-level filtering. Non-matches exit
// silently — Claude proceeds via its normal flow (auto allows; default mode
// shows the terminal prompt).

guard family(for: toolName) != .unknown else { exit(0) }

let patternsURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/nudge/patterns.txt")

func loadPatterns() -> [String] {
    guard let raw = try? String(contentsOf: patternsURL, encoding: .utf8) else { return [] }
    return raw.split(whereSeparator: { $0.isNewline })
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

/// Converts a glob (`*` = single segment, `**` = recursive, `?` = single char)
/// into an anchored regex string. Used for path-based tool patterns like
/// `Edit(/etc/**)` or `Write(**/.env*)`.
func globToRegex(_ glob: String) -> String {
    var out = "^"
    var i = glob.startIndex
    while i < glob.endIndex {
        let c = glob[i]
        switch c {
        case "*":
            let next = glob.index(after: i)
            if next < glob.endIndex && glob[next] == "*" {
                out += ".*"
                i = glob.index(after: next)
                continue
            }
            out += "[^/]*"
        case "?":
            out += "[^/]"
        case "+", "(", ")", "[", "]", "{", "}", "|", "^", "$", ".", "\\":
            out += "\\" + String(c)
        default:
            out += String(c)
        }
        i = glob.index(after: i)
    }
    out += "$"
    return out
}

func globMatch(path: String, glob: String) -> Bool {
    let pattern = globToRegex(glob)
    return path.range(of: pattern, options: .regularExpression) != nil
}

/// Splits a pattern like `Edit(/etc/**)` into ("Edit", "/etc/**"). Returns nil
/// for malformed patterns or any non-`Tool(...)` line.
func parsePattern(_ pattern: String) -> (tool: String, spec: String)? {
    guard let openIdx = pattern.firstIndex(of: "("), pattern.hasSuffix(")") else { return nil }
    let toolPart = String(pattern[..<openIdx])
    let inner = String(pattern[pattern.index(after: openIdx)..<pattern.index(before: pattern.endIndex)])
    return (toolPart, inner)
}

// Returns the matched pattern (the literal string from patterns.txt), or nil
// if no pattern matched. Forwarded to Nudge so the UI can decide whether
// "Always allow" is offerable (only prefix/exact patterns translate to valid
// Claude permission rules — infix has no equivalent).
//
// Priority: infix matches win over prefix/exact when both fire on the same
// input. That way `git push --force origin main` (matches both
// `Bash(git push:*)` and `Bash(*--force*)`) returns the infix, hiding the
// always-allow option.
func matchedPattern(toolName: String, target: String, patterns: [String]) -> String? {
    var firstInfix: String? = nil
    var firstPromotable: String? = nil

    for pattern in patterns {
        guard let (toolPart, inner) = parsePattern(pattern), toolPart == toolName else { continue }

        switch family(for: toolName) {
        case .bash:
            if inner.hasPrefix("*") && inner.hasSuffix("*") {
                let needle = String(inner.dropFirst().dropLast())
                if !needle.isEmpty && target.contains(needle) {
                    if firstInfix == nil { firstInfix = pattern }
                }
            } else if inner.hasSuffix(":*") {
                let prefix = String(inner.dropLast(2))
                if target.hasPrefix(prefix), firstPromotable == nil {
                    firstPromotable = pattern
                }
            } else {
                if target == inner, firstPromotable == nil {
                    firstPromotable = pattern
                }
            }
        case .path:
            // Path patterns are always promotable (no infix syntax).
            if globMatch(path: target, glob: inner), firstPromotable == nil {
                firstPromotable = pattern
            }
        case .unknown:
            break
        }
    }

    return firstInfix ?? firstPromotable
}

guard let matched = matchedPattern(toolName: toolName, target: target, patterns: loadPatterns()) else {
    exit(0)
}

// `command` here is the display string for the popover — for Bash it's the
// shell command, for Edit/Write/Read it's the file path.
let prompt: [String: Any] = [
    "id": UUID().uuidString,
    "tool": toolName,
    "command": target,
    "cwd": cwd,
    "sessionId": sessionId,
    "permissionMode": permissionMode,
    "matchedPattern": matched,
]
guard let body = try? JSONSerialization.data(withJSONObject: prompt) else { exit(0) }

// MARK: - Locate Nudge

let portFileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/nudge/port")

func readPort() -> UInt16? {
    guard let raw = try? String(contentsOf: portFileURL, encoding: .utf8) else { return nil }
    return UInt16(raw.trimmingCharacters(in: .whitespacesAndNewlines))
}

func probe(port: UInt16) -> Bool {
    let s = socket(AF_INET, SOCK_STREAM, 0)
    guard s >= 0 else { return false }
    defer { close(s) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return result == 0
}

func tryLaunchAndWaitForPort() -> UInt16? {
    let p = Process()
    p.launchPath = "/usr/bin/open"
    p.arguments = ["-ga", "Nudge"]
    try? p.run()
    let deadline = Date().addingTimeInterval(2.0)
    while Date() < deadline {
        if let port = readPort(), probe(port: port) { return port }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return nil
}

guard let port = (readPort().flatMap { probe(port: $0) ? $0 : nil }) ?? tryLaunchAndWaitForPort() else {
    exit(0) // Nudge not available — fall back to Claude's terminal prompt.
}

// MARK: - POST and wait

let url = URL(string: "http://127.0.0.1:\(port)/prompt")!
var req = URLRequest(url: url)
req.httpMethod = "POST"
req.httpBody = body
req.setValue("application/json", forHTTPHeaderField: "Content-Type")
req.timeoutInterval = 600

let semaphore = DispatchSemaphore(value: 0)
var responseData: Data?
var responseError: Error?
let task = URLSession.shared.dataTask(with: req) { data, _, error in
    responseData = data
    responseError = error
    semaphore.signal()
}
task.resume()
semaphore.wait()

guard responseError == nil,
      let data = responseData,
      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let decisionStr = parsed["decision"] as? String,
      decisionStr == "allow" || decisionStr == "deny"
else {
    exit(0) // Anything goes wrong, fall back.
}

// MARK: - Write Claude Code hook output

let response: [String: Any] = [
    "hookSpecificOutput": [
        "hookEventName": "PreToolUse",
        "permissionDecision": decisionStr,
    ]
]
if let outputData = try? JSONSerialization.data(withJSONObject: response) {
    FileHandle.standardOutput.write(outputData)
}
exit(0)
