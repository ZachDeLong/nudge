import SwiftUI
import NudgeCore

/// SwiftUI source-of-truth for the prompt side of the popover. Holding it in an
/// ObservableObject (like `AgentChatStore`) lets the controller change state
/// inside `withAnimation`, so SwiftUI transitions run between prompts instead
/// of the whole root view being torn down and rebuilt.
@MainActor
final class PromptStore: ObservableObject {
    @Published var prompt: Prompt?
    @Published var queueDepth: Int = 0
    @Published var prefs: Prefs = .load()
    /// Short-lived acknowledgement shown in place of the buttons right after a
    /// decision, before the panel moves on. Nil = buttons.
    @Published var notice: DecisionNotice?
}

enum DecisionNotice: Equatable {
    case allowed
    case denied
    case sent

    var label: String {
        switch self {
        case .allowed: return "Allowed"
        case .denied:  return "Denied"
        case .sent:    return "Sent"
        }
    }

    var symbol: String {
        switch self {
        case .allowed: return "checkmark.circle.fill"
        case .denied:  return "xmark.circle.fill"
        case .sent:    return "paperplane.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .allowed: return .green
        case .denied:  return .secondary
        case .sent:    return .accentColor
        }
    }
}
