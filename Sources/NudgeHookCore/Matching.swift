import Foundation

public enum ToolFamily {
    case bash       // matches against tool_input.command
    case path       // matches against tool_input.file_path with glob
    case unknown
}

public func family(for tool: String) -> ToolFamily {
    switch tool {
    case "Bash": return .bash
    case "Edit", "Write", "Read", "MultiEdit", "NotebookEdit": return .path
    default: return .unknown
    }
}

/// Splits a pattern like `Edit(/etc/**)` into ("Edit", "/etc/**"). Rejects any
/// line with no `(`, no trailing `)`, an empty tool name, or an empty inner —
/// those would silently match nothing or (in the case of `Bash(:*)`) match
/// every command and become promotable to "Always allow."
public func parsePattern(_ pattern: String) -> (tool: String, spec: String)? {
    guard let openIdx = pattern.firstIndex(of: "("), pattern.hasSuffix(")") else { return nil }
    let toolPart = String(pattern[..<openIdx])
    let inner = String(pattern[pattern.index(after: openIdx)..<pattern.index(before: pattern.endIndex)])
    guard !toolPart.isEmpty, !inner.isEmpty else { return nil }
    return (toolPart, inner)
}

public func globToRegex(_ glob: String) -> String {
    var out = "^"
    var i = glob.startIndex
    while i < glob.endIndex {
        let c = glob[i]
        switch c {
        case "*":
            let next = glob.index(after: i)
            if next < glob.endIndex && glob[next] == "*" {
                out += ".*"
                i = glob.index(after: next)
                continue
            }
            out += "[^/]*"
        case "?":
            out += "[^/]"
        case "+", "(", ")", "[", "]", "{", "}", "|", "^", "$", ".", "\\":
            out += "\\" + String(c)
        default:
            out += String(c)
        }
        i = glob.index(after: i)
    }
    out += "$"
    return out
}

public func globMatch(path: String, glob: String) -> Bool {
    let pattern = globToRegex(glob)
    return path.range(of: pattern, options: .regularExpression) != nil
}

