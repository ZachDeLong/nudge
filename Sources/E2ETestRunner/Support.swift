// Shared harness pieces: the isolated Nudge instance, polling, and small
// JSON helpers, kept apart from main.swift so another driver can reuse them.

import Darwin
import Foundation

func die(_ message: String) -> Never {
    FileHandle.standardError.write("nudge-test-e2e: \(message)\n".data(using: .utf8)!)
    exit(2)
}

/// mkdtemp(3) on `template` (ending in XXXXXX); returns the directory made.
/// The C string must stay alive across the call, so no `&array` shortcut:
/// the pointer mkdtemp returns would dangle as soon as the call returns.
func makeTempDir(_ template: String) throws -> String {
    var buf = Array(template.utf8CString)
    let ok = buf.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!) != nil }
    guard ok else { throw FixtureError("mkdtemp(\(template)) failed: \(errno)") }
    return buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

/// Polls `condition` every 50ms until it's true or `seconds` pass.
@discardableResult
func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        usleep(50_000)
    }
    return condition()
}

/// True when something accepts TCP connections on 127.0.0.1:`port`.
func portAnswers(_ port: UInt16) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }
}

/// Removes temp dirs left by runs killed before they could clean up. Only
/// ours, only older than 30 minutes, and only when nothing answers on the
/// dir's port: anything newer may belong to a run that's still going.
func sweepStaleTempDirs() {
    let fm = FileManager.default
    let tmp = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath()
    guard let names = try? fm.contentsOfDirectory(atPath: tmp.path) else { return }
    let cutoff = Date().addingTimeInterval(-30 * 60)
    for name in names where name.hasPrefix("nudge-e2e.") || name.hasPrefix("nudge-e2e-claude.") {
        let dir = tmp.appendingPathComponent(name)
        guard let attrs = try? fm.attributesOfItem(atPath: dir.path),
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let modified = attrs[.modificationDate] as? Date, modified < cutoff
        else { continue }
        if let p = try? String(contentsOf: dir.appendingPathComponent("port"), encoding: .utf8),
           let port = UInt16(p.trimmingCharacters(in: .whitespacesAndNewlines)), portAnswers(port) {
            continue
        }
        try? fm.removeItem(at: dir)
    }
}

/// A config dir like one a forgotten NUDGE_CONFIG_DIR would point at after
/// its Nudge is gone: patterns and prefs, but nothing listening on its port.
func makeStaleConfigDir(patterns: [String]) throws -> URL {
    let dir = URL(fileURLWithPath: try makeTempDir("/tmp/nudge-e2e.XXXXXX"), isDirectory: true)
    try (patterns.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("patterns.txt"), atomically: true, encoding: .utf8)
    try #"{"enabled":true,"skipWhenTerminalFocused":false}"#.write(to: dir.appendingPathComponent("prefs.json"), atomically: true, encoding: .utf8)
    // Port 1 (tcpmux) is closed on any normal Mac.
    try "1\n".write(to: dir.appendingPathComponent("port"), atomically: true, encoding: .utf8)
    return dir
}

// MARK: - Isolated Nudge instance

/// A Nudge app launched on its own temp config dir, normally with the test
/// API on (`testAPI: false` is only for proving the gate holds).
final class NudgeInstance {
    let configDir: URL
    let process = Process()
    private(set) var port: UInt16 = 0
    private(set) var token = ""

    var patternsURL: URL { configDir.appendingPathComponent("patterns.txt") }
    var logURL: URL { configDir.appendingPathComponent("app.log") }

    init(binDir: URL, testAPI: Bool = true) throws {
        guard let dir = try? makeTempDir("/tmp/nudge-e2e.XXXXXX") else { die("mkdtemp failed: \(errno)") }
        configDir = URL(fileURLWithPath: dir, isDirectory: true)

        // Terminal-focus skipping would make results depend on whichever app
        // is frontmost on the Mac right now; the harness wants determinism.
        let prefs = #"{"enabled":true,"skipWhenTerminalFocused":false}"#
        try prefs.write(to: configDir.appendingPathComponent("prefs.json"), atomically: true, encoding: .utf8)
        try "".write(to: patternsURL, atomically: true, encoding: .utf8)

        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        process.executableURL = binDir.appendingPathComponent("Nudge")
        process.environment = NudgeInstance.environment(configDir: configDir, testAPI: testAPI)
        process.standardOutput = log
        process.standardError = log
        try process.run()

        let up = waitUntil(10) {
            guard let p = try? String(contentsOf: configDir.appendingPathComponent("port"), encoding: .utf8),
                  let port = UInt16(p.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let t = try? String(contentsOf: configDir.appendingPathComponent("token"), encoding: .utf8)
            else { return false }
            self.port = port
            self.token = t.trimmingCharacters(in: .whitespacesAndNewlines)
            // Any HTTP answer means the server is up; the gate check wants the 404.
            return (try? self.request("/test/queue", body: Data("{}".utf8))) != nil
        }
        guard up else {
            stop()
            die("isolated Nudge didn't come up within 10s; log: \(logURL.path)")
        }
    }

    static func environment(configDir: URL, testAPI: Bool) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["NUDGE_CONFIG_DIR"] = configDir.path
        env["NUDGE_TEST_API"] = testAPI ? "1" : nil
        return env
    }

