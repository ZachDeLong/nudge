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

// MARK: splitBashCommand — heredocs and comments (regression)
//
// An apostrophe in a heredoc body or a # comment used to open a single quote
// that never closed, swallowing every later line into one segment, so
// `Bash(git push:*)` silently missed a push after `Don't forget...`.

expect(
    splitBashCommand("sh <<'EOF'\nDon't forget to bump the version.\nEOF\ngit push origin main"),
    ["sh <<'EOF'", "Don't forget to bump the version.", "git push origin main"],
    "split: apostrophe in a heredoc body doesn't open a quote"
)
expect(
    splitBashCommand("cat > NOTES.md <<'EOF'\nDon't forget to bump the version.\nEOF\ngit push origin main"),
    ["cat > NOTES.md <<'EOF'", "git push origin main"],
    "split: apostrophe in a skipped text body doesn't open a quote either"
)
expect(
    splitBashCommand("bash <<EOF\nrm -rf foo\nEOF"),
    ["bash <<EOF", "rm -rf foo"],
    "split: a shell's heredoc body lines stay candidates"
)
expect(
    splitBashCommand("bash <<-EOF\n\tit's here\n\tEOF\nrm x"),
    ["bash <<-EOF", "it's here", "rm x"],
    "split: <<- terminator may be tab-indented"
)
expect(
    splitBashCommand("bash <<A <<'B'\na's\nA\nb's\nB\nls"),
    ["bash <<A <<'B'", "a's", "b's", "ls"],
    "split: two heredocs on one line"
)

