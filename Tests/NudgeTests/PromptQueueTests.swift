import XCTest
@testable import NudgeCore

final class PromptQueueTests: XCTestCase {
    func testEnqueueAndResolveAllow() async throws {
        let queue = PromptQueue()
        let prompt = Prompt(id: "1", tool: "Bash", command: "ls", cwd: "/tmp", sessionId: "s")

        let task = Task { try await queue.enqueue(prompt) }
        try await Task.sleep(nanoseconds: 20_000_000)
        await queue.resolve(id: "1", with: .allow)
        let result = try await task.value
        XCTAssertEqual(result.decision, .allow)
    }

    func testFIFOOrdering() async throws {
        let queue = PromptQueue()
        let p1 = Prompt(id: "1", tool: "Bash", command: "a", cwd: "/", sessionId: "s")
        let p2 = Prompt(id: "2", tool: "Bash", command: "b", cwd: "/", sessionId: "s")

        let t1 = Task { try await queue.enqueue(p1) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let t2 = Task { try await queue.enqueue(p2) }
        try await Task.sleep(nanoseconds: 20_000_000)

        await queue.resolve(id: "1", with: .allow)
        let r1 = try await t1.value
        XCTAssertEqual(r1.decision, .allow)

        await queue.resolve(id: "2", with: .deny)
        let r2 = try await t2.value
        XCTAssertEqual(r2.decision, .deny)
    }

    /// Letting go of finished messages in bulk reaches one queued behind a
    /// permission prompt, and leaves the permission prompt alone.
    func testResolveAllAnswersMatchesBehindTheHead() async throws {
        let queue = PromptQueue()
        let permission = Prompt(id: "p", tool: "Bash", command: "a", cwd: "/", sessionId: "s")
        let finished = Prompt(id: "f", kind: .finished, tool: "Stop", command: "done", cwd: "/", sessionId: "s")

        let tp = Task { try await queue.enqueue(permission) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let tf = Task { try await queue.enqueue(finished) }
        try await Task.sleep(nanoseconds: 20_000_000)

        let count = await queue.resolveAll(where: { $0.resolvedKind == .finished },
                                           with: DecisionResponse(decision: .cancel))
        XCTAssertEqual(count, 1)
        let rf = try await tf.value
        XCTAssertEqual(rf.decision, .cancel)
        let left = await queue.snapshot().map(\.id)
        XCTAssertEqual(left, ["p"])

        await queue.resolve(id: "p", with: .deny)
        _ = try await tp.value
    }

    func testEnqueueWithTimeoutFires() async throws {
        let queue = PromptQueue()
        let prompt = Prompt(id: "to", tool: "Bash", command: "x", cwd: "/", sessionId: "s")
        do {
            _ = try await queue.enqueueWithTimeout(prompt, seconds: 0.1)
            XCTFail("expected timeout")
        } catch PromptQueue.QueueError.timedOut {
            // expected
        }
    }

    func testCancellingCallerWithdrawsPrompt() async throws {
        let queue = PromptQueue()
        let prompt = Prompt(id: "gone", tool: "Bash", command: "x", cwd: "/", sessionId: "s")

        let task = Task { try await queue.enqueue(prompt) }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected withdrawal")
        } catch PromptQueue.QueueError.withdrawn {
            // expected
        }
        let resolved = await queue.resolve(id: "gone", with: .allow)
        XCTAssertFalse(resolved)
    }
}
