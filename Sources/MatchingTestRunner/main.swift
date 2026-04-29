// Command-line runner for NudgeHookCore matching tests.
//
// Mirrors Tests/NudgeHookCoreTests/MatchingTests.swift but uses plain Swift
// assertions so it runs without XCTest (which requires full Xcode, not just
// Command Line Tools). Use `swift test` for the XCTest version when Xcode
// is installed; use `make test` (which invokes this binary) otherwise.

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
        failures.append("✗ \(name)\n    expected: nil\n    actual:   \(String(describing: actual))")
    }
}

// MARK: splitBashCommand

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
expect(splitBashCommand("  ls   &&   pwd  "), ["ls", "pwd"], "split: trims whitespace")
expect(splitBashCommand(""), [], "split: empty input")
expect(splitBashCommand("ls && "), ["ls"], "split: trailing operator")

// MARK: matchedPattern

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
    "match: chained git push (the bug fix)"
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
expect(
    matchedPattern(toolName: "Bash", target: "cd /foo && git push --force", patterns: patterns),
    "Bash(*--force*)",
    "match: infix --force inside chain"
)
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
