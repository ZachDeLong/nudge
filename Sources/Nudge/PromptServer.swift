import Foundation
import Network

actor PromptServer {
    private let queue: PromptQueue
    private let requestedPort: NWEndpoint.Port
    private var listener: NWListener?
    private(set) var boundPort: UInt16 = 0
    private let timeoutSeconds: TimeInterval

    init(queue: PromptQueue, port: UInt16, timeoutSeconds: TimeInterval = 300) {
        self.queue = queue
        self.requestedPort = port == 0 ? .any : NWEndpoint.Port(rawValue: port)!
        self.timeoutSeconds = timeoutSeconds
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

    private func respond(to req: HTTPCodec.Request, on conn: NWConnection) async {
        guard req.method == "POST", req.path == "/prompt" else {
            let resp = HTTPCodec.writeResponse(status: 404, contentType: "text/plain", body: Array("not found".utf8))
            conn.send(content: Data(resp), completion: .contentProcessed { _ in })
            return
        }
        let prompt: Prompt
        do {
            prompt = try JSONDecoder().decode(Prompt.self, from: Data(req.body))
        } catch {
            let resp = HTTPCodec.writeResponse(status: 400, contentType: "text/plain", body: Array("bad json".utf8))
            conn.send(content: Data(resp), completion: .contentProcessed { _ in })
            return
        }
        do {
            let decision = try await queue.enqueueWithTimeout(prompt, seconds: timeoutSeconds)
            let body = try JSONEncoder().encode(DecisionResponse(decision: decision))
            let resp = HTTPCodec.writeResponse(status: 200, contentType: "application/json", body: Array(body))
            conn.send(content: Data(resp), completion: .contentProcessed { _ in })
        } catch {
            let resp = HTTPCodec.writeResponse(status: 408, contentType: "text/plain", body: Array("timeout".utf8))
            conn.send(content: Data(resp), completion: .contentProcessed { _ in })
        }
    }
}
