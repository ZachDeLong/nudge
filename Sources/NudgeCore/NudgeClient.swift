import Darwin
import Foundation

public enum NudgeClientError: Error, Equatable {
    case tokenMissing
    case unauthorized
    case requestTimedOut
    case unexpectedStatus(Int)
    case ioFailure
}

public enum NudgeClient {
    public static func locatePort(
        portFileURL: URL = PortFile.defaultURL,
        launchTimeout: TimeInterval = 2.0
    ) -> UInt16? {
        if let port = readPort(from: portFileURL), probe(port: port) {
            return port
        }
        return launchAndWaitForPort(portFileURL: portFileURL, timeout: launchTimeout)
    }

    public static func postPrompt(
        _ prompt: Prompt,
        to path: String,
        port: UInt16
    ) throws -> DecisionResponse {
        let body = try JSONEncoder().encode(prompt)
        let response = try post(path: path, port: port, body: body)
        switch response.status {
        case 200:
            do {
                return try JSONDecoder().decode(DecisionResponse.self, from: response.body)
            } catch {
                throw NudgeClientError.ioFailure
            }
        case 401:
            throw NudgeClientError.unauthorized
        case 408:
            throw NudgeClientError.requestTimedOut
        default:
            throw NudgeClientError.unexpectedStatus(response.status)
        }
    }

    public static func postAgentEvent(
        _ event: AgentHookEvent,
        port: UInt16
    ) throws {
        let body = try JSONEncoder().encode(event)
        let response = try post(path: "/agent-event", port: port, body: body)
        switch response.status {
        case 200:
            return
        case 401:
            throw NudgeClientError.unauthorized
        default:
            throw NudgeClientError.unexpectedStatus(response.status)
        }
    }

    private static func readPort(from url: URL) -> UInt16? {
        try? PortFile.read(from: url)
    }

    private static func probe(port: UInt16) -> Bool {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { close(s) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private static func launchAndWaitForPort(portFileURL: URL, timeout: TimeInterval) -> UInt16? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-ga", "Nudge"]
        do {
            try p.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let port = readPort(from: portFileURL), probe(port: port) {
                return port
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    private static func post(path: String, port: UInt16, body: Data) throws -> HTTPCodec.Response {
        let token: String
        do {
            token = try TokenFile.read()
        } catch {
            throw NudgeClientError.tokenMissing
        }
        let raw = try sendRequestAndReadResponse(
            port: port,
            request: makePostRequest(path: path, port: port, body: body, token: token)
        )
        do {
            return try HTTPCodec.parseResponse(raw)
        } catch {
            throw NudgeClientError.ioFailure
        }
    }

    private static func makePostRequest(path: String, port: UInt16, body: Data, token: String) -> Data {
        let lines = [
            "POST \(path) HTTP/1.1",
            "Host: 127.0.0.1:\(port)",
            "Content-Type: application/json",
            "Authorization: Bearer \(token)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            "",
        ]
        var request = Data()
        request.append(lines.joined(separator: "\r\n").data(using: .utf8)!)
        request.append(body)
        return request
    }

    private static func sendRequestAndReadResponse(port: UInt16, request: Data) throws -> Data {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { throw NudgeClientError.ioFailure }
        defer { close(s) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else { throw NudgeClientError.ioFailure }

        let writeResult = request.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int in
            var written = 0
            while written < buf.count {
                let n = Darwin.write(s, buf.baseAddress!.advanced(by: written), buf.count - written)
                if n <= 0 { return -1 }
                written += n
            }
            return written
        }
        guard writeResult >= 0 else { throw NudgeClientError.ioFailure }

        var response = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr in
                Darwin.read(s, ptr.baseAddress, ptr.count)
            }
            if n < 0 { throw NudgeClientError.ioFailure }
            if n == 0 { break }
            response.append(contentsOf: buf[0..<n])
        }
        return response
    }
}
