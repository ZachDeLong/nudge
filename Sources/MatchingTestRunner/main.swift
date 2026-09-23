// Command-line runner for NudgeHookCore matching tests + NudgeCore token tests.
//
// Plain Swift assertions so this works on machines with only Command Line
// Tools (no XCTest). Run via `make test`. Build via `swift build --product
// nudge-test-matching`.

import Foundation
import NudgeCore
import NudgeHookCore

var failures: [String] = []
var passed = 0

func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected {
        passed += 1
    } else {
        failures.append("✗ \(name)\n    expected: \(expected)\n    actual:   \(actual)")
    }
}

func expectNil<T>(_ actual: T?, _ name: String) {
    if actual == nil {
        passed += 1
    } else {
        failures.append("✗ \(name)\n    expected: nil\n    actual:   \(String(describing: actual!))")
    }
}

// MARK: splitBashCommand — core operators

expect(splitBashCommand("git push origin main"), ["git push origin main"], "split: no operators")
expect(splitBashCommand("cd /foo && git push"), ["cd /foo", "git push"], "split: &&")
expect(splitBashCommand("make build || echo failed"), ["make build", "echo failed"], "split: ||")
expect(splitBashCommand("ls; pwd; whoami"), ["ls", "pwd", "whoami"], "split: ;")
expect(splitBashCommand("cat foo | grep bar"), ["cat foo", "grep bar"], "split: |")
expect(splitBashCommand("sleep 5 & echo done"), ["sleep 5", "echo done"], "split: &")
expect(
    splitBashCommand("cd /tmp && rm -rf foo; echo done"),
    ["cd /tmp", "rm -rf foo", "echo done"],
    "split: mixed operators"
)

// MARK: splitBashCommand — quoting and substitution

expect(
    splitBashCommand("echo \"hello && world\" && pwd"),
    ["echo \"hello && world\"", "pwd"],
    "split: respects double quotes"
)
expect(
    splitBashCommand("echo 'a; b; c' ; pwd"),
    ["echo 'a; b; c'", "pwd"],
    "split: respects single quotes"
)
expect(
    splitBashCommand("echo $(date && hostname) && ls"),
    ["echo $(date && hostname)", "ls"],
    "split: respects $(...)"
)
expect(
    splitBashCommand("echo `date && hostname` && ls"),
    ["echo `date && hostname`", "ls"],
    "split: respects backticks"
)
expect(
    splitBashCommand("echo a \\&\\& b && pwd"),
    ["echo a \\&\\& b", "pwd"],
    "split: respects escaped operators"
)

// MARK: splitBashCommand — redirection tokens (regression)

expect(
    splitBashCommand("ls &>/tmp/out && rm -rf x"),
    ["ls &>/tmp/out", "rm -rf x"],
    "split: &> is redirect, not background"
)
expect(
    splitBashCommand("echo hi 2>&1 ; rm -rf foo"),
    ["echo hi 2>&1", "rm -rf foo"],
    "split: 2>&1 is FD-dup, not background"
)

// MARK: splitBashCommand — arithmetic

expect(
    splitBashCommand("echo $((1+1)) && pwd"),
    ["echo $((1+1))", "pwd"],
    "split: $((arith)) doesn't break operator parsing"
)
expect(
    splitBashCommand("echo $((1>2 && 0)) && rm foo"),
    ["echo $((1>2 && 0))", "rm foo"],
    "split: && inside $((arith)) doesn't split"
)

// MARK: splitBashCommand — subshells and brace groups

expect(
    splitBashCommand("(rm -rf foo); ls"),
    ["(rm -rf foo)", "ls"],
    "split: subshell stays as one segment"
)
expect(
    splitBashCommand("(cd /foo && rm -rf bar) && deploy"),
    ["(cd /foo && rm -rf bar)", "deploy"],
    "split: && inside subshell doesn't split"
)
expect(
    splitBashCommand("{ rm -rf foo; }"),
    ["{ rm -rf foo; }"],
    "split: brace group stays as one segment"
)

// MARK: splitBashCommand — whitespace, edge cases

