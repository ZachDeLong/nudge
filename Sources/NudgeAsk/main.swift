import Foundation
import Darwin
import AppKit

// MARK: - Args
//
// Usage: nudge-ask "<question>"
// Prints the user's typed answer to stdout and exits 0.
// Exits non-zero (with stderr message) on cancel/timeout/server error so
// Claude can detect it via shell exit code.

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("usage: nudge-ask <question>\n", stderr)
    exit(2)
}
let question = args[1...].joined(separator: " ")
guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    fputs("nudge-ask: question is empty\n", stderr)
    exit(2)
}

// Honor the same toggles the hook respects. If Nudge is paused, or the user
// is already at a terminal/IDE with the skip toggle on, exit non-zero so
// Claude falls back to asking inline in the terminal.
struct HookSettings: Codable {
    var enabled: Bool
    var skipWhenTerminalFocused: Bool
    static let `default` = HookSettings(enabled: true, skipWhenTerminalFocused: true)
}
let prefsURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/nudge/prefs.json")
let askSettings: HookSettings = {
    if let data = try? Data(contentsOf: prefsURL),
       let s = try? JSONDecoder().decode(HookSettings.self, from: data) {
        return s
    }
    return .default
}()

if !askSettings.enabled {
    fputs("nudge-ask: Nudge is paused\n", stderr)
    exit(1)
}

let terminalBundleIDs: Set<String> = [
    "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
    "dev.warp.Warp-Stable", "dev.warp.Warp", "com.github.wez.wezterm",
    "co.zeit.hyper", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
    "com.visualstudio.code.oss", "com.todesktop.230313mzl4w4u92",
]
if askSettings.skipWhenTerminalFocused,
   let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
   terminalBundleIDs.contains(frontmost) {
    fputs("nudge-ask: terminal is focused (skip-when-terminal toggle is on)\n", stderr)
    exit(1)
}

let cwd = FileManager.default.currentDirectoryPath
let sessionId = ProcessInfo.processInfo.environment["CLAUDE_SESSION_ID"] ?? "ask"

let body: [String: Any] = [
    "id": UUID().uuidString,
    "kind": "ask",
    "tool": "Ask",
    "command": question,           // popover renders this as the question body
    "cwd": cwd,
    "sessionId": sessionId,
    "permissionMode": "default",
]
guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
    fputs("nudge-ask: failed to encode request\n", stderr)
    exit(1)
}

// MARK: - Locate Nudge

let portFileURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/nudge/port")

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
    fputs("nudge-ask: Nudge is not running and could not be launched\n", stderr)
    exit(1)
}

// MARK: - POST and wait
//
// Raw TCP socket implementation. We previously used URLSession but it fails
// with -1005 (network connection lost) on long-idle localhost connections,
// even though curl works fine to the same endpoint.

func sendRequestAndReadResponse(host: String, port: UInt16, request: Data) -> Data? {
    let s = socket(AF_INET, SOCK_STREAM, 0)
    guard s >= 0 else {
        fputs("nudge-ask: socket() failed\n", stderr)
        return nil
    }
    defer { close(s) }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr(host)

    let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if connectResult != 0 {
        fputs("nudge-ask: connect() failed (errno=\(errno))\n", stderr)
        return nil
    }

    // Write the entire request.
    let writeResult = request.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int in
        var written = 0
        while written < buf.count {
            let n = Darwin.write(s, buf.baseAddress!.advanced(by: written), buf.count - written)
            if n <= 0 { return -1 }
            written += n
        }
        return written
    }
    if writeResult < 0 {
        fputs("nudge-ask: write() failed\n", stderr)
        return nil
    }

    // Read until EOF (server uses Connection: close).
    var response = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = buf.withUnsafeMutableBufferPointer { ptr in
            Darwin.read(s, ptr.baseAddress, ptr.count)
        }
        if n < 0 {
            fputs("nudge-ask: read() failed (errno=\(errno))\n", stderr)
            return nil
        }
        if n == 0 { break } // EOF
        response.append(contentsOf: buf[0..<n])
    }
    return response
}

// Build raw HTTP/1.1 request — explicit CRLF joining, no multi-line string
// (Swift multi-line strings + indentation rules are too easy to get wrong here).
let requestLines = [
    "POST /ask HTTP/1.1",
    "Host: 127.0.0.1:\(port)",
    "Content-Type: application/json",
    "Content-Length: \(bodyData.count)",
    "Connection: close",
    "",
    "",
]
let requestHead = requestLines.joined(separator: "\r\n")
var requestBytes = Data()
requestBytes.append(requestHead.data(using: .utf8)!)
requestBytes.append(bodyData)

guard let rawResponse = sendRequestAndReadResponse(host: "127.0.0.1", port: port, request: requestBytes) else {
    exit(1)
}

// Split headers from body.
guard let headerEndRange = rawResponse.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else {
    fputs("nudge-ask: malformed response (no header terminator)\n", stderr)
    exit(1)
}
let headerData = rawResponse[..<headerEndRange.lowerBound]
let bodyDataResp = rawResponse[headerEndRange.upperBound...]
let headerText = String(data: headerData, encoding: .utf8) ?? ""
let firstLine = headerText.components(separatedBy: "\r\n").first ?? ""
let statusParts = firstLine.split(separator: " ", maxSplits: 2)
let responseStatus = (statusParts.count >= 2 ? Int(statusParts[1]) : nil) ?? 0
let responseData: Data? = Data(bodyDataResp)
let responseError: Error? = nil

if let error = responseError {
    fputs("nudge-ask: request failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}

if responseStatus == 408 {
    fputs("nudge-ask: timed out\n", stderr)
    exit(124)
}

guard responseStatus == 200, let data = responseData else {
    fputs("nudge-ask: unexpected status \(responseStatus)\n", stderr)
    exit(1)
}

guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let decision = parsed["decision"] as? String else {
    fputs("nudge-ask: malformed response\n", stderr)
    exit(1)
}

switch decision {
case "text":
    let text = (parsed["text"] as? String) ?? ""
    print(text)
    exit(0)
case "cancel":
    fputs("nudge-ask: cancelled by user\n", stderr)
    exit(130)
default:
    fputs("nudge-ask: unexpected decision: \(decision)\n", stderr)
    exit(1)
}
