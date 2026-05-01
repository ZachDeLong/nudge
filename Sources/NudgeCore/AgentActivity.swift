import Foundation

public enum AgentActivityState: String, Codable, Equatable, Sendable {
    case unknown
    case thinking
    case usingTool
    case waitingForInput
    case idle
    case failed
    case ended
}

public struct AgentHookEvent: Codable, Equatable, Sendable {
    public let id: String
    public let occurredAt: Date
    public let nudgeSessionID: String?
    public let claudeSessionID: String?
    public let eventName: String
    public let cwd: String?
    public let transcriptPath: String?
    public let permissionMode: String?
    public let toolName: String?
    public let toolSummary: String?
    public let promptPreview: String?
    public let message: String?
    public let error: String?

    public init(
        id: String = UUID().uuidString,
        occurredAt: Date = Date(),
        nudgeSessionID: String?,
        claudeSessionID: String?,
        eventName: String,
        cwd: String?,
        transcriptPath: String?,
        permissionMode: String?,
        toolName: String?,
        toolSummary: String?,
        promptPreview: String?,
        message: String?,
        error: String?
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.nudgeSessionID = nudgeSessionID
        self.claudeSessionID = claudeSessionID
        self.eventName = eventName
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.permissionMode = permissionMode
        self.toolName = toolName
        self.toolSummary = toolSummary
        self.promptPreview = promptPreview
        self.message = message
        self.error = error
    }
}

public struct AgentActivitySnapshot: Codable, Equatable, Sendable {
    public var nudgeSessionID: String?
    public var claudeSessionID: String?
    public var cwd: String?
    public var state: AgentActivityState
    public var currentToolName: String?
    public var currentToolSummary: String?
    public var transcriptPath: String?
    public var lastEventName: String
    public var lastPromptPreview: String?
    public var lastMessage: String?
    public var lastError: String?
    public var updatedAt: Date

    public init(event: AgentHookEvent) {
        nudgeSessionID = event.nudgeSessionID
        claudeSessionID = event.claudeSessionID
        cwd = event.cwd
        state = Self.state(for: event)
        currentToolName = event.toolName
        currentToolSummary = event.toolSummary
        transcriptPath = event.transcriptPath
        lastEventName = event.eventName
        lastPromptPreview = event.promptPreview
        lastMessage = event.message
        lastError = event.error
        updatedAt = event.occurredAt
    }

    public mutating func apply(_ event: AgentHookEvent) {
        nudgeSessionID = event.nudgeSessionID ?? nudgeSessionID
        claudeSessionID = event.claudeSessionID ?? claudeSessionID
        cwd = event.cwd ?? cwd
        transcriptPath = event.transcriptPath ?? transcriptPath
        lastEventName = event.eventName
        lastPromptPreview = event.promptPreview ?? lastPromptPreview
        lastMessage = event.message ?? lastMessage
        lastError = event.error ?? lastError
        updatedAt = event.occurredAt

        switch event.eventName {
        case "PreToolUse":
            state = .usingTool
            currentToolName = event.toolName
            currentToolSummary = event.toolSummary
        case "PostToolUse":
            state = .thinking
            currentToolName = nil
            currentToolSummary = event.toolSummary
        case "UserPromptSubmit":
            state = .thinking
            currentToolName = nil
            currentToolSummary = nil
        case "Notification":
            state = Self.notificationState(message: event.message)
            if state != .usingTool {
                currentToolName = nil
                currentToolSummary = nil
            }
        case "Stop":
            state = .idle
            currentToolName = nil
            currentToolSummary = nil
        case "PostToolUseFailure", "StopFailure":
            state = .failed
            currentToolName = nil
            currentToolSummary = nil
        case "SessionEnd":
            state = .ended
            currentToolName = nil
            currentToolSummary = nil
        default:
            state = Self.state(for: event)
        }
    }

    private static func state(for event: AgentHookEvent) -> AgentActivityState {
        switch event.eventName {
        case "PreToolUse": return .usingTool
        case "PostToolUse", "UserPromptSubmit": return .thinking
        case "Notification": return Self.notificationState(message: event.message)
        case "Stop": return .idle
        case "PostToolUseFailure", "StopFailure": return .failed
        case "SessionEnd": return .ended
        default: return .unknown
        }
    }

    private static func notificationState(message: String?) -> AgentActivityState {
        let lowered = (message ?? "").lowercased()
        if lowered.contains("waiting") || lowered.contains("input") || lowered.contains("permission") {
            return .waitingForInput
        }
        return .thinking
    }
}

public actor AgentActivityStore {
    private var byKey: [String: AgentActivitySnapshot] = [:]

    public init() {}

    public func record(_ event: AgentHookEvent) {
        let key = key(for: event)
        if var snapshot = byKey[key] {
            snapshot.apply(event)
            byKey[key] = snapshot
        } else {
            byKey[key] = AgentActivitySnapshot(event: event)
        }
    }

    public func snapshots() -> [AgentActivitySnapshot] {
        Array(byKey.values)
    }

    private func key(for event: AgentHookEvent) -> String {
        if let id = event.nudgeSessionID, !id.isEmpty { return "nudge:\(id)" }
        if let id = event.claudeSessionID, !id.isEmpty { return "claude:\(id)" }
        if let cwd = event.cwd, !cwd.isEmpty { return "cwd:\(cwd)" }
        return "event:\(event.id)"
    }
}
