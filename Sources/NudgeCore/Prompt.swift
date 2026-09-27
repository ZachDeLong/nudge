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
    /// Which agent is asking: "claude" or "codex". Nil from older hooks, and
    /// from nudge-ask, reads as Claude.
    public let agent: String?
    /// The agent's own one-line explanation of the request, when it gives one
    /// (both agents send `tool_input.description` with approval requests).
    public let detail: String?
    /// The hook event that raised it: "PreToolUse" (a pattern match) or
    /// "PermissionRequest" (the agent's own prompt). Nil from older hooks and
    /// nudge-ask.
    public let event: String?
    /// `CallKey` of the tool call, so the app can match this prompt to other
    /// hook events for the same call.
    public let callKey: String?
    /// Claude Code's `agent_id` when a subagent made the call; nil for the
    /// main thread.
    public let subagentId: String?

    public init(
        id: String,
        kind: PromptKind? = nil,
        tool: String,
        command: String,
        cwd: String,
        sessionId: String,
        permissionMode: String? = nil,
        matchedPattern: String? = nil,
        agent: String? = nil,
        detail: String? = nil,
        event: String? = nil,
        callKey: String? = nil,
        subagentId: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.tool = tool
        self.command = command
        self.cwd = cwd
        self.sessionId = sessionId
        self.permissionMode = permissionMode
        self.matchedPattern = matchedPattern
        self.agent = agent
        self.detail = detail
        self.event = event
        self.callKey = callKey
        self.subagentId = subagentId
    }

    public var resolvedKind: PromptKind { kind ?? .permission }

    /// Raised by the agent's own approval prompt rather than a pattern.
    public var isPermissionRequest: Bool { event == "PermissionRequest" }

    /// "Claude" or "Codex", for titles and notices.
    public var agentName: String { agent == "codex" ? "Codex" : "Claude" }
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
