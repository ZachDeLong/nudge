import Foundation

public actor PromptQueue {
    private struct Pending {
        let prompt: Prompt
        let continuation: CheckedContinuation<DecisionResponse, Error>
    }

    private var pending: [Pending] = []
    private var onHeadChange: ((Prompt?, Int) -> Void)?

    public enum QueueError: Error, Equatable {
        case timedOut
    }

    public init() {}

    public func enqueue(_ prompt: Prompt) async throws -> DecisionResponse {
        try await withCheckedThrowingContinuation { cont in
            let item = Pending(prompt: prompt, continuation: cont)
            let wasEmpty = pending.isEmpty
            pending.append(item)
            if wasEmpty { notifyHead() }
        }
    }

    public func enqueueWithTimeout(_ prompt: Prompt, seconds: TimeInterval) async throws -> DecisionResponse {
        try await withThrowingTaskGroup(of: DecisionResponse.self) { group in
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

    /// Resolves the head only if it's still the prompt the caller was looking
    /// at. Pass the id the UI rendered.
    ///
    /// Without the id check this resolved whatever happened to be first, so a
    /// head that timed out between render and click would hand your Allow to
    /// the *next* prompt — approving a command you never read. The window is
    /// milliseconds, but it's the exact failure this app exists to prevent, so
    /// a stale click is dropped rather than guessed at.
    ///
    /// Returns true if the prompt was resolved.
    @discardableResult
    public func resolve(id: String, with response: DecisionResponse) -> Bool {
        guard let head = pending.first, head.prompt.id == id else { return false }
        pending.removeFirst()
        head.continuation.resume(returning: response)
        notifyHead()
        return true
    }

    /// Convenience for permission decisions.
    @discardableResult
    public func resolve(id: String, with decision: Decision) -> Bool {
        resolve(id: id, with: DecisionResponse(decision: decision))
    }

    public func setOnHeadChange(_ cb: @escaping (Prompt?, Int) -> Void) {
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
