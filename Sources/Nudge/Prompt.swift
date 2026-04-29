import Foundation

struct Prompt: Codable, Equatable, Identifiable {
    let id: String
    let tool: String
    let command: String
    let cwd: String
    let sessionId: String
}

enum Decision: String, Codable {
    case allow
    case deny
}

struct DecisionResponse: Codable {
    let decision: Decision
}
