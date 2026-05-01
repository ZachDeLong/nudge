import Foundation
import NudgeCore

let args = Array(CommandLine.arguments.dropFirst())
let backend = TmuxAgentBackend()

func usage() {
    fputs("""
    nudge-claude              Start a new Claude session in tmux and attach.
    nudge-claude attach [id]  Re-attach to an existing session (most recent if no id).
    nudge-claude list         List mirrored Claude sessions.
    nudge-claude --help       Show this help.

    """, stderr)
}

func describe(_ session: AgentSessionSummary) -> String {
    if let title = session.customTitle, !title.isEmpty {
        return title
    }
    return "\(session.kind.rawValue) - \(session.projectName)"
}

func status(_ session: AgentSessionSummary) -> String {
    if session.isEnded { return "ended" }
    return session.isAttached ? "attached" : "detached"
}

switch args.first {
case "list":
    do {
        let sessions = try backend.listSessions()
        if sessions.isEmpty {
            print("No active sessions. Start one with: nudge-claude")
        } else {
            for session in sessions {
                print("\(session.id)\t\(status(session))\t\(describe(session))\t\(session.tmuxSession)")
            }
        }
        exit(0)
    } catch {
        fputs("nudge-claude: \(error)\n", stderr)
        exit(1)
    }

case "attach":
    do {
        let sessions = try backend.listSessions()
        let target: AgentSessionSummary?
        if args.count >= 2 {
            let needle = args[1]
            target = sessions.first(where: { $0.id == needle })
                ?? sessions.first(where: { $0.tmuxSession == needle })
        } else {
            target = sessions.first
        }
        guard let session = target else {
            fputs("nudge-claude: no matching session. Run `nudge-claude list` to see active sessions.\n", stderr)
            exit(1)
        }
        print("Attaching to: \(describe(session))")
        print("Detach without stopping Claude: Ctrl-b then d")
        try backend.attach(to: session)
        exit(0)
    } catch {
        fputs("nudge-claude: \(error)\n", stderr)
        exit(1)
    }

case "--help", "-h", "help":
    usage()
    exit(0)

default:
    let cwd = FileManager.default.currentDirectoryPath
    do {
        let session = try backend.createSession(
            kind: .claude,
            executable: "claude",
            arguments: args,
            cwd: cwd
        )
        print("Nudge started Claude session: \(session.tmuxSession)")
        print("Detach without stopping Claude: Ctrl-b then d")
        print("Re-attach later from any terminal: nudge-claude attach")
        try backend.attach(to: session)
    } catch {
        fputs("nudge-claude: \(error)\n", stderr)
        exit(1)
    }
}
