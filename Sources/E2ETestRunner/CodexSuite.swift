// End-to-end harness, layer 2 for Codex: real Codex, driven the way the
// ChatGPT app drives it. Each scenario starts `codex app-server` over stdio
// with a throwaway CODEX_HOME (auth.json copied in, deleted with the rest),
// in a throwaway git repo, with the two hook entries install-codex-hook.sh
// writes (PermissionRequest -> nudge-hook, Interrupt -> nudge-agent-hook),
// pointed at the freshly built binaries and the harness's isolated Nudge.
// The harness trusts them the way `/hooks` does (config/batchWrite of
// hooks.state), starts a thread that asks before every command (approval
// policy "untrusted"), and asserts on what Codex did: did the command run,
// what did the hook report back, did Codex fall back to asking its client.
//
// Codex waits for the PermissionRequest hook before it asks its client, so
// a request that reaches the client ("Codex's own prompt") while Nudge is
// answering is a failure.
//
// Isolation from the user's real setup:
// - CODEX_HOME is the temp home, so ~/.codex/hooks.json and config.toml are
//   never loaded, and every hook run Codex reports must come from the temp
//   hooks.json (HookRunSummary.sourcePath).
// - The harness watches the process tree under the app-server for anything
//   from /Applications/Nudge.app, and the real Nudge's windows for a popover.
// - ~/.codex's hooks.json and config.toml, and ~/.config/nudge, are
//   fingerprinted before and after.
//
// Scenarios are INCONCLUSIVE (retried once) when the model didn't run what
// it was told; FAIL is for Nudge or the hook round trip misbehaving.

import Darwin
import Foundation

// MARK: - Fixtures

/// One JSON object per file in Tests/e2e/codex.
struct CodexFixture {
    let name: String
    let description: String
    /// Codex approval policy for the thread: "untrusted" asks before any
    /// command that isn't known to be read-only.
    let policy: String
    let sandbox: String
    let prompt: String
    /// "allow" | "deny" over the test API; "interrupt" stops the turn
    /// (turn/interrupt, what the app's Stop sends); "kill9" SIGKILLs the
    /// app-server. All while the prompt is up.
    let respond: String
    /// Fields the queued prompt must have (sessionId, cwd and agent are
    /// always checked).
    let expectPrompt: [String: Any]
    /// Substrings the prompted command must contain; if Codex's command
    /// lacks them it didn't follow the instruction (INCONCLUSIVE).
    let expectCommandContains: [String]
    /// A file (relative to the repo) the command creates, and whether it
    /// must exist afterwards.
    let expectFile: String
    let expectFileExists: Bool
    let timeout: TimeInterval

    init(url: URL) throws {
        name = url.deletingPathExtension().lastPathComponent
        guard let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw FixtureError("\(name): not a JSON object")
        }
        description = obj["description"] as? String ?? ""
        policy = obj["policy"] as? String ?? "untrusted"
        sandbox = obj["sandbox"] as? String ?? "workspace-write"
        guard let prompt = obj["prompt"] as? String else { throw FixtureError("\(name): missing prompt") }
        self.prompt = prompt
        guard let respond = obj["respond"] as? String, ["allow", "deny", "interrupt", "kill9"].contains(respond) else {
            throw FixtureError("\(name): respond must be allow | deny | interrupt | kill9")
        }
        self.respond = respond
        expectPrompt = obj["expectPrompt"] as? [String: Any] ?? [:]
        expectCommandContains = obj["expectCommandContains"] as? [String] ?? []
        guard let file = obj["expectFile"] as? String, let exists = obj["expectFileExists"] as? Bool else {
            throw FixtureError("\(name): expectFile and expectFileExists are required")
        }
        expectFile = file
        expectFileExists = exists
        timeout = (obj["timeoutSeconds"] as? NSNumber)?.doubleValue ?? 120
    }
}

// MARK: - Sandbox

/// /tmp/nudge-e2e-codex.XXXXXX (0700): `home/` is CODEX_HOME, `repo/` the
/// git repo Codex works in.
final class CodexSandbox {
    let root: URL
    var home: URL { root.appendingPathComponent("home") }
    var repo: URL { root.appendingPathComponent("repo") }
    var hooksFile: URL { home.appendingPathComponent("hooks.json") }

