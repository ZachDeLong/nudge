// End-to-end harness, layer 1: recorded Claude Code PreToolUse payloads go
// into the real `nudge-hook` binary, against a real Nudge app, and each case
// asserts what actually happened — was a prompt queued (tool, command,
// matched pattern), and what did the hook hand back to Claude Code.
//
// No LLM, no screenshots, no clicks. The harness launches its own Nudge with
// NUDGE_CONFIG_DIR pointing at a temp dir (own port, token, patterns, prefs)
// and NUDGE_TEST_API=1, reads the queue and answers prompts over the gated
// `/test/*` endpoints, and never touches ~/.config/nudge or the installed app.
//
// Plain Swift, no XCTest, so it runs on Command Line Tools. Run via `make e2e`.
// Usage: nudge-test-e2e [--bin-dir DIR] [--fixtures DIR] [--keep] [name-filter...]
//
// Fixtures (Tests/e2e/fixtures/*.json) are driver-agnostic on purpose: the
// payload is what Claude Code sends, the expectations are what Nudge and the
// hook should do with it. A later layer can swap `runHook` for a real
// `claude -p` session and keep the same app-side assertions.

import Darwin
import Foundation

// MARK: - Options

struct Options {
    var binDir: URL
    var fixturesDir = URL(fileURLWithPath: "Tests/e2e/fixtures")
    var keepTempDir = false
    var filters: [String] = []
}

func parseOptions() -> Options {
    // Default to the directory this runner was built into: `swift build`
    // puts Nudge and nudge-hook right next to it.
    let selfURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    var opts = Options(binDir: selfURL.deletingLastPathComponent())
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--bin-dir":
            guard let v = args.next() else { die("--bin-dir needs a value") }
            opts.binDir = URL(fileURLWithPath: v)
        case "--fixtures":
            guard let v = args.next() else { die("--fixtures needs a value") }
            opts.fixturesDir = URL(fileURLWithPath: v)
        case "--keep":
            opts.keepTempDir = true
        case "-h", "--help":
            print("usage: nudge-test-e2e [--bin-dir DIR] [--fixtures DIR] [--keep] [name-filter...]")
            exit(0)
        default:
            opts.filters.append(arg)
        }
    }
    return opts
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write("nudge-test-e2e: \(message)\n".data(using: .utf8)!)
    exit(2)
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
        var template = Array("/tmp/nudge-e2e.XXXXXX".utf8CString)
        guard let dir = mkdtemp(&template) else { die("mkdtemp failed: \(errno)") }
        configDir = URL(fileURLWithPath: String(cString: dir), isDirectory: true)

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

// MARK: - Hook process

/// One `nudge-hook` invocation, fed a payload on stdin the way Claude Code does.
final class HookRun {
    let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private var out = Data()
    private var err = Data()
    private let lock = NSLock()

    init(binDir: URL, instance: NudgeInstance, payload: Data) throws {
        process.executableURL = binDir.appendingPathComponent("nudge-hook")
        process.environment = NudgeInstance.environment(configDir: instance.configDir, testAPI: false)
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in self?.append(h.availableData, err: false) }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in self?.append(h.availableData, err: true) }
        try process.run()
        stdin.fileHandleForWriting.write(payload)
        try stdin.fileHandleForWriting.close()
    }

    private func append(_ data: Data, err isErr: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isErr { err.append(data) } else { out.append(data) }
    }

    var isRunning: Bool { process.isRunning }

    /// Waits for exit, then drains the pipes.
    func finish(within seconds: TimeInterval) -> Bool {
        guard waitUntil(seconds, { !process.isRunning }) else { return false }
        process.waitUntilExit()
        for pipe in [stdout, stderr] {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        append(stdout.fileHandleForReading.readDataToEndOfFile(), err: false)
        append(stderr.fileHandleForReading.readDataToEndOfFile(), err: true)
        return true
    }

    var stdoutText: String { lock.lock(); defer { lock.unlock() }; return String(decoding: out, as: UTF8.self) }
    var stderrText: String { lock.lock(); defer { lock.unlock() }; return String(decoding: err, as: UTF8.self) }

    /// "exit N" or "signal N", for messages.
    var termination: String {
        process.terminationReason == .uncaughtSignal
            ? "signal \(process.terminationStatus)"
            : "exit \(process.terminationStatus)"
    }

    func kill() {
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }
}

// MARK: - Fixtures

/// One JSON object per file in Tests/e2e/fixtures; the fields map 1:1 onto
/// the properties below. Cases run in file-name order.
struct Fixture {
    let name: String
    let description: String
    let patterns: [String]
    /// Sent verbatim when the fixture holds a string (a recorded payload,
    /// byte for byte, or deliberately malformed input); re-serialized otherwise.
    let payload: Data
    /// Fields the queued prompt must have; nil = nothing may be queued.
    let expectPrompt: [String: Any]?
    /// "allow" | "deny" answer it through the app; "hangup" SIGTERMs the hook
    /// the way Claude Code does when the user stops waiting.
    let respond: String?
    /// Exact hook stdout as JSON; nil = stdout must be empty.
    let expectStdout: Any?
    let expectExit: Int32
    /// Set when the case asserts what *should* happen but currently doesn't.
    let knownFailure: String?

