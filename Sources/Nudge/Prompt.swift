import Foundation

enum PromptKind: String, Codable {
    case permission
    case ask
}

struct Prompt: Codable, Equatable, Identifiable {
    let id: String
    /// `.permission` (default) for the existing Allow/Deny flow; `.ask` for a
    /// text-input request from `nudge-ask` (Claude wants a free-form answer).
    let kind: PromptKind?
    let tool: String
    /// For permission prompts: the command/path being requested.
    /// For asks: the question Claude is asking (we display it as the body).
    let command: String
    let cwd: String
    let sessionId: String
    let permissionMode: String?
    let matchedPattern: String?

    var resolvedKind: PromptKind { kind ?? .permission }
}

enum Decision: String, Codable {
    case allow
    case deny
    case text       // ask was answered with free-form text
    case cancel     // ask was cancelled (Esc / click-outside)
}

struct DecisionResponse: Codable {
    let decision: Decision
    /// Present when `decision == .text` — the user's typed answer.
    let text: String?
}