expect(splitBashCommand("  ls   &&   pwd  "), ["ls", "pwd"], "split: trims whitespace")
expect(splitBashCommand(""), [], "split: empty input")
expect(splitBashCommand("ls && "), ["ls"], "split: trailing operator")
expect(
    splitBashCommand("ls\r\n&& rm foo"),
    ["ls", "rm foo"],
    "split: trims CRLF"
)

// MARK: splitBashCommand — newlines are separators (regression)
//
// Claude Code emits multi-line bash constantly. Before this, the whole block
// stayed one segment and no prefix/exact pattern could ever match past line 1.

expect(splitBashCommand("ls\nrm -rf foo"), ["ls", "rm -rf foo"], "split: newline separates")
expect(
    splitBashCommand("cd /tmp\necho hi\nrm -rf foo"),
    ["cd /tmp", "echo hi", "rm -rf foo"],
    "split: multiple newlines"
)
expect(splitBashCommand("\n\nls\n\n"), ["ls"], "split: blank lines collapse away")
expect(
    splitBashCommand("ls\n&& rm foo"),
    ["ls", "rm foo"],
    "split: newline then operator doesn't emit an empty segment"
)
expect(
    splitBashCommand("git push \\\n  --force"),
    ["git push \\\n  --force"],
    "split: backslash line continuation stays one segment"
)
expect(
    splitBashCommand("echo \"line1\nline2\" && ls"),
    ["echo \"line1\nline2\"", "ls"],
    "split: newline inside double quotes is not a separator"
)
expect(
    splitBashCommand("echo 'line1\nline2'"),
    ["echo 'line1\nline2'"],
    "split: newline inside single quotes is not a separator"
)
expect(
    splitBashCommand("echo $(date\nhostname)"),
    ["echo $(date\nhostname)"],
    "split: newline inside $(...) is not a separator"
)
expect(
    splitBashCommand("(cd /tmp\nrm -rf foo)"),
    ["(cd /tmp\nrm -rf foo)"],
    "split: newline inside a subshell stays wrapped for peeling"
)

// MARK: bashCandidates — peel subshell/brace wrappers

expect(
    bashCandidates(for: "(rm -rf foo); ls"),
    ["(rm -rf foo)", "rm -rf foo", "ls"],
    "candidates: peels subshell"
)
expect(
    bashCandidates(for: "{ rm -rf foo; }"),
    ["{ rm -rf foo; }", "rm -rf foo"],
    "candidates: peels brace group"
)
expect(
    bashCandidates(for: "(cd /foo && rm -rf bar)"),
    ["(cd /foo && rm -rf bar)", "cd /foo", "rm -rf bar"],
    "candidates: peels subshell and re-splits inside"
)
expect(
    bashCandidates(for: "(cd /tmp\nrm -rf foo)"),
    ["(cd /tmp\nrm -rf foo)", "cd /tmp", "rm -rf foo"],
    "candidates: peels subshell and splits its newlines"
)

// MARK: parsePattern — tighter validation

func parseToOptional(_ p: String) -> String? {
    guard let r = parsePattern(p) else { return nil }
    return "\(r.tool):\(r.spec)"
}

expect(parseToOptional("Bash(git push:*)"), "Bash:git push:*", "parse: well-formed prefix")
expect(parseToOptional("Edit(/etc/**)"), "Edit:/etc/**", "parse: well-formed path")
expectNil(parseToOptional("Bash()"), "parse: rejects empty inner")
expectNil(parseToOptional("Bash(unclosed"), "parse: rejects no closing paren")
expectNil(parseToOptional("(no tool)"), "parse: rejects empty tool name")
expectNil(parseToOptional("nothing here"), "parse: rejects no parens at all")

// MARK: hasTokenPrefix — token-boundary safety

expect(hasTokenPrefix("rm", prefix: "rm"), true, "tokenprefix: exact match")
expect(hasTokenPrefix("rm -rf foo", prefix: "rm"), true, "tokenprefix: prefix + space")
expect(hasTokenPrefix("rmdir /tmp", prefix: "rm"), false, "tokenprefix: rmdir is not rm")
expect(hasTokenPrefix("rmadison ubuntu", prefix: "rm"), false, "tokenprefix: rmadison is not rm")
expect(hasTokenPrefix("git push", prefix: "git push"), true, "tokenprefix: multi-word exact")
expect(hasTokenPrefix("git push origin main", prefix: "git push"), true, "tokenprefix: multi-word prefix + space")
expect(hasTokenPrefix("git pushd", prefix: "git push"), false, "tokenprefix: git pushd is not git push")

