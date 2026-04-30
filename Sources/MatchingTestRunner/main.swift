// Command-line runner for NudgeHookCore matching tests.
//
// Plain Swift assertions so this works on machines with only Command Line
// Tools (no XCTest). Run via `make test`. Build via `swift build --product
// nudge-test-matching`.

import Foundation
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

// MARK: report

print("\(passed) passed, \(failures.count) failed")
for failure in failures {
    print(failure)
}
exit(failures.isEmpty ? 0 : 1)
