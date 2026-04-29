import Foundation

/// Tool families the hook knows how to match against.
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

/// Splits a pattern like `Edit(/etc/**)` into ("Edit", "/etc/**"). Returns nil
/// for malformed patterns or any non-`Tool(...)` line.
public func parsePattern(_ pattern: String) -> (tool: String, spec: String)? {
    guard let openIdx = pattern.firstIndex(of: "("), pattern.hasSuffix(")") else { return nil }
    let toolPart = String(pattern[..<openIdx])
    let inner = String(pattern[pattern.index(after: openIdx)..<pattern.index(before: pattern.endIndex)])
    return (toolPart, inner)
}

/// Converts a glob (`*` = single segment, `**` = recursive, `?` = single char)
/// into an anchored regex string. Used for path-based tool patterns.
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
/// operators (`&&`, `||`, `;`, `|`, `&`) outside of quotes and command
/// substitutions. Not a full bash parser — handles the common cases well enough
/// that prefix patterns like `Bash(git push:*)` match the `git push` segment of
/// a chained call like `cd foo && git push`.
public func splitBashCommand(_ command: String) -> [String] {
    var segments: [String] = []
    var current = ""
    var i = command.startIndex
    var inSingle = false
    var inDouble = false
    var inBacktick = false
    var dollarParenDepth = 0

    func flush() {
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { segments.append(trimmed) }
        current = ""
    }

    while i < command.endIndex {
        let c = command[i]

        // Backslash escape outside single quotes copies the next char verbatim.
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

        // Outside any quoted/escaped context.
        if c == "'" { inSingle = true; current.append(c); i = command.index(after: i); continue }
        if c == "\"" { inDouble = true; current.append(c); i = command.index(after: i); continue }
        if c == "`" { inBacktick = true; current.append(c); i = command.index(after: i); continue }

        // $( opens a command substitution; we track depth so nested ()s don't close it early.
        if c == "$" {
            let next = command.index(after: i)
            if next < command.endIndex && command[next] == "(" {
                dollarParenDepth += 1
                current.append(c)
                current.append(command[next])
                i = command.index(after: next)
                continue
            }
        }
        if dollarParenDepth > 0 {
            if c == "(" { dollarParenDepth += 1 }
            if c == ")" { dollarParenDepth -= 1 }
            current.append(c)
            i = command.index(after: i)
            continue
        }

        // Two-char operators: && and ||
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

        // Single-char operators: ; | &
        if c == ";" || c == "|" || c == "&" {
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

/// Returns the matched pattern (the literal string from patterns.txt), or nil
/// if no pattern matched.
///
/// Priority: infix matches win over prefix/exact when both fire on the same
/// input. That way `git push --force origin main` (matches both
/// `Bash(git push:*)` and `Bash(*--force*)`) returns the infix, hiding the
/// always-allow option in the UI.
///
/// Bash matching tokenizes the command into top-level subcommands so prefix
/// and exact patterns can match individual segments of a chained call. Infix
/// patterns still match against the full command string (substring search
/// already handles the chained case for free).
public func matchedPattern(toolName: String, target: String, patterns: [String]) -> String? {
    var firstInfix: String? = nil
    var firstPromotable: String? = nil

    let bashCandidates: [String] = {
        guard family(for: toolName) == .bash else { return [] }
        let segments = splitBashCommand(target)
        return segments.isEmpty ? [target] : segments
    }()

    for pattern in patterns {
        guard let (toolPart, inner) = parsePattern(pattern), toolPart == toolName else { continue }

        switch family(for: toolName) {
        case .bash:
            if inner.hasPrefix("*") && inner.hasSuffix("*") {
                let needle = String(inner.dropFirst().dropLast())
                if !needle.isEmpty && target.contains(needle), firstInfix == nil {
                    firstInfix = pattern
                }
            } else if inner.hasSuffix(":*") {
                let prefix = String(inner.dropLast(2))
                if bashCandidates.contains(where: { $0.hasPrefix(prefix) }), firstPromotable == nil {
                    firstPromotable = pattern
                }
            } else {
                if bashCandidates.contains(where: { $0 == inner }), firstPromotable == nil {
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
