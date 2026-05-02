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

// MARK: report

print("\(passed) passed, \(failures.count) failed")
for failure in failures {
    print(failure)
}
exit(failures.isEmpty ? 0 : 1)
