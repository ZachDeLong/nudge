import XCTest
@testable import Nudge

final class PromptQueueTests: XCTestCase {
    func testEnqueueAndResolveAllow() async throws {
        let queue = PromptQueue()
        let prompt = Prompt(id: "1", tool: "Bash", command: "ls", cwd: "/tmp", sessionId: "s")

        let task = Task { try await queue.enqueue(prompt) }
        try await Task.sleep(nanoseconds: 20_000_000)
        await queue.resolveHead(with: .allow)
        let result = try await task.value
        XCTAssertEqual(result, .allow)
    }

    func testFIFOOrdering() async throws {
        let queue = PromptQueue()
        let p1 = Prompt(id: "1", tool: "Bash", command: "a", cwd: "/", sessionId: "s")
        let p2 = Prompt(id: "2", tool: "Bash", command: "b", cwd: "/", sessionId: "s")

        let t1 = Task { try await queue.enqueue(p1) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let t2 = Task { try await queue.enqueue(p2) }
        try await Task.sleep(nanoseconds: 20_000_000)

        await queue.resolveHead(with: .allow)
        let r1 = try await t1.value
        XCTAssertEqual(r1, .allow)

        await queue.resolveHead(with: .deny)
        let r2 = try await t2.value
        XCTAssertEqual(r2, .deny)
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
}
