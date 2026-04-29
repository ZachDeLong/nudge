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
        .frame(width: 380)
        .padding(16)
        .background(VisualEffectBackground())
    }

    @ViewBuilder
    private func content(for prompt: Prompt) -> some View {
        HStack(spacing: 10) {
            ClaudeBadge()
            VStack(alignment: .leading, spacing: 1) {
                Text("Permission request")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(prompt.tool) · \(URL(fileURLWithPath: prompt.cwd).lastPathComponent)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if queueDepth > 1 {
                Text("\(queueDepth - 1) more queued")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.12))
                    .foregroundColor(.orange)
                    .clipShape(Capsule())
            }
        }
        .padding(.bottom, 12)

        commandBox(for: prompt.command)
            .padding(.bottom, 14)

        HStack(spacing: 8) {
            Button(action: onDeny) { Text("Deny").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)

            Menu {
                Button("Always allow this command", action: onAlwaysAllow)
                Button("Allow for this session", action: onSessionAllow)
            } label: {
                Text("Allow")
                    .frame(maxWidth: .infinity)
            } primaryAction: {
                onAllow()
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }

    /// Renders the command with destructive tokens highlighted in red.
    @ViewBuilder
    private func commandBox(for command: String) -> some View {
        Text(highlight(command: command))
            .font(.system(size: 12, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.black.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .textSelection(.enabled)
    }

    /// Token-by-token highlighter. Marks --force, --hard, -rf etc. as destructive,
    /// and main/master branches when the command is a push.
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

private struct ClaudeBadge: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(LinearGradient(colors: [Color(red: 1.0, green: 0.42, blue: 0.21),
                                         Color(red: 0.81, green: 0.32, blue: 0.17)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 32, height: 32)
            .overlay(Text("✦").foregroundColor(.white).font(.system(size: 14, weight: .bold)))
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
