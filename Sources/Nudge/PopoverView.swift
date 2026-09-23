import SwiftUI
import AppKit
import NudgeCore

struct PopoverView: View {
    @ObservedObject var state: PromptStore
    let onAllow: () -> Void
    let onDeny: () -> Void
    let onAlwaysAllow: () -> Void
    let onSessionAllow: () -> Void
    let onSubmitText: (String) -> Void
    let onCancelAsk: () -> Void
    let onTogglePause: () -> Void
    let onToggleSkipTerminal: () -> Void
    let onQuit: () -> Void
    let onEnableGlobalKeys: () -> Void
    @ObservedObject var agentChat: AgentChatStore
    let onRefreshAgentSessions: () -> Void
    let onSelectAgentSession: (String) -> Void
    let onSendAgentMessage: (String, String) -> Void
    let onEndAgentSession: (String) -> Void
    let onRenameAgentSession: (String, String?) -> Void

    static let width: CGFloat = 420
    static let cornerRadius: CGFloat = 14

    /// Cross-fade with a hair of scale, the way Control Center swaps content.
    /// Old and new overlap in a ZStack so nothing stacks or jumps mid-fade.
    static let switchTransition: AnyTransition = .opacity.combined(with: .scale(scale: 0.985))

    var body: some View {
        ZStack(alignment: .top) {
            if let prompt = state.prompt {
                VStack(spacing: 0) { content(for: prompt) }
                    .id(prompt.id)
                    .transition(Self.switchTransition)
            } else {
                VStack(spacing: 0) { idle() }
                    .transition(Self.switchTransition)
            }
        }
        .padding(16)
        .frame(width: Self.width)
        .background(PopoverBackground(cornerRadius: Self.cornerRadius))
    }

    @ViewBuilder
    private func content(for prompt: Prompt) -> some View {
        switch prompt.resolvedKind {
        case .permission:
            permissionContent(for: prompt)
        case .ask:
            askContent(for: prompt)
        }
    }

    // MARK: - Permission flow

