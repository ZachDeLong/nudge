import Foundation
import XCTest
@testable import NudgeCore

final class AgentActivityTests: XCTestCase {
    func testActivityStoreTracksToolThenIdleForNudgeSession() async {
        let store = AgentActivityStore()

        await store.record(event(
            "PreToolUse",
            toolName: "Edit",
            toolSummary: "/tmp/project/App.swift"
        ))
        await store.record(event("Stop", occurredAt: Date(timeIntervalSince1970: 2)))

        let snapshots = await store.snapshots()

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.nudgeSessionID, "claude-1")
        XCTAssertEqual(snapshots.first?.state, .idle)
        XCTAssertNil(snapshots.first?.currentToolName)
        XCTAssertEqual(snapshots.first?.transcriptPath, "/tmp/transcript.jsonl")
    }

    func testNotificationWaitingState() {
        let event = event("Notification", message: "Claude is waiting for your input")

        let snapshot = AgentActivitySnapshot(event: event)

        XCTAssertEqual(snapshot.state, .waitingForInput)
    }

    func testFailureAndSessionEndTransitionsClearActiveTool() {
        var snapshot = AgentActivitySnapshot(event: event(
            "PreToolUse",
            toolName: "Bash",
            toolSummary: "swift test"
        ))

        snapshot.apply(event(
            "PostToolUseFailure",
            occurredAt: Date(timeIntervalSince1970: 2),
            error: "command failed"
        ))

        XCTAssertEqual(snapshot.state, .failed)
        XCTAssertNil(snapshot.currentToolName)
        XCTAssertNil(snapshot.currentToolSummary)
        XCTAssertEqual(snapshot.lastError, "command failed")

        snapshot.apply(event("SessionEnd", occurredAt: Date(timeIntervalSince1970: 3)))

        XCTAssertEqual(snapshot.state, .ended)
        XCTAssertNil(snapshot.currentToolName)
        XCTAssertNil(snapshot.currentToolSummary)
    }

    func testStoreKeepsMultipleNudgeSessionsInSameCwdSeparate() async {
        let store = AgentActivityStore()

        await store.record(event(
            "PreToolUse",
            nudgeSessionID: "claude-1",
            claudeSessionID: "session-a",
            cwd: "/tmp/project",
            toolName: "Edit",
            toolSummary: "App.swift"
        ))
        await store.record(event(
            "PreToolUse",
            nudgeSessionID: "claude-2",
            claudeSessionID: "session-b",
            cwd: "/tmp/project",
            toolName: "Bash",
            toolSummary: "swift test"
        ))

        let snapshots = await store.snapshots()
        let byNudgeID = Dictionary(uniqueKeysWithValues: snapshots.compactMap { snapshot in
            snapshot.nudgeSessionID.map { ($0, snapshot) }
        })

        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(byNudgeID["claude-1"]?.currentToolName, "Edit")
        XCTAssertEqual(byNudgeID["claude-2"]?.currentToolName, "Bash")
    }

    func testStoreFallsBackToClaudeSessionIDWhenNudgeIDIsMissing() async {
        let store = AgentActivityStore()

        await store.record(event(
            "PreToolUse",
            nudgeSessionID: nil,
            claudeSessionID: "session-a",
            toolName: "Read",
            toolSummary: "README.md"
        ))
        await store.record(event(
            "PostToolUse",
            nudgeSessionID: nil,
            claudeSessionID: "session-a",
            occurredAt: Date(timeIntervalSince1970: 2)
        ))

        let snapshots = await store.snapshots()

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.claudeSessionID, "session-a")
        XCTAssertEqual(snapshots.first?.state, .thinking)
        XCTAssertNil(snapshots.first?.currentToolName)
    }

    func testStorePrunesEndedSnapshotsAfterTTL() async {
        let store = AgentActivityStore(endedSnapshotTTL: 10)
        let startedAt = Date(timeIntervalSince1970: 100)

        await store.record(event("SessionEnd", occurredAt: startedAt))

        let beforeTTL = await store.snapshots(now: startedAt.addingTimeInterval(9))
        let afterTTL = await store.snapshots(now: startedAt.addingTimeInterval(11))

        XCTAssertEqual(beforeTTL.count, 1)
        XCTAssertTrue(afterTTL.isEmpty)
    }

    private func event(
        _ eventName: String,
        nudgeSessionID: String? = "claude-1",
        claudeSessionID: String? = "abc",
        occurredAt: Date = Date(timeIntervalSince1970: 1),
        cwd: String? = "/tmp/project",
        transcriptPath: String? = "/tmp/transcript.jsonl",
        permissionMode: String? = "default",
        toolName: String? = nil,
        toolSummary: String? = nil,
        promptPreview: String? = nil,
        message: String? = nil,
        error: String? = nil
    ) -> AgentHookEvent {
        AgentHookEvent(
            occurredAt: occurredAt,
            nudgeSessionID: nudgeSessionID,
            claudeSessionID: claudeSessionID,
            eventName: eventName,
            cwd: cwd,
            transcriptPath: transcriptPath,
            permissionMode: permissionMode,
            toolName: toolName,
            toolSummary: toolSummary,
            promptPreview: promptPreview,
            message: message,
            error: error
        )
    }
}
