import Foundation

public enum TmuxAgentError: Error, CustomStringConvertible, Equatable, Sendable {
    case tmuxUnavailable
    case commandFailed(command: String, status: Int32, stderr: String)
    case sessionMissing(String)

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
                AgentSessionFiles.remove(id: session.id)
                return nil
            }
            var live = session
            live.isAttached = attachedCount(for: session.tmuxSession) > 0
            return live
        }
    }

    public func detail(for session: AgentSessionSummary, lineLimit: Int = 180) throws -> AgentSessionDetail {
        guard hasSession(session.tmuxSession) else {
            AgentSessionFiles.remove(id: session.id)
            throw TmuxAgentError.sessionMissing(session.tmuxSession)
        }
        let raw = try capture(session: session, lineLimit: lineLimit)
        return AgentSessionDetail(summary: session, transcript: Self.cleanTranscript(raw))
    }

    /// Strips ANSI escape sequences, drops lines that are mostly decorative
    /// box-drawing or separator characters (the Claude Code TUI's input
    /// border), and collapses runs of blank lines. The chat-mirror cares
    /// about what was said, not how the terminal painted it.
    static func cleanTranscript(_ raw: String) -> String {
        let stripped = raw.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
        let decorativeChars: Set<Character> = ["─", "━", "=", "_", "-", "│", "║", "•", "⌐"]
        let lines = stripped.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var out: [String] = []
        var blankRun = 0
        for raw in lines {
            let line = String(raw)
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

    public func send(_ text: String, to session: AgentSessionSummary) throws {
        guard hasSession(session.tmuxSession) else {
            AgentSessionFiles.remove(id: session.id)
            throw TmuxAgentError.sessionMissing(session.tmuxSession)
        }
        // tmux send-keys -l forwards bytes verbatim; an embedded ESC or DCS
        // would reach the pane's input parser. Strip C0 control chars (and
        // DEL) so chat messages can't deliver terminal escape sequences.
        // Newlines are intentionally dropped — the explicit `Enter` send-keys
        // call below is what submits the message.
        let safe = String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        }))
        guard !safe.isEmpty else { return }
        let target = "\(session.tmuxSession):0.0"
        _ = try run(["send-keys", "-t", target, "-l", safe])
        _ = try run(["send-keys", "-t", target, "Enter"])
    }

    public func attach(to session: AgentSessionSummary) throws {
        guard hasSession(session.tmuxSession) else {
            AgentSessionFiles.remove(id: session.id)
            throw TmuxAgentError.sessionMissing(session.tmuxSession)
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
        return try run(["capture-pane", "-t", target, "-p", "-S", "-\(lineLimit)"])
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

    @discardableResult
    private func run(_ args: [String]) throws -> String {
        let process = Process()
        let command = Self.configureTmuxProcess(process, args: args)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw TmuxAgentError.tmuxUnavailable
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