    init(auth: URL, binDir: URL, configDir: URL) throws {
        let made = try makeTempDir("/tmp/nudge-e2e-codex.XXXXXX")
        // Codex reports cwd as given; hand it the resolved /private/tmp path
        // so what the prompt says matches.
        guard let real = realpath(made, nil) else { throw FixtureError("realpath \(made) failed: \(errno)") }
        root = URL(fileURLWithPath: String(cString: real), isDirectory: true)
        free(real)
        activeCodexSandbox = root.path
        let fm = FileManager.default
        try fm.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        let authCopy = home.appendingPathComponent("auth.json")
        try fm.copyItem(at: auth, to: authCopy)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authCopy.path)

        // The entries install-codex-hook.sh writes, with the harness's binaries
        // and config dir. NUDGE_CONFIG_DIR goes on the command line, not into
        // Codex's environment, so a leaked real hook couldn't find this Nudge.
        let prefix = "NUDGE_CONFIG_DIR=\(shellQuote(configDir.path)) "
        let hook = { (name: String) -> [String: Any] in
            ["type": "command",
             "command": prefix + shellQuote(binDir.appendingPathComponent(name).path) + " --agent codex"]
        }
        let hooks: [String: Any] = ["hooks": [
            "PermissionRequest": [["hooks": [hook("nudge-hook")]]],
            "Interrupt": [["hooks": [hook("nudge-agent-hook")]]],
        ]]
        try JSONSerialization.data(withJSONObject: hooks, options: [.prettyPrinted, .sortedKeys]).write(to: hooksFile)

        let noHooks = root.appendingPathComponent("no-git-hooks")
        try fm.createDirectory(at: noHooks, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        for (key, value) in [("user.name", "Nudge E2E"), ("user.email", "e2e@nudge.invalid"),
                             ("commit.gpgsign", "false"), ("core.hooksPath", noHooks.path)] {
            try git(["config", key, value])
        }
        try "hello from the nudge codex e2e harness\n".write(to: repo.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        try git(["add", "-A"])
        try git(["commit", "-q", "-m", "init"])
    }

    private func git(_ args: [String]) throws {
        let r = runTool("/usr/bin/git", ["-C", repo.path] + args)
        guard r.ok else { throw FixtureError("git \(args.joined(separator: " ")): \(r.err)") }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
        activeCodexSandbox = nil
    }
}

/// For the SIGINT handler: the sandbox holding a copy of auth.json.
nonisolated(unsafe) var activeCodexSandbox: String?
nonisolated(unsafe) var activeAppServerPID: pid_t = 0

// MARK: - App-server client

/// `codex app-server` over stdio: newline-delimited JSON-RPC. Records every
/// notification, and answers Codex's own approval requests with decline
/// (counting them: while Nudge answers, there shouldn't be any).
final class CodexAppServer {
    struct Event {
        let at: Date
        let method: String
        let params: [String: Any]
    }

    let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let cond = NSCondition()
    private var buffer = Data()
    private var responses: [Int: [String: Any]] = [:]
    private var nextID = 0
    private var outputClosed = false
    private var _events: [Event] = []
    private var _ownPrompts: [Event] = []

    init(codex: String, home: URL, cwd: URL, stderr: URL) throws {
        process.executableURL = URL(fileURLWithPath: codex)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("NUDGE_") || key.hasPrefix("CODEX_") { env[key] = nil }
        env["CODEX_HOME"] = home.path
        process.environment = env
        process.standardInput = input
        process.standardOutput = output
        FileManager.default.createFile(atPath: stderr.path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: stderr)
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        try process.run()
        activeAppServerPID = process.processIdentifier
    }

    var pid: pid_t { process.processIdentifier }
    var events: [Event] { cond.lock(); defer { cond.unlock() }; return _events }
    var ownPrompts: [Event] { cond.lock(); defer { cond.unlock() }; return _ownPrompts }