// MARK: collapseWhitespace + spacing tolerance (regression)
//
// `git  push --force` used to slip past `Bash(git push:*)` because the prefix
// compare was byte-exact on the space run.

expect(collapseWhitespace("  git   push  "), "git push", "collapse: trims and collapses runs")
expect(collapseWhitespace("git\t\tpush"), "git push", "collapse: tabs become one space")
expect(collapseWhitespace("git push"), "git push", "collapse: already-normal is unchanged")
expect(collapseWhitespace("   "), "", "collapse: whitespace-only becomes empty")

expect(hasTokenPrefix("git  push origin", prefix: "git push"), true, "tokenprefix: double space in segment")
expect(hasTokenPrefix("git\tpush origin", prefix: "git push"), true, "tokenprefix: tab in segment")
expect(hasTokenPrefix("git push origin", prefix: "git  push"), true, "tokenprefix: double space in pattern")
expect(hasTokenPrefix("git  pushd", prefix: "git push"), false, "tokenprefix: spacing tolerance doesn't loosen the boundary")
expect(hasTokenPrefix("rm -rf foo", prefix: ""), false, "tokenprefix: empty prefix never matches")
expect(hasTokenPrefix("rm -rf foo", prefix: "   "), false, "tokenprefix: whitespace-only prefix never matches")

// MARK: matchedPattern — baseline (existing behavior preserved)

let patterns = [
    "Bash(git push:*)",
    "Bash(rm:*)",
    "Bash(*--force*)",
    "Bash(*deploy*)",
    "Edit(/etc/**)",
    "Write(**/.env*)",
]

expect(
    matchedPattern(toolName: "Bash", target: "git push", patterns: patterns),
    "Bash(git push:*)",
    "match: bare git push"
)
expect(
    matchedPattern(toolName: "Bash", target: "git push origin main", patterns: patterns),
    "Bash(git push:*)",
    "match: git push with args"
)
expect(
    matchedPattern(toolName: "Bash", target: "cd /foo && git push", patterns: patterns),
    "Bash(git push:*)",
    "match: chained git push"
)
expect(
    matchedPattern(toolName: "Bash", target: "cd /tmp && rm -rf build", patterns: patterns),
    "Bash(rm:*)",
    "match: chained rm"
)
expectNil(
    matchedPattern(toolName: "Bash", target: "cd /foo && ls -la", patterns: patterns),
    "match: chained command with no matching segment"
)

// MARK: matchedPattern — over-match regression (rmdir, rmadison)

expectNil(
    matchedPattern(toolName: "Bash", target: "rmdir /tmp/foo", patterns: patterns),
    "match: rmdir doesn't match Bash(rm:*)"
)
expectNil(
    matchedPattern(toolName: "Bash", target: "cd /foo && rmadison ubuntu", patterns: patterns),
    "match: rmadison doesn't match Bash(rm:*) even when chained"
)

// MARK: matchedPattern — subshell/brace evasion (regression)

expect(
    matchedPattern(toolName: "Bash", target: "(rm -rf foo)", patterns: patterns),
    "Bash(rm:*)",
    "match: subshell-wrapped rm caught"
)
expect(
    matchedPattern(toolName: "Bash", target: "(rm -rf foo); ls", patterns: patterns),
    "Bash(rm:*)",
    "match: subshell + chained ls — rm wins"
)
expect(
    matchedPattern(toolName: "Bash", target: "{ rm -rf foo; }", patterns: patterns),
    "Bash(rm:*)",
    "match: brace-group-wrapped rm caught"
)
expect(
    matchedPattern(toolName: "Bash", target: "(cd /foo && rm -rf bar) && deploy", patterns: patterns),
    "Bash(*deploy*)",
    "match: subshell + infix deploy — infix still wins on full string"
)

// MARK: matchedPattern — multi-line evasion (regression)

