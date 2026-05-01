import Foundation

public enum TmuxAgentError: Error, CustomStringConvertible, Equatable, Sendable {
    case tmuxUnavailable
    case commandFailed(command: String, status: Int32, stderr: String)
    case sessionMissing(String)
    case sessionEnded(String)

    public var description: String {
        switch self {
        case .tmuxUnavailable:
            return "tmux is not installed. Install it with: brew install tmux"
        case .commandFailed(let command, let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "\(command) failed with status \(status)"
                : "\(command) failed with status \(status): \(detail)"
        case .sessionMissing(let session):
            return "tmux session not found: \(session)"
        case .sessionEnded(let session):
            return "tmux session has ended: \(session)"
        }
    }
}

public struct TmuxAgentBackend: Sendable {
    public init() {}

    public func createSession(
        kind: AgentKind,
        executable: String,
        arguments: [String],
        cwd: String
    ) throws -> AgentSessionSummary {
        guard isTmuxAvailable() else { throw TmuxAgentError.tmuxUnavailable }

        let id = "\(kind.rawValue)-\(Int(Date().timeIntervalSince1970))-\(ProcessInfo.processInfo.processIdentifier)"
        let tmuxSession = "nudge-\(id)"
        let command = ([executable] + arguments).map(Self.shellQuote).joined(separator: " ")

        _ = try run(["new-session", "-d", "-s", tmuxSession, "-c", cwd, command])

        let summary = AgentSessionSummary(
            id: id,
            kind: kind,
            title: "\(kind.rawValue) - \(URL(fileURLWithPath: cwd).lastPathComponent)",
            cwd: cwd,
            tmuxSession: tmuxSession,
            createdAt: Date(),
            isAttached: false
        )
        do {
            try AgentSessionFiles.write(summary)
        } catch {
            try? run(["kill-session", "-t", tmuxSession])
            throw error
        }
        return summary
    }

    public func listSessions() throws -> [AgentSessionSummary] {
        guard isTmuxAvailable() else { return [] }

        return try AgentSessionFiles.readAll().compactMap { session in
            guard hasSession(session.tmuxSession) else {
                return nil
            }
            var live = session
            live.isAttached = attachedCount(for: session.tmuxSession) > 0
            live.isEnded = isPaneDead(session.tmuxSession)
            return live
        }
    }

    public func detail(for session: AgentSessionSummary, lineLimit: Int = 180) throws -> AgentSessionDetail {
        guard hasSession(session.tmuxSession) else {
            throw TmuxAgentError.sessionMissing(session.tmuxSession)
        }
        var live = session
        live.isEnded = isPaneDead(session.tmuxSession)
        let raw = try capture(session: session, lineLimit: lineLimit)
        return AgentSessionDetail(summary: live, transcript: Self.cleanTranscript(raw))
    }

    /// Strips ANSI escape sequences, drops lines that are mostly decorative
    /// box-drawing or separator characters (the Claude Code TUI's input
    /// border), and collapses runs of blank lines. The chat-mirror cares
    /// about what was said, not how the terminal painted it.
    static func cleanTranscript(_ raw: String) -> String {
        let escapePattern = "\u{001B}(?:\\[[0-?]*[ -/]*[@-~]|\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)|P[\\s\\S]*?\u{001B}\\\\|[_^X][\\s\\S]*?\u{001B}\\\\|[@-_])"
        let stripped = raw.replacingOccurrences(
            of: escapePattern,
            with: "",
            options: .regularExpression
        )
        let decorativeChars: Set<Character> = [
            "\u{2500}", "\u{2501}", "=", "_", "-", "\u{2502}", "\u{2551}", "\u{2022}", "\u{2310}",
        ]
        let lines = stripped.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var out: [String] = []
        var blankRun = 0
        for raw in lines {
            let line = trimTrailingHorizontalWhitespace(String(raw))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                blankRun += 1
                if blankRun <= 1 { out.append("") }
                continue
            }
            blankRun = 0
            let nonSpace = trimmed.filter { !$0.isWhitespace }
            if !nonSpace.isEmpty {
                let decorative = nonSpace.filter { decorativeChars.contains($0) }.count
                if Double(decorative) / Double(nonSpace.count) > 0.6 { continue }
            }
            out.append(line)
        }
        while out.last?.isEmpty == true { out.removeLast() }
        while out.first?.isEmpty == true { out.removeFirst() }
        return out.joined(separator: "\n")
    }