    @ViewBuilder
    private func permissionContent(for prompt: Prompt) -> some View {
        header(prompt: prompt, title: PromptCopy.title(for: prompt))

        let trimmed = prompt.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCommand = !trimmed.isEmpty

        if hasCommand {
            commandBox(for: prompt)
        } else {
            InfoRow(
                symbol: "questionmark.circle",
                text: "\(prompt.tool) operation in \(PromptCopy.projectName(prompt))"
            )
        }

        if let pattern = prompt.matchedPattern, !pattern.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: "scope")
                    .font(.system(size: 10, weight: .medium))
                (Text("Matched ")
                    .font(.system(size: 10.5))
                + Text(pattern)
                    .font(.system(size: 10.5, design: .monospaced)))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.top, 8)
            .help("The pattern in ~/.config/nudge/patterns.txt that routed this prompt to Nudge")
        }

        let offerOptions = hasCommand && Promotion.isPromotable(prompt.matchedPattern)

        ZStack {
          if let notice = state.notice {
            NoticeRow(notice: notice)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
          } else {
          HStack(spacing: 8) {
            // Permission panels never take key, so the keycaps are only
            // true when the global monitor can hear them.
            let keys = state.globalKeysAvailable
            Button(action: onDeny) {
                ButtonLabel(title: "Deny", key: keys ? "esc" : nil)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)

            Button(action: onAllow) {
                ButtonLabel(title: "Allow", key: keys ? "⏎" : nil, weight: .semibold, prominent: true)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            if offerOptions {
                Menu {
                    Button("Allow for this session", action: onSessionAllow)
                    Button("Always allow \(Promotion.menuLabel(for: prompt))", action: onAlwaysAllow)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(width: 40)
                .help("Allow for this session, or always")
            }
          }
          .transition(.opacity)
          }
        }
        .padding(.top, 12)
    }

    // MARK: - Ask flow

    @ViewBuilder
    private func askContent(for prompt: Prompt) -> some View {
        header(prompt: prompt, title: "Claude is asking")
        AskBody(question: prompt.command, notice: state.notice, onSubmit: onSubmitText, onCancel: onCancelAsk)
    }

    // MARK: - Shared header

    @ViewBuilder
    private func header(prompt: Prompt, title: String) -> some View {
        HStack(spacing: 11) {
            ToolBadge(tool: prompt.tool)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(prompt.tool) · \(PromptCopy.projectName(prompt))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if state.queueDepth > 1 {
                QueuePill(waiting: state.queueDepth - 1)
            }
        }
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func commandBox(for prompt: Prompt) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            Group {
                if prompt.tool == "Bash" {
                    Text(CommandHighlighter.highlight(prompt.command))
                } else {
                    Text(prompt.command)
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .textSelection(.enabled)
        }
        .frame(maxHeight: 140)
        .fixedSize(horizontal: false, vertical: false)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Idle

    private static let appVersion: String? =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    @ViewBuilder
    private func idle() -> some View {
        let prefs = state.prefs
        VStack(alignment: .leading, spacing: 14) {
            // Status row — brand badge, state, master switch. Mirrors a Control
            // Center module header: the switch *is* the primary action.
            HStack(spacing: 11) {
                ToolBadge(tool: "Bash", dimmed: !prefs.enabled)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nudge")
                        .font(.system(size: 13, weight: .semibold))
                    Text(prefs.enabled
                         ? "Watching for permission requests"
                         : "Paused · prompts stay in the terminal")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("Nudge enabled", isOn: Binding(
                    get: { prefs.enabled },
                    set: { _ in onTogglePause() }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(prefs.enabled ? "Pause Nudge" : "Resume Nudge")
            }

            SettingRow(
                symbol: "macwindow",
                title: "Skip when terminal is focused",
                detail: "Stay quiet while a terminal or IDE is in front",
                isOn: Binding(
                    get: { prefs.skipWhenTerminalFocused },
                    set: { _ in onToggleSkipTerminal() }
                )
            )

            if !state.globalKeysAvailable {
                HStack(spacing: 10) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Answer with ⏎ and esc from any app")
                            .font(.system(size: 12))
                        Text("Needs Accessibility access")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Enable…", action: onEnableGlobalKeys)
                        .controlSize(.small)
                }
                .transition(.opacity)
            }

            Divider()

            AgentSessionsPanel(
                store: agentChat,
                onRefresh: onRefreshAgentSessions,
                onSelect: onSelectAgentSession,
                onSend: onSendAgentMessage,
                onEndSession: onEndAgentSession,
                onRenameSession: onRenameAgentSession
            )

            Divider()

            HStack(alignment: .firstTextBaseline) {
                if let version = Self.appVersion {
                    Text("Nudge \(version)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button(action: onQuit) {
                    Text("Quit Nudge")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Copy

/// User-facing strings derived from a prompt. Titles follow the macOS
/// permission-alert idiom ("“Safari” would like to…") so the popover reads
/// like the OS asking, not like a log line.
enum PromptCopy {
    static func title(for prompt: Prompt) -> String {
        switch prompt.tool {
        case "Bash":
            return "Claude wants to run a command"
        case "Edit", "MultiEdit", "NotebookEdit":
            return "Claude wants to edit a file"
        case "Write":
            return "Claude wants to write a file"
        case "Read":
            return "Claude wants to read a file"
        case "WebFetch", "WebSearch":
            return "Claude wants to reach the web"
        case let tool where tool.hasPrefix("mcp__"):
            return "Claude wants to use an MCP tool"
        default:
            return "Claude wants to use \(prompt.tool)"
        }
    }

    static func projectName(_ prompt: Prompt) -> String {
        let name = URL(fileURLWithPath: prompt.cwd).lastPathComponent
        return name.isEmpty ? prompt.cwd : name
    }
}

/// Paints the dangerous parts of a shell command red: force flags, hard
/// resets, and protected branch names on push/reset/rebase.
enum CommandHighlighter {
    private static let alwaysDangerous: Set<String> = [
        "--force", "-f", "-rf", "-fr", "-Rf", "-fR", "--hard",
        "--no-verify", "--force-with-lease",
    ]
    private static let dangerousBranches: Set<String> = [
        "main", "master", "production", "prod", "release",
    ]

    static func highlight(_ command: String) -> AttributedString {
        var result = AttributedString()
        let tokens = command.split(separator: " ", omittingEmptySubsequences: false)
        let isPush = command.contains("git push")
        let isReset = command.contains("git reset") || command.contains("git rebase")

        for (i, raw) in tokens.enumerated() {
            let token = String(raw)
            var attr = AttributedString(token)

            let isFlag = alwaysDangerous.contains(token)
                || token.hasPrefix("-rf") || token.hasPrefix("-fr")
            let isDangerousBranch = (isPush || isReset) && dangerousBranches.contains(token)

            if isFlag || isDangerousBranch {
                attr.foregroundColor = .red
                attr.font = .system(size: 12, weight: .semibold, design: .monospaced)
            }
            result += attr
            if i < tokens.count - 1 {
                result += AttributedString(" ")
            }
        }
        return result
    }
}

// MARK: - Agent session mirror

private struct AgentSessionsPanel: View {
    @ObservedObject var store: AgentChatStore
    let onRefresh: () -> Void
    let onSelect: (String) -> Void
    let onSend: (String, String) -> Void
    let onEndSession: (String) -> Void
    let onRenameSession: (String, String?) -> Void

    @State private var draft: String = ""
    @State private var renameDraft: String = ""
    @State private var isRenaming: Bool = false
    @FocusState private var inputFocused: Bool
    @FocusState private var renameFocused: Bool

    private var selectedID: String {
        store.detail?.id ?? store.sessions.first?.id ?? ""
    }

    private static let sessionLabelTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private func sessionLabel(_ session: AgentSessionSummary) -> String {
        if let title = session.customTitle, !title.isEmpty {
            return title
        }
        let time = Self.sessionLabelTimeFormatter.string(from: session.createdAt)
        let label = "\(session.kind.rawValue) · \(session.projectName) · \(time)"
        return session.isEnded ? "\(label) · ended" : label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(.secondary)
                Text("Agent sessions")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if let detail = store.detail {
                    Button(action: { beginRename(detail) }) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("Rename this session")
                    .popover(isPresented: $isRenaming, arrowEdge: .top) {
                        renamePopoverBody(for: detail)
                    }
                    Button(action: { onEndSession(detail.id) }) {
                        Image(systemName: "stop.circle")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("End this session (kills the tmux pane)")
                }
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Refresh sessions")
            }

            if store.sessions.isEmpty {
                InfoRow(symbol: "terminal", text: "No mirrored sessions · start one with nudge-claude")
            } else {
                Picker("Session", selection: Binding(
                    get: { selectedID },
                    set: { onSelect($0) }
                )) {
                    ForEach(store.sessions) { session in
                        Text(sessionLabel(session))
                            .tag(session.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                if let detail = store.detail {
                    if let activity = activity(for: detail.summary) {
                        activityRow(activity)
                    }
                    transcriptView(detail.transcript)

                    if detail.summary.isEnded {
                        InfoRow(symbol: "exclamationmark.circle", text: "Session ended", boxed: true)
                    } else {
                        messageComposer(for: detail)
                    }
                }
            }

            if let error = store.error, !error.isEmpty {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func activity(for session: AgentSessionSummary) -> AgentActivitySnapshot? {
        if let activity = store.activities.first(where: { $0.nudgeSessionID == session.id }) {
            return activity
        }

        // Recovery path for manually wired/older hooks that did not inherit
        // NUDGE_AGENT_SESSION_ID. Only use cwd when it is unambiguous.
        let sameCwdSessions = store.sessions.filter { $0.cwd == session.cwd }
        guard sameCwdSessions.count == 1 else { return nil }

        let sameCwdActivities = store.activities.filter {
            ($0.nudgeSessionID ?? "").isEmpty && $0.cwd == session.cwd
        }
        return sameCwdActivities.count == 1 ? sameCwdActivities[0] : nil
    }

    @ViewBuilder
    private func activityRow(_ activity: AgentActivitySnapshot) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(activityColor(activity.state))
                .frame(width: 7, height: 7)
            Text(activityText(activity))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
        }
    }

    private func activityText(_ activity: AgentActivitySnapshot) -> String {
        switch activity.state {
        case .usingTool:
            let name = activity.currentToolName ?? "Tool"
            if let summary = activity.currentToolSummary, !summary.isEmpty {
                return "\(name): \(summary)"
            }
            return "\(name) running"
        case .thinking:
            return "Thinking"
        case .waitingForInput:
            return "Waiting for input"
        case .idle:
            return "Idle"
        case .failed:
            return activity.lastError ?? "Failed"
        case .ended:
            return "Ended"
        case .unknown:
            return activity.lastEventName
        }
    }

    private func activityColor(_ state: AgentActivityState) -> Color {
        switch state {
        case .usingTool, .thinking:
            return .accentColor
        case .waitingForInput:
            return .orange
        case .failed:
            return .red
        case .idle, .ended, .unknown:
            return .secondary.opacity(0.7)
        }
    }

    @ViewBuilder
    private func messageComposer(for detail: AgentSessionDetail) -> some View {
        HStack(spacing: 8) {
            TextField("Message \(detail.summary.kind.rawValue)", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...4)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .focused($inputFocused)
                .onKeyPress(.return) {
                    if NSEvent.modifierFlags.contains(.shift) {
                        return .ignored
                    }
                    send()
                    return .handled
                }
                .help("Enter sends. Shift+Enter inserts a newline.")

            Button(action: send) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Send message")
        }
        .onAppear { inputFocused = true }
        .onChange(of: detail.id) { _, _ in inputFocused = true }
    }

    @ViewBuilder
    private func transcriptView(_ transcript: String) -> some View {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        ScrollView(.vertical, showsIndicators: true) {
            Text(text.isEmpty ? "No output yet." : transcript)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        // Chat semantics: newest output lives at the bottom, so that is where
        // the view rests — and stays as the mirror polls in fresh lines.
        .defaultScrollAnchor(.bottom)
        .frame(maxHeight: 180)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func send() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !selectedID.isEmpty else { return }
        draft = ""
        onSend(selectedID, trimmed)
    }

    private func beginRename(_ detail: AgentSessionDetail) {
        renameDraft = detail.summary.customTitle ?? sessionLabel(detail.summary)
        isRenaming = true
    }

    private func commitRename(_ id: String) {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        onRenameSession(id, trimmed.isEmpty ? nil : trimmed)
        isRenaming = false
    }

    private func cancelRename() {
        isRenaming = false
    }

    @ViewBuilder
    private func renamePopoverBody(for detail: AgentSessionDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rename session")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Session name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 240)
                .focused($renameFocused)
                .onAppear { renameFocused = true }
                .onSubmit { commitRename(detail.id) }
            HStack {
                Spacer()
                Button("Cancel") { cancelRename() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commitRename(detail.id) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }
}

// MARK: - Ask body (text input)

private struct AskBody: View {
    let question: String
    let notice: DecisionNotice?
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @State private var text: String = ""
    @FocusState private var focused: Bool

    private var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Question
            ScrollView(.vertical, showsIndicators: true) {
                Text(question)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 120)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Answer field — TextField with vertical axis gives a multi-line
            // input with consistent padding (TextEditor adds its own and
            // misaligns with placeholder). Enter sends; Shift+Enter breaks the
            // line, matching the chat composer below the fold.
            VStack(alignment: .trailing, spacing: 5) {
                TextField("Type your answer…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(3...8)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .focused($focused)
                    .onKeyPress(.return) {
                        if NSEvent.modifierFlags.contains(.shift) {
                            return .ignored
                        }
                        submit()
                        return .handled
                    }
                Text("⇧⏎ for a new line")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            // Buttons
            ZStack {
                if let notice {
                    NoticeRow(notice: notice)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else {
                    HStack(spacing: 8) {
                        Button(action: onCancel) {
                            ButtonLabel(title: "Cancel", key: "esc")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .keyboardShortcut(.cancelAction)

                        Button(action: submit) {
                            ButtonLabel(title: "Send", key: "⏎", weight: .semibold, prominent: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isEmpty)
                    }
                    .transition(.opacity)
                }
            }
        }
        .onAppear { focused = true }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
    }
}

// MARK: - Small parts

/// Stands in for the button row for a beat after a decision, so the click
/// visibly landed before the panel moves on. The symbol bounces once.
private struct NoticeRow: View {
    let notice: DecisionNotice
    @State private var bounced = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: notice.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(notice.tint)
                .symbolEffect(.bounce, options: .nonRepeating, value: bounced)
            Text(notice.label)
                .font(.system(size: 13, weight: .semibold))
        }
        .frame(maxWidth: .infinity, minHeight: 28)
        .onAppear { bounced = true }
    }
}

/// Button title with a keycap showing the shortcut that triggers it. The
/// permission shortcuts are *global* (they fire from whatever app is in
/// front), so making them visible matters more than it would in a dialog.
private struct ButtonLabel: View {
    let title: String
    let key: String?
    var weight: Font.Weight = .medium
    var prominent: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: weight))
            if let key {
                KeyCap(key, prominent: prominent)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct KeyCap: View {
    let label: String
    let prominent: Bool

    init(_ label: String, prominent: Bool = false) {
        self.label = label
        self.prominent = prominent
    }

    var body: some View {
        Text(label)
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .foregroundStyle(prominent ? Color.white.opacity(0.9) : Color.secondary)
            .padding(.horizontal, 4.5)
            .padding(.vertical, 1.5)
            .background(
                prominent ? Color.white.opacity(0.22) : Color.primary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
    }
}

private struct QueuePill: View {
    let waiting: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "tray.full")
                .font(.system(size: 9, weight: .semibold))
            Text("\(waiting) more")
                .font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Color.primary.opacity(0.08))
        .foregroundStyle(.secondary)
        .clipShape(Capsule())
        .help("\(waiting) more prompt\(waiting == 1 ? "" : "s") waiting behind this one")
    }
}

/// Label + description + switch, laid out like a System Settings row.
private struct SettingRow: View {
    let symbol: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12))
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// Icon + one line of secondary text. `boxed` gives it the same inset card
/// treatment as the command/transcript boxes.
private struct InfoRow: View {
    let symbol: String
    let text: String
    var boxed: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, boxed ? 10 : 0)
        .padding(.vertical, boxed ? 8 : 2)
        .background(boxed ? Color.primary.opacity(0.06) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ToolBadge: View {
    let tool: String
    var dimmed: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(fill)
            .frame(width: 32, height: 32)
            .overlay(
                Image(systemName: symbol(for: tool))
                    .foregroundStyle(.white)
                    .font(.system(size: 14, weight: .semibold))
            )
    }

    private var fill: LinearGradient {
        if dimmed {
            return LinearGradient(
                colors: [Color.gray.opacity(0.55), Color.gray.opacity(0.4)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [Color(red: 1.0, green: 0.42, blue: 0.21),
                     Color(red: 0.81, green: 0.32, blue: 0.17)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    private func symbol(for tool: String) -> String {
        switch tool {
        case "Bash":                                return "terminal.fill"
        case "Edit", "Write", "MultiEdit",
             "NotebookEdit":                        return "pencil"
        case "Read":                                return "eye.fill"
        case "Glob", "Grep":                        return "magnifyingglass"
        case "WebFetch", "WebSearch":               return "globe"
        case "Ask":                                 return "bubble.left.fill"
        case let t where t.hasPrefix("mcp__"):      return "puzzlepiece.extension.fill"
        default:                                    return "sparkles"
        }
    }
}

/// Liquid Glass on macOS 26, the classic popover material before that. Both
/// sample what is behind the window, so the panel reads as part of the menu
/// bar system rather than a floating card.
private struct PopoverBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSView {
        if PreviewRenderer.isRendering {
            let flat = NSView()
            flat.wantsLayer = true
            flat.layer?.backgroundColor = NSColor(calibratedRed: 0.14, green: 0.14, blue: 0.15, alpha: 1).cgColor
            return flat
        }
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            return glass
        }
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