expect(
    matchedPattern(toolName: "Bash", target: "ls\nrm -rf /tmp/foo", patterns: patterns),
    "Bash(rm:*)",
    "match: newline-separated rm caught"
)
expect(
    matchedPattern(toolName: "Bash", target: "cd /tmp\necho hi\nrm -rf foo", patterns: patterns),
    "Bash(rm:*)",
    "match: rm on the third line caught"
)
expect(
    matchedPattern(toolName: "Bash", target: "cd /repo\ngit push origin main", patterns: patterns),
    "Bash(git push:*)",
    "match: newline-separated git push caught"
)
expect(
    matchedPattern(toolName: "Bash", target: "(cd /tmp\nrm -rf foo)", patterns: patterns),
    "Bash(rm:*)",
    "match: newline inside a subshell still peels to rm"
)
expect(
    matchedPattern(toolName: "Bash", target: "git push \\\n  --force origin", patterns: patterns),
    "Bash(*--force*)",
    "match: line continuation keeps the command whole, infix still wins"
)
// Heredoc bodies get split too. That's the deliberate trade: an extra prompt
// when a script *containing* `rm -rf` is written out, never a missed one.
expect(
    matchedPattern(toolName: "Bash", target: "cat <<EOF > /tmp/s.sh\nrm -rf /tmp/foo\nEOF", patterns: patterns),
    "Bash(rm:*)",
    "match: heredoc body errs toward prompting"
)
// A quoted newline is still just text — no phantom segment, no false prompt.
expectNil(
    matchedPattern(toolName: "Bash", target: "echo 'safe\nrm -rf foo'", patterns: patterns),
    "match: rm inside a single-quoted multi-line string doesn't fire"
)

// MARK: matchedPattern — spacing tolerance (regression)

expect(
    matchedPattern(toolName: "Bash", target: "git  push origin main", patterns: patterns),
    "Bash(git push:*)",
    "match: double space between git and push"
)
expect(
    matchedPattern(toolName: "Bash", target: "git\tpush origin main", patterns: patterns),
    "Bash(git push:*)",
    "match: tab between git and push"
)
expect(
    matchedPattern(toolName: "Bash", target: "ls &&    rm   -rf foo", patterns: patterns),
    "Bash(rm:*)",
    "match: padded chain segment"
)
expect(
    matchedPattern(toolName: "Bash", target: "git  pushd /tmp", patterns: ["Bash(git push:*)"]),
    nil,
    "match: spacing tolerance doesn't turn pushd into push"
)
expect(
    matchedPattern(toolName: "Bash", target: "git  push", patterns: ["Bash(git push)"]),
    "Bash(git push)",
    "match: exact pattern tolerates spacing too"
)

// MARK: matchedPattern — infix normalization (the BLOCKER)

expect(
    matchedPattern(toolName: "Bash", target: "git push --FORCE origin main", patterns: patterns),
    "Bash(*--force*)",
    "match: case-folded infix catches --FORCE"
)
expect(
    matchedPattern(toolName: "Bash", target: "git push --for\"\"ce", patterns: patterns),
    "Bash(*--force*)",
    "match: stripped quotes catches --for\"\"ce"
)
expect(
    matchedPattern(toolName: "Bash", target: "git push --for'\"\"'ce", patterns: patterns),
    "Bash(*--force*)",
    "match: mixed quotes still strip"
)
expect(
    matchedPattern(toolName: "Bash", target: "git push --for\\ce", patterns: patterns),
    "Bash(*--force*)",
    "match: stripped backslash catches --for\\ce"
)
expect(
    matchedPattern(toolName: "Bash", target: "git push $(echo --force)", patterns: patterns),
    "Bash(*--force*)",
    "match: $(echo --force) body inlined into haystack"
)
expect(
    matchedPattern(toolName: "Bash", target: "git push `echo --force`", patterns: patterns),
    "Bash(*--force*)",
    "match: `echo --force` body inlined into haystack"
)

// MARK: matchedPattern — infix wins over prefix (priority preserved)

expect(
    matchedPattern(toolName: "Bash", target: "git push --force origin main", patterns: patterns),
    "Bash(*--force*)",
    "match: infix wins over prefix on same command"
)
expect(
    matchedPattern(toolName: "Bash", target: "cd /foo && git push --force", patterns: patterns),
    "Bash(*--force*)",
    "match: infix wins even when chained"
)
expect(
    matchedPattern(toolName: "Bash", target: "git push --FORCE origin", patterns: patterns),
    "Bash(*--force*)",
    "match: infix wins even with case variant"
)