    init(url: URL) throws {
        name = url.deletingPathExtension().lastPathComponent
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixtureError("\(name): not a JSON object")
        }
        description = obj["description"] as? String ?? ""
        guard let patterns = obj["patterns"] as? [String] else { throw FixtureError("\(name): missing patterns") }
        self.patterns = patterns
        switch obj["payload"] {
        case let s as String:
            payload = Data(s.utf8)
        case let o as [String: Any]:
            payload = try JSONSerialization.data(withJSONObject: o)
        default:
            throw FixtureError("\(name): payload must be an object or string")
        }
        expectPrompt = obj["expectPrompt"] as? [String: Any]
        respond = obj["respond"] as? String
        let stdout = obj["expectStdout"]
        expectStdout = stdout is NSNull ? nil : stdout
        expectExit = (obj["expectExit"] as? NSNumber)?.int32Value ?? 0
        knownFailure = obj["knownFailure"] as? String

        if expectPrompt != nil {
            guard let respond, ["allow", "deny", "hangup"].contains(respond) else {
                throw FixtureError("\(name): expectPrompt needs respond = allow | deny | hangup")
            }
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

// MARK: - Running a case

/// Runs one fixture, returning the list of expectation failures (empty = pass).
func run(_ fx: Fixture, instance: NudgeInstance, binDir: URL) -> [String] {
    var problems: [String] = []
    instance.drain()
    do {
        try instance.setPatterns(fx.patterns)
    } catch {
        return ["couldn't write patterns: \(error)"]
    }

    let hook: HookRun
    do {
        hook = try HookRun(binDir: binDir, instance: instance, payload: fx.payload)
    } catch {
        return ["couldn't start nudge-hook: \(error)"]
    }
    defer { hook.kill() }

    // Whichever happens first: the hook exits (no prompt) or a prompt shows up.
    var queued: [[String: Any]] = []
    waitUntil(5) {
        queued = (try? instance.queue()) ?? []
        return !queued.isEmpty || !hook.isRunning
    }
    if queued.isEmpty, !hook.isRunning {
        // It may have queued and been answered by something else in between;
        // the hook's output check below catches that.
        queued = (try? instance.queue()) ?? []
    }

    guard let expected = fx.expectPrompt else {
        if let got = queued.first {
            problems.append("expected no prompt, but one was queued: \(describe(got))")
            // Unblock the hook now rather than letting it hang out the wait.
            if let id = got["id"] as? String { _ = try? instance.resolve(id: id, decision: "deny") }
        }
        if !hook.finish(within: 5) {
            problems.append("hook still running after 5s with nothing to answer")
        }
        checkOutput(fx, hook, into: &problems)
        return problems
    }

    guard let prompt = queued.first, let id = prompt["id"] as? String else {
        _ = hook.finish(within: 1)
        problems.append("expected a prompt, but none was queued (hook \(hook.isRunning ? "still running" : hook.termination), stdout \(describe(hook.stdoutText)), stderr \(describe(hook.stderrText)))")
        return problems
    }
    if queued.count != 1 {
        problems.append("expected 1 queued prompt, found \(queued.count)")
    }
    for key in expected.keys.sorted() where !jsonEqual(prompt[key], expected[key]) {
        problems.append("prompt.\(key): expected \(describe(expected[key])), got \(describe(prompt[key]))")
    }

    switch fx.respond {
    case "hangup":
        // Claude Code gives up on a hook by killing it: Esc in the terminal,
        // answering there instead, or the session ending.
        hook.process.terminate()
        if !hook.finish(within: 5) { problems.append("hook ignored SIGTERM") }
        let withdrawn = waitUntil(3) { ((try? instance.queue()) ?? []).allSatisfy { $0["id"] as? String != id } }
        if !withdrawn {
            problems.append("prompt \(id) still queued 3s after its hook died (should be withdrawn)")
        }
        // Answering a withdrawn prompt must reach no one.
        if let status = try? instance.resolve(id: id, decision: "allow"), status != 409 {
            problems.append("resolving the withdrawn prompt returned HTTP \(status), expected 409")
        }
        if !hook.stdoutText.isEmpty {
            problems.append("killed hook wrote stdout: \(describe(hook.stdoutText))")
        }
    default:
        let decision = fx.respond!
        do {
            let status = try instance.resolve(id: id, decision: decision)
            if status != 200 { problems.append("resolve(\(decision)) returned HTTP \(status)") }
        } catch {
            problems.append("resolve(\(decision)) failed: \(error)")
        }
        if !hook.finish(within: 5) {
            problems.append("hook still waiting 5s after the \(decision) was sent")
            return problems
        }
        checkOutput(fx, hook, into: &problems)
        if let left = try? instance.queue(), !left.isEmpty {
            problems.append("queue not empty after answering: \(left.count) left")
        }
    }
    return problems
}

func checkOutput(_ fx: Fixture, _ hook: HookRun, into problems: inout [String]) {
    guard !hook.isRunning else { return }
    if hook.process.terminationReason != .exit || hook.process.terminationStatus != fx.expectExit {
        problems.append("hook: expected exit \(fx.expectExit), got \(hook.termination)")
    }
    let text = hook.stdoutText
    if let expected = fx.expectStdout {
        guard let got = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else {
            problems.append("hook stdout: expected \(describe(expected)), got non-JSON \(describe(text))")
            return
        }
        if !jsonEqual(got, expected) {
            problems.append("hook stdout: expected \(describe(expected)), got \(describe(got))")
        }
    } else if !text.isEmpty {
        problems.append("hook stdout: expected nothing, got \(describe(text))")
    }
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

// MARK: - Main

setvbuf(Darwin.stdout, nil, _IOLBF, 0)
let opts = parseOptions()
for bin in ["Nudge", "nudge-hook"] where !FileManager.default.isExecutableFile(atPath: opts.binDir.appendingPathComponent(bin).path) {
    die("\(bin) not found in \(opts.binDir.path) — build first (make e2e does)")
}
guard ProcessInfo.processInfo.environment["NUDGE_CONFIG_DIR"] == nil else {
    die("unset NUDGE_CONFIG_DIR; the harness makes its own")
}

let fixtureURLs = ((try? FileManager.default.contentsOfDirectory(at: opts.fixturesDir, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
let fixtures: [Fixture]
do {
    fixtures = try fixtureURLs.map(Fixture.init(url:))
        .filter { fx in opts.filters.isEmpty || opts.filters.contains { fx.name.contains($0) } }
} catch {
    die("bad fixture: \(error)")
}
guard !fixtures.isEmpty else { die("no fixtures in \(opts.fixturesDir.path)") }

let before = realConfigFingerprint()
let instance: NudgeInstance
do {
    instance = try NudgeInstance(binDir: opts.binDir)
} catch {
    die("couldn't launch isolated Nudge: \(error)")
}
print("→ isolated Nudge on 127.0.0.1:\(instance.port), config \(instance.configDir.path)")

// Ctrl-C still takes the isolated app down, so an interrupted run doesn't
// strand a second menu bar icon. (The temp dir stays; it's under /tmp.)
var appPID: pid_t = instance.process.processIdentifier
signal(SIGINT) { _ in
    kill(appPID, SIGTERM)
    _exit(130)
}

var passed = 0, failed = 0, xfailed = 0, xpassed = 0
var report: [String] = []

// Preflight: the gate itself. An instance launched without NUDGE_TEST_API
// must not serve /test/* at all, even with the right token...
do {
    let plain = try NudgeInstance(binDir: opts.binDir, testAPI: false)
    let status = try plain.request("/test/queue", body: Data("{}".utf8)).status
    plain.stop(removingConfig: true)
    if status == 404 {
        print("PASS   preflight-gate — without NUDGE_TEST_API, /test/queue is a 404 even with the token")
        passed += 1
    } else {
        print("FAIL   preflight-gate — without NUDGE_TEST_API, /test/queue returned \(status), expected 404")
        failed += 1
    }
} catch {
    print("FAIL   preflight-gate — \(error)")
    failed += 1
}

// ...and with it, nothing answers without this instance's bearer token.
do {
    let (status, _) = try instance.request("/test/queue", body: Data("{}".utf8), token: String(repeating: "0", count: 64))
    if status == 401 {
        print("PASS   preflight-auth — /test/queue rejects a wrong token (401)")
        passed += 1
    } else {
        print("FAIL   preflight-auth — /test/queue with a wrong token returned \(status), expected 401")
        failed += 1
    }
} catch {
    print("FAIL   preflight-auth — \(error)")
    failed += 1
}

for fx in fixtures {
    let start = Date()
    let problems = run(fx, instance: instance, binDir: opts.binDir)
    let ms = Int(Date().timeIntervalSince(start) * 1000)
    let label: String
    switch (problems.isEmpty, fx.knownFailure != nil) {
    case (true, false): label = "PASS  "; passed += 1
    case (false, false): label = "FAIL  "; failed += 1
    case (false, true): label = "XFAIL "; xfailed += 1
    case (true, true): label = "XPASS "; xpassed += 1
    }
    print("\(label) \(fx.name) (\(ms)ms) — \(fx.description)")
    if let why = fx.knownFailure {
        print("         known failure: \(why)")
    }
    for p in problems { print("         · \(p)") }
}

instance.drain()
instance.stop()
let after = realConfigFingerprint()
if before != after {
    print("FAIL   isolation — ~/.config/nudge changed during the run: \(before) → \(after)")
    failed += 1
}
if opts.keepTempDir {
    print("→ kept \(instance.configDir.path)")
} else {
    try? FileManager.default.removeItem(at: instance.configDir)
}

print("\n\(passed) passed, \(failed) failed, \(xfailed) known failures, \(xpassed) unexpectedly passed")
if xpassed > 0 {
    print("(an XPASS means a knownFailure got fixed — drop the knownFailure field from that fixture)")
}
exit(failed + xpassed == 0 ? 0 : 1)
