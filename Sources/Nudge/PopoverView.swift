import SwiftUI
import AppKit

struct PopoverView: View {
    let prompt: Prompt?
    let queueDepth: Int
    let onAllow: () -> Void
    let onDeny: () -> Void

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

        Text(prompt.command)
            .font(.system(size: 12, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.black.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 14)
            .textSelection(.enabled)

        HStack(spacing: 8) {
            Button(action: onDeny) { Text("Deny").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)

            Button(action: onAllow) { Text("Allow").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
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
