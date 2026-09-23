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
        /// The caller stopped waiting (see `withdraw(id:)`).
        case withdrawn
    }

    public init() {}

    /// Waits for the user's decision on `prompt`. Cancelling the calling task
    /// withdraws the prompt, which is how the server drops a prompt whose
    /// caller hung up.
    public func enqueue(_ prompt: Prompt) async throws -> DecisionResponse {
        let id = prompt.id
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                // Cancelled before it was ever queued: don't put it on screen.
                // Checked on the actor, so a cancel landing after this point
                // finds the prompt queued and withdraws it below.
                guard !Task.isCancelled else {
                    cont.resume(throwing: QueueError.withdrawn)
                    return
                }
                pending.append(Pending(prompt: prompt, continuation: cont))
                // Notify even when the head is unchanged: the depth moved, and
                // the UI shows it (menu bar count, "N more" pill).
                notifyHead()
            }
        } onCancel: {
            Task { await self.withdraw(id: id) }
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

    /// Drops a prompt whose caller is no longer waiting — the hook was killed
    /// because the user interrupted Claude or answered in the terminal. Left
    /// in place it would sit on screen for the full timeout, answering it
    /// would reach nobody, and every prompt queued behind it would wait too.
    ///
    /// Returns true if the prompt was still pending.
    @discardableResult
    public func withdraw(id: String) -> Bool {
        removePrompt(id: id, error: .withdrawn)
    }

    @discardableResult
    private func removePrompt(id: String, error: QueueError = .timedOut) -> Bool {
        guard let idx = pending.firstIndex(where: { $0.prompt.id == id }) else { return false }
        let removed = pending.remove(at: idx)
        removed.continuation.resume(throwing: error)
        notifyHead()
        return true
    }

    private func notifyHead() {
        onHeadChange?(pending.first?.prompt, pending.count)
    }
}
