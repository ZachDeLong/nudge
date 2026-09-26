// End-to-end harness, layer 2: real Claude Code. Each scenario runs
// `claude -p` in a throwaway git sandbox whose `origin` is a local bare repo,
// with a settings file whose only PreToolUse hook is the freshly built
// `nudge-hook` pointed at the harness's own isolated Nudge. The harness
// answers the prompt (test API, a real click on the popover, or by killing
// Claude) and asserts on real effects: did the bare remote get the commit,
// what did Claude's transcript say happened to the tool call.
//
// Isolation from the user's real setup:
// - `--setting-sources project` keeps ~/.claude/settings.json (and the real
//   Nudge hooks in it) out; the sandbox has no project settings, so the only
//   hooks are the ones in our `--settings` file.
// - Every run asserts that from Claude's own `--include-hook-events` stream:
//   only our PreToolUse and our Stop hook may fire, each at most once per
//   call. The Stop hook is a positive control: it proves hook events are
//   being reported, so their absence means something.
// - While Claude runs, the harness watches the process tree under it for
//   anything from /Applications/Nudge.app, and the real Nudge's windows for
//   a popover.
//
// Claude is non-deterministic, so a scenario where Claude didn't do what it
// was told (never ran git push, split the command differently) is
// INCONCLUSIVE and retried once; FAIL is reserved for Nudge (or the hook
// round trip) misbehaving.
//
// Needs a logged-in `claude` in this session. Over SSH the login keychain is
// locked, so run it through scripts/gui-run.sh (see `make e2e-claude`).

import CoreGraphics
import Darwin
import Foundation

// MARK: - Fixtures

/// One JSON object per file in Tests/e2e/claude; fields map 1:1 onto these.
struct ClaudeFixture {
    let name: String
    let description: String
    let patterns: [String]
    /// Files written into the sandbox before Claude starts.
    let files: [String: String]
    /// Commit `files` in setup, so Claude only has to push.
    let commitFiles: Bool
    let prompt: String
    /// "allow" | "deny" over the test API, "click" the popover's Allow button,
    /// "kill" SIGTERM Claude while the prompt is pending.
    let respond: String
    /// Fields the first queued prompt must have (sessionId and cwd are always checked).
    let expectPrompt: [String: Any]
    /// Substrings the prompted command must contain; if Claude's command lacks
    /// them it didn't follow the instruction, so the run is INCONCLUSIVE.
    let expectCommandContains: [String]
    /// "pushed" (the remote has Claude's commit) | "unchanged".
    let expectRemote: String
    let timeout: TimeInterval

    init(url: URL) throws {
        name = url.deletingPathExtension().lastPathComponent
        guard let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw FixtureError("\(name): not a JSON object")
        }
        description = obj["description"] as? String ?? ""
        guard let patterns = obj["patterns"] as? [String] else { throw FixtureError("\(name): missing patterns") }
        self.patterns = patterns
        files = obj["files"] as? [String: String] ?? [:]
        commitFiles = obj["commitFiles"] as? Bool ?? false
        guard let prompt = obj["prompt"] as? String else { throw FixtureError("\(name): missing prompt") }
        self.prompt = prompt
        guard let respond = obj["respond"] as? String, ["allow", "deny", "click", "kill", "kill9"].contains(respond) else {
            throw FixtureError("\(name): respond must be allow | deny | click | kill | kill9")
        }
        self.respond = respond
        expectPrompt = obj["expectPrompt"] as? [String: Any] ?? [:]
        expectCommandContains = obj["expectCommandContains"] as? [String] ?? []
        guard let remote = obj["expectRemote"] as? String, ["pushed", "unchanged"].contains(remote) else {
            throw FixtureError("\(name): expectRemote must be pushed | unchanged")
        }
        expectRemote = remote
        timeout = (obj["timeoutSeconds"] as? NSNumber)?.doubleValue ?? 150
    }
}

// MARK: - Sandbox

/// /tmp/nudge-e2e-claude.XXXXXX with `work/` (the repo Claude runs in) and
/// `remote.git/` (its origin, a local bare repo, so a push never leaves the
/// machine). Git is configured locally so the user's global identity,
/// signing, and hooks don't matter.
final class Sandbox {
    let root: URL
    var work: URL { root.appendingPathComponent("work") }
    var remote: URL { root.appendingPathComponent("remote.git") }
    var settings: URL { root.appendingPathComponent("claude-settings.json") }