    private static func trimTrailingHorizontalWhitespace(_ line: String) -> String {
        var end = line.endIndex
        while end > line.startIndex {
            let previous = line.index(before: end)
            let character = line[previous]
            guard character == " " || character == "\t" else { break }
            end = previous
        }
        return String(line[..<end])
    }

    public func send(_ text: String, to session: AgentSessionSummary) throws {
        guard hasSession(session.tmuxSession) else {
            throw TmuxAgentError.sessionMissing(session.tmuxSession)
        }
        guard !isPaneDead(session.tmuxSession) else {
            throw TmuxAgentError.sessionEnded(session.tmuxSession)
        }
        let safe = Self.sanitizedPasteText(text)
        guard !safe.isEmpty else { return }
        let target = "\(session.tmuxSession):0.0"
        let bufferName = "nudge-\(session.id)-\(UUID().uuidString)"

        _ = try run(["load-buffer", "-b", bufferName, "-"], input: Data(safe.utf8))
        defer { try? run(["delete-buffer", "-b", bufferName]) }

        _ = try run(["paste-buffer", "-d", "-p", "-b", bufferName, "-t", target])
        _ = try run(["send-keys", "-t", target, "Enter"])
    }

    static func sanitizedPasteText(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return String(String.UnicodeScalarView(normalized.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x09, 0x0A:
                return true
            case 0x20...0x7E:
                return true
            case 0xA0...0x10FFFF:
                return true
            default:
                return false
            }
        }))
    }

    public func attach(to session: AgentSessionSummary) throws {
        guard hasSession(session.tmuxSession) else {
            throw TmuxAgentError.sessionMissing(session.tmuxSession)
        }
        guard !isPaneDead(session.tmuxSession) else {
            throw TmuxAgentError.sessionEnded(session.tmuxSession)
        }
        try runAttached(["attach-session", "-t", session.tmuxSession])
    }

    public func killSession(_ session: AgentSessionSummary) {
        _ = try? run(["kill-session", "-t", session.tmuxSession])
        AgentSessionFiles.remove(id: session.id)
    }

    public func isTmuxAvailable() -> Bool {
        (try? run(["-V"])) != nil
    }

    private func capture(session: AgentSessionSummary, lineLimit: Int) throws -> String {
        let target = "\(session.tmuxSession):0.0"
        return try run(["capture-pane", "-t", target, "-p", "-J", "-S", "-\(lineLimit)"])
    }

    private func hasSession(_ name: String) -> Bool {
        (try? run(["has-session", "-t", name])) != nil
    }

    private func attachedCount(for name: String) -> Int {
        guard let raw = try? run(["display-message", "-p", "-t", name, "#{session_attached}"]) else {
            return 0
        }
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func isPaneDead(_ name: String) -> Bool {
        let target = "\(name):0.0"
        guard let raw = try? run(["display-message", "-p", "-t", target, "#{pane_dead}"]) else {
            return false
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    @discardableResult
    private func run(_ args: [String], input: Data? = nil) throws -> String {
        let process = Process()
        let command = Self.configureTmuxProcess(process, args: args)

        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = input.map { _ in Pipe() }
        process.standardOutput = stdout
        process.standardError = stderr
        if let stdin {
            process.standardInput = stdin
        }

        do {
            try process.run()
        } catch {
            throw TmuxAgentError.tmuxUnavailable
        }
        if let input, let stdin {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }
        process.waitUntilExit()

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw TmuxAgentError.commandFailed(
                command: "\(command) \(args.joined(separator: " "))",
                status: process.terminationStatus,
                stderr: err
            )
        }
        return out
    }

    private func runAttached(_ args: [String]) throws {
        let process = Process()
        let command = Self.configureTmuxProcess(process, args: args)
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        do {
            try process.run()
        } catch {
            throw TmuxAgentError.tmuxUnavailable
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw TmuxAgentError.commandFailed(
                command: "\(command) \(args.joined(separator: " "))",
                status: process.terminationStatus,
                stderr: ""
            )
        }
    }

    private static func configureTmuxProcess(_ process: Process, args: [String]) -> String {
        if let path = tmuxExecutablePath() {
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            return path
        }

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux"] + args
        return "tmux"
    }

    private static func tmuxExecutablePath() -> String? {
        let envPath = ProcessInfo.processInfo.environment["NUDGE_TMUX_PATH"]
        let candidates = [
            envPath,
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
        ].compactMap { $0 }

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-=/:.,")
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
