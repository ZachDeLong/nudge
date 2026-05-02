import SwiftUI
import AppKit
import NudgeCore

struct PopoverView: View {
    let prompt: Prompt?
    let queueDepth: Int
    let prefs: Prefs
    let onAllow: () -> Void
    let onDeny: () -> Void
    let onAlwaysAllow: () -> Void
    let onSessionAllow: () -> Void
    let onSubmitText: (String) -> Void
    let onCancelAsk: () -> Void
    let onTogglePause: () -> Void
    let onToggleSkipTerminal: () -> Void
    let onQuit: () -> Void
    @ObservedObject var agentChat: AgentChatStore
    let onRefreshAgentSessions: () -> Void
    let onSelectAgentSession: (String) -> Void
    let onSendAgentMessage: (String, String) -> Void
    let onEndAgentSession: (String) -> Void
    let onRenameAgentSession: (String, String?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let prompt = prompt {
                content(for: prompt)
            } else {
                idle()
            }
        }
        .padding(16)
        .frame(width: 420)
        .background(VisualEffectBackground())
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
        header(prompt: prompt, title: "Permission request")

        let trimmed = prompt.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCommand = !trimmed.isEmpty

        if hasCommand {
            commandBox(for: prompt)
                .padding(.bottom, 12)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle")
                    .foregroundColor(.secondary)
                Text("\(prompt.tool) operation in \(URL(fileURLWithPath: prompt.cwd).lastPathComponent)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.bottom, 12)
        }

        let offerOptions = hasCommand && isPromotablePattern(prompt.matchedPattern)

        HStack(spacing: 8) {
            Button(action: onDeny) {
                Text("Deny")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)

            Button(action: onAllow) {
                Text("Allow")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            if offerOptions {
                Menu {
                    Button("Allow for this session", action: onSessionAllow)
                    Button("Always allow this command", action: onAlwaysAllow)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(width: 40)
                .help("More options")
            }
        }
    }

    // MARK: - Ask flow

    @ViewBuilder
    private func askContent(for prompt: Prompt) -> some View {
        header(prompt: prompt, title: "Claude is asking")
        AskBody(question: prompt.command, onSubmit: onSubmitText, onCancel: onCancelAsk)
    }

    // MARK: - Shared header

    @ViewBuilder
    private func header(prompt: Prompt, title: String) -> some View {
        HStack(spacing: 11) {
            ToolBadge(tool: prompt.tool)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(prompt.tool) · \(URL(fileURLWithPath: prompt.cwd).lastPathComponent)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            if queueDepth > 1 {
                Text("\(queueDepth - 1) queued")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08))
                    .foregroundColor(.secondary)
                    .clipShape(Capsule())
            }
        }
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func commandBox(for prompt: Prompt) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            Group {
                if prompt.tool == "Bash" {
                    Text(highlight(command: prompt.command))
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
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func isPromotablePattern(_ pattern: String?) -> Bool {
        guard let p = pattern, p.hasPrefix("Bash("), p.hasSuffix(")") else {
            // Path-based patterns (Edit/Write/Read/...) are always promotable.
            if let p = pattern,
               (p.hasPrefix("Edit(") || p.hasPrefix("Write(") || p.hasPrefix("Read(")
                || p.hasPrefix("MultiEdit(") || p.hasPrefix("NotebookEdit(")) {
                return true
            }
            // Mcp() patterns are only promotable when they're exact (no `*`),
            // because Claude Code's permissions.allow can't express MCP globs
            // beyond `mcp__server` (whole server) or `mcp__server__tool` (one).
            if let p = pattern, p.hasPrefix("Mcp("), p.hasSuffix(")") {
                let inner = String(p.dropFirst(4).dropLast())
                return !inner.contains("*")
            }
            return false
        }
        let inner = String(p.dropFirst(5).dropLast())
        if inner.hasPrefix("*") && inner.hasSuffix("*") { return false }
        return true
    }

    private func highlight(command: String) -> AttributedString {
        var result = AttributedString()
        let tokens = command.split(separator: " ", omittingEmptySubsequences: false)
        let isPush = command.contains("git push")
        let isReset = command.contains("git reset") || command.contains("git rebase")

        let alwaysDangerous: Set<String> = [
            "--force", "-f", "-rf", "-fr", "-Rf", "-fR", "--hard",
            "--no-verify", "--force-with-lease",
        ]
        let dangerousBranches: Set<String> = ["main", "master", "production", "prod", "release"]

        for (i, raw) in tokens.enumerated() {
            let token = String(raw)
            var attr = AttributedString(token)

            let isFlag = alwaysDangerous.contains(token) || token.hasPrefix("-rf") || token.hasPrefix("-fr")
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

    @ViewBuilder
    private func idle() -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Status row: brand badge + state pill
            HStack(spacing: 11) {
                ToolBadge(tool: "Bash") // generic Nudge badge
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nudge")
                        .font(.system(size: 13, weight: .semibold))
                    Text(prefs.enabled ? "Watching for permission requests" : "Paused")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
                StatusDot(active: prefs.enabled)
            }

            // Pause / Resume — primary action.
            Button(action: onTogglePause) {
                Text(prefs.enabled ? "Pause Nudge" : "Resume Nudge")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            // Settings toggle — checkbox-style row.
            Toggle(isOn: Binding(
                get: { prefs.skipWhenTerminalFocused },
                set: { _ in onToggleSkipTerminal() }
            )) {
                Text("Skip when terminal is focused")
                    .font(.system(size: 12))
            }
            .toggleStyle(.checkbox)

            Divider()

            AgentSessionsPanel(
                store: agentChat,
                onRefresh: onRefreshAgentSessions,
                onSelect: onSelectAgentSession,
                onSend: onSendAgentMessage,
                onEndSession: onEndAgentSession,
                onRenameSession: onRenameAgentSession
            )

            HStack {
                Spacer()
                Button(action: onQuit) {
                    Text("Quit Nudge")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
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
        let label = "\(session.kind.rawValue) - \(session.projectName) - \(time)"
        return session.isEnded ? "\(label) - ended" : label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundColor(.secondary)
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
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .foregroundColor(.secondary)
                    Text("No mirrored sessions")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.vertical, 2)
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
                        endedSessionNotice()
                    } else {
                        messageComposer(for: detail)
                    }
                }
            }

            if let error = store.error, !error.isEmpty {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
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
                .foregroundColor(.secondary)
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
    private func endedSessionNotice() -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .foregroundColor(.secondary)
            Text("Session ended")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                .clipShape(RoundedRectangle(cornerRadius: 8))
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
        ScrollView(.vertical, showsIndicators: true) {
            Text(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No output yet." : transcript)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .frame(maxHeight: 180)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                .foregroundColor(.secondary)
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
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @State private var text: String = ""
    @FocusState private var focused: Bool

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
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Answer field — TextField with vertical axis gives a multi-line
            // input with consistent padding (TextEditor adds its own and
            // misaligns with placeholder).
            TextField("Type your answer…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(3...8)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .focused($focused)

            // Buttons
            HStack(spacing: 8) {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)

                Button(action: submit) {
                    Text("Send")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

private struct StatusDot: View {
    let active: Bool
    var body: some View {
        Circle()
            .fill(active ? Color.green : Color.secondary.opacity(0.5))
            .frame(width: 8, height: 8)
    }
}

private struct ToolBadge: View {
    let tool: String

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(red: 1.0, green: 0.42, blue: 0.21),
                         Color(red: 0.81, green: 0.32, blue: 0.17)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
            .frame(width: 32, height: 32)
            .overlay(
                Image(systemName: symbol(for: tool))
                    .foregroundColor(.white)
                    .font(.system(size: 14, weight: .semibold))
            )
    }

    private func symbol(for tool: String) -> String {
        switch tool {
        case "Bash":            return "terminal.fill"
        case "Edit", "Write":   return "pencil"
        case "Read":            return "eye.fill"
        case "Glob", "Grep":    return "magnifyingglass"
        case "Ask":             return "bubble.left.fill"
        default:                return "sparkles"
        }
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
