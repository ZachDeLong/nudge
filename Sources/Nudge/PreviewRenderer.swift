import AppKit
import SwiftUI
import NudgeCore

/// Offscreen renders of every popover state, for README screenshots and for
/// eyeballing UI changes without clicking through the real menu bar flow.
///
///     Nudge --render-previews <dir>      (or `make previews`)
///
/// Draws each state into a bitmap at 2x and exits. Nothing is shown on
/// screen, no server is started and the running Nudge is untouched. The
/// window backdrop (glass / vibrancy) has nothing behind it offscreen, so a
/// flat dark card is painted underneath — everything else is the real view.
@MainActor
enum PreviewRenderer {
    static let flag = "--render-previews"

    /// True while rendering. `PopoverBackground` reads this to swap the glass /
    /// vibrancy backdrop (which has nothing to sample offscreen and paints
    /// transparent) for a flat popover-coloured card.
    static private(set) var isRendering = false

    /// Returns the output directory when launched in preview mode.
    static func requestedDirectory(from args: [String] = CommandLine.arguments) -> URL? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    static func renderAll(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        isRendering = true
        defer { isRendering = false }
        for (name, view) in sampleStates() {
            let data = try render(view)
            try data.write(to: dir.appendingPathComponent("\(name).png"), options: .atomic)
        }
    }

    // MARK: - Rendering

