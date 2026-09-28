import Foundation

public enum PromptKind: String, Codable, Equatable {
    case permission
    case ask
    /// The agent finished its turn while you were away from its terminal.
    /// Shows its last message; a reply keeps the session going.
    case finished
    /// Claude's multiple-choice questions (its AskUserQuestion tool). The
    /// answers go back through the PermissionRequest hook.
    case question
}

/// One of Claude's AskUserQuestion questions: 2–4 options, single or
/// multiple choice. Claude's own dialog also takes free text ("Other").
public struct AskQuestion: Codable, Equatable {
    public struct Option: Codable, Equatable {
        public let label: String
        public let description: String?

        public init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }

    public let question: String
    /// A short tag Claude gives the question ("Auth method").
    public let header: String?
    public let options: [Option]
    public let multiSelect: Bool

    public init(question: String, header: String? = nil, options: [Option], multiSelect: Bool = false) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }

    /// The questions in an AskUserQuestion `tool_input`, or nil if it isn't
    /// shaped the way Nudge knows how to answer (Claude then asks itself).
    public static func parse(toolInput: [String: Any]) -> [AskQuestion]? {
        guard let raw = toolInput["questions"] as? [[String: Any]], !raw.isEmpty else { return nil }
        var questions: [AskQuestion] = []
        for q in raw {
            guard let text = q["question"] as? String, !text.isEmpty,
                  let rawOptions = q["options"] as? [[String: Any]] else { return nil }
            let options = rawOptions.compactMap { o in
                (o["label"] as? String).map { Option(label: $0, description: o["description"] as? String) }
            }
            guard !options.isEmpty, options.count == rawOptions.count else { return nil }
            questions.append(AskQuestion(question: text, header: q["header"] as? String, options: options,
                                         multiSelect: q["multiSelect"] as? Bool ?? false))
        }
        // Answers are keyed by question text, so two identical ones can't
        // both be answered.
        guard Set(questions.map(\.question)).count == questions.count else { return nil }
        return questions
    }

    /// The answer as Claude's own dialog records it: the chosen labels joined
    /// with ", " (option order), then any text typed under Other. Nil when
    /// nothing is chosen, or a single-choice question has both.
    public func answer(chosen: Set<String>, other: String) -> String? {
        let typed = other.trimmingCharacters(in: .whitespacesAndNewlines)
        let labels = options.map(\.label).filter(chosen.contains)
        if !multiSelect, labels.count + (typed.isEmpty ? 0 : 1) != 1 { return nil }
        let parts = labels + (typed.isEmpty ? [] : [typed])
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
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
    /// `CLAUDE_CODE_ENTRYPOINT` of the session: "cli" in a terminal,
    /// "claude-desktop" in the Claude app. Tells the app which window shows
    /// this session.
    public let entrypoint: String?
    /// For `.question`: what Claude asked, in order.
    public let questions: [AskQuestion]?

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
        subagentId: String? = nil,
        entrypoint: String? = nil,
        questions: [AskQuestion]? = nil
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
        self.entrypoint = entrypoint
        self.questions = questions
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
    /// Answers to a `.question` prompt, in `answers`.
    case answer
}

public struct DecisionResponse: Codable, Equatable {
    public let decision: Decision
    /// Present when `decision == .text`.
    public let text: String?
    /// Present when `decision == .answer`: question text → answer.
    public let answers: [String: String]?

    public init(decision: Decision, text: String? = nil, answers: [String: String]? = nil) {
        self.decision = decision
        self.text = text
        self.answers = answers
    }
}
