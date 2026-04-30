import AppKit
import Foundation
import NudgeCore

// MARK: - Args

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("usage: nudge-ask <question>\n", stderr)
    exit(2)
}
let question = args[1...].joined(separator: " ")
guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    fputs("nudge-ask: question is empty\n", stderr)
    exit(2)
}

// Honor the same toggles the hook respects. If Nudge is paused, or the user
// is already at a terminal/IDE with the skip toggle on, exit non-zero so
// Claude falls back to asking inline in the terminal.
let askSettings = Prefs.load()

if !askSettings.enabled {
    fputs("nudge-ask: Nudge is paused\n", stderr)
    exit(1)
}

if askSettings.skipWhenTerminalFocused,
   let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
   FrontmostApp.terminalBundleIDs.contains(frontmost) {
    fputs("nudge-ask: terminal is focused (skip-when-terminal toggle is on)\n", stderr)
    exit(1)
}

let prompt = Prompt(
    id: UUID().uuidString,
    kind: .ask,
    tool: "Ask",
    command: question,
    cwd: FileManager.default.currentDirectoryPath,
    sessionId: ProcessInfo.processInfo.environment["CLAUDE_SESSION_ID"] ?? "ask",
    permissionMode: "default"
)

// MARK: - Locate Nudge

guard let port = NudgeClient.locatePort() else {
    fputs("nudge-ask: Nudge is not running and could not be launched\n", stderr)
    exit(1)
}

// MARK: - POST and wait

let response: DecisionResponse
do {
    response = try NudgeClient.postPrompt(prompt, to: "/ask", port: port)
} catch NudgeClientError.requestTimedOut {
    fputs("nudge-ask: timed out\n", stderr)
    exit(124)
} catch NudgeClientError.unauthorized {
    fputs("nudge-ask: auth failed (token mismatch). Try restarting Nudge.\n", stderr)
    exit(1)
} catch NudgeClientError.tokenMissing {
    fputs("nudge-ask: token file missing or invalid. Try restarting Nudge.\n", stderr)
    exit(1)
} catch NudgeClientError.unexpectedStatus(let status) {
    fputs("nudge-ask: unexpected status \(status)\n", stderr)
    exit(1)
} catch {
    fputs("nudge-ask: request failed: \(error)\n", stderr)
    exit(1)
}

switch response.decision {
case .text:
    print(response.text ?? "")
    exit(0)
case .cancel:
    fputs("nudge-ask: cancelled by user\n", stderr)
    exit(130)
default:
    fputs("nudge-ask: unexpected decision: \(response.decision.rawValue)\n", stderr)
    exit(1)
}