    private static func render(_ view: PopoverView) throws -> Data {
        let hosting = NSHostingView(rootView: AnyView(
            view.clipShape(RoundedRectangle(cornerRadius: PopoverView.cornerRadius, style: .continuous))
        ))
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: PopoverView.width, height: 10))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        // A window (never ordered front) gives the hierarchy a backing store,
        // appearance and layout pass, which bare views do not get.
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            throw RenderError.contextUnavailable
        }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        // The bitmap context is in pixels; draw in points at 2x.
        ctx.cgContext.scaleBy(x: scale, y: scale)
        hosting.displayIgnoringOpacity(hosting.bounds, in: ctx)
        // Card colour goes *under* whatever the view drew, so nothing the
        // hierarchy paints (or clears) can knock it out.
        ctx.cgContext.setBlendMode(.destinationOver)
        NSBezierPath(
            roundedRect: hosting.bounds,
            xRadius: PopoverView.cornerRadius,
            yRadius: PopoverView.cornerRadius
        ).fill()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw RenderError.encodeFailed
        }
        return png
    }

    enum RenderError: Error {
        case contextUnavailable
        case encodeFailed
    }

    // MARK: - Sample states

    private static func sampleStates() -> [(String, PopoverView)] {
        let cwd = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/nudge").path
        let watching = Prefs(enabled: true, skipWhenTerminalFocused: true)
        let paused = Prefs(enabled: false, skipWhenTerminalFocused: true)

        let push = Prompt(
            id: "p1", tool: "Bash",
            command: "git push --force origin main",
            cwd: cwd, sessionId: "s", permissionMode: "default",
            matchedPattern: "Bash(git push:*)"
        )
        let rm = Prompt(
            id: "p2", tool: "Bash",
            command: "rm -rf node_modules .next && npm ci",
            cwd: cwd, sessionId: "s", permissionMode: "default",
            matchedPattern: "Bash(rm:*)"
        )
        let edit = Prompt(
            id: "p3", tool: "Edit",
            command: "\(cwd)/.env.local",
            cwd: cwd, sessionId: "s", permissionMode: "default",
            matchedPattern: "Edit(**/.env*)"
        )
        let forceInfix = Prompt(
            id: "p4", tool: "Bash",
            command: "git rebase -i --force main",
            cwd: cwd, sessionId: "s", permissionMode: "default",
            matchedPattern: "Bash(*--force*)"
        )
        let codexBash = Prompt(
            id: "c1", tool: "Bash",
            command: "npm install --save-dev vitest",
            cwd: cwd, sessionId: "s", permissionMode: "default",
            agent: "codex",
            detail: "Install vitest so the new tests can run?"
        )
        let codexPatch = Prompt(
            id: "c2", tool: "apply_patch",
            command: """
            *** Begin Patch
            *** Update File: Sources/Nudge/PromptStore.swift
            @@
            -    case withdrawn
            +    case withdrawn(agent: String)
            *** Update File: Sources/Nudge/MenuBarController.swift
            @@
            -            showNotice(.withdrawn)
            +            showNotice(.withdrawn(agent: shown.agentName))
            *** End Patch
            """,
            cwd: cwd, sessionId: "s", permissionMode: "default",
            agent: "codex"
        )
        let claudeRequest = Prompt(
            id: "r1", tool: "Bash",
            command: "mkdir -p build/previews",
            cwd: cwd, sessionId: "s", permissionMode: "default",
            agent: "claude",
            detail: "Create the previews output directory"
        )
        let ask = Prompt(
            id: "a1", kind: .ask, tool: "Ask",
            command: "Two migrations touch the users table. Apply them in one transaction, or split them so the second can be rolled back on its own?",
            cwd: cwd, sessionId: "s"
        )

        let emptyChat = AgentChatStore()

        let chat = AgentChatStore()
        let session = AgentSessionSummary(
            id: "sess-1", kind: .claude, title: "claude",
            cwd: cwd, tmuxSession: "nudge-1",
            createdAt: Date(timeIntervalSinceNow: -1500),
            isAttached: true
        )
        chat.sessions = [session]
        chat.detail = AgentSessionDetail(summary: session, transcript: """
        > tighten the popover animation and respect Reduce Motion

        ● I'll read PromptPanel.show() first, then gate the overshoot on
          NSWorkspace.accessibilityDisplayShouldReduceMotion.

        ● Read(Sources/Nudge/MenuBarController.swift)
          ⎿ Read 120 lines

        ● Update(Sources/Nudge/MenuBarController.swift)
          ⎿ Updated 2 hunks

        ● Building… swift build -c release
        """)
        chat.activities = [AgentActivitySnapshot(event: AgentHookEvent(
            nudgeSessionID: "sess-1", claudeSessionID: "c1",
            eventName: "PreToolUse", cwd: cwd, transcriptPath: nil,
            permissionMode: "default", toolName: "Bash",
            toolSummary: "swift build -c release",
            promptPreview: nil, message: nil, error: nil
        ))]

        func make(
            _ prompt: Prompt?, depth: Int, prefs: Prefs, store: AgentChatStore,
            notice: DecisionNotice? = nil, globalKeys: Bool = true
        ) -> PopoverView {
            let state = PromptStore()
            state.prompt = prompt
            state.queueDepth = depth
            state.prefs = prefs
            state.notice = notice
            state.globalKeysAvailable = globalKeys
            return PopoverView(
                state: state,
                onAllow: {}, onDeny: {}, onAlwaysAllow: {}, onSessionAllow: {},
                onSubmitText: { _ in }, onCancelAsk: {},
                onTogglePause: {}, onToggleSkipTerminal: {}, onQuit: {},
                onEnableGlobalKeys: {},
                agentChat: store,
                onRefreshAgentSessions: {}, onSelectAgentSession: { _ in },
                onSendAgentMessage: { _, _ in }, onEndAgentSession: { _ in },
                onRenameAgentSession: { _, _ in }
            )
        }

        return [
            ("permission-bash",    make(push,       depth: 1, prefs: watching, store: emptyChat)),
            ("permission-queued",  make(rm,         depth: 3, prefs: watching, store: emptyChat)),
            ("permission-edit",    make(edit,       depth: 1, prefs: watching, store: emptyChat)),
            ("permission-infix",   make(forceInfix, depth: 1, prefs: watching, store: emptyChat)),
            ("permission-allowed", make(push,       depth: 1, prefs: watching, store: emptyChat, notice: .allowed)),
            ("permission-withdrawn", make(rm,       depth: 1, prefs: watching, store: emptyChat, notice: .withdrawn(agent: "Claude"))),
            ("codex-command",      make(codexBash,  depth: 1, prefs: watching, store: emptyChat)),
            ("codex-patch",        make(codexPatch, depth: 1, prefs: watching, store: emptyChat)),
            ("claude-request",     make(claudeRequest, depth: 1, prefs: watching, store: emptyChat)),
            ("permission-no-keys", make(push,       depth: 1, prefs: watching, store: emptyChat, globalKeys: false)),
            ("ask",                make(ask,        depth: 1, prefs: watching, store: emptyChat)),
            ("idle-watching",      make(nil,        depth: 0, prefs: watching, store: emptyChat)),
            ("idle-no-keys",       make(nil,        depth: 0, prefs: watching, store: emptyChat, globalKeys: false)),
            ("idle-paused",        make(nil,        depth: 0, prefs: paused,   store: emptyChat)),
            ("idle-chat",          make(nil,        depth: 0, prefs: watching, store: chat)),
        ]
    }
}
