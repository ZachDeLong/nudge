import Foundation

struct Prompt: Codable, Equatable, Identifiable {
    let id: String
    let tool: String
    let command: String
    let cwd: String
    let sessionId: String
    /// Claude Code's `permission_mode` at the time of the prompt — "default",
    /// "auto", "plan", etc.
    let permissionMode: String?
    /// The literal pattern from patterns.txt that matched this command, e.g.
    /// `Bash(git push:*)`. Used to decide whether "Always allow" is offerable
    /// (only prefix/exact patterns translate to valid Claude permission rules)
    /// and what gets written to permissions.allow when chosen.
    let matchedPattern: String?
}

enum Decision: String, Codable {
    case allow
    case deny
}

struct DecisionResponse: Codable {
    let decision: Decision
}