// MARK: matchedPattern — empty-pattern rejection (regression)

let evilPatterns = ["Bash(:*)", "Bash()", "(no tool)"]
expectNil(
    matchedPattern(toolName: "Bash", target: "anything at all", patterns: evilPatterns),
    "match: Bash(:*), Bash(), (no tool) all silently dropped"
)

// MARK: matchedPattern — path patterns (sanity, unchanged)

expect(
    matchedPattern(toolName: "Edit", target: "/etc/hosts", patterns: patterns),
    "Edit(/etc/**)",
    "match: edit path inside /etc"
)
expectNil(
    matchedPattern(toolName: "Edit", target: "/Users/zach/foo.txt", patterns: patterns),
    "match: edit path outside /etc"
)
expect(
    matchedPattern(toolName: "Write", target: "/Users/zach/project/.env", patterns: patterns),
    "Write(**/.env*)",
    "match: write .env file"
)

// MARK: family — MCP tool detection

expect(family(for: "mcp__playwright__browser_evaluate"), .mcp, "family: mcp__... → .mcp")
expect(family(for: "mcp__computer-use__request_access"), .mcp, "family: mcp__... with hyphen server → .mcp")
expect(family(for: "mcp__"), .unknown, "family: bare mcp__ prefix is not a real tool")
expect(family(for: "Bash"), .bash, "family: Bash unchanged")
expect(family(for: "Edit"), .path, "family: Edit unchanged")
expect(family(for: "WebFetch"), .unknown, "family: non-matched tools stay unknown")

// MARK: mcpMatchTarget — strips the `mcp__` prefix

expect(
    mcpMatchTarget(for: "mcp__playwright__browser_evaluate"),
    "playwright__browser_evaluate",
    "mcpMatchTarget: strips mcp__ prefix"
)
expectNil(mcpMatchTarget(for: "Bash"), "mcpMatchTarget: nil for non-MCP tool")
expectNil(mcpMatchTarget(for: "mcp__"), "mcpMatchTarget: nil for empty MCP name")

// MARK: matchedPattern — MCP

let mcpPatterns = [
    "Mcp(playwright__*)",
    "Mcp(computer-use__request_access)",
]

expect(
    matchedPattern(
        toolName: "mcp__playwright__browser_evaluate",
        target: "playwright__browser_evaluate",
        patterns: mcpPatterns
    ),
    "Mcp(playwright__*)",
    "match: MCP server-wide glob"
)
expect(
    matchedPattern(
        toolName: "mcp__computer-use__request_access",
        target: "computer-use__request_access",
        patterns: mcpPatterns
    ),
    "Mcp(computer-use__request_access)",
    "match: MCP exact tool"
)
expectNil(
    matchedPattern(
        toolName: "mcp__supabase__authenticate",
        target: "supabase__authenticate",
        patterns: mcpPatterns
    ),
    "match: MCP non-matching server doesn't fire"
)
expect(
    matchedPattern(
        toolName: "mcp__anything__here",
        target: "anything__here",
        patterns: ["Mcp(*)"]
    ),
    "Mcp(*)",
    "match: catch-all MCP glob"
)
// Bash patterns shouldn't accidentally match MCP tools, and vice versa.
expectNil(
    matchedPattern(
        toolName: "mcp__playwright__browser_evaluate",
        target: "playwright__browser_evaluate",
        patterns: ["Bash(playwright:*)"]
    ),
    "match: Bash patterns ignore MCP tools"
)
expectNil(
    matchedPattern(
        toolName: "Bash",
        target: "playwright run",
        patterns: ["Mcp(playwright__*)"]
    ),
    "match: Mcp patterns ignore Bash tools"
)

// MARK: matchedPattern — quoted operator doesn't fool the splitter

expect(
    matchedPattern(
        toolName: "Bash",
        target: "echo \"a && b\" && git push",
        patterns: patterns
    ),
    "Bash(git push:*)",
    "match: quoted operator doesn't fool the splitter"
)