    private func receive(_ data: Data) {
        cond.lock()
        defer { cond.broadcast(); cond.unlock() }
        guard !data.isEmpty else {
            outputClosed = true
            output.fileHandleForReading.readabilityHandler = nil
            return
        }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            let method = msg["method"] as? String
            let params = msg["params"] as? [String: Any] ?? [:]
            if let method, let id = msg["id"] {
                // Codex asking its client: it would have shown its own prompt.
                _ownPrompts.append(Event(at: Date(), method: method, params: params))
                let answer: [String: Any]
                if method.hasSuffix("/requestApproval") && method != "item/permissions/requestApproval" {
                    answer = ["id": id, "result": ["decision": "decline"]]
                } else {
                    answer = ["id": id, "error": ["code": -32601, "message": "not supported by the harness"]]
                }
                try? send(answer)
            } else if let method {
                _events.append(Event(at: Date(), method: method, params: params))
            } else if let id = (msg["id"] as? NSNumber)?.intValue {
                responses[id] = msg
            }
        }
    }

    private func send(_ obj: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: obj)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    /// Sends a request and waits for its result.
    @discardableResult
    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval = 30) throws -> [String: Any] {
        cond.lock()
        nextID += 1
        let id = nextID
        cond.unlock()
        try send(["id": id, "method": method, "params": params])
        cond.lock()
        defer { cond.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while responses[id] == nil {
            if outputClosed { throw FixtureError("app-server closed its output while waiting for \(method)") }
            if !cond.wait(until: deadline) { throw FixtureError("no answer to \(method) within \(Int(timeout))s") }
        }
        let response = responses.removeValue(forKey: id)!
        if let error = response["error"] { throw FixtureError("\(method) failed: \(describe(error))") }
        return response["result"] as? [String: Any] ?? [:]
    }

    func notify(_ method: String) {
        try? send(["method": method])
    }

    /// Hook runs Codex reported, by notification ("hook/started" | "hook/completed").
    func hookRuns(_ method: String, event: String? = nil) -> [[String: Any]] {
        events.filter { $0.method == method }
            .compactMap { $0.params["run"] as? [String: Any] }
            .filter { event == nil || $0["eventName"] as? String == event }
    }

    /// Items Codex completed of `type` (e.g. "commandExecution").
    func completedItems(_ type: String) -> [[String: Any]] {
        events.filter { $0.method == "item/completed" }
            .compactMap { $0.params["item"] as? [String: Any] }
            .filter { $0["type"] as? String == type }
    }

    var completedTurn: [String: Any]? {
        events.last { $0.method == "turn/completed" }?.params["turn"] as? [String: Any]
    }

    var agentMessages: [String] {
        completedItems("agentMessage").compactMap { $0["text"] as? String }.filter { !$0.isEmpty }
    }

    /// Closes stdin (the app quitting), then escalates.
    func shutDown() {
        try? input.fileHandleForWriting.close()
        if !waitUntil(5, { !process.isRunning }) {
            process.terminate()
            if !waitUntil(3, { !process.isRunning }) { kill(pid, SIGKILL) }
        }
        process.waitUntilExit()
        activeAppServerPID = 0
    }
}

// MARK: - One attempt

struct CodexContext {
    let opts: Options
    let instance: NudgeInstance
    let codex: String
    let model: String
    let auth: URL
    let artifacts: URL
}

