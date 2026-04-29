import SwiftUI
import AppKit

struct PopoverView: View {
    let prompt: Prompt?
    let queueDepth: Int
    let onAllow: () -> Void
    let onDeny: () -> Void
    let onAlwaysAllow: () -> Void
    let onSessionAllow: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let prompt = prompt {
                content(for: prompt)
            } else {
                idle()
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(VisualEffectBackground())
    }

    @ViewBuilder
    private func content(for prompt: Prompt) -> some View {
        HStack(spacing: 11) {
            ToolBadge(tool: prompt.tool)
            VStack(alignment: .leading, spacing: 2) {
                Text("Permission request")
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

        let trimmed = prompt.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCommand = !trimmed.isEmpty

        if hasCommand {
            commandBox(for: prompt.command)
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

        // Show the always/session menu whenever there's a real command to act
        // on. We can't reliably mirror Claude's "always allow" availability
        // (it depends on Claude's internal pattern classifier), so the
        // semantics here are simply "stop having Nudge prompt about this".
        let offerAlways = hasCommand

        HStack(spacing: 8) {
            Button(action: onDeny) {
                Text("Deny")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)

            if offerAlways {
                Menu {
                    Button("Allow for this session", action: onSessionAllow)
                    Button("Always allow this command", action: onAlwaysAllow)
                } label: {
                    Text("Allow")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                } primaryAction: {
                    onAllow()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            } else {
                Button(action: onAllow) {
                    Text("Allow")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private func commandBox(for command: String) -> some View {
        Text(highlight(command: command))
            .font(.system(size: 12, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .textSelection(.enabled)
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
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("Nudge is ready")
                .font(.system(size: 13, weight: .medium))
            Text("Waiting for permission requests…")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 24)
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