// Heredoc bodies only count as commands when a shell may run them: a script
// fed to python or written out with cat is text (Zach, 2026-09-27: `--force`
// in a python heredoc popped `Bash(*--force*)`). Unknown readers stay checked.
expect(splitBashCommand("cat <<EOF\nrm -rf foo\nEOF"), ["cat <<EOF"], "split: cat's heredoc body is text")
expect(splitBashCommand("python3 - <<'EOF'\nimport os\nEOF\nls"), ["python3 - <<'EOF'", "ls"], "split: python's heredoc body is text")
expect(splitBashCommand("FOO=1 /usr/bin/python3.12 <<EOF\nx\nEOF"), ["FOO=1 /usr/bin/python3.12 <<EOF"], "split: assignment + path + versioned python")
expect(splitBashCommand("git commit -F - <<EOF\nrm it\nEOF"), ["git commit -F - <<EOF"], "split: commit message body is text")
expect(splitBashCommand("cat <<EOF | sh\nrm -rf foo\nEOF"), ["cat <<EOF", "sh", "rm -rf foo"], "split: cat piped into sh runs the body")
expect(splitBashCommand("ls; cat <<EOF\nrm x\nEOF"), ["ls", "cat <<EOF"], "split: an earlier command on the line with no heredoc still counts")
expect(splitBashCommand("ssh box <<EOF\nrm -rf foo\nEOF"), ["ssh box <<EOF", "rm -rf foo"], "split: ssh's body is remote shell")
expect(splitBashCommand("docker exec -i c sh <<EOF\nrm x\nEOF"), ["docker exec -i c sh <<EOF", "rm x"], "split: unknown reader stays checked")
expect(splitBashCommand("sudo -u bob python3 <<EOF\nrm x\nEOF"), ["sudo -u bob python3 <<EOF", "rm x"], "split: sudo with flags is unknown, stays checked")
expect(splitBashCommand("sudo tee /etc/x <<EOF\nrm x\nEOF"), ["sudo tee /etc/x <<EOF"], "split: sudo tee body is text")
expect(splitBashCommand("ls\ncat <<EOF\nrm x\nEOF\nbash <<B\nrm y\nB"), ["ls", "cat <<EOF", "bash <<B", "rm y"], "split: each heredoc line decides for itself")
let pyForce = "python3 - <<'EOF'\nimport argparse\np = argparse.ArgumentParser()\np.add_argument('--force')\nEOF"
expectNil(matchedPattern(toolName: "Bash", target: pyForce, patterns: ["Bash(*--force*)"]), "match: --force in a python heredoc doesn't fire")
expect(bashInfixText(pyForce), "python3 - <<'EOF'\n\n\n\nEOF", "infix text: python body removed")
expect(
    matchedPattern(toolName: "Bash", target: "bash <<EOF\ngit push --force\nEOF", patterns: ["Bash(*--force*)"]),
    "Bash(*--force*)",
    "match: --force in a bash heredoc still fires"
)
expect(
    matchedPattern(toolName: "Bash", target: pyForce + "\ngit push --force", patterns: ["Bash(*--force*)"]),
    "Bash(*--force*)",
    "match: --force after a python heredoc still fires"
)
expect(
    splitBashCommand("x=$(cat <<'EOF'\nit's\nEOF\n) && rm foo"),
    ["x=$(cat <<'EOF'\nit's\nEOF\n)", "rm foo"],
    "split: heredoc inside $(...) stays in the substitution"
)
expect(
    splitBashCommand("(cat <<EOF\nit's\nEOF\n); ls"),
    ["(cat <<EOF\nit's\nEOF\n)", "ls"],
    "split: heredoc inside a subshell stays wrapped"
)
expect(
    splitBashCommand("bash <<EOF\nit's never closed"),
    ["bash <<EOF", "it's never closed"],
    "split: unterminated heredoc runs to the end"
)
expect(splitBashCommand("cat <<< 'hi' && ls"), ["cat <<< 'hi'", "ls"], "split: <<< is a here-string, not a heredoc")
expect(splitBashCommand("echo $((1<<2)) && ls"), ["echo $((1<<2))", "ls"], "split: << inside arithmetic is a shift")
expect(
    splitBashCommand("((x=1<<2))\necho done && rm -rf /tmp/important"),
    ["((x=1<<2))", "echo done", "rm -rf /tmp/important"],
    "split: << inside a bare ((...)) is a shift, not a heredoc"
)
expect(splitBashCommand("((x<<=2)); rm foo"), ["((x<<=2))", "rm foo"], "split: <<= inside ((...))")
expect(splitBashCommand("((16#ff > 1)) && ls"), ["((16#ff > 1))", "ls"], "split: # inside ((...)) isn't a comment")
expect(
    matchedPattern(toolName: "Bash", target: "((x=1<<2))\necho done && rm -rf /tmp/important", patterns: ["Bash(rm:*)"]),
    "Bash(rm:*)",
    "match: rm after a bare ((...)) shift"
)
expect(splitBashCommand("# Let's ship it\ngit push origin main"), ["git push origin main"], "split: apostrophe in a comment")
expect(splitBashCommand("ls # don't\nrm foo"), ["ls", "rm foo"], "split: trailing comment")
expect(splitBashCommand("echo foo#bar && ls"), ["echo foo#bar", "ls"], "split: # inside a word isn't a comment")
expect(splitBashCommand("echo ${#x} $# && ls"), ["echo ${#x} $#", "ls"], "split: ${#x} and $# aren't comments")
expect(splitBashCommand("echo '# not a comment' && ls"), ["echo '# not a comment'", "ls"], "split: quoted # isn't a comment")
expect(
    matchedPattern(toolName: "Bash", target: "cat > NOTES.md <<'EOF'\nDon't forget.\nEOF\ngit push origin main", patterns: ["Bash(git push:*)"]),
    "Bash(git push:*)",
    "match: git push after a heredoc with an apostrophe"
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
// A script written out with cat is text; one fed to a shell is checked.
expectNil(
    matchedPattern(toolName: "Bash", target: "cat <<EOF > /tmp/s.sh\nrm -rf /tmp/foo\nEOF", patterns: patterns),
    "match: a script written out with cat doesn't fire"
)
expect(
    matchedPattern(toolName: "Bash", target: "sh <<EOF\nrm -rf /tmp/foo\nEOF", patterns: patterns),
    "Bash(rm:*)",
    "match: a heredoc fed to sh fires"
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

// MARK: HookProtocol — Claude Code and Codex answers
//
// Shapes confirmed against live runs (Claude Code 2.1.280, Codex CLI 0.154):
// PermissionRequest wants `decision: {behavior}`; a bare string is ignored.

func jsonString(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}

expect(
    jsonString(hookDecisionOutput(event: .preToolUse, allow: true)),
    #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Allowed in Nudge."}}"#,
    "protocol: PreToolUse allow keeps its shape and reason"
)
expect(
    jsonString(hookDecisionOutput(event: .preToolUse, allow: false)),
    #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"The user denied this in Nudge."}}"#,
    "protocol: PreToolUse deny says a person said no"
)
expect(
    jsonString(hookDecisionOutput(event: .permissionRequest, allow: true)),
    #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#,
    "protocol: PermissionRequest allow uses the decision object"
)
expect(
    jsonString(hookDecisionOutput(event: .permissionRequest, allow: false)),
    #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"The user denied this in Nudge."},"hookEventName":"PermissionRequest"}}"#,
    "protocol: PermissionRequest deny tells the agent a person said no"
)

expect(HookAgent.from(arguments: ["nudge-hook"]), .claude, "protocol: no flag means Claude")
expect(HookAgent.from(arguments: ["nudge-hook", "--agent", "codex"]), .codex, "protocol: --agent codex")
expect(HookAgent.from(arguments: ["nudge-hook", "--agent", "Codex"]), .codex, "protocol: agent flag ignores case")
expect(HookAgent.from(arguments: ["nudge-hook", "--agent"]), .claude, "protocol: dangling flag falls back to Claude")
expect(HookAgent.from(arguments: ["nudge-hook", "--agent", "cursor"]), .claude, "protocol: unknown agent falls back to Claude")
expect(FrontmostApp.sessionUIBundleIDs(entrypoint: nil, agent: "codex").contains("com.openai.codex"), true, "protocol: ChatGPT/Codex app counts as the agent's own UI")
expect(FrontmostApp.sessionUIBundleIDs(entrypoint: nil), FrontmostApp.terminalBundleIDs, "protocol: for a terminal Claude session only the terminal list counts as its own UI")
expect(FrontmostApp.sessionUIBundleIDs(entrypoint: "cli").contains("com.anthropic.claudefordesktop"), false, "protocol: CLI entrypoint doesn't count the Claude app")
expect(FrontmostApp.sessionUIBundleIDs(entrypoint: "claude-desktop").contains("com.anthropic.claudefordesktop"), true, "protocol: a Claude app session counts the Claude app as its own UI")
// Finished messages: only interactive Claude sessions, main thread, away from them.
expect(shouldOfferFinishedMessage(agent: .claude, eventName: "Stop", entrypoint: "cli", isSubagent: false, userIsAtSession: false), true, "finished: terminal session, you're elsewhere")
expect(shouldOfferFinishedMessage(agent: .claude, eventName: "Stop", entrypoint: "cli", isSubagent: false, userIsAtSession: true), false, "finished: you're at the terminal, so nothing")
expect(shouldOfferFinishedMessage(agent: .claude, eventName: "Stop", entrypoint: "sdk-cli", isSubagent: false, userIsAtSession: false), false, "finished: claude -p never waits on you")
expect(shouldOfferFinishedMessage(agent: .claude, eventName: "Stop", entrypoint: nil, isSubagent: false, userIsAtSession: false), false, "finished: unknown entrypoint stays out of the way")
expect(shouldOfferFinishedMessage(agent: .claude, eventName: "Stop", entrypoint: "claude-desktop", isSubagent: false, userIsAtSession: false), true, "finished: Claude app session")
expect(shouldOfferFinishedMessage(agent: .claude, eventName: "Stop", entrypoint: "cli", isSubagent: true, userIsAtSession: false), false, "finished: subagents don't count")
expect(shouldOfferFinishedMessage(agent: .claude, eventName: "PostToolUse", entrypoint: "cli", isSubagent: false, userIsAtSession: false), false, "finished: only on Stop")
let codexTUI = [["/bin/sh", "-c", "nudge-agent-hook --agent codex"], ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "--model", "gpt-6"]]
let codexApp = [["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "app-server"]]
let codexExec = [["/usr/local/bin/codex", "exec", "--skip-git-repo-check", "fix it"]]
let codexExecAlias = [["codex", "-c", "model=gpt-6", "e", "fix it"]]
expect(shouldOfferFinishedMessage(agent: .codex, eventName: "Stop", entrypoint: nil, codexAncestors: { codexTUI }, isSubagent: false, userIsAtSession: false), true, "finished: Codex TUI")
expect(shouldOfferFinishedMessage(agent: .codex, eventName: "Stop", entrypoint: nil, codexAncestors: { codexApp }, isSubagent: false, userIsAtSession: false), true, "finished: Codex in the ChatGPT app")
expect(shouldOfferFinishedMessage(agent: .codex, eventName: "Stop", entrypoint: nil, codexAncestors: { codexExec }, isSubagent: false, userIsAtSession: false), false, "finished: codex exec never waits on you")
expect(codexRunIsScripted(ancestorArguments: codexExecAlias), true, "finished: codex e (alias) is scripted too")
expect(codexRunIsScripted(ancestorArguments: [["/usr/bin/python3", "exec.py"]]), false, "finished: no Codex in sight means a person")
expect(shouldOfferFinishedMessage(agent: .codex, eventName: "Stop", entrypoint: nil, codexAncestors: { codexTUI }, isSubagent: false, userIsAtSession: true), false, "finished: Codex, you're at it")
expect(FrontmostApp.sessionUIBundleIDs(entrypoint: nil, agent: "codex").contains("com.openai.codex"), true, "finished: the ChatGPT app is Codex's own UI")
expect(finishedMessageText("  Pushed to origin/main.\n", agent: .claude), "Pushed to origin/main.", "finished: message trimmed")
expect(finishedMessageText(nil, agent: .claude), "Claude finished its turn.", "finished: no message still says something")
expect(finishedMessageText(nil, agent: .codex), "Codex finished its turn.", "finished: named for the agent")
expect(finishedMessageText(String(repeating: "a", count: 5000), agent: .claude).count, 4001, "finished: long messages capped")
expect(stopReplyOutput(reply: "now open a PR")["decision"] as? String, "block", "finished: a reply keeps Claude going")
expect(stopReplyOutput(reply: "now open a PR")["reason"] as? String, "The user replied from Nudge: now open a PR", "finished: the reply reaches Claude as its reason")

do {
    let out = askInAgentUIOutput(pattern: "Bash(git push:*)")["hookSpecificOutput"] as? [String: String]
    expect(out?["hookEventName"], "PreToolUse", "protocol: hand-back answers PreToolUse")
    expect(out?["permissionDecision"], "ask", "protocol: a pattern match at the agent's UI asks there instead of running unasked")
    expect(out?["permissionDecisionReason"], "Nudge: this matches Bash(git push:*).", "protocol: hand-back names the pattern")
}

// Wait bound: Codex shows no prompt of its own while the hook waits, so the
// hook gives up after two minutes. Claude's dialog runs alongside, so no bound.
expect(hookMaxWait(agent: .codex, environment: [:], harness: false), 120, "wait: Codex gives up after two minutes")
expectNil(hookMaxWait(agent: .claude, environment: [:], harness: false), "wait: Claude waits for the app's timeout")
expect(hookMaxWait(agent: .codex, environment: ["NUDGE_HOOK_MAX_WAIT": "1"], harness: false), 120,
       "wait: the override is ignored outside the harness")
expect(hookMaxWait(agent: .codex, environment: ["NUDGE_HOOK_MAX_WAIT": "1.5"], harness: true), 1.5,
       "wait: the harness can shorten it")
expect(hookMaxWait(agent: .codex, environment: ["NUDGE_HOOK_MAX_WAIT": "soon"], harness: true), 120,
       "wait: a malformed override is ignored")
expect(hookMaxWait(agent: .codex, environment: ["NUDGE_HOOK_MAX_WAIT": "0"], harness: true), 120,
       "wait: a zero override is ignored")
expect(handBackMessage(agent: .codex, waited: 120), "Nudge got no answer in 2 minutes, so Codex is asking here instead.",
       "wait: the hand-back message names the wait and the agent")
expect(handBackMessage(agent: .codex, waited: 60), "Nudge got no answer in a minute, so Codex is asking here instead.",
       "wait: one minute reads naturally")
expect(handBackMessage(agent: .codex, waited: 1), "Nudge got no answer in 1 second, so Codex is asking here instead.",
       "wait: short harness waits read in seconds")

expect(HookEvent(rawValue: "PermissionRequest"), .permissionRequest, "protocol: event name parses")

// Mode policy: PermissionRequest everywhere it fires but dontAsk; patterns
// in the modes where you approve calls yourself: not auto, bypassPermissions or dontAsk.
for mode in ["default", "acceptEdits", "plan", "auto", "bypassPermissions"] {
    expect(nudgeAsks(event: .permissionRequest, permissionMode: mode), true, "mode: PermissionRequest asks in \(mode)")
}
expect(nudgeAsks(event: .permissionRequest, permissionMode: "dontAsk"), false, "mode: PermissionRequest stays quiet in dontAsk")
for mode in ["default", "acceptEdits", "plan"] {
    expect(nudgeAsks(event: .preToolUse, permissionMode: mode), true, "mode: patterns ask in \(mode)")
}
expect(nudgeAsks(event: .preToolUse, permissionMode: "auto"), false, "mode: patterns stay quiet in auto")
expect(nudgeAsks(event: .preToolUse, permissionMode: "dontAsk"), false, "mode: patterns stay quiet in dontAsk")
expect(nudgeAsks(event: .preToolUse, permissionMode: "bypassPermissions"), false, "mode: patterns stay quiet in bypassPermissions")
expect(toolsLeftToAgentUI.contains("ExitPlanMode"), true, "protocol: plan approval stays in Claude's own UI")

expect(displayTarget(toolName: "Bash", input: ["command": "mkdir build", "description": "Make dir"]), "mkdir build", "display: Bash shows the command")
expect(displayTarget(toolName: "Write", input: ["file_path": "/tmp/a.txt", "content": "x"]), "/tmp/a.txt", "display: file tools show the path")
expect(
    displayTarget(toolName: "apply_patch", input: ["command": "*** Begin Patch\n*** Add File: a.txt\n+hi\n*** End Patch"]),
    "*** Begin Patch\n*** Add File: a.txt\n+hi\n*** End Patch",
    "display: Codex apply_patch shows the patch"
)
expect(displayTarget(toolName: "WebFetch", input: ["url": "https://example.com", "prompt": "x"]), "https://example.com", "display: WebFetch shows the URL")
expect(displayTarget(toolName: "mcp__github__create_issue", input: ["title": "x", "description": "why"]),
       "mcp__github__create_issue\n{\n  \"description\" : \"why\",\n  \"title\" : \"x\"\n}",
       "display: MCP shows the tool name, then every argument")
expect(displayTarget(toolName: "mcp__supabase__execute_sql", input: ["query": "select 1"]).hasSuffix("\"query\" : \"select 1\"\n}"), true,
       "display: MCP SQL is visible")
expect(displayTarget(toolName: "mcp__github__list_issues", input: [:]), "mcp__github__list_issues", "display: MCP with no arguments shows the name")
expect(
    displayTarget(toolName: "SomethingNew", input: ["b": 2, "a": "x", "description": "why"]),
    #"{"a":"x","b":2}"#,
    "display: unknown tools show their input, minus the description"
)
expect(displayTarget(toolName: "SomethingNew", input: [:]), "", "display: unknown tool with no input shows nothing")

expect(
    patchedFiles("*** Begin Patch\n*** Update File: a.swift\n@@\n-x\n+y\n*** Add File: b.txt\n+hi\n*** Delete File: c.txt\n*** Update File: a.swift\n*** End Patch"),
    ["a.swift", "b.txt", "c.txt"],
    "patch: files in order, once each"
)
expect(patchedFiles("echo hi"), [], "patch: non-patch text names no files")

// MARK: CallKey — one tool call across hook events

func parsedInput(_ json: String) -> Any? {
    try? JSONSerialization.jsonObject(with: Data(json.utf8))
}

do {
    let a = CallKey.make(sessionID: "s1", toolName: "Bash",
                         toolInput: parsedInput(#"{"command":"git push origin main","description":"Push"}"#))
    let b = CallKey.make(sessionID: "s1", toolName: "Bash",
                         toolInput: parsedInput(#"{"description":"Push","command":"git push origin main"}"#))
    expect(a, b, "callkey: key order in tool_input doesn't matter")
    expect(a.count, 64, "callkey: sha256 hex")
    let otherSession = CallKey.make(sessionID: "s2", toolName: "Bash",
                                    toolInput: parsedInput(#"{"command":"git push origin main","description":"Push"}"#))
    expect(a == otherSession, false, "callkey: another session is another call")
    let otherInput = CallKey.make(sessionID: "s1", toolName: "Bash",
                                  toolInput: parsedInput(#"{"command":"git push origin dev","description":"Push"}"#))
    expect(a == otherInput, false, "callkey: another command is another call")
    let otherTool = CallKey.make(sessionID: "s1", toolName: "Write",
                                 toolInput: parsedInput(#"{"command":"git push origin main","description":"Push"}"#))
    expect(a == otherTool, false, "callkey: another tool is another call")
    let nested1 = CallKey.make(sessionID: "s", toolName: "mcp__x__y", toolInput: parsedInput(#"{"o":{"b":1,"a":[1,2]}}"#))
    let nested2 = CallKey.make(sessionID: "s", toolName: "mcp__x__y", toolInput: parsedInput(#"{"o":{"a":[1,2],"b":1}}"#))
    expect(nested1, nested2, "callkey: nested key order doesn't matter")
    expect(CallKey.make(sessionID: "s", toolName: "T", toolInput: nil) == CallKey.make(sessionID: "s", toolName: "T", toolInput: parsedInput("{}")),
           false, "callkey: missing input differs from empty input")
}

// MARK: RecentAllows — dedupe a PermissionRequest right after a pattern allow

do {
    var recent = RecentAllows(ttl: 30)
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    recent.record("k", at: t0)
    expect(recent.consume("other", at: t0.addingTimeInterval(1)), false, "recent: another call isn't covered")
    expect(recent.consume("k", at: t0.addingTimeInterval(1)), true, "recent: the same call right after is covered")
    expect(recent.consume("k", at: t0.addingTimeInterval(2)), false, "recent: an allow covers one request, not two")
    recent.record("k", at: t0)
    expect(recent.consume("k", at: t0.addingTimeInterval(31)), false, "recent: entries expire")
    recent.record("a", at: t0)
    recent.record("b", at: t0.addingTimeInterval(20))
    expect(recent.consume("b", at: t0.addingTimeInterval(40)), true, "recent: expiry is per entry")
    expect(recent.consume("a", at: t0.addingTimeInterval(40)), false, "recent: an older entry expired meanwhile")
}

// MARK: ClaudeSettings — PermissionRequest hook for installs that predate it

do {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nudge-migrate-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let settings = dir.appendingPathComponent("settings.json")
    let marker = dir.appendingPathComponent("config/permission-request-hook")
    let hook = ClaudeSettings.nudgeHookCommand
    let agentHook = "/Applications/Nudge.app/Contents/MacOS/nudge-agent-hook"
    func write(_ obj: Any) { try? JSONSerialization.data(withJSONObject: obj).write(to: settings) }
    func read() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: settings))) as? [String: Any] ?? [:]
    }
    func backups() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("settings.json.bak.") }.count
    }
    let v131: [String: Any] = [
        "model": "opus",
        "permissions": ["allow": ["Bash(git status:*)"], "ask": ["Bash(git push:*)"]],
        "hooks": [
            "PreToolUse": [
                ["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/local/bin/my-guard"]]],
                ["matcher": "Bash|Edit|Write|Read|MultiEdit|NotebookEdit|mcp__.*", "hooks": [["type": "command", "command": hook]]],
                ["matcher": "*", "hooks": [["type": "command", "command": agentHook]]],
            ],
            "PermissionRequest": [["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/local/bin/other-tool", "timeout": 30]]]],
            "Stop": [["hooks": [["type": "command", "command": agentHook]]]],
        ],
    ]

    expect(ClaudeSettings.addPermissionRequestHook(settings: settings, marker: marker), .notInstalled, "migrate: no settings.json → not installed")
    write(["hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/local/bin/my-guard"]]]]]])
    expect(ClaudeSettings.addPermissionRequestHook(settings: settings, marker: marker), .notInstalled, "migrate: without Nudge's PreToolUse hook it adds nothing")
    expect((read()["hooks"] as? [String: Any])?["PermissionRequest"] == nil, true, "migrate: a settings file without Nudge is left alone")
    expect(backups(), 0, "migrate: no backup when nothing is written")

    write(v131)
    expect(ClaudeSettings.addPermissionRequestHook(settings: settings, marker: marker), .added, "migrate: 1.3.x settings get the hook")
    let after = read()
    let hooks = after["hooks"] as? [String: Any] ?? [:]
    let pr = hooks["PermissionRequest"] as? [[String: Any]] ?? []
    expect(pr.count, 2, "migrate: the user's own PermissionRequest hook stays, Nudge's is appended")
    expect((pr.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String, "/usr/local/bin/other-tool", "migrate: other PermissionRequest hook untouched")
    expect((pr.first?["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int, 30, "migrate: other hook keeps its timeout")
    expect(pr.last?["matcher"] as? String, "*", "migrate: Nudge's entry matches every tool")
    expect((pr.last?["hooks"] as? [[String: Any]])?.first?["command"] as? String, hook, "migrate: Nudge's entry runs nudge-hook")
    expect((hooks["PreToolUse"] as? [[String: Any]])?.count, 3, "migrate: PreToolUse entries untouched")
    expect((hooks["Stop"] as? [[String: Any]])?.count, 1, "migrate: other events untouched")
    expect(after["model"] as? String, "opus", "migrate: other settings untouched")
    expect((after["permissions"] as? [String: Any])?["ask"] as? [String], ["Bash(git push:*)"], "migrate: permissions untouched")
    expect(backups(), 1, "migrate: backs up before writing")
    expect(FileManager.default.fileExists(atPath: marker.path), true, "migrate: leaves a marker")
    let raw = (try? String(contentsOf: settings, encoding: .utf8)) ?? ""
    expect(raw.contains(#"\/Applications"#), false, "migrate: doesn't escape slashes")

    // The user takes it out again: the marker keeps Nudge from re-adding it.
    write(v131)
    expect(ClaudeSettings.addPermissionRequestHook(settings: settings, marker: marker), .alreadyMigrated, "migrate: runs once")
    expect(((read()["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])?.count, 1, "migrate: a removed entry stays removed")

    // Fresh install (install-hook.sh already added it): nothing to write.
    try? FileManager.default.removeItem(at: marker)
    var fresh = v131
    var freshHooks = fresh["hooks"] as! [String: Any]
    freshHooks["PermissionRequest"] = [["matcher": "*", "hooks": [["type": "command", "command": hook]]]]
    fresh["hooks"] = freshHooks
    write(fresh)
    let before = try? Data(contentsOf: settings)
    expect(ClaudeSettings.addPermissionRequestHook(settings: settings, marker: marker), .alreadyPresent, "migrate: already there")
    expect(try? Data(contentsOf: settings), before, "migrate: already there → file untouched")
    expect(FileManager.default.fileExists(atPath: marker.path), true, "migrate: already there still marks it done")

    try? FileManager.default.removeItem(at: marker)
    try? Data("{ not json".utf8).write(to: settings)
    if case .failed = ClaudeSettings.addPermissionRequestHook(settings: settings, marker: marker) { passed += 1 } else {
        failures.append("✗ migrate: malformed settings.json should fail")
    }
    expect(try? String(contentsOf: settings, encoding: .utf8), "{ not json", "migrate: malformed settings.json left as is")
    expect(FileManager.default.fileExists(atPath: marker.path), false, "migrate: a failed run isn't marked done")

    // settings.json symlinked from a dotfiles repo: edit the target, keep the link.
    let dotfiles = dir.appendingPathComponent("dotfiles")
    try? FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
    let target = dotfiles.appendingPathComponent("claude-settings.json")
    let link = dir.appendingPathComponent("linked-settings.json")
    try? JSONSerialization.data(withJSONObject: v131).write(to: target)
    try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    expect(ClaudeSettings.addPermissionRequestHook(settings: link, marker: marker), .added, "migrate: symlinked settings.json gets the hook")
    let linkType = (try? FileManager.default.attributesOfItem(atPath: link.path))?[.type] as? FileAttributeType
    expect(linkType, .typeSymbolicLink, "migrate: the symlink stays a symlink")
    let targetHooks = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: target))) as? [String: Any])?["hooks"] as? [String: Any]
    expect((targetHooks?["PermissionRequest"] as? [[String: Any]])?.count, 2, "migrate: the link's target has the hook")
}

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

// MARK: PromptQueue — depth updates and withdrawn callers (regression)
//
// The queue only announced head changes, so the "N more" pill and menu bar
// count never moved when prompts piled up behind the head. And a prompt whose
// hook was killed (user pressed Esc in Claude Code) stayed queued until the
// five-minute timeout, blocking everything behind it.

final class HeadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(String?, Int)] = []

    func record(_ prompt: Prompt?, _ depth: Int) {
        lock.lock(); defer { lock.unlock() }
        events.append((prompt?.id, depth))
    }

    var last: (id: String?, depth: Int)? {
        lock.lock(); defer { lock.unlock() }
        return events.last.map { (id: $0.0, depth: $0.1) }
    }
}

func withdrawnError(_ error: Error) -> Bool {
    (error as? PromptQueue.QueueError) == .withdrawn
}

do {
    let queue = PromptQueue()
    let heads = HeadRecorder()
    await queue.setOnHeadChange { heads.record($0, $1) }

    let callerA = Task { try await queue.enqueue(makePrompt("A", command: "rm a")) }
    try await Task.sleep(nanoseconds: 100_000_000)
    let callerB = Task { try await queue.enqueue(makePrompt("B", command: "rm b")) }
    try await Task.sleep(nanoseconds: 100_000_000)
    expect(heads.last?.id, "A", "queue depth: head unchanged when a prompt joins behind it")
    expect(heads.last?.depth, 2, "queue depth: joining prompt is announced")

    let withdrewB = await queue.withdraw(id: "B")
    expect(withdrewB, true, "queue withdraw: a queued prompt can be withdrawn")
    expect(heads.last?.depth, 1, "queue depth: leaving prompt behind the head is announced")
    do {
        _ = try await callerB.value
        failures.append("✗ queue withdraw: withdrawn caller should throw")
    } catch {
        expect(withdrawnError(error), true, "queue withdraw: withdrawn caller gets .withdrawn")
    }

    // The server's path: the hook hangs up, so the task waiting on the
    // decision is cancelled, and the head it owned has to go with it.
    let callerC = Task { try await queue.enqueue(makePrompt("C", command: "rm c")) }
    try await Task.sleep(nanoseconds: 100_000_000)
    expect(heads.last?.depth, 2, "queue cancel: C queued behind A")
    callerA.cancel()
    try await Task.sleep(nanoseconds: 100_000_000)
    expect(heads.last?.id, "C", "queue cancel: cancelling the head's caller withdraws it")
    expect(heads.last?.depth, 1, "queue cancel: depth drops with the withdrawn head")
    do {
        _ = try await callerA.value
        failures.append("✗ queue cancel: cancelled caller should throw")
    } catch {
        expect(withdrawnError(error), true, "queue cancel: cancelled caller gets .withdrawn")
    }

    let resolvedC = await queue.resolve(id: "C", with: .allow)
    expect(resolvedC, true, "queue cancel: the survivor still resolves normally")
    expect(try await callerC.value.decision, Decision.allow, "queue cancel: survivor gets its decision")
    expect(heads.last?.id, nil, "queue cancel: queue drains to empty")
}

do {
    // Cancelled before the prompt ever reached the queue: it must never be
    // shown, whichever side of the actor hop the cancel lands on.
    let queue = PromptQueue()
    let heads = HeadRecorder()
    await queue.setOnHeadChange { heads.record($0, $1) }

    for i in 0..<20 {
        let caller = Task { try await queue.enqueue(makePrompt("early-\(i)", command: "rm x")) }
        caller.cancel()
        _ = try? await caller.value
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    expect(heads.last?.id, nil, "queue cancel: prompts cancelled on arrival never stay queued")
    expect(heads.last?.depth ?? 0, 0, "queue cancel: no ghost depth left behind")
}

do {
    // The server's exact path: the waiting task runs enqueueWithTimeout, and
    // cancellation has to reach the enqueue inside its task group.
    let queue = PromptQueue()
    let heads = HeadRecorder()
    await queue.setOnHeadChange { heads.record($0, $1) }
    let waiter = Task { try await queue.enqueueWithTimeout(makePrompt("W", command: "rm w"), seconds: 30) }
    try await Task.sleep(nanoseconds: 100_000_000)
    expect(heads.last?.id, "W", "queue hangup: prompt is on screen while its caller waits")
    waiter.cancel()
    _ = try? await waiter.value
    try await Task.sleep(nanoseconds: 100_000_000)
    expect(heads.last?.id, nil, "queue hangup: cancelling the waiter clears it well before the timeout")
}

do {
    // A timeout still reads as a timeout, not a withdrawal.
    let queue = PromptQueue()
    do {
        _ = try await queue.enqueueWithTimeout(makePrompt("T", command: "rm t"), seconds: 0.1)
        failures.append("✗ queue timeout: expected a throw")
    } catch {
        expect((error as? PromptQueue.QueueError), .timedOut, "queue timeout: expiry surfaces as .timedOut")
    }
}

// MARK: PromptQueue — finished messages step aside
//
// A finished message waits up to ten minutes for a reply. A permission
// prompt arriving meanwhile goes ahead of it rather than stalling its
// session, and the message comes back once the prompt is answered.

func makeFinished(_ id: String) -> Prompt {
    Prompt(id: id, kind: .finished, tool: "Stop", command: "Done.", cwd: "/tmp",
           sessionId: "other", permissionMode: "auto", event: "Stop")
}

do {
    let queue = PromptQueue()
    let heads = HeadRecorder()
    await queue.setOnHeadChange { heads.record($0, $1) }

    let finishedF = Task { try await queue.enqueue(makeFinished("F")) }
    try await Task.sleep(nanoseconds: 100_000_000)
    let finishedG = Task { try await queue.enqueue(makeFinished("G")) }
    try await Task.sleep(nanoseconds: 100_000_000)
    let permP = Task { try await queue.enqueue(makePrompt("P", command: "rm p")) }
    try await Task.sleep(nanoseconds: 100_000_000)
    let permQ = Task { try await queue.enqueue(makePrompt("Q", command: "rm q")) }
    try await Task.sleep(nanoseconds: 100_000_000)
    let order = await queue.snapshot().map(\.id)
    expect(order, ["P", "Q", "F", "G"], "queue yield: prompts go ahead of finished messages, each kind in order")

    await queue.resolve(id: "P", with: .allow)
    await queue.resolve(id: "Q", with: .deny)
    expect(heads.last?.id, "F", "queue yield: the finished message comes back after the prompts")
    let gotP = try await permP.value
    expect(gotP.decision, Decision.allow, "queue yield: the jumping prompt gets its own answer")
    _ = try await permQ.value
    await queue.resolve(id: "F", with: .cancel)
    await queue.resolve(id: "G", with: .cancel)
    _ = try await finishedF.value
    _ = try await finishedG.value
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

// MARK: TmuxAgentBackend — large captures don't deadlock (regression)
//
// run() waited for tmux to exit before reading its stdout, so a capture larger
// than the ~64KB pipe buffer hung forever: tmux blocked writing, Nudge blocked
// waiting. A fake tmux (via NUDGE_TMUX_PATH) prints 300KB for capture-pane;
// it also exits without reading stdin on load-buffer, which used to risk a
// SIGPIPE crash on send().

func withinDeadline<T>(_ seconds: TimeInterval, _ body: @escaping () -> T) -> T? {
    let done = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Thread.detachNewThread {
        box.value = body()
        done.signal()
    }
    return done.wait(timeout: .now() + seconds) == .success ? box.value : nil
}

final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("nudge-fake-tmux-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let fake = dir.appendingPathComponent("tmux")
    try """
    #!/bin/sh
    case "$1" in
      capture-pane) head -c 300000 /dev/zero | tr '\\0' 'x'; echo; echo "tail-marker" ;;
      display-message) echo 0 ;;
      load-buffer) exit 0 ;;
      *) exit 0 ;;
    esac
    """.write(to: fake, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    setenv("NUDGE_TMUX_PATH", fake.path, 1)
    defer { unsetenv("NUDGE_TMUX_PATH") }

    let session = AgentSessionSummary(
        id: "fake", kind: .claude, title: "fake", cwd: "/tmp",
        tmuxSession: "nudge-fake", createdAt: Date(), isAttached: false
    )
    let backend = TmuxAgentBackend()

    let transcript = withinDeadline(10) { (try? backend.detail(for: session))?.transcript }
    if let transcript {
        expect(transcript?.hasSuffix("tail-marker"), true, "tmux: 300KB capture arrives whole")
    } else {
        failures.append("✗ tmux: capture of 300KB deadlocked (no result in 10s)")
    }

    let big = String(repeating: "y", count: 1_000_000)
    let sent = withinDeadline(10) { () -> Bool in
        (try? backend.send(big, to: session)) != nil
    }
    expect(sent != nil, true, "tmux: send survives tmux exiting without reading stdin")
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

// MARK: MessageLinks (finished panel)

let linkFiles: Set<String> = ["/work/app/demo.mp4", "/work/app/out/report.html", "/Users/dev/shot.png", "/work/notes.md"]
func linkTargets(_ text: String, cwd: String = "/work/app") -> [String] {
    MessageLinks.find(in: text, cwd: cwd, fileExists: { linkFiles.contains($0) }).map { link in
        link.url.isFileURL ? link.url.path : link.url.absoluteString
    }
}
func linkTexts(_ text: String) -> [String] {
    MessageLinks.find(in: text, cwd: "/work/app", fileExists: { linkFiles.contains($0) })
        .map { (text as NSString).substring(with: $0.range) }
}
expect(linkTargets("Dev server is up at localhost:3000."), ["http://localhost:3000"], "links: bare localhost with port")
expect(linkTargets("Open http://127.0.0.1:8080/admin now"), ["http://127.0.0.1:8080/admin"], "links: scheme + path")
expect(linkTargets("see 127.0.0.1:5173/docs"), ["http://127.0.0.1:5173/docs"], "links: bare IP with path")
expect(linkTargets("Docs: https://example.com/a?b=1."), ["https://example.com/a?b=1"], "links: https, trailing period dropped")
expect(linkTargets("Rendered demo.mp4 and out/report.html."), ["/work/app/demo.mp4", "/work/app/out/report.html"], "links: relative files that exist")
expect(linkTexts("Rendered demo.mp4, done."), ["demo.mp4"], "links: comma after a file isn't part of it")
expect(linkTargets("Saved ~/shot.png"), [], "links: ~ expands to the real home, not /Users/dev")
expect(linkTargets("Saved /Users/dev/shot.png"), ["/Users/dev/shot.png"], "links: absolute path")
expect(linkTargets("Wrote ../notes.md"), ["/work/notes.md"], "links: ../ resolves against cwd")
expect(linkTargets("Wrote `demo.mp4`"), ["/work/app/demo.mp4"], "links: inside backticks")
expect(linkTargets("Missing gone.mp4 and e.g. this"), [], "links: missing files and abbreviations stay plain")
expect(linkTargets("Fetched https://cdn.example.com/demo.mp4"), ["https://cdn.example.com/demo.mp4"], "links: a URL isn't also a file")

print("\(passed) passed, \(failures.count) failed")
for failure in failures {
    print(failure)
}
exit(failures.isEmpty ? 0 : 1)