    init(files: [String: String], commitFiles: Bool) throws {
        let made = try makeTempDir("/tmp/nudge-e2e-claude.XXXXXX")
        // Claude reports cwd with symlinks resolved (/private/tmp/...).
        // realpath, not resolvingSymlinksInPath: that one strips /private.
        guard let real = realpath(made, nil) else { throw FixtureError("realpath \(made) failed: \(errno)") }
        root = URL(fileURLWithPath: String(cString: real), isDirectory: true)
        free(real)
        let noHooks = root.appendingPathComponent("no-hooks")
        try FileManager.default.createDirectory(at: noHooks, withIntermediateDirectories: true)
        try git(["init", "-q", "--bare", "-b", "main", remote.path], in: root)
        try git(["init", "-q", "-b", "main", work.path], in: root)
        for (key, value) in [
            ("user.name", "Nudge E2E"), ("user.email", "e2e@nudge.invalid"),
            ("commit.gpgsign", "false"), ("tag.gpgsign", "false"),
            ("core.hooksPath", noHooks.path),
        ] {
            try git(["config", key, value], in: work)
        }
        try "# nudge e2e sandbox\n".write(to: work.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(["add", "README.md"], in: work)
        try git(["commit", "-q", "-m", "init"], in: work)
        try git(["remote", "add", "origin", remote.path], in: work)
        try git(["push", "-q", "origin", "main"], in: work)
        for (name, content) in files {
            try content.write(to: work.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        if commitFiles, !files.isEmpty {
            try git(["add", "-A"], in: work)
            try git(["commit", "-q", "-m", "e2e setup"], in: work)
        }
    }

    @discardableResult
    private func git(_ args: [String], in dir: URL) throws -> String {
        let r = runTool("/usr/bin/git", ["-C", dir.path] + args)
        guard r.ok else { throw FixtureError("git \(args.joined(separator: " ")): \(r.err)") }
        return r.out
    }

    func head(of repo: URL) -> String? {
        let r = runTool("/usr/bin/git", ["-C", repo.path, "rev-parse", "--verify", "-q", "refs/heads/main"])
        return r.ok ? r.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
        // Claude Code makes ~/.claude/projects/<cwd>/memory/ for any cwd, even
        // with --no-session-persistence. rmdir only removes empty dirs, so
        // this can't take anything Claude actually wrote.
        let slug = String(work.path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let projectDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(slug)")
        rmdir(projectDir.appendingPathComponent("memory").path)
        rmdir(projectDir.path)
    }
}

/// The `--settings` file: our hook, a no-op Stop hook as the positive
/// control for the hook-event audit, and allow rules for the tools Claude
/// may use so nothing unmatched stalls headless mode.
func claudeSettings(hook: URL, configDir: URL) throws -> Data {
    // NUDGE_CONFIG_DIR goes on the hook's command line, not into Claude's
    // environment: if some other Nudge hook fired, it must not find the
    // harness instance and hide the leak.
    let command = "NUDGE_CONFIG_DIR=\(shellQuote(configDir.path)) \(shellQuote(hook.path))"
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let settings: [String: Any] = [
        "hooks": [
            "PreToolUse": [[
                "matcher": "Bash|Edit|Write|Read|MultiEdit|NotebookEdit|mcp__.*",
                "hooks": [["type": "command", "command": command, "timeout": 300]],
            ]],
            "Stop": [["hooks": [["type": "command", "command": "true"]]]],
        ],
        "permissions": ["allow": ["Bash", "Read", "Write", "Edit", "Glob", "Grep"]],
        // The user's global CLAUDE.md is instructions for real work; keep it
        // out of a test session.
        "claudeMdExcludes": ["\(home)/.claude/CLAUDE.md", "\(home)/.agent-config/**"],
    ]
    return try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
}

// MARK: - Claude process

let claudeSystemPrompt = """
You are being driven by an automated end-to-end test of a permission hook. \
Follow the user's instructions literally: run exactly the commands given, \
verbatim, with the Bash tool, and nothing else. Do not explore the repository, \
do not add flags, and do not retry or work around a command that is denied or fails.
"""

final class ClaudeRun {
    let process = Process()
    let sessionID = UUID().uuidString.lowercased()
    let started = Date()

    init(bin: String, model: String, prompt: String, settings: URL, cwd: URL,
         transcript: URL, stderr: URL) throws {
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = [
            "-p", prompt,
            "--model", model,
            "--output-format", "stream-json", "--verbose", "--include-hook-events",
            "--setting-sources", "project",
            "--settings", settings.path,
            "--strict-mcp-config",
            "--no-session-persistence",
            "--session-id", sessionID,
            "--permission-prompts", "none",
            "--tools", "Bash,Read,Write,Edit,Glob,Grep",
            "--append-system-prompt", claudeSystemPrompt,
            "--max-budget-usd", "0.50",
        ]
        process.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("NUDGE_") { env[key] = nil }
        // In case the harness itself was started from inside Claude Code.
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"] { env[key] = nil }
        process.environment = env
        FileManager.default.createFile(atPath: transcript.path, contents: nil)
        FileManager.default.createFile(atPath: stderr.path, contents: nil)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = try FileHandle(forWritingTo: transcript)
        process.standardError = try FileHandle(forWritingTo: stderr)
        try process.run()
        activeClaudePID = process.processIdentifier
    }

    var pid: pid_t { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    /// SIGTERM, then SIGKILL if it hasn't gone within `grace` seconds.
    func stop(grace: TimeInterval = 5) {
        guard process.isRunning else { return }
        process.terminate()
        if !waitUntil(grace, { !process.isRunning }) { kill(pid, SIGKILL) }
    }
}

/// For the SIGINT handler (C function pointers can't capture).
nonisolated(unsafe) var activeClaudePID: pid_t = 0
nonisolated(unsafe) var activeAppPID: pid_t = 0

// MARK: - Transcript

/// What Claude's stream-json output says happened.
struct Transcript {
    struct ToolUse {
        let id: String
        let name: String
        let input: [String: Any]
        var command: String { input["command"] as? String ?? "" }
    }
    struct ToolResult {
        let isError: Bool
        let text: String
    }
    struct HookResponse {
        let name: String
        let stdout: String
        let exitCode: Int
    }

    var toolUses: [ToolUse] = []
    var results: [String: ToolResult] = [:]
    var hookStarts: [String] = []
    var hookResponses: [HookResponse] = []
    var result: [String: Any]?
    var lines = 0

    init(url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            lines += 1
            switch obj["type"] as? String {
            case "assistant":
                let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                for block in content where block["type"] as? String == "tool_use" {
                    toolUses.append(ToolUse(id: block["id"] as? String ?? "",
                                            name: block["name"] as? String ?? "",
                                            input: block["input"] as? [String: Any] ?? [:]))
                }
            case "user":
                let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                for block in content where block["type"] as? String == "tool_result" {
                    guard let id = block["tool_use_id"] as? String else { continue }
                    results[id] = ToolResult(isError: block["is_error"] as? Bool ?? false,
                                             text: Transcript.text(of: block["content"]))
                }
            case "system":
                switch obj["subtype"] as? String {
                case "hook_started":
                    hookStarts.append(obj["hook_name"] as? String ?? "?")
                case "hook_response":
                    hookResponses.append(HookResponse(name: obj["hook_name"] as? String ?? "?",
                                                      stdout: obj["stdout"] as? String ?? "",
                                                      exitCode: (obj["exit_code"] as? NSNumber)?.intValue ?? -1))
                default:
                    break
                }
            case "result":
                result = obj
            default:
                break
            }
        }
    }

    static func text(of content: Any?) -> String {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    var pushes: [ToolUse] { toolUses.filter { $0.name == "Bash" && $0.command.contains("git push") } }
    var cost: Double { (result?["total_cost_usd"] as? NSNumber)?.doubleValue ?? 0 }
    var resultText: String { result?["result"] as? String ?? "" }
    var notLoggedIn: Bool {
        resultText.contains("Not logged in") || (result?["terminal_reason"] as? String == "api_error" && toolUses.isEmpty
            && resultText.lowercased().contains("login"))
    }
}

// MARK: - Clicking the popover

/// Finds the harness instance's popover by owner pid (two Nudges are
/// running, so never by name), screenshots it, checks it shows the prompt,
/// and clicks its Allow button through Peekaboo. Returns problems.
func clickAllow(peekaboo: String, appPID: pid_t, prompt: [String: Any], screenshot: URL) -> [String] {
    var window: WindowInfo?
    guard waitUntil(5, {
        window = popoverWindows(ownedBy: [appPID]).first
        return window != nil
    }), let window else {
        return ["no popover window owned by the harness Nudge (pid \(appPID)) appeared within 5s"]
    }
    usleep(700_000) // let the drop-in animation settle before the screenshot

    let see = runTool(peekaboo, ["see", "--window-id", "\(window.id)", "--json", "--path", screenshot.path], timeout: 40)
    guard let seeObj = try? JSONSerialization.jsonObject(with: Data(see.out.utf8)) as? [String: Any],
          seeObj["success"] as? Bool == true,
          let data = seeObj["data"] as? [String: Any],
          let snapshot = data["snapshot_id"] as? String
    else {
        return ["peekaboo see --window-id \(window.id) failed: \(see.out.prefix(400)) \(see.err.prefix(400))"]
    }
    let elements = data["ui_elements"] as? [[String: Any]] ?? []
    var problems: [String] = []
    let texts = elements.flatMap { [$0["label"] as? String, $0["value"] as? String].compactMap { $0 } }
    if let pattern = prompt["matchedPattern"] as? String, !texts.contains("Matched \(pattern)") {
        problems.append("popover doesn't show \"Matched \(pattern)\"; its texts: \(describe(texts))")
    }
    let firstLine = (prompt["command"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? ""
    if !firstLine.isEmpty, !texts.contains(where: { $0.contains(firstLine) }) {
        problems.append("popover doesn't show the command (first line \(describe(firstLine))); its texts: \(describe(texts))")
    }
    // "Allow", or "Allow, ⏎" when global shortcuts are on and the keycap shows.
    guard let allow = elements.first(where: {
        let label = $0["label"] as? String ?? ""
        return $0["ax_role"] as? String == "AXButton" && (label == "Allow" || label.hasPrefix("Allow,"))
    }), let elementID = allow["id"] as? String else {
        return problems + ["no Allow button in the popover; elements: \(describe(elements.map { $0["label"] ?? "?" }))"]
    }

    let click = runTool(peekaboo, ["click", "--on", elementID, "--snapshot", snapshot,
                                   "--window-id", "\(window.id)", "--json"], timeout: 30)
    guard let clickObj = try? JSONSerialization.jsonObject(with: Data(click.out.utf8)) as? [String: Any],
          clickObj["success"] as? Bool == true
    else {
        return problems + ["peekaboo click on \(elementID) failed: \(click.out.prefix(400)) \(click.err.prefix(400))"]
    }
    let clicked = (clickObj["data"] as? [String: Any])?["clickedElement"] as? String ?? "?"
    print("         · clicked \(describe(clicked)) in window \(window.id) (owner pid \(window.pid)); screenshot \(screenshot.path)")
    return problems
}

/// Why Peekaboo can't drive the UI right now, or nil if it can. Checked
/// before starting Claude, so a missing grant is a SKIP, not a wasted run.
/// `peekaboo permissions` misreports on macOS 27, so this does the real
/// thing on the harness's own UI: a synthetic prompt (no Claude) opens the
/// isolated Nudge's popover, and `see` must capture it and read its buttons.
func peekabooNotReady(_ peekaboo: String, instance: NudgeInstance, binDir: URL, artifacts: URL) -> String? {
    let command = "nudge-e2e-preflight"
    do {
        try instance.setPatterns(["Bash(\(command))"])
    } catch {
        return "preflight: couldn't write patterns: \(error)"
    }
    let payload: [String: Any] = [
        "session_id": "nudge-e2e-preflight", "cwd": "/tmp", "permission_mode": "default",
        "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["command": command],
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let hook = try? HookRun(binDir: binDir, instance: instance, payload: data)
    else { return "preflight: couldn't run nudge-hook" }
    defer {
        instance.drain()
        _ = hook.finish(within: 5)
        hook.kill()
    }
    guard waitUntil(5, { !((try? instance.queue()) ?? []).isEmpty }) else {
        return "preflight: the synthetic prompt never reached the isolated Nudge"
    }
    var window: WindowInfo?
    guard waitUntil(5, {
        window = popoverWindows(ownedBy: [instance.process.processIdentifier]).first
        return window != nil
    }), let window else {
        return "preflight: the isolated Nudge's popover didn't appear on screen"
    }
    usleep(500_000)
    let shot = artifacts.appendingPathComponent("peekaboo-preflight.png")
    let see = runTool(peekaboo, ["see", "--window-id", "\(window.id)", "--json", "--path", shot.path], timeout: 40)
    let obj = try? JSONSerialization.jsonObject(with: Data(see.out.utf8)) as? [String: Any]
    let elements = (obj?["data"] as? [String: Any])?["ui_elements"] as? [[String: Any]] ?? []
    guard obj?["success"] as? Bool == true, FileManager.default.fileExists(atPath: shot.path) else {
        return "Peekaboo can't capture the popover (Screen Recording?): \(see.out.prefix(300)) \(see.err.prefix(200))"
    }
    guard elements.contains(where: { $0["ax_role"] as? String == "AXButton" }) else {
        return "Peekaboo captured the popover but read no buttons from it (Accessibility?)"
    }
    try? FileManager.default.removeItem(at: shot)
    return nil
}

// MARK: - One attempt

enum Verdict: String {
    case pass = "PASS"
    case fail = "FAIL"
    case inconclusive = "INCONCLUSIVE"
    case skip = "SKIP"
}

struct Attempt {
    var verdict = Verdict.pass
    var problems: [String] = []
    var inconclusive: [String] = []
    var info: [String] = []
    var cost = 0.0
    var seconds = 0.0
}

struct SuiteContext {
    let opts: Options
    let instance: NudgeInstance
    let claude: String
    let peekaboo: String?
    let artifacts: URL
}

let realNudgeAppPath = "/Applications/Nudge.app/Contents/MacOS/Nudge"
let realNudgeBundle = "/Applications/Nudge.app/"

func runAttempt(_ fx: ClaudeFixture, attempt n: Int, ctx: SuiteContext) -> Attempt {
    var a = Attempt()
    let instance = ctx.instance
    let appPID = instance.process.processIdentifier
    let hookPath = ctx.opts.binDir.appendingPathComponent("nudge-hook").resolvingSymlinksInPath().path
    let tag = "\(fx.name)-\(n)"
    let transcriptURL = ctx.artifacts.appendingPathComponent("\(tag).jsonl")
    let stderrURL = ctx.artifacts.appendingPathComponent("\(tag).stderr.txt")

    let sandbox: Sandbox
    do {
        sandbox = try Sandbox(files: fx.files, commitFiles: fx.commitFiles)
        try claudeSettings(hook: ctx.opts.binDir.appendingPathComponent("nudge-hook"), configDir: instance.configDir)
            .write(to: sandbox.settings)
        instance.drain()
        try instance.setPatterns(fx.patterns)
    } catch {
        a.verdict = .fail
        a.problems = ["setup: \(error)"]
        return a
    }
    defer { if !ctx.opts.keepTempDir { sandbox.remove() } }
    let remoteBefore = sandbox.head(of: sandbox.remote)
    let workBefore = sandbox.head(of: sandbox.work)

    let realNudgePIDs = Set(processTable().filter { $0.path == realNudgeAppPath }.map(\.pid))

    let run: ClaudeRun
    do {
        run = try ClaudeRun(bin: ctx.claude, model: ctx.opts.model, prompt: fx.prompt, settings: sandbox.settings,
                            cwd: sandbox.work, transcript: transcriptURL, stderr: stderrURL)
    } catch {
        a.verdict = .fail
        a.problems = ["couldn't start claude: \(error)"]
        return a
    }

    // Poll until Claude exits: answer prompts as the fixture says, and watch
    // for anything from the user's real Nudge.
    var prompts: [[String: Any]] = []
    var seen = Set<String>()
    var firstPromptAt: Date?
    var answeredAt: Date?
    var killedAt: Date?
    var withdrawnAt: Date?
    var violations: [String] = []
    var lastWatch = Date.distantPast
    var timedOut = false
    let deadline = run.started.addingTimeInterval(fx.timeout)

    while run.isRunning {
        if Date() > deadline {
            timedOut = true
            break
        }
        if Date().timeIntervalSince(lastWatch) > 0.25 {
            lastWatch = Date()
            for p in descendants(of: run.pid, in: processTable()) where p.path.hasPrefix(realNudgeBundle) {
                let v = "a real Nudge binary ran inside the test session: pid \(p.pid) \(p.path)"
                if !violations.contains(v) { violations.append(v) }
            }
            for w in popoverWindows(ownedBy: realNudgePIDs) {
                let v = "the real Nudge (pid \(w.pid)) showed a popover-sized window \(w.id) during the run (if you opened it yourself, rerun)"
                if !violations.contains(v) { violations.append(v) }
            }
        }
        let queue = (try? instance.queue()) ?? []
        if killedAt != nil, withdrawnAt == nil, let id = prompts.first?["id"] as? String,
           !queue.contains(where: { $0["id"] as? String == id }) {
            withdrawnAt = Date()
        }
        if let head = queue.first, let id = head["id"] as? String, !seen.contains(id) {
            seen.insert(id)
            prompts.append(head)
            let first = prompts.count == 1
            if first { firstPromptAt = Date() }
            switch fx.respond {
            case "click" where first:
                if let peekaboo = ctx.peekaboo {
                    let shot = ctx.artifacts.appendingPathComponent("\(tag)-popover.png")
                    a.problems += clickAllow(peekaboo: peekaboo, appPID: appPID, prompt: head, screenshot: shot)
                    if !FileManager.default.fileExists(atPath: shot.path) {
                        a.problems.append("no screenshot at \(shot.path)")
                    }
                    // The click must be what answered it.
                    if !waitUntil(5, { ((try? instance.queue()) ?? []).allSatisfy { $0["id"] as? String != id } }) {
                        a.problems.append("prompt \(id) still queued 5s after clicking Allow; denying it over the test API")
                        _ = try? instance.resolve(id: id, decision: "deny")
                    }
                }
                answeredAt = Date()
            case "kill" where first, "kill9" where first:
                // SIGTERM is closing the terminal or `kill`; SIGKILL is a crash
                // or `kill -9`, where Claude Code gets no chance to clean up.
                kill(run.process.processIdentifier, fx.respond == "kill9" ? SIGKILL : SIGTERM)
                killedAt = Date()
            default:
                // Allow for allow/click, deny for deny/kill: a retry after a
                // deny gets denied too, and extras after a click are allowed.
                let decision = ["deny", "kill", "kill9"].contains(fx.respond) ? "deny" : "allow"
                if (try? instance.resolve(id: id, decision: decision)) != 200 {
                    a.problems.append("resolve(\(decision)) for prompt \(id) didn't return 200")
                }
                if first { answeredAt = Date() }
            }
        }
        usleep(100_000)
    }
    if timedOut { run.stop() }
    run.process.waitUntilExit()
    let endedAt = Date()
    a.seconds = endedAt.timeIntervalSince(run.started)
    activeClaudePID = 0

    // Withdrawal: the killed session's prompt must leave the queue.
    var withdrawnAfter: TimeInterval?
    if let killedAt, let id = prompts.first?["id"] as? String {
        if withdrawnAt != nil || waitUntil(10, { ((try? instance.queue()) ?? []).allSatisfy { $0["id"] as? String != id } }) {
            withdrawnAfter = (withdrawnAt ?? Date()).timeIntervalSince(killedAt)
        } else {
            a.problems.append("prompt \(id) still queued 10s after claude was killed (should be withdrawn)")
        }
        if let status = try? instance.resolve(id: id, decision: "allow"), status != 409 {
            a.problems.append("answering the withdrawn prompt returned HTTP \(status), expected 409")
        }
    }
    // Any of our hooks still alive now was orphaned by Claude's exit.
    let orphans = processTable().filter { $0.path == hookPath }
    if !orphans.isEmpty {
        a.problems.append("nudge-hook still running after claude exited: pids \(orphans.map(\.pid))")
        for p in orphans { kill(p.pid, SIGKILL) }
    }
    instance.drain()

    let t = Transcript(url: transcriptURL)
    a.cost = t.cost
    if t.notLoggedIn {
        die("claude says it isn't logged in (\(t.resultText)). Over SSH the login keychain is locked: run `scripts/gui-run.sh make e2e-claude`.")
    }

    // Timings.
    var timing = String(format: "claude ran %.1fs", a.seconds)
    if let f = firstPromptAt { timing += String(format: ", prompt queued at %.1fs", f.timeIntervalSince(run.started)) }
    if let ans = answeredAt { timing += String(format: ", claude exited %.1fs after the answer", endedAt.timeIntervalSince(ans)) }
    if let w = withdrawnAfter { timing += String(format: ", prompt withdrawn %.2fs after %@", w, fx.respond == "kill9" ? "SIGKILL" : "SIGTERM") }
    timing += String(format: ", $%.4f", a.cost)
    a.info.append(timing)
    let commands = t.toolUses.map { "\($0.name): \($0.command.isEmpty ? describe($0.input) : describe($0.command))" }
    a.info.append("tool calls: \(commands.isEmpty ? "none" : commands.joined(separator: " | "))")

    // 1. Isolation.
    a.problems += violations
    a.problems += auditHooks(t, finishedNormally: !timedOut && killedAt == nil)

    // 2. The core invariant: every git push Claude ran was routed to Nudge,
    //    with exactly the command Claude sent.
    for push in t.pushes where !prompts.contains(where: { $0["command"] as? String == push.command }) {
        a.problems.append("Claude ran \(describe(push.command)) but Nudge never queued a prompt for it")
    }
    guard let prompt = prompts.first else {
        if t.pushes.isEmpty {
            a.inconclusive.append("Claude never ran git push (result: \(describe(String(t.resultText.prefix(200)))))")
        }
        if timedOut { a.inconclusive.append("timed out after \(Int(fx.timeout))s") }
        return finish(a)
    }
    if prompts.count > 1 {
        a.info.append("\(prompts.count) prompts queued (Claude retried): \(prompts.map { describe($0["command"]) })")
    }
    var expected = fx.expectPrompt
    expected["sessionId"] = run.sessionID
    expected["cwd"] = sandbox.work.path
    for key in expected.keys.sorted() where !jsonEqual(prompt[key], expected[key]) {
        a.problems.append("prompt.\(key): expected \(describe(expected[key])), got \(describe(prompt[key]))")
    }
    let command = prompt["command"] as? String ?? ""
    let missing = fx.expectCommandContains.filter { !command.contains($0) }
    if !missing.isEmpty {
        a.inconclusive.append("Claude's command \(describe(command)) lacks \(describe(missing)), so it didn't run what it was asked")
    }

    // 3. Real effects.
    let remoteAfter = sandbox.head(of: sandbox.remote)
    let workAfter = sandbox.head(of: sandbox.work)
    let pushUse = t.pushes.first { $0.command == command }
    let pushResult = pushUse.flatMap { t.results[$0.id] }
    let ourHookOutputs = t.hookResponses.filter { $0.name.hasPrefix("PreToolUse:") }.map(\.stdout)
    switch fx.respond {
    case "allow", "click":
        if !ourHookOutputs.contains(where: { $0.contains(#""permissionDecision":"allow""#) }) {
            a.problems.append("no PreToolUse hook response carried permissionDecision allow; got \(describe(ourHookOutputs))")
        }
        if workAfter == workBefore, !fx.commitFiles {
            a.inconclusive.append("Claude didn't make a commit, so there was nothing to push")
        } else if remoteAfter != workAfter || remoteAfter == remoteBefore {
            a.problems.append("remote main is \(remoteAfter ?? "missing"), expected Claude's commit \(workAfter ?? "?") (was \(remoteBefore ?? "?")); push result: \(describe(pushResult?.text))")
        } else {
            a.info.append("remote main advanced \(remoteBefore?.prefix(7) ?? "?") → \(remoteAfter?.prefix(7) ?? "?")")
        }
        if let r = pushResult, r.isError {
            a.problems.append("the allowed push came back as an error: \(describe(r.text))")
        }
    case "deny":
        if remoteAfter != remoteBefore {
            a.problems.append("remote main moved \(remoteBefore ?? "?") → \(remoteAfter ?? "?") despite Deny")
        }
        if !ourHookOutputs.contains(where: { $0.contains(#""permissionDecision":"deny""#) }) {
            a.problems.append("no PreToolUse hook response carried permissionDecision deny; got \(describe(ourHookOutputs))")
        }
        let denials = t.result?["permission_denials"] as? [[String: Any]] ?? []
        if let id = pushUse?.id, !denials.contains(where: { $0["tool_use_id"] as? String == id }) {
            a.problems.append("the push isn't in the result's permission_denials: \(describe(denials))")
        }
        if let r = pushResult {
            if r.isError {
                a.info.append("Claude saw: \(describe(String(r.text.prefix(200))))")
            } else {
                a.problems.append("the denied push ran anyway; tool result: \(describe(r.text))")
            }
        } else {
            a.problems.append("no tool result for the denied push in the transcript")
        }
    case "kill", "kill9":
        if remoteAfter != remoteBefore {
            a.problems.append("remote main moved \(remoteBefore ?? "?") → \(remoteAfter ?? "?") though claude was killed before answering")
        }
        a.info.append("claude \(run.process.terminationReason == .uncaughtSignal ? "died of signal" : "exited") \(run.process.terminationStatus) after \(fx.respond == "kill9" ? "SIGKILL" : "SIGTERM")")
    default:
        break
    }
    if timedOut {
        a.problems.append("claude still running after \(Int(fx.timeout))s with the prompt answered")
    }
    return finish(a)
}

func finish(_ a: Attempt) -> Attempt {
    var a = a
    a.verdict = !a.problems.isEmpty ? .fail : (!a.inconclusive.isEmpty ? .inconclusive : .pass)
    return a
}

/// Claude's own hook-event stream vs. what our settings define. Anything
/// else firing (SessionStart, UserPromptSubmit, PostToolUse, a second
/// PreToolUse) means hooks leaked in from the user's settings or a plugin.
func auditHooks(_ t: Transcript, finishedNormally: Bool) -> [String] {
    var problems: [String] = []
    var counts: [String: Int] = [:]
    for name in t.hookStarts { counts[name, default: 0] += 1 }
    for (name, count) in counts.sorted(by: { $0.key < $1.key }) {
        if name == "Stop" {
            if count > 1 { problems.append("Stop hooks fired \(count)x; ours is the only one allowed") }
        } else if name.hasPrefix("PreToolUse:") {
            let tool = String(name.dropFirst("PreToolUse:".count))
            let calls = t.toolUses.filter { $0.name == tool }.count
            if count > calls {
                problems.append("\(name) fired \(count)x for \(calls) call(s): a second PreToolUse hook is loaded")
            }
        } else {
            problems.append("hook \(name) fired \(count)x, but the run's settings don't define it (user settings or a plugin leaked in)")
        }
    }
    if finishedNormally, t.result != nil, counts["Stop", default: 0] != 1 {
        problems.append("positive control: our Stop hook should fire exactly once, saw \(counts["Stop", default: 0]) (are hook events being reported?)")
    }
    return problems
}

// MARK: - Suite

func claudeLoggedIn(_ claude: String) -> Bool {
    let r = runTool(claude, ["auth", "status"], timeout: 30)
    guard let obj = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any] else { return false }
    return obj["loggedIn"] as? Bool == true
}

/// Fingerprint of the user's Claude Code config the harness must not touch.
func realClaudeConfigFingerprint() -> [String: String] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    var out: [String: String] = [:]
    for name in [".claude/settings.json", ".claude/settings.local.json", ".claude.json"] {
        let attrs = try? FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(name).path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        out[name] = attrs.map { "\($0[.size] ?? 0)@\(mtime)" } ?? "absent"
    }
    return out
}

func runClaudeSuite(_ opts: Options) -> Never {
    let fixturesDir = opts.fixturesDirGiven ? opts.fixturesDir : URL(fileURLWithPath: "Tests/e2e/claude")
    let fixtureURLs = ((try? FileManager.default.contentsOfDirectory(at: fixturesDir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let fixtures: [ClaudeFixture]
    do {
        fixtures = try fixtureURLs.map(ClaudeFixture.init(url:))
            .filter { fx in opts.filters.isEmpty || opts.filters.contains { fx.name.contains($0) } }
    } catch {
        die("bad fixture: \(error)")
    }
    guard !fixtures.isEmpty else { die("no fixtures in \(fixturesDir.path)") }

    guard let claude = opts.claudeBin ?? findExecutable("claude", extraDirs: ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]) else {
        die("claude not found; pass --claude-bin")
    }
    guard claudeLoggedIn(claude) else {
        die("""
        `\(claude) auth status` says not logged in for this session. Over SSH the \
        login keychain is locked; run `scripts/gui-run.sh make e2e-claude` to run \
        inside the logged-in GUI session.
        """)
    }
    let peekaboo = opts.peekabooBin ?? findExecutable("peekaboo", extraDirs: ["/opt/homebrew/bin", "/usr/local/bin"])

    let stamp: String = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }()
    let artifacts = opts.artifactsDir ?? URL(fileURLWithPath: ".build/e2e-claude/\(stamp)")
    do {
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
    } catch {
        die("can't create \(artifacts.path): \(error)")
    }

    let nudgeBefore = realConfigFingerprint()
    let claudeBefore = realClaudeConfigFingerprint()
    let instance: NudgeInstance
    do {
        instance = try NudgeInstance(binDir: opts.binDir)
    } catch {
        die("couldn't launch isolated Nudge: \(error)")
    }
    activeAppPID = instance.process.processIdentifier
    signal(SIGINT) { _ in
        if activeClaudePID > 0 { kill(activeClaudePID, SIGTERM) }
        kill(activeAppPID, SIGTERM)
        _exit(130)
    }
    print("→ isolated Nudge pid \(activeAppPID) on 127.0.0.1:\(instance.port), config \(instance.configDir.path)")
    print("→ \(claude) --model \(opts.model); artifacts in \(artifacts.path)")
    if let peekaboo { print("→ \(peekaboo)") }
    let realPIDs = processTable().filter { $0.path == realNudgeAppPath }.map(\.pid)
    print(realPIDs.isEmpty
        ? "→ real Nudge not running: its window watch has nothing to watch (the hook audit still applies)"
        : "→ real Nudge pid \(realPIDs.map(String.init).joined(separator: ",")): failing on any popover it shows")

    var tally: [Verdict: Int] = [:]
    var claudeRuns = 0
    var totalCost = 0.0
    let ctx = SuiteContext(opts: opts, instance: instance, claude: claude, peekaboo: peekaboo, artifacts: artifacts)

    for fx in fixtures {
        if fx.respond == "click" {
            let why = peekaboo.map { peekabooNotReady($0, instance: instance, binDir: opts.binDir, artifacts: artifacts) }
                ?? "peekaboo not found (pass --peekaboo)"
            if let why {
                print("SKIP         \(fx.name) — \(why)")
                tally[.skip, default: 0] += 1
                continue
            }
        }
        var final = Attempt()
        for n in 1...2 {
            claudeRuns += 1
            let a = runAttempt(fx, attempt: n, ctx: ctx)
            totalCost += a.cost
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
    if realClaudeConfigFingerprint() != claudeBefore {
        // ~/.claude.json is Claude Code's own state file; it may be rewritten
        // by any session, including the user's. Report, don't fail on it.
        print("note         ~/.claude settings/state files changed during the run: \(claudeBefore) → \(realClaudeConfigFingerprint())")
    }

    let failed = tally[.fail, default: 0] + (isolationFailed ? 1 : 0)
    print(String(format: "\n%d passed, %d failed, %d inconclusive, %d skipped — %d claude runs, $%.4f",
                 tally[.pass, default: 0], failed, tally[.inconclusive, default: 0], tally[.skip, default: 0],
                 claudeRuns, totalCost))
    exit(failed == 0 && tally[.inconclusive, default: 0] == 0 ? 0 : 1)
}
