import AppKit
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
    /// Whether global ⏎/esc can reach Nudge. They need Accessibility access;
    /// without it the keycaps would advertise shortcuts that do nothing.
    @Published var globalKeysAvailable: Bool = GlobalKeys.isAvailable
}

/// Global key monitoring (⏎ allows, esc denies from any app) only receives
/// events once the user has trusted Nudge under Privacy & Security →
/// Accessibility.
enum GlobalKeys {
    static var isAvailable: Bool { AXIsProcessTrusted() }

    /// Registers Nudge in the Accessibility list (showing the system prompt
    /// the first time) and opens the pane so the switch is one click away.
    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum DecisionNotice: Equatable {
    case allowed
    case denied
    case sent
    /// The prompt left the queue without an answer from here: the agent
    /// (named here) was interrupted, or the request timed out.
    case withdrawn(agent: String)

    var label: String {
        switch self {
        case .allowed:   return "Allowed"
        case .denied:    return "Denied"
        case .sent:      return "Sent"
        case .withdrawn(let agent): return "\(agent) stopped waiting"
        }
    }

    var symbol: String {
        switch self {
        case .allowed:   return "checkmark.circle.fill"
        case .denied:    return "xmark.circle.fill"
        case .sent:      return "paperplane.circle.fill"
        case .withdrawn: return "arrow.uturn.backward.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .allowed:   return .green
        case .denied:    return .secondary
        case .sent:      return .accentColor
        case .withdrawn: return .secondary
        }
    }

    /// How long the notice holds the panel. Our own decisions just need a
    /// beat to register; a withdrawal is unexpected, so it gets time to read.
    var holdDuration: TimeInterval {
        if case .withdrawn = self { return 1.2 }
        return 0.52
    }
}