// MARK: TokenFile — exercises the public surface (ensure / read)

func tempTokenURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nudge-token-\(UUID().uuidString)")
}

do {
    let url = tempTokenURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let token = try TokenFile.ensure(at: url)
    let read = try TokenFile.read(from: url)
    expect(read, token, "token: ensure+read round-trip")
    expect(token.count, 64, "token: ensure produces 64-char hex")
}

do {
    let url = tempTokenURL()
    do {
        _ = try TokenFile.read(from: url)
        failures.append("✗ token: read on missing path should throw")
    } catch TokenFile.FileError.missing {
        passed += 1
    } catch {
        failures.append("✗ token: read on missing path threw \(error), expected .missing")
    }
}

do {
    let url = tempTokenURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try "not-a-valid-token\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    do {
        _ = try TokenFile.read(from: url)
        failures.append("✗ token: read on malformed content should throw")
    } catch TokenFile.FileError.malformed {
        passed += 1
    } catch {
        failures.append("✗ token: read on malformed content threw \(error), expected .malformed")
    }
}

do {
    let urlA = tempTokenURL()
    let urlB = tempTokenURL()
    defer { try? FileManager.default.removeItem(at: urlA) }
    defer { try? FileManager.default.removeItem(at: urlB) }
    let a = try TokenFile.ensure(at: urlA)
    let b = try TokenFile.ensure(at: urlB)
    if a != b { passed += 1 } else { failures.append("✗ token: ensure on two paths must produce unique tokens") }
}

do {
    let url = tempTokenURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let first = try TokenFile.ensure(at: url)
    let second = try TokenFile.ensure(at: url)
    expect(first, second, "token: ensure() is idempotent on same path")
}

do {
    let url = tempTokenURL()
    defer { try? FileManager.default.removeItem(at: url) }
    _ = try TokenFile.ensure(at: url)
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    expect(perms, 0o600, "token: ensure produces 0o600 file")
}

do {
    let url = tempTokenURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try String(repeating: "c", count: 64).write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    do {
        _ = try TokenFile.read(from: url)
        failures.append("✗ token: read on world-readable file should throw")
    } catch FilePermsError.permsTooBroad {
        passed += 1
    } catch {
        failures.append("✗ token: read on world-readable file threw \(error), expected .permsTooBroad")
    }
}

// MARK: AutoLaunch — Quit means quit (regression)
//
// The agent hook fires on every tool call, so without the marker a deliberate
// Quit was undone by `open -ga Nudge` within milliseconds.

func tempMarkerURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nudge-autolaunch-\(UUID().uuidString)")
}

do {
    let url = tempMarkerURL()
    defer { try? FileManager.default.removeItem(at: url) }
    expect(AutoLaunch.isSuppressed(at: url), false, "autolaunch: absent marker means allowed")
    AutoLaunch.suppress(at: url)
    expect(AutoLaunch.isSuppressed(at: url), true, "autolaunch: suppress writes the marker")
    AutoLaunch.allow(at: url)
    expect(AutoLaunch.isSuppressed(at: url), false, "autolaunch: allow clears the marker")
}

do {
    // suppress/allow are called on every quit and launch — they must not throw
    // or accumulate state when repeated.
    let url = tempMarkerURL()
    defer { try? FileManager.default.removeItem(at: url) }
    AutoLaunch.allow(at: url)
    AutoLaunch.allow(at: url)
    expect(AutoLaunch.isSuppressed(at: url), false, "autolaunch: allow is idempotent")
    AutoLaunch.suppress(at: url)
    AutoLaunch.suppress(at: url)
    expect(AutoLaunch.isSuppressed(at: url), true, "autolaunch: suppress is idempotent")
}

do {
    // The real payoff: with the marker set and no reachable Nudge, locatePort
    // must decline instead of spawning `open` and stalling for launchTimeout.
    let marker = tempMarkerURL()
    let missingPort = tempMarkerURL()
    defer { try? FileManager.default.removeItem(at: marker) }
    AutoLaunch.suppress(at: marker)

    let started = Date()
    let port = NudgeClient.locatePort(
        portFileURL: missingPort,
        launchTimeout: 2.0,
        autoLaunchMarkerURL: marker
    )
    let elapsed = Date().timeIntervalSince(started)

    expectNil(port, "autolaunch: locatePort declines while suppressed")
    if elapsed < 0.5 {
        passed += 1
    } else {
        failures.append("✗ autolaunch: locatePort stalled \(elapsed)s — it tried to launch anyway")
    }
}