func runCodexAttempt(_ fx: CodexFixture, attempt n: Int, ctx: CodexContext) -> Attempt {
    var a = Attempt()
    let instance = ctx.instance
    let tag = "\(fx.name)-\(n)"
    let hookPath = ctx.opts.binDir.appendingPathComponent("nudge-hook").resolvingSymlinksInPath().path

    let sandbox: CodexSandbox
    do {
        sandbox = try CodexSandbox(auth: ctx.auth, binDir: ctx.opts.binDir, configDir: instance.configDir)
        instance.drain()
        try instance.setPatterns([])
    } catch {
        a.verdict = .fail
        a.problems = ["setup: \(error)"]
        return a
    }
    defer { if !ctx.opts.keepTempDir { sandbox.remove() } }

    let realNudgePIDs = Set(processTable().filter { $0.path == realNudgeAppPath }.map(\.pid))
    let server: CodexAppServer
    do {
        server = try CodexAppServer(codex: ctx.codex, home: sandbox.home, cwd: sandbox.repo,
                                    stderr: ctx.artifacts.appendingPathComponent("\(tag).stderr.txt"))
    } catch {
        a.verdict = .fail
        a.problems = ["couldn't start codex app-server: \(error)"]
        return a
    }
    defer { if server.process.isRunning { server.shutDown() } }

    // Handshake, then trust our two hooks the way /hooks does.
    let threadID: String
    let turnID: String
    do {
        try server.request("initialize", ["clientInfo": ["name": "nudge-e2e", "title": NSNull(), "version": "0"],
                                          "capabilities": ["experimentalApi": true, "requestAttestation": false]])
        server.notify("initialized")
        let listed = try server.request("hooks/list", ["cwds": [sandbox.repo.path]])
        let hooks = (listed["data"] as? [[String: Any]] ?? []).flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
        let ours = hooks.filter { $0["sourcePath"] as? String == sandbox.hooksFile.path }
        if ours.count != hooks.count {
            a.problems.append("Codex loaded hooks from outside the temp home: \(describe(hooks.map { $0["sourcePath"] ?? "?" }))")
        }
        let events = Set(ours.compactMap { $0["eventName"] as? String })
        if events != ["permissionRequest", "interrupt"] {
            a.problems.append("expected Codex to load our permissionRequest and interrupt hooks, got \(describe(Array(events)))")
        }
        let trust = ours.filter { $0["trustStatus"] as? String != "trusted" }.compactMap { hook -> [String: Any]? in
            guard let key = hook["key"] as? String, let hash = hook["currentHash"] as? String else { return nil }
            return ["keyPath": "hooks.state", "value": [key: ["trusted_hash": hash]], "mergeStrategy": "upsert"]
        }
        if !trust.isEmpty {
            try server.request("config/batchWrite", ["edits": trust, "reloadUserConfig": true])
        }
        let recheck = try server.request("hooks/list", ["cwds": [sandbox.repo.path]])
        let untrusted = (recheck["data"] as? [[String: Any]] ?? []).flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .filter { $0["trustStatus"] as? String != "trusted" }
        if !untrusted.isEmpty {
            a.problems.append("hooks still untrusted after trusting them: \(describe(untrusted.map { $0["key"] ?? "?" }))")
        }
        guard a.problems.isEmpty else { return finish(a) }

        let thread = try server.request("thread/start", [
            "cwd": sandbox.repo.path, "approvalPolicy": fx.policy, "sandbox": fx.sandbox,
            "approvalsReviewer": "user", "model": ctx.model, "ephemeral": true,
        ])
        guard let id = (thread["thread"] as? [String: Any])?["id"] as? String else {
            throw FixtureError("thread/start returned no thread id: \(describe(thread))")
        }
        threadID = id
        let turn = try server.request("turn/start", [
            "threadId": threadID, "effort": "low",
            "input": [["type": "text", "text": fx.prompt, "text_elements": [Any]()]],
        ])
        guard let tid = (turn["turn"] as? [String: Any])?["id"] as? String else {
            throw FixtureError("turn/start returned no turn id: \(describe(turn))")
        }
        turnID = tid
    } catch {
        a.verdict = .fail
        a.problems.append("app-server: \(error)")
        return finish(a)
    }

    // Poll until the turn ends: answer the prompt as the fixture says, and
    // watch for the user's real Nudge.
    var prompt: [String: Any]?
    var promptAt: Date?
    var actedAt: Date?
    var withdrawnAt: Date?
    var violations: [String] = []
    var lastWatch = Date.distantPast
    let deadline = Date().addingTimeInterval(fx.timeout)
    var timedOut = false
    while server.completedTurn == nil, server.process.isRunning {
        if Date() > deadline { timedOut = true; break }
        if Date().timeIntervalSince(lastWatch) > 0.25 {
            lastWatch = Date()
            for p in descendants(of: server.pid, in: processTable()) where p.path.hasPrefix(realNudgeBundle) {
                let v = "a real Nudge binary ran under the Codex app-server: pid \(p.pid) \(p.path)"
                if !violations.contains(v) { violations.append(v) }
            }
            for w in popoverWindows(ownedBy: realNudgePIDs) {
                let v = "the real Nudge (pid \(w.pid)) showed a popover-sized window \(w.id) during the run"
                if !violations.contains(v) { violations.append(v) }
            }
        }
        let queue = (try? instance.queue()) ?? []
        if prompt == nil, let head = queue.first, let id = head["id"] as? String {
            prompt = head
            promptAt = Date()
            switch fx.respond {
            case "allow", "deny":
                if (try? instance.resolve(id: id, decision: fx.respond)) != 200 {
                    a.problems.append("resolve(\(fx.respond)) for prompt \(id) didn't return 200")
                }
            case "interrupt":
                do {
                    try server.request("turn/interrupt", ["threadId": threadID, "turnId": turnID])
                } catch {
                    a.problems.append("turn/interrupt: \(error)")
                }
            case "kill9":
                kill(server.pid, SIGKILL)
            default:
                break
            }
            actedAt = Date()
        }
        usleep(100_000)
    }

    // Withdrawal, while the app-server (for interrupt) is still up: a Stop in
    // the ChatGPT app doesn't end the app-server, so the prompt has to go on
    // the Interrupt event alone.
    if let id = prompt?["id"] as? String, ["interrupt", "kill9"].contains(fx.respond) {
        let gone = { ((try? instance.queue()) ?? []).allSatisfy { $0["id"] as? String != id } }
        if waitUntil(3, gone) {
            withdrawnAt = Date()
        } else {
            a.problems.append("prompt \(id) still queued 3s after the \(fx.respond == "kill9" ? "SIGKILL" : "interrupt") (should be withdrawn)")
        }
        if fx.respond == "interrupt", !server.process.isRunning {
            a.problems.append("the app-server exited on its own after the interrupt, so this didn't test the Interrupt hook")
        }
        if let status = try? instance.resolve(id: id, decision: "allow"), status != 409 {
            a.problems.append("answering the withdrawn prompt returned HTTP \(status), expected 409")
        }
    }
    if fx.respond == "interrupt" {
        usleep(500_000) // let a stray approval request land before shutting down
    }
    server.shutDown()
    let orphans = processTable().filter { $0.path == hookPath }
    if !orphans.isEmpty {
        a.problems.append("nudge-hook still running after the app-server exited: pids \(orphans.map(\.pid))")
        for p in orphans { kill(p.pid, SIGKILL) }
    }
    instance.drain()

    // What happened, for the log.
    let commands = server.completedItems("commandExecution")
        .map { "\($0["status"] as? String ?? "?"): \($0["command"] as? String ?? "?")" }
    let permissionRuns = server.hookRuns("hook/completed", event: "permissionRequest")
    let turnStarted = server.events.first { $0.method == "turn/started" }?.at
    let turnEnded = server.events.last { $0.method == "turn/completed" }?.at
    var timing: [String] = []
    if let s = turnStarted, let p = promptAt {
        timing.append(String(format: "prompt queued %.1fs into the turn", p.timeIntervalSince(s)))
    }
    if let acted = actedAt, let e = turnEnded, ["allow", "deny"].contains(fx.respond) {
        timing.append(String(format: "turn ended %.1fs after the answer", e.timeIntervalSince(acted)))
    }
    if let w = withdrawnAt, let acted = actedAt {
        timing.append(String(format: "prompt withdrawn %.2fs after the %@", w.timeIntervalSince(acted), fx.respond))
    }
    a.info.append(timing.isEmpty ? "no prompt" : timing.joined(separator: ", "))
    if let turn = server.completedTurn, turn["status"] as? String != "completed" {
        let error = (turn["error"] as? [String: Any])?["message"] as? String
        a.info.append("turn ended \(turn["status"] as? String ?? "?")\(error.map { ": \(String($0.prefix(200)))" } ?? "")")
    }
    a.info.append("commands: \(commands.isEmpty ? "none" : commands.joined(separator: " | "))")
    a.info.append("PermissionRequest hook: \(permissionRuns.map { "\($0["status"] ?? "?") \(describe($0["entries"]))" })")
    if let last = server.agentMessages.last { a.info.append("Codex said: \(describe(String(last.prefix(160))))") }
    if !server.ownPrompts.isEmpty {
        a.info.append("Codex's own approval requests: \(server.ownPrompts.map { "\($0.method) \(describe($0.params["command"]))" })")
    }

    // 1. Isolation.
    a.problems += violations
    let foreign = server.hookRuns("hook/started").filter { $0["sourcePath"] as? String != sandbox.hooksFile.path }
    if !foreign.isEmpty {
        a.problems.append("hooks ran from outside the temp home: \(describe(foreign.map { $0["sourcePath"] ?? "?" }))")
    }

    // 2. The prompt.
    let fileExists = FileManager.default.fileExists(atPath: sandbox.repo.appendingPathComponent(fx.expectFile).path)
    guard let prompt else {
        if server.hookRuns("hook/started", event: "permissionRequest").isEmpty {
            a.inconclusive.append("Codex never asked for approval (commands: \(commands.isEmpty ? "none" : commands.joined(separator: " | ")))")
        } else {
            a.problems.append("Codex ran the PermissionRequest hook but Nudge never queued a prompt")
        }
        if timedOut { a.inconclusive.append("timed out after \(Int(fx.timeout))s") }
        return finish(a)
    }
    var expected = fx.expectPrompt
    expected["sessionId"] = threadID
    expected["cwd"] = sandbox.repo.path
    expected["agent"] = "codex"
    for key in expected.keys.sorted() where !jsonEqual(prompt[key], expected[key]) {
        a.problems.append("prompt.\(key): expected \(describe(expected[key])), got \(describe(prompt[key]))")
    }
    let command = prompt["command"] as? String ?? ""
    let missing = fx.expectCommandContains.filter { !command.contains($0) }
    if !missing.isEmpty {
        a.inconclusive.append("Codex's command \(describe(command)) lacks \(describe(missing)), so it didn't run what it was asked")
    }

    // 3. Real effects.
    if fileExists != fx.expectFileExists {
        a.problems.append(fx.expectFileExists
            ? "\(fx.expectFile) wasn't created: the allowed command didn't run"
            : "\(fx.expectFile) exists: the command ran though it was \(fx.respond == "deny" ? "denied" : "stopped")")
    }
    let turnStatus = server.completedTurn?["status"] as? String
    switch fx.respond {
    case "allow", "deny":
        // Nudge answered, so Codex must not have asked its own client.
        if !server.ownPrompts.isEmpty {
            a.problems.append("Codex asked its own client too: \(server.ownPrompts.map(\.method)); the hook's answer didn't take")
        }
        let wantStatus = fx.respond == "allow" ? "completed" : "blocked"
        if !permissionRuns.contains(where: { $0["status"] as? String == wantStatus }) {
            a.problems.append("no PermissionRequest hook run ended \(wantStatus): \(describe(permissionRuns.map { $0["status"] ?? "?" }))")
        }
        if fx.respond == "deny" {
            let feedback = permissionRuns.flatMap { $0["entries"] as? [[String: Any]] ?? [] }.compactMap { $0["text"] as? String }
            if !feedback.contains("The user denied this in Nudge.") {
                a.problems.append("Codex didn't get the denial message; hook entries: \(describe(feedback))")
            }
        }
        if turnStatus != "completed" { a.problems.append("turn ended \(turnStatus ?? "without turn/completed")") }
    case "interrupt":
        if turnStatus != "interrupted" { a.problems.append("turn ended \(turnStatus ?? "without turn/completed"), expected interrupted") }
        if server.hookRuns("hook/started", event: "interrupt").isEmpty {
            a.problems.append("Codex didn't run the Interrupt hook")
        }
    default:
        break
    }
    if timedOut { a.problems.append("turn still running after \(Int(fx.timeout))s") }
    return finish(a)
}

