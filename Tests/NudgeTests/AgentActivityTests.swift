import XCTest
@testable import NudgeCore

final class AgentActivityTests: XCTestCase {
    func testActivityStoreTracksToolThenIdleForNudgeSession() async {
        let store = AgentActivityStore()

        await store.record(AgentHookEvent(
            nudgeSessionID: "claude-1",
            claudeSessionID: "abc",
            eventName: "PreToolUse",
            cwd: "/tmp/project",
            transcriptPath: "/tmp/transcript.jsonl",
            permissionMode: "default",
            toolName: "Edit",
            toolSummary: "/tmp/project/App.swift",
            promptPreview: nil,
            message: nil,
            error: nil
        ))
        await store.record(AgentHookEvent(
            nudgeSessionID: "claude-1",
            claudeSessionID: "abc",
            eventName: "Stop",
            cwd: "/tmp/project",
            transcriptPath: "/tmp/transcript.jsonl",
            permissionMode: "default",
            toolName: nil,
            toolSummary: nil,
            promptPreview: nil,
            message: nil,
            error: nil
        ))

        let snapshots = await store.snapshots()

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.nudgeSessionID, "claude-1")
        XCTAssertEqual(snapshots.first?.state, .idle)
        XCTAssertNil(snapshots.first?.currentToolName)
        XCTAssertEqual(snapshots.first?.transcriptPath, "/tmp/transcript.jsonl")
    }

    func testNotificationWaitingState() {
        let event = AgentHookEvent(
            nudgeSessionID: "claude-1",
            claudeSessionID: "abc",
            eventName: "Notification",
            cwd: "/tmp/project",
            transcriptPath: nil,
            permissionMode: nil,
            toolName: nil,
            toolSummary: nil,
            promptPreview: nil,
            message: "Claude is waiting for your input",
            error: nil
        )

        let snapshot = AgentActivitySnapshot(event: event)

        XCTAssertEqual(snapshot.state, .waitingForInput)
    }
}
