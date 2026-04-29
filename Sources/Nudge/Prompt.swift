import Foundation

struct Prompt: Codable, Equatable, Identifiable {
    let id: String
    let tool: String
    let command: String
    let cwd: String
    let sessionId: String
    /// Claude Code's `permission_mode` at the time of the prompt — "default",
    /// "auto", "plan", etc. We use it to decide whether "Always allow" makes
    /// sense to offer (in auto mode Claude wouldn't have prompted, so the
    /// concept of "always" is moot).
    let permissionMode: String?
}

enum Decision: String, Codable {
    case allow
    case deny
}

struct DecisionResponse: Codable {
    let decision: Decision
}
