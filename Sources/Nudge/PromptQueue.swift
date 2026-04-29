import Foundation

actor PromptQueue {
    private struct Pending {
        let prompt: Prompt
        let continuation: CheckedContinuation<Decision, Error>
    }

    private var pending: [Pending] = []
    private var onHeadChange: ((Prompt?, Int) -> Void)?

    enum QueueError: Error {
        case timedOut
    }

    func enqueue(_ prompt: Prompt) async throws -> Decision {
        return try await withCheckedThrowingContinuation { cont in
            let item = Pending(prompt: prompt, continuation: cont)
            let wasEmpty = pending.isEmpty
            pending.append(item)
            if wasEmpty { notifyHead() }
        }
    }

    func enqueueWithTimeout(_ prompt: Prompt, seconds: TimeInterval) async throws -> Decision {
        try await withThrowingTaskGroup(of: Decision.self) { group in
            group.addTask { try await self.enqueue(prompt) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                await self.removePrompt(id: prompt.id)
                throw QueueError.timedOut
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    func resolveHead(with decision: Decision) {
        guard !pending.isEmpty else { return }
        let head = pending.removeFirst()
        head.continuation.resume(returning: decision)
        notifyHead()
    }

    func setOnHeadChange(_ cb: @escaping (Prompt?, Int) -> Void) {
        onHeadChange = cb
        notifyHead()
    }

    private func removePrompt(id: String) {
        if let idx = pending.firstIndex(where: { $0.prompt.id == id }) {
            let removed = pending.remove(at: idx)
            removed.continuation.resume(throwing: QueueError.timedOut)
            if idx == 0 { notifyHead() }
        }
    }

    private func notifyHead() {
        onHeadChange?(pending.first?.prompt, pending.count)
    }
}
