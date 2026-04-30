import Foundation

public enum PromptKind: String, Codable, Equatable {
    case permission
    case ask
}

public struct Prompt: Codable, Equatable, Identifiable {
    public let id: String
    /// `.permission` (default) for the existing Allow/Deny flow; `.ask` for a
    /// text-input request from `nudge-ask` (Claude wants a free-form answer).
    public let kind: PromptKind?
    public let tool: String
    /// For permission prompts: the command/path being requested.
    /// For asks: the question Claude is asking (we display it as the body).
    public let command: String
    public let cwd: String
    public let sessionId: String
    public let permissionMode: String?
    public let matchedPattern: String?

    public init(
        id: String,
        kind: PromptKind? = nil,
        tool: String,
        command: String,
        cwd: String,
        sessionId: String,
        permissionMode: String? = nil,
        matchedPattern: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.tool = tool
        self.command = command
        self.cwd = cwd
        self.sessionId = sessionId
        self.permissionMode = permissionMode
        self.matchedPattern = matchedPattern
    }

    public var resolvedKind: PromptKind { kind ?? .permission }
}

public enum Decision: String, Codable, Equatable {
    case allow
    case deny
    case text
    case cancel
}

public struct DecisionResponse: Codable, Equatable {
    public let decision: Decision
    /// Present when `decision == .text`.
    public let text: String?

    public init(decision: Decision, text: String? = nil) {
        self.decision = decision
        self.text = text
    }
}