// MARK: NudgeClient — missing bundle fails fast (regression)
//
// `open -ga <app>` exits non-zero when the app isn't installed. Ignoring that
// meant an uninstalled Nudge cost the full launchTimeout on every hook call.

do {
    let missingPort = tempMarkerURL()
    let absentMarker = tempMarkerURL()

    let started = Date()
    let port = NudgeClient.locatePort(
        portFileURL: missingPort,
        launchTimeout: 5.0,
        autoLaunchMarkerURL: absentMarker,
        appName: "NudgeDefinitelyNotInstalled"
    )
    let elapsed = Date().timeIntervalSince(started)

    expectNil(port, "locate: unknown app yields no port")
    if elapsed < 1.0 {
        passed += 1
    } else {
        failures.append("✗ locate: waited \(elapsed)s for a missing app — should bail on open's exit status")
    }
}

// MARK: PromptQueue — decisions are matched to a prompt id (regression)
//
// resolveHead popped whatever was first, so a head that expired between render
// and click handed your Allow to the next prompt — approving something you
// never read.

func makePrompt(_ id: String, command: String) -> Prompt {
    Prompt(
        id: id,
        tool: "Bash",
        command: command,
        cwd: "/tmp",
        sessionId: "test",
        permissionMode: "default",
        matchedPattern: "Bash(rm:*)"
    )
}

do {
    let queue = PromptQueue()
    let head = makePrompt("prompt-A", command: "rm -rf /tmp/a")

    let caller = Task { try await queue.enqueue(head) }
    try await Task.sleep(nanoseconds: 150_000_000)

    let stale = await queue.resolve(id: "prompt-STALE", with: .allow)
    expect(stale, false, "queue: a decision carrying a stale id is dropped")

    let matched = await queue.resolve(id: "prompt-A", with: .deny)
    expect(matched, true, "queue: a decision carrying the head's id lands")

    let got = try await caller.value
    expect(got.decision, Decision.deny, "queue: caller receives the decision meant for its own prompt")
}

do {
    // The actual near-miss: A expires, B becomes head, and a click still in
    // flight for A must not resolve B.
    let queue = PromptQueue()
    let a = makePrompt("A", command: "rm -rf /tmp/a")
    let b = makePrompt("B", command: "rm -rf /tmp/b")

    let callerA = Task { try? await queue.enqueueWithTimeout(a, seconds: 0.3) }
    try await Task.sleep(nanoseconds: 100_000_000)
    let callerB = Task { try await queue.enqueue(b) }
    try await Task.sleep(nanoseconds: 400_000_000)  // A has now timed out; B is head

    let leaked = await queue.resolve(id: "A", with: .allow)
    expect(leaked, false, "queue: click meant for the expired prompt does not approve its successor")

    _ = await callerA.value
    let resolvedB = await queue.resolve(id: "B", with: .deny)
    expect(resolvedB, true, "queue: successor still resolves under its own id")
    let gotB = try await callerB.value
    expect(gotB.decision, Decision.deny, "queue: successor got deny, not the leaked allow")
}

// MARK: AgentActivityStore — pruning uses our clock, not the wire's

func activityEvent(_ name: String, session: String, at date: Date) -> AgentHookEvent {
    AgentHookEvent(
        occurredAt: date,
        nudgeSessionID: session,
        claudeSessionID: nil,
        eventName: name,
        cwd: "/tmp",
        transcriptPath: nil,
        permissionMode: nil,
        toolName: nil,
        toolSummary: nil,
        promptPreview: nil,
        message: nil,
        error: nil
    )
}

