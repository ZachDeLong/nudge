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
// hook should do with it.
//
// `--claude` switches to layer 2 (ClaudeSuite.swift, `make e2e-claude`): real
// `claude -p` sessions instead of recorded payloads.

import Darwin
import Foundation

// MARK: - Options

struct Options {
    var binDir: URL
    var fixturesDir = URL(fileURLWithPath: "Tests/e2e/fixtures")
    var fixturesDirGiven = false
    var keepTempDir = false
    var filters: [String] = []
    // Layer 2 (`--claude`) only.
    var claude = false
    var model = "haiku"
    var claudeBin: String?
    var peekabooBin: String?
    var artifactsDir: URL?
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
            opts.fixturesDirGiven = true
        case "--keep":
            opts.keepTempDir = true
        case "--claude":
            opts.claude = true
        case "--model":
            guard let v = args.next() else { die("--model needs a value") }
            opts.model = v
        case "--claude-bin":
            guard let v = args.next() else { die("--claude-bin needs a value") }
            opts.claudeBin = v
        case "--peekaboo":
            guard let v = args.next() else { die("--peekaboo needs a value") }
            opts.peekabooBin = v
        case "--artifacts":
            guard let v = args.next() else { die("--artifacts needs a value") }
            opts.artifactsDir = URL(fileURLWithPath: v)
        case "-h", "--help":
            print("""
            usage: nudge-test-e2e [--bin-dir DIR] [--fixtures DIR] [--keep] [name-filter...]
                   nudge-test-e2e --claude [--bin-dir DIR] [--fixtures DIR] [--keep]
                                  [--model NAME] [--claude-bin PATH] [--peekaboo PATH]
                                  [--artifacts DIR] [name-filter...]
            """)
            exit(0)
        default:
            opts.filters.append(arg)
        }
    }
    return opts
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

    /// With `viaShell`, the hook runs as a background child of `sh`, so killing
    /// `process` (the shell) orphans the hook while its stdout reader (us)
    /// stays alive: the "parent died" path, isolated from "reader closed".
    init(binDir: URL, instance: NudgeInstance, payload: Data, viaShell: Bool = false) throws {
        let hookPath = binDir.appendingPathComponent("nudge-hook").path
        if viaShell {
            // An async list gets /dev/null as stdin, so hand it the real one on fd 3.
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "exec 3<&0; \"$0\" <&3 3<&- & echo $! >&2; wait", hookPath]
        } else {
            process.executableURL = URL(fileURLWithPath: hookPath)
        }
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
        if let pid = shellChildPID, Darwin.kill(pid, 0) == 0 { Darwin.kill(pid, SIGKILL) }
    }

    /// The hook's pid when started `viaShell` (the shell echoes `$!` to stderr).
    var shellChildPID: pid_t? {
        stderrText.split(separator: "\n").lazy.compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }.first
    }

    /// Closes our end of the hook's stdout, as if the caller that would read
    /// the answer had died.
    func closeReader() {
        stdout.fileHandleForReading.readabilityHandler = nil
        try? stdout.fileHandleForReading.close()
    }
}

/// Total CPU time (user + system) a process has used, via `ps`.
func cpuSeconds(pid: pid_t) -> Double? {
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-o", "time=", "-p", String(pid)]
    let out = Pipe()
    ps.standardOutput = out
    ps.standardError = FileHandle.nullDevice
    guard (try? ps.run()) != nil else { return nil }
    ps.waitUntilExit()
    // "M:SS.ss" or "H:MM:SS.ss"
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = text.split(separator: ":").compactMap { Double($0) }
    guard !parts.isEmpty else { return nil }
    return parts.reduce(0) { $0 * 60 + $1 }
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
    /// the way Claude Code does when the user stops waiting; "reader-gone"
    /// closes the hook's stdout reader and "parent-killed" SIGKILLs its parent
    /// shell, the two ways a SIGKILLed Claude leaves the hook behind.
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
            guard let respond, ["allow", "deny", "hangup", "reader-gone", "parent-killed"].contains(respond) else {
                throw FixtureError("\(name): expectPrompt needs respond = allow | deny | hangup | reader-gone | parent-killed")
            }
        }
    }
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
        hook = try HookRun(binDir: binDir, instance: instance, payload: fx.payload,
                           viaShell: fx.respond == "parent-killed")
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
    case "reader-gone", "parent-killed":
        // Claude SIGKILLed: nothing signals the hook (it has its own process
        // group), so it has to notice on its own and exit.
        // The watcher sleeps in kevent; a busy loop there would burn a core
        // for as long as the user takes to answer.
        let hookPID = fx.respond == "parent-killed" ? hook.shellChildPID : hook.process.processIdentifier
        Thread.sleep(forTimeInterval: 1)
        if let pid = hookPID, let cpu = cpuSeconds(pid: pid), cpu > 0.2 {
            problems.append("hook used \(cpu)s of CPU in 1s of waiting (busy loop?)")
        }
        let hookAlive: () -> Bool
        if fx.respond == "reader-gone" {
            hook.closeReader()
            hookAlive = { hook.isRunning }
        } else {
            guard let pid = hook.shellChildPID else {
                problems.append("couldn't learn the hook's pid from the wrapper shell")
                return problems
            }
            Darwin.kill(hook.process.processIdentifier, SIGKILL) // the shell only; the hook is orphaned
            hookAlive = { Darwin.kill(pid, 0) == 0 }
        }
        if !waitUntil(3, { !hookAlive() }) {
            problems.append("hook still running 3s after its caller went away")
        }
        // exit(0) runs every atexit handler on the watcher thread: a crash
        // there would also end the process, so require a clean exit.
        if fx.respond == "reader-gone", !hook.isRunning,
           hook.process.terminationReason != .exit || hook.process.terminationStatus != 0 {
            problems.append("hook ended with \(hook.termination), expected exit 0")
        }
        let withdrawn = waitUntil(3) { ((try? instance.queue()) ?? []).allSatisfy { $0["id"] as? String != id } }
        if !withdrawn {
            problems.append("prompt \(id) still queued after its caller went away (should be withdrawn)")
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

// MARK: - Main

setvbuf(Darwin.stdout, nil, _IOLBF, 0)
let opts = parseOptions()
for bin in ["Nudge", "nudge-hook"] where !FileManager.default.isExecutableFile(atPath: opts.binDir.appendingPathComponent(bin).path) {
    die("\(bin) not found in \(opts.binDir.path) — build first (make e2e does)")
}
guard ProcessInfo.processInfo.environment["NUDGE_CONFIG_DIR"] == nil else {
    die("unset NUDGE_CONFIG_DIR; the harness makes its own")
}
if opts.claude {
    runClaudeSuite(opts)
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
