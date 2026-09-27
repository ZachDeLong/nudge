import Foundation
import Network
import NudgeCore

/// One-shot latch safe to read from concurrent callbacks. Exists so a
/// continuation can be resumed exactly once from `NWListener`'s state handler.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    /// Returns true exactly once, to the first caller.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

actor PromptServer {
    private static let maxAgentEventBodyBytes = 32 * 1024
    private static let maxRequestBytes = 1024 * 1024

    private let queue: PromptQueue
    private let activityStore: AgentActivityStore
    private let requestedPort: NWEndpoint.Port
    private var listener: NWListener?
    private(set) var boundPort: UInt16 = 0
    private let timeoutSeconds: TimeInterval
    private let tokenURL: URL
    /// Serves `/test/*` (see `respondToTestAPI`). Off unless the app was
    /// launched by the e2e harness; see `TestAPI.isEnabled`.
    private let testAPIEnabled: Bool
    /// Pattern prompts just allowed, so the PermissionRequest an ask rule
    /// raises right after for the same call doesn't pop a second time.
    private var recentAllows = RecentAllows()

    init(
        queue: PromptQueue,
        activityStore: AgentActivityStore,
        port: UInt16,
        tokenURL: URL = TokenFile.defaultURL,
        timeoutSeconds: TimeInterval = 300,
        testAPIEnabled: Bool = false
    ) {
        self.queue = queue
        self.activityStore = activityStore
        self.requestedPort = port == 0 ? .any : NWEndpoint.Port(rawValue: port)!
        self.timeoutSeconds = timeoutSeconds
        self.tokenURL = tokenURL
        self.testAPIEnabled = testAPIEnabled
    }

    func start() async throws {
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        let listener = try NWListener(using: params, on: requestedPort)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            Task { await self?.handle(connection: conn) }
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // NWListener delivers state updates on the queue we hand it, which
            // is concurrent, so the once-only latch has to be atomic rather than
            // a captured `var` — resuming a continuation twice is a crash, and
            // the plain capture is a hard error under the Swift 6 language mode.
            let resumed = OnceFlag()
            listener.stateUpdateHandler = { state in
                if case .ready = state {
                    if resumed.claim() { cont.resume() }
                } else if case .failed(let err) = state {
                    if resumed.claim() { cont.resume(throwing: err) }
                }
            }
            listener.start(queue: .global())
        }
        // Read here, once ready, rather than from a Task spawned in the state
        // handler: that raced the resume above, and a caller reading
        // `boundPort` right after start() sometimes got 0 and wrote it to the
        // port file, leaving the hooks nothing to connect to.
        boundPort = listener.port?.rawValue ?? 0
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(connection: NWConnection) async {
        connection.start(queue: .global())
        var buf: [UInt8] = []
        readLoop: while true {
            let chunk: [UInt8] = await withCheckedContinuation { cont in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, _ in
                    if let d = data { cont.resume(returning: Array(d)) }
                    else if isComplete { cont.resume(returning: []) }
                    else { cont.resume(returning: []) }
                }
            }
            if chunk.isEmpty { break readLoop }
            buf.append(contentsOf: chunk)
            if buf.count > Self.maxRequestBytes {
                let resp = HTTPCodec.writeResponse(status: 413, contentType: "text/plain", body: Array("payload too large".utf8))
                await sendAndAwait(Data(resp), on: connection)
                connection.cancel()
                return
            }
            do {
                let req = try HTTPCodec.parseRequest(buf)
                await respond(to: req, on: connection)
                connection.cancel()
                return
            } catch HTTPCodec.ParseError.needMoreData {
                continue
            } catch HTTPCodec.ParseError.bodyTooLarge {
                // Declared body exceeds the codec cap. Reject on the headers
                // alone instead of buffering toward maxRequestBytes first.
                let resp = HTTPCodec.writeResponse(status: 413, contentType: "text/plain", body: Array("payload too large".utf8))
                await sendAndAwait(Data(resp), on: connection)
                connection.cancel()
                return
            } catch {
                let resp = HTTPCodec.writeResponse(status: 400, contentType: "text/plain", body: Array("bad request".utf8))
                connection.send(content: Data(resp), completion: .contentProcessed { _ in connection.cancel() })
                return
            }
        }
        connection.cancel()
    }

    /// Awaits NWConnection.send completion so the caller can safely cancel
    /// the connection afterwards without dropping in-flight data.
    private func sendAndAwait(_ data: Data, on conn: NWConnection) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            conn.send(content: data, completion: .contentProcessed { _ in
                cont.resume()
            })
        }
    }

    private func respond(to req: HTTPCodec.Request, on conn: NWConnection) async {
        guard req.method == "POST" else {
            let resp = HTTPCodec.writeResponse(status: 404, contentType: "text/plain", body: Array("not found".utf8))
            await sendAndAwait(Data(resp), on: conn)
            return
        }
        guard isAuthorized(req) else {
            let resp = HTTPCodec.writeResponse(status: 401, contentType: "text/plain", body: Array("unauthorized".utf8))
            await sendAndAwait(Data(resp), on: conn)
            return
        }
        if req.path == "/agent-event" {
            await respondToAgentEvent(req, on: conn)
            return
        }
        // Disabled, `/test/*` falls through to the 404 below like any unknown
        // path, so a normal install can't be probed for it.
        if testAPIEnabled, req.path.hasPrefix("/test/") {
            await respondToTestAPI(req, on: conn)
            return
        }
        guard req.path == "/prompt" || req.path == "/ask" else {
            let resp = HTTPCodec.writeResponse(status: 404, contentType: "text/plain", body: Array("not found".utf8))
            await sendAndAwait(Data(resp), on: conn)
            return
        }
        let prompt: Prompt
        do {
            prompt = try JSONDecoder().decode(Prompt.self, from: Data(req.body))
        } catch {
            let resp = HTTPCodec.writeResponse(status: 400, contentType: "text/plain", body: Array("bad json".utf8))
            await sendAndAwait(Data(resp), on: conn)
            return
        }
        // You allowed this exact call in a pattern prompt a moment ago, and
        // Claude is asking again only because an ask rule outranks a hook's
        // allow. Answer for you instead of asking twice.
        if prompt.isPermissionRequest, let key = prompt.callKey, recentAllows.consume(key) {
            let body = (try? JSONEncoder().encode(DecisionResponse(decision: .allow))) ?? Data()
            let resp = HTTPCodec.writeResponse(status: 200, contentType: "application/json", body: Array(body))
            await sendAndAwait(Data(resp), on: conn)
            return
        }
        let waiter = Task { [queue, timeoutSeconds] in
            try await queue.enqueueWithTimeout(prompt, seconds: timeoutSeconds)
        }
        Self.watchForHangup(conn) { waiter.cancel() }
        do {
            let response = try await waiter.value
            if response.decision == .allow, prompt.resolvedKind == .permission,
               !prompt.isPermissionRequest, let key = prompt.callKey {
                recentAllows.record(key)
            }
            let body = try JSONEncoder().encode(response)
            let resp = HTTPCodec.writeResponse(status: 200, contentType: "application/json", body: Array(body))
            await sendAndAwait(Data(resp), on: conn)
        } catch PromptQueue.QueueError.withdrawn {
            return // The caller hung up; there is no one to answer.
        } catch is CancellationError {
            return
        } catch {
            let resp = HTTPCodec.writeResponse(status: 408, contentType: "text/plain", body: Array("timeout".utf8))
            await sendAndAwait(Data(resp), on: conn)
        }
    }

    /// Calls `onHangup` when the peer closes the connection. A hook sends one
    /// request and then only reads, so any read completing here means it went
    /// away: Claude Code killed it because the user pressed Esc in the
    /// terminal, or the session ended. Without this its prompt stayed on
    /// screen until the timeout, and answering it reached no one.
    ///
    /// Also fires, harmlessly, when we cancel the connection after answering.
    private nonisolated static func watchForHangup(
        _ conn: NWConnection,
        onHangup: @escaping @Sendable () -> Void
    ) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, isComplete, error in
            if isComplete || error != nil {
                onHangup()
            } else if data != nil {
                watchForHangup(conn, onHangup: onHangup)
            }
        }
    }

    private func respondToAgentEvent(_ req: HTTPCodec.Request, on conn: NWConnection) async {
        guard req.body.count <= Self.maxAgentEventBodyBytes else {
            let resp = HTTPCodec.writeResponse(status: 413, contentType: "text/plain", body: Array("payload too large".utf8))
            await sendAndAwait(Data(resp), on: conn)
            return
        }

        do {
            let event = try JSONDecoder().decode(AgentHookEvent.self, from: Data(req.body))
            await activityStore.record(event)
            // Before answering: Claude waits for this hook, so a later prompt
            // can't be swept by an event that arrives late.
            await withdrawAnsweredElsewhere(event)
            let resp = HTTPCodec.writeResponse(status: 200, contentType: "text/plain", body: Array("ok".utf8))
            await sendAndAwait(Data(resp), on: conn)
        } catch {
            let resp = HTTPCodec.writeResponse(status: 400, contentType: "text/plain", body: Array("bad json".utf8))
            await sendAndAwait(Data(resp), on: conn)
        }
    }

    /// Drops PermissionRequest prompts Claude stopped waiting on because you
    /// answered its own dialog. Esc or No in the terminal kills the hook,
    /// which the hangup watch catches. Yes doesn't: Claude leaves the hook
    /// running until it answers or times out (Claude Code 2.1.283), so its
    /// prompt would sit in the menu bar answering nothing. The agent hook's
    /// events stand in for that missing signal:
    ///
    /// - PostToolUse / PostToolUseFailure: that exact call was allowed and ran.
    /// - Stop: the main thread's turn is over, so nothing it asked is still
    ///   waiting. Subagent prompts are left alone; a background subagent can
    ///   outlive the turn.
    /// - SessionEnd: nothing in the session is waiting.
    private func withdrawAnsweredElsewhere(_ event: AgentHookEvent) async {
        guard let session = event.claudeSessionID else { return }
        switch event.eventName {
        case "PostToolUse", "PostToolUseFailure":
            guard let key = event.callKey else { return }
            await queue.withdraw(limit: 1) { $0.isPermissionRequest && $0.callKey == key }
        case "Stop", "StopFailure":
            guard event.subagentID == nil else { return }
            await queue.withdraw { $0.isPermissionRequest && $0.sessionId == session && $0.subagentId == nil }
        case "SessionEnd":
            await queue.withdraw { $0.isPermissionRequest && $0.sessionId == session }
        default:
            return
        }
    }

    private struct TestResolveRequest: Decodable {
        let id: String
        let decision: Decision
        let text: String?
    }

    /// E2E harness endpoints, behind the same bearer token as everything else:
    ///
    /// - `POST /test/queue` → `{"prompts": [Prompt]}`, head first.
    /// - `POST /test/resolve` with `{"id", "decision", "text"?}` → answers the
    ///   head prompt exactly as a click would reach the queue. 409 if `id`
    ///   isn't the head, the same stale-answer guard the popover gets.
    ///
    /// This answers prompts without a click, so it only exists on an instance
    /// the harness launched with its own config dir (`TestAPI.isEnabled`).
    private func respondToTestAPI(_ req: HTTPCodec.Request, on conn: NWConnection) async {
        switch req.path {
        case "/test/queue":
            let prompts = await queue.snapshot()
            let body = (try? JSONEncoder().encode(["prompts": prompts])) ?? Data()
            let resp = HTTPCodec.writeResponse(status: 200, contentType: "application/json", body: Array(body))
            await sendAndAwait(Data(resp), on: conn)
        case "/test/resolve":
            guard let body = try? JSONDecoder().decode(TestResolveRequest.self, from: Data(req.body)) else {
                let resp = HTTPCodec.writeResponse(status: 400, contentType: "text/plain", body: Array("bad json".utf8))
                await sendAndAwait(Data(resp), on: conn)
                return
            }
            let response = DecisionResponse(decision: body.decision, text: body.text)
            let resolved = await queue.resolve(id: body.id, with: response)
            let resp = resolved
                ? HTTPCodec.writeResponse(status: 200, contentType: "text/plain", body: Array("ok".utf8))
                : HTTPCodec.writeResponse(status: 409, contentType: "text/plain", body: Array("not the head prompt".utf8))
            await sendAndAwait(Data(resp), on: conn)
        default:
            let resp = HTTPCodec.writeResponse(status: 404, contentType: "text/plain", body: Array("not found".utf8))
            await sendAndAwait(Data(resp), on: conn)
        }
    }

    /// Re-reads the token on every request so a rotation on disk takes effect
    /// without restarting the server. Compares the bearer value byte-by-byte
    /// to avoid leaking length-prefix-match timing information.
    private func isAuthorized(_ req: HTTPCodec.Request) -> Bool {
        guard let header = req.headers.first(where: {
            $0.key.caseInsensitiveCompare("Authorization") == .orderedSame
        })?.value else {
            return false
        }
        guard let token = try? TokenFile.read(from: tokenURL) else { return false }
        let expected = "Bearer \(token)"
        let a = Array(header.utf8)
        let b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