/// Splits a bash command into top-level subcommands by recognizing sequencing
/// operators (`&&`, `||`, `;`, `|`, `&`) outside of quotes, command substitutions,
/// arithmetic expansions, backticks, subshell groups, and brace groups. Skips
/// `&` adjacent to redirection syntax (`&>`, `2>&1`). Not a full bash parser —
/// covers the shapes Claude Code actually emits.
public func splitBashCommand(_ command: String) -> [String] {
    var segments: [String] = []
    var current = ""
    var i = command.startIndex
    var inSingle = false
    var inDouble = false
    var inBacktick = false
    var dollarParenDepth = 0
    var arithDepth = 0       // tracks $(( ... )) so its inner && doesn't split
    var subshellDepth = 0    // tracks (cmd; cmd) — keep as one segment for peeling
    var braceDepth = 0       // tracks { cmd; } — same

    func flush() {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { segments.append(trimmed) }
        current = ""
    }

    while i < command.endIndex {
        let c = command[i]

        if c == "\\" && !inSingle {
            current.append(c)
            let next = command.index(after: i)
            if next < command.endIndex {
                current.append(command[next])
                i = command.index(after: next)
            } else {
                i = command.index(after: i)
            }
            continue
        }

        if inSingle {
            current.append(c)
            if c == "'" { inSingle = false }
            i = command.index(after: i)
            continue
        }
        if inDouble {
            current.append(c)
            if c == "\"" { inDouble = false }
            i = command.index(after: i)
            continue
        }
        if inBacktick {
            current.append(c)
            if c == "`" { inBacktick = false }
            i = command.index(after: i)
            continue
        }

        if c == "'" { inSingle = true; current.append(c); i = command.index(after: i); continue }
        if c == "\"" { inDouble = true; current.append(c); i = command.index(after: i); continue }
        if c == "`" { inBacktick = true; current.append(c); i = command.index(after: i); continue }

        // $(( arithmetic — checked before $( substitution since both start with $(.
        if c == "$" {
            let n1 = command.index(after: i)
            if n1 < command.endIndex && command[n1] == "(" {
                let n2 = command.index(after: n1)
                if n2 < command.endIndex && command[n2] == "(" {
                    arithDepth += 1
                    current.append(contentsOf: "$((")
                    i = command.index(after: n2)
                    continue
                }
                dollarParenDepth += 1
                current.append("$")
                current.append("(")
                i = command.index(after: n1)
                continue
            }
        }
        if arithDepth > 0 {
            let next = command.index(after: i)
            if c == ")" && next < command.endIndex && command[next] == ")" {
                arithDepth -= 1
                current.append(contentsOf: "))")
                i = command.index(after: next)
                continue
            }
            current.append(c)
            i = command.index(after: i)
            continue
        }
        if dollarParenDepth > 0 {
            if c == "(" { dollarParenDepth += 1 }
            if c == ")" { dollarParenDepth -= 1 }
            current.append(c)
            i = command.index(after: i)
            continue
        }

        // Subshell ( ... ) — keep as one segment so bashCandidates can peel and recurse.
        if c == "(" {
            subshellDepth += 1
            current.append(c)
            i = command.index(after: i)
            continue
        }
        if c == ")" {
            if subshellDepth > 0 { subshellDepth -= 1 }
            current.append(c)
            i = command.index(after: i)
            continue
        }

        // Brace group { ... ; } — `{` only opens a group when it's the start of a token.
        if c == "{" {
            let prev = current.reversed().first(where: { !$0.isWhitespace })
            let atTokenStart = prev == nil || prev == ";" || prev == "&" || prev == "|" || prev == "(" || prev == "{"
            if atTokenStart { braceDepth += 1 }
            current.append(c)
            i = command.index(after: i)
            continue
        }
        if c == "}" && braceDepth > 0 {
            braceDepth -= 1
            current.append(c)
            i = command.index(after: i)
            continue
        }

        // Inside any group, don't split on operators.
        if subshellDepth > 0 || braceDepth > 0 {
            current.append(c)
            i = command.index(after: i)
            continue
        }

        let next = command.index(after: i)

        if c == "&" && next < command.endIndex && command[next] == "&" {
            flush()
            i = command.index(after: next)
            continue
        }
        if c == "|" && next < command.endIndex && command[next] == "|" {
            flush()
            i = command.index(after: next)
            continue
        }

        // Single & is background, but `&>` is redirect-all and `N>&M` is FD-dup.
        if c == "&" {
            let nextIsGt = next < command.endIndex && command[next] == ">"
            let prevIsGt = current.last == ">"
            if nextIsGt || prevIsGt {
                current.append(c)
                i = command.index(after: i)
                continue
            }
            flush()
            i = command.index(after: i)
            continue
        }
        if c == ";" || c == "|" {
            flush()
            i = command.index(after: i)
            continue
        }

        current.append(c)
        i = command.index(after: i)
    }

    flush()
    return segments
}

