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

let prompt: [String: Any] = [
    "id": UUID().uuidString,
    "tool": toolName,
    "command": command,
    "cwd": cwd,
    "sessionId": sessionId,
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