do {
    let store = AgentActivityStore(endedSnapshotTTL: 60, maxSnapshots: 10)
    let now = Date()

    await store.record(activityEvent("SessionEnd", session: "ended-one", at: now), now: now)
    // A client whose clock is far ahead (or which is lying) must not age out
    // everyone else's snapshots.
    await store.record(
        activityEvent("Stop", session: "live-one", at: now.addingTimeInterval(86_400)),
        now: now
    )

    let snaps = await store.snapshots(now: now)
    expect(snaps.count, 2, "activity: a future-dated event doesn't evict the ended snapshot")
}

// MARK: Checksum — the updater's integrity gate
//
// nudge-update refuses to swap /Applications/Nudge.app unless the download
// matches. A parser that accepts junk turns that back into "install anything."

expect(
    Checksum.parseShasumOutput("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  Nudge.app.zip"),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "checksum: parses shasum output"
)
expect(
    Checksum.parseShasumOutput("E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855  x.zip"),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "checksum: case-folds the digest"
)
expectNil(Checksum.parseShasumOutput(""), "checksum: rejects empty file")
expectNil(Checksum.parseShasumOutput("   \n  "), "checksum: rejects whitespace-only file")
expectNil(Checksum.parseShasumOutput("<!DOCTYPE html><html>404</html>"), "checksum: rejects an HTML error page")
expectNil(Checksum.parseShasumOutput("e3b0c44298fc1c14  short.zip"), "checksum: rejects a truncated digest")
expectNil(
    Checksum.parseShasumOutput("z3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  x.zip"),
    "checksum: rejects non-hex characters"
)
expectNil(
    Checksum.parseShasumOutput("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b8551  x.zip"),
    "checksum: rejects an over-long digest"
)

do {
    // Hash a known value against the published SHA-256 of the empty string, so
    // the digest is checked against an external constant rather than itself.
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nudge-sum-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data().write(to: url)
    expect(
        Checksum.sha256Hex(of: url),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "checksum: sha256 of empty file matches the known constant"
    )

    try Data("nudge".utf8).write(to: url)
    let nonEmpty = Checksum.sha256Hex(of: url)
    expect(nonEmpty?.count, 64, "checksum: digest is 64 hex chars")
    if nonEmpty != "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" {
        passed += 1
    } else {
        failures.append("✗ checksum: content change didn't change the digest")
    }
}

do {
    let missing = URL(fileURLWithPath: "/nope/nudge-\(UUID().uuidString)")
    expectNil(Checksum.sha256Hex(of: missing), "checksum: unreadable file yields nil, not a bogus digest")
}

// MARK: Version — semver parsing

expect(Version("1.2.3")?.description, "1.2.3", "version: parses MAJOR.MINOR.PATCH")
expect(Version("v1.2.3")?.description, "1.2.3", "version: strips v prefix")
expect(Version("V0.1.0")?.description, "0.1.0", "version: strips V prefix")
expect(Version("1.2.3-beta")?.description, "1.2.3", "version: drops pre-release suffix")
expect(Version("1.2.3+build7")?.description, "1.2.3", "version: drops build metadata")
expect(Version(" v1.2.3 ")?.description, "1.2.3", "version: trims whitespace")
expectNil(Version("1.2"), "version: 1.2 is not three parts")
expectNil(Version("1.2.x"), "version: non-int component")
expectNil(Version("garbage"), "version: garbage")

if let a = Version("1.2.3"), let b = Version("1.2.4") {
    if a < b { passed += 1 } else { failures.append("✗ version: 1.2.3 < 1.2.4") }
}
if let a = Version("1.2.3"), let b = Version("1.3.0") {
    if a < b { passed += 1 } else { failures.append("✗ version: 1.2.3 < 1.3.0") }
}
if let a = Version("1.2.3"), let b = Version("2.0.0") {
    if a < b { passed += 1 } else { failures.append("✗ version: 1.2.3 < 2.0.0") }
}
if let a = Version("1.2.3"), let b = Version("v1.2.3") {
    if a == b { passed += 1 } else { failures.append("✗ version: 1.2.3 == v1.2.3") }
}
if let a = Version("0.10.0"), let b = Version("0.9.0") {
    if a > b { passed += 1 } else { failures.append("✗ version: 0.10.0 > 0.9.0 (numeric, not lexical)") }
}

// MARK: report

print("\(passed) passed, \(failures.count) failed")
for failure in failures {
    print(failure)
}
exit(failures.isEmpty ? 0 : 1)