    func setPatterns(_ patterns: [String]) throws {
        try (patterns.joined(separator: "\n") + "\n").write(to: patternsURL, atomically: true, encoding: .utf8)
    }

    /// The pending prompts, head first, as raw JSON objects.
    func queue() throws -> [[String: Any]] {
        let (status, body) = try request("/test/queue", body: Data("{}".utf8))
        guard status == 200,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let prompts = obj["prompts"] as? [[String: Any]]
        else { throw HarnessError.badResponse(status, String(decoding: body, as: UTF8.self)) }
        return prompts
    }

    /// Answers prompt `id` through the app's own queue. Returns the HTTP status
    /// (200 resolved, 409 not the head / no longer pending).
    func resolve(id: String, decision: String) throws -> Int {
        let body = try JSONSerialization.data(withJSONObject: ["id": id, "decision": decision])
        return try request("/test/resolve", body: body).status
    }

    /// Denies anything left over so the next case starts on an empty queue.
    func drain() {
        for _ in 0..<20 {
            guard let head = (try? queue())?.first, let id = head["id"] as? String else { return }
            _ = try? resolve(id: id, decision: "deny")
            usleep(50_000)
        }
    }

    func request(_ path: String, body: Data, token: String? = nil) throws -> (status: Int, body: Data) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = 5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token ?? self.token)", forHTTPHeaderField: "Authorization")
        let done = DispatchSemaphore(value: 0)
        var result: Result<(Int, Data), Error> = .failure(HarnessError.noResponse)
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse {
                result = .success((http.statusCode, data ?? Data()))
            }
            done.signal()
        }.resume()
        done.wait()
        let (status, data) = try result.get()
        return (status, data)
    }

    func stop(removingConfig: Bool = false) {
        defer { if removingConfig { try? FileManager.default.removeItem(at: configDir) } }
        if process.isRunning {
            process.terminate()
            if !waitUntil(3, { !process.isRunning }) { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

enum HarnessError: Error, CustomStringConvertible {
    case noResponse
    case badResponse(Int, String)

    var description: String {
        switch self {
        case .noResponse: return "no response"
        case .badResponse(let s, let b): return "HTTP \(s): \(b)"
        }
    }
}

struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func jsonEqual(_ a: Any?, _ b: Any?) -> Bool {
    let lhs = (a is NSNull ? nil : a) as? NSObject
    let rhs = (b is NSNull ? nil : b) as? NSObject
    if lhs == nil || rhs == nil { return lhs == nil && rhs == nil }
    return lhs!.isEqual(rhs!)
}

func describe(_ v: Any?) -> String {
    guard let v, !(v is NSNull) else { return "<none>" }
    if JSONSerialization.isValidJSONObject(v),
       let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) {
        return String(decoding: d, as: UTF8.self)
    }
    if let s = v as? String {
        let d = try? JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed])
        return d.map { String(String(decoding: $0, as: UTF8.self).dropFirst().dropLast()) } ?? s
    }
    return "\(v)"
}

// MARK: - Isolation guard

/// The user's real Nudge state, fingerprinted before and after the run: the
/// harness must leave ~/.config/nudge exactly as it found it.
func realConfigFingerprint() -> [String: String] {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/nudge")
    var out: [String: String] = [:]
    for name in ["port", "token", "patterns.txt", "prefs.json", "no-autolaunch"] {
        let path = dir.appendingPathComponent(name).path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            out[name] = "absent"
            continue
        }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        out[name] = "\(attrs[.size] ?? 0)@\(mtime)"
    }
    return out
}