/// Returns prefix/exact match candidates for a Bash target — top-level segments
/// from `splitBashCommand`, plus the contents of any subshell `(...)` or brace
/// group `{...;}` wrappers. So `(rm -rf foo); ls` yields `["(rm -rf foo)",
/// "rm -rf foo", "ls"]`, letting `Bash(rm:*)` match the wrapped destructive
/// call instead of being silently bypassed.
public func bashCandidates(for target: String) -> [String] {
    let segments = splitBashCommand(target)
    var out: [String] = []
    for seg in segments {
        out.append(seg)
        let trimmed = seg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { continue }
        let first = trimmed.first!
        let last = trimmed.last!
        let isParen = first == "(" && last == ")"
        let isBrace = first == "{" && last == "}"
        if isParen || isBrace {
            var inner = String(trimmed.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if inner.hasSuffix(";") {
                inner = String(inner.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !inner.isEmpty {
                out.append(contentsOf: bashCandidates(for: inner))
            }
        }
    }
    return out
}

/// Normalizes a bash command for infix substring search so superficial syntax
/// variants don't bypass the safety check. Strips quote markers, backslash
/// escapes, `$(...)` and backtick boundaries, and case-folds. Catches the
/// common accidental bypasses (`--FORCE`, `--for""ce`, `git push --for\\ce`,
/// `$(echo --force)`).
///
/// Does NOT catch determined adversarial inputs — env-var split-and-reassemble
/// (`F=--force git push $F`), `printf '\\x2d\\x2dforce'` hex escapes, `eval`,
/// `base64 -d`, etc. all need real bash interpretation. Nudge's threat model
/// is agent-accident, not adversarial bypass — the agent already has shell
/// access; this just keeps the safety prompt honest against incidental
/// command-shape variation.
public func normalizeForInfix(_ s: String) -> String {
    var out = ""
    var i = s.startIndex
    while i < s.endIndex {
        let c = s[i]
        if c == "\\" {
            let next = s.index(after: i)
            if next < s.endIndex {
                out.append(s[next])
                i = s.index(after: next)
            } else {
                i = s.index(after: i)
            }
            continue
        }
        if c == "'" || c == "\"" || c == "`" {
            i = s.index(after: i)
            continue
        }
        if c == "$" {
            let next = s.index(after: i)
            if next < s.endIndex && s[next] == "(" {
                i = s.index(after: next)
                continue
            }
        }
        if c == "(" || c == ")" {
            i = s.index(after: i)
            continue
        }
        out.append(c)
        i = s.index(after: i)
    }
    return out.lowercased()
}

/// True if `segment` starts with `prefix` at a token boundary — segment equals
/// prefix exactly, or the next char after the prefix is whitespace. Stops
/// `Bash(rm:*)` from matching `rmdir` while still matching `rm` and `rm -rf foo`.
public func hasTokenPrefix(_ segment: String, prefix: String) -> Bool {
    if segment == prefix { return true }
    guard segment.hasPrefix(prefix) else { return false }
    let nextIdx = segment.index(segment.startIndex, offsetBy: prefix.count)
    return segment[nextIdx].isWhitespace
}

/// Returns the matched pattern (the literal string from patterns.txt), or nil
/// if no pattern matched.
///
/// Priority: infix matches win over prefix/exact when both fire on the same
/// input. Infix patterns are deny-leaning (you wrote `Bash(*--force*)` because
/// you want to be asked when `--force` appears) so they aren't promotable, and
/// infix taking priority hides the "Always allow" option in the UI.
///
/// Bash matching tokenizes the command into top-level subcommands and peels
/// subshell/brace wrappers so prefix and exact patterns match individual
/// segments of a chained or wrapped call. Infix matching normalizes both sides
/// (strips quotes/backslashes, case-folds, inlines `$(...)` bodies) so trivial
/// syntax variants don't bypass the safety check.
public func matchedPattern(toolName: String, target: String, patterns: [String]) -> String? {
    var firstInfix: String? = nil
    var firstPromotable: String? = nil

    let candidates: [String]
    let normalizedTarget: String
    if family(for: toolName) == .bash {
        candidates = bashCandidates(for: target)
        normalizedTarget = normalizeForInfix(target)
    } else {
        candidates = []
        normalizedTarget = ""
    }

    for pattern in patterns {
        guard let (toolPart, inner) = parsePattern(pattern), toolPart == toolName else { continue }

        switch family(for: toolName) {
        case .bash:
            if inner.hasPrefix("*") && inner.hasSuffix("*") {
                let needle = normalizeForInfix(String(inner.dropFirst().dropLast()))
                if !needle.isEmpty && normalizedTarget.contains(needle), firstInfix == nil {
                    firstInfix = pattern
                }
            } else if inner.hasSuffix(":*") {
                let prefix = String(inner.dropLast(2))
                guard !prefix.isEmpty else { continue }
                if candidates.contains(where: { hasTokenPrefix($0, prefix: prefix) }), firstPromotable == nil {
                    firstPromotable = pattern
                }
            } else {
                if candidates.contains(where: { $0 == inner }), firstPromotable == nil {
                    firstPromotable = pattern
                }
            }
        case .path:
            if globMatch(path: target, glob: inner), firstPromotable == nil {
                firstPromotable = pattern
            }
        case .unknown:
            break
        }
    }

    return firstInfix ?? firstPromotable
}