// MARK: - Suite

/// Fingerprint of the user's Codex config the harness must not touch.
func realCodexConfigFingerprint() -> [String: String] {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    var out: [String: String] = [:]
    for name in ["hooks.json", "config.toml"] {
        let attrs = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        out[name] = attrs.map { "\($0[.size] ?? 0)@\(mtime)" } ?? "absent"
    }
    return out
}

func runCodexSuite(_ opts: Options) -> Never {
    signal(SIGPIPE, SIG_IGN) // a dead app-server's stdin must be an error, not our death
    let fixturesDir = opts.fixturesDirGiven ? opts.fixturesDir : URL(fileURLWithPath: "Tests/e2e/codex")
    let fixtureURLs = ((try? FileManager.default.contentsOfDirectory(at: fixturesDir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let fixtures: [CodexFixture]
    do {
        fixtures = try fixtureURLs.map(CodexFixture.init(url:))
            .filter { fx in opts.filters.isEmpty || opts.filters.contains { fx.name.contains($0) } }
    } catch {
        die("bad fixture: \(error)")
    }
    guard !fixtures.isEmpty else { die("no fixtures in \(fixturesDir.path)") }

    guard let codex = opts.codexBin
        ?? findExecutable("codex", extraDirs: ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin"])
        ?? ["/Applications/ChatGPT.app/Contents/Resources/codex"].first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    else {
        die("codex not found; pass --codex-bin")
    }
    let auth = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    guard FileManager.default.isReadableFile(atPath: auth.path) else {
        die("no \(auth.path): log in to Codex first (the harness copies it into each temp home)")
    }
    let model = opts.modelGiven ? opts.model : "gpt-6-luna"

    let stamp: String = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }()
    let artifacts = opts.artifactsDir ?? URL(fileURLWithPath: ".build/e2e-codex/\(stamp)")
    do {
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
    } catch {
        die("can't create \(artifacts.path): \(error)")
    }

    let nudgeBefore = realConfigFingerprint()
    let codexBefore = realCodexConfigFingerprint()
    let instance: NudgeInstance
    do {
        instance = try NudgeInstance(binDir: opts.binDir)
    } catch {
        die("couldn't launch isolated Nudge: \(error)")
    }
    activeAppPID = instance.process.processIdentifier
    signal(SIGINT) { _ in
        if activeAppServerPID > 0 { kill(activeAppServerPID, SIGKILL) }
        kill(activeAppPID, SIGTERM)
        // The sandbox holds a copy of auth.json: don't leave it behind.
        if let dir = activeCodexSandbox { try? FileManager.default.removeItem(atPath: dir) }
        _exit(130)
    }
    let version = runTool(codex, ["--version"], timeout: 20).out.trimmingCharacters(in: .whitespacesAndNewlines)
    print("→ isolated Nudge pid \(activeAppPID) on 127.0.0.1:\(instance.port), config \(instance.configDir.path)")
    print("→ \(codex) (\(version)) app-server, model \(model); artifacts in \(artifacts.path)")

    var tally: [Verdict: Int] = [:]
    var codexRuns = 0
    let ctx = CodexContext(opts: opts, instance: instance, codex: codex, model: model, auth: auth, artifacts: artifacts)
    for fx in fixtures {
        var final = Attempt()
        for n in 1...2 {
            codexRuns += 1
            let a = runCodexAttempt(fx, attempt: n, ctx: ctx)
            final = a
            let label = a.verdict.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
            print("\(label) \(fx.name)\(n > 1 ? " (retry)" : "") — \(fx.description)")
            for line in a.info { print("         · \(line)") }
            for p in a.problems { print("         ✗ \(p)") }
            for p in a.inconclusive { print("         ? \(p)") }
            if a.verdict != .inconclusive { break }
        }
        tally[final.verdict, default: 0] += 1
    }

    instance.drain()
    instance.stop()
    if !opts.keepTempDir { try? FileManager.default.removeItem(at: instance.configDir) }
    var isolationFailed = false
    if realConfigFingerprint() != nudgeBefore {
        print("FAIL         isolation — ~/.config/nudge changed during the run")
        isolationFailed = true
    }
    if realCodexConfigFingerprint() != codexBefore {
        print("FAIL         isolation — ~/.codex/hooks.json or config.toml changed during the run: \(codexBefore) → \(realCodexConfigFingerprint())")
        isolationFailed = true
    }
    let failed = tally[.fail, default: 0] + (isolationFailed ? 1 : 0)
    print("\n\(tally[.pass, default: 0]) passed, \(failed) failed, \(tally[.inconclusive, default: 0]) inconclusive — \(codexRuns) codex runs")
    exit(failed == 0 && tally[.inconclusive, default: 0] == 0 ? 0 : 1)
}
