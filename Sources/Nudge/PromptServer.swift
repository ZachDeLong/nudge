import Foundation
import Network
import NudgeCore

actor PromptServer {
    private let queue: PromptQueue
    private let activityStore: AgentActivityStore
    private let requestedPort: NWEndpoint.Port
    private var listener: NWListener?
    private(set) var boundPort: UInt16 = 0
    private let timeoutSeconds: TimeInterval
    private let tokenURL: URL

    init(
        queue: PromptQueue,
        activityStore: AgentActivityStore,
        port: UInt16,
        tokenURL: URL = TokenFile.defaultURL,
        timeoutSeconds: TimeInterval = 300
    ) {
        self.queue = queue
        self.activityStore = activityStore
        self.requestedPort = port == 0 ? .any : NWEndpoint.Port(rawValue: port)!
        self.timeoutSeconds = timeoutSeconds
        self.tokenURL = tokenURL
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
            var resumed = false
            listener.stateUpdateHandler = { state in
                if resumed { return }
                if case .ready = state {
                    if let port = listener.port {
                        Task { await self.setBoundPort(port.rawValue) }
                    }
                    resumed = true
                    cont.resume()
                } else if case .failed(let err) = state {
                    resumed = true
                    cont.resume(throwing: err)
                }
            }
            listener.start(queue: .global())
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func setBoundPort(_ p: UInt16) {
        boundPort = p
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
            do {
                let req = try HTTPCodec.parseRequest(buf)
                await respond(to: req, on: connection)
                connection.cancel()
                return
            } catch HTTPCodec.ParseError.needMoreData {
                continue
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
        do {
            let response = try await queue.enqueueWithTimeout(prompt, seconds: timeoutSeconds)
            let body = try JSONEncoder().encode(response)
            let resp = HTTPCodec.writeResponse(status: 200, contentType: "application/json", body: Array(body))
            await sendAndAwait(Data(resp), on: conn)
        } catch {
            let resp = HTTPCodec.writeResponse(status: 408, contentType: "text/plain", body: Array("timeout".utf8))
            await sendAndAwait(Data(resp), on: conn)
        }
    }

    private func respondToAgentEvent(_ req: HTTPCodec.Request, on conn: NWConnection) async {
        do {
            let event = try JSONDecoder().decode(AgentHookEvent.self, from: Data(req.body))
            await activityStore.record(event)
            let resp = HTTPCodec.writeResponse(status: 200, contentType: "text/plain", body: Array("ok".utf8))
            await sendAndAwait(Data(resp), on: conn)
        } catch {
            let resp = HTTPCodec.writeResponse(status: 400, contentType: "text/plain", body: Array("bad json".utf8))
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
