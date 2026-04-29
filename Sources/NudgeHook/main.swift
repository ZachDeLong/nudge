import Foundation
import Darwin

// MARK: - Read stdin

let inputData = FileHandle.standardInput.readDataToEndOfFile()
guard let inputJSON = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any] else {
    exit(0) // Malformed — fall back to Claude's normal flow.
}

let toolName = inputJSON["tool_name"] as? String ?? "Unknown"
let toolInput = inputJSON["tool_input"] as? [String: Any] ?? [:]
let command = toolInput["command"] as? String ?? ""
let cwd = inputJSON["cwd"] as? String ?? FileManager.default.currentDirectoryPath
let sessionId = inputJSON["session_id"] as? String ?? "unknown"
let permissionMode = inputJSON["permission_mode"] as? String ?? "default"

// MARK: - Pattern gate
//
// We only popover for Bash commands matching a user-defined pattern in
// ~/.config/nudge/patterns.txt. Claude Code's `matcher` field filters by tool
// name only ("Bash"), not by command — so the install script sets matcher to
// "Bash" and we do the command-level filtering here. Non-matches exit silently
// so Claude proceeds via its normal flow (auto mode allows; default mode prompts).

guard toolName == "Bash" else { exit(0) }

let patternsURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/nudge/patterns.txt")

func loadPatterns() -> [String] {
    guard let raw = try? String(contentsOf: patternsURL, encoding: .utf8) else { return [] }
    return raw.split(whereSeparator: { $0.isNewline })
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

// Each pattern is a Claude Code permission rule. We support:
//   Bash(<prefix>:*)  → command starts with <prefix>
//   Bash(*<infix>*)   → command contains <infix>
//   Bash(<exact>)     → command equals <exact>
// Non-Bash(...) lines are ignored.
//
// Returns the matched pattern (the literal string from patterns.txt), or nil
// if no pattern matched. The matched pattern is forwarded to Nudge so the UI
// can decide whether "Always allow" is offerable (only prefix/exact patterns
// translate to valid Claude permission rules — infix has no equivalent).
//
// Priority: infix matches win over prefix/exact when both fire on the same
// command. That way `git push --force origin main` (matches both
// `Bash(git push:*)` and `Bash(*--force*)`) returns the infix, hiding the
// always-allow option — promoting `git push:*` to permissions.allow would
// also auto-allow future `git push --force` calls, which is the unsafe path.
func matchedPattern(for command: String, patterns: [String]) -> String? {
    var firstInfix: String? = nil
    var firstPromotable: String? = nil
    for pattern in patterns {
        guard pattern.hasPrefix("Bash(") && pattern.hasSuffix(")") else { continue }
        let inner = String(pattern.dropFirst(5).dropLast())
        if inner.hasPrefix("*") && inner.hasSuffix("*") {
            let needle = String(inner.dropFirst().dropLast())
            if !needle.isEmpty && command.contains(needle) {
                if firstInfix == nil { firstInfix = pattern }
            }
        } else if inner.hasSuffix(":*") {
            let prefix = String(inner.dropLast(2))
            if command.hasPrefix(prefix), firstPromotable == nil {
                firstPromotable = pattern
            }
        } else {
            if command == inner, firstPromotable == nil {
                firstPromotable = pattern
            }
        }
    }
    return firstInfix ?? firstPromotable
}

guard let matched = matchedPattern(for: command, patterns: loadPatterns()) else { exit(0) }

let prompt: [String: Any] = [
    "id": UUID().uuidString,
    "tool": toolName,
    "command": command,
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
