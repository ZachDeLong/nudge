import XCTest
@testable import NudgeHookCore

final class SplitBashCommandTests: XCTestCase {
    func testNoOperators() {
        XCTAssertEqual(splitBashCommand("git push origin main"), ["git push origin main"])
    }

    func testAndAnd() {
        XCTAssertEqual(
            splitBashCommand("cd /foo && git push"),
            ["cd /foo", "git push"]
        )
    }

    func testOrOr() {
        XCTAssertEqual(
            splitBashCommand("make build || echo failed"),
            ["make build", "echo failed"]
        )
    }

    func testSemicolon() {
        XCTAssertEqual(
            splitBashCommand("ls; pwd; whoami"),
            ["ls", "pwd", "whoami"]
        )
    }

    func testPipe() {
        XCTAssertEqual(
            splitBashCommand("cat foo | grep bar"),
            ["cat foo", "grep bar"]
        )
    }

    func testBackground() {
        XCTAssertEqual(
            splitBashCommand("sleep 5 & echo done"),
            ["sleep 5", "echo done"]
        )
    }

    func testMixed() {
        XCTAssertEqual(
            splitBashCommand("cd /tmp && rm -rf foo; echo done"),
            ["cd /tmp", "rm -rf foo", "echo done"]
        )
    }

    func testDoesNotSplitInsideDoubleQuotes() {
        XCTAssertEqual(
            splitBashCommand("echo \"hello && world\" && pwd"),
            ["echo \"hello && world\"", "pwd"]
        )
    }

    func testDoesNotSplitInsideSingleQuotes() {
        XCTAssertEqual(
            splitBashCommand("echo 'a; b; c' ; pwd"),
            ["echo 'a; b; c'", "pwd"]
        )
    }

    func testDoesNotSplitInsideDollarParen() {
        XCTAssertEqual(
            splitBashCommand("echo $(date && hostname) && ls"),
            ["echo $(date && hostname)", "ls"]
        )
    }

    func testDoesNotSplitInsideBacktick() {
        XCTAssertEqual(
            splitBashCommand("echo `date && hostname` && ls"),
            ["echo `date && hostname`", "ls"]
        )
    }

    func testEscapedOperator() {
        XCTAssertEqual(
            splitBashCommand("echo a \\&\\& b && pwd"),
            ["echo a \\&\\& b", "pwd"]
        )
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(
            splitBashCommand("  ls   &&   pwd  "),
            ["ls", "pwd"]
        )
    }

    func testEmpty() {
        XCTAssertEqual(splitBashCommand(""), [])
    }

    func testTrailingOperatorIsIgnored() {
        XCTAssertEqual(splitBashCommand("ls && "), ["ls"])
    }
}

final class MatchedPatternTests: XCTestCase {
    let patterns = [
        "Bash(git push:*)",
        "Bash(rm:*)",
        "Bash(*--force*)",
        "Bash(*deploy*)",
        "Edit(/etc/**)",
        "Write(**/.env*)",
    ]

    // MARK: Bash — single-segment baseline

    func testBareGitPushMatches() {
        XCTAssertEqual(
            matchedPattern(toolName: "Bash", target: "git push", patterns: patterns),
            "Bash(git push:*)"
        )
    }

    func testGitPushWithArgsMatches() {
        XCTAssertEqual(
            matchedPattern(toolName: "Bash", target: "git push origin main", patterns: patterns),
            "Bash(git push:*)"
        )
    }

    // MARK: Bash — chained commands (the bug this whole change is about)

    func testChainedGitPushMatchesPrefix() {
        XCTAssertEqual(
            matchedPattern(toolName: "Bash", target: "cd /foo && git push", patterns: patterns),
            "Bash(git push:*)"
        )
    }

    func testChainedRmMatchesPrefix() {
        XCTAssertEqual(
            matchedPattern(toolName: "Bash", target: "cd /tmp && rm -rf build", patterns: patterns),
            "Bash(rm:*)"
        )
    }

    func testCompoundCommandWithoutMatchReturnsNil() {
        XCTAssertNil(
            matchedPattern(toolName: "Bash", target: "cd /foo && ls -la", patterns: patterns)
        )
    }

    // MARK: Bash — infix (substring) matching

    func testInfixForceMatchesEvenInChained() {
        XCTAssertEqual(
            matchedPattern(toolName: "Bash", target: "cd /foo && git push --force", patterns: patterns),
            "Bash(*--force*)"
        )
    }

    // MARK: Bash — infix wins over prefix on conflict

    func testInfixWinsOverPrefix() {
        // git push --force matches both Bash(git push:*) and Bash(*--force*).
        // Infix should win so the UI hides the always-allow option.
        XCTAssertEqual(
            matchedPattern(toolName: "Bash", target: "git push --force origin main", patterns: patterns),
            "Bash(*--force*)"
        )
    }

    func testInfixWinsEvenInChainedCommand() {
        XCTAssertEqual(
            matchedPattern(toolName: "Bash", target: "cd /foo && git push --force", patterns: patterns),
            "Bash(*--force*)"
        )
    }

    // MARK: Path patterns (sanity — unchanged behavior)

    func testEditPathMatches() {
        XCTAssertEqual(
            matchedPattern(toolName: "Edit", target: "/etc/hosts", patterns: patterns),
            "Edit(/etc/**)"
        )
    }

    func testEditPathOutsideEtcDoesNotMatch() {
        XCTAssertNil(
            matchedPattern(toolName: "Edit", target: "/Users/zach/foo.txt", patterns: patterns)
        )
    }

    func testWriteEnvMatches() {
        XCTAssertEqual(
            matchedPattern(toolName: "Write", target: "/Users/zach/project/.env", patterns: patterns),
            "Write(**/.env*)"
        )
    }

    // MARK: Quote-safe matching

    func testCommandWithQuotedOperatorStillMatches() {
        // `git push` must still match even when surrounded by other commands
        // that contain quoted && inside arguments.
        XCTAssertEqual(
            matchedPattern(
                toolName: "Bash",
                target: "echo \"a && b\" && git push",
                patterns: patterns
            ),
            "Bash(git push:*)"
        )
    }
}
