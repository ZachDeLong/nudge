import Darwin
import Foundation

public enum NudgeClientError: Error, Equatable {
    case launchFailed
    case tokenMissing
    case connectFailed(errno: Int32)
    case writeFailed
    case readFailed(errno: Int32)
    case malformedResponse
    case requestTimedOut
    case unexpectedStatus(Int)
    case badJSON
}

public enum NudgeClient {
    public static func readPort(from url: URL = PortFile.defaultURL) -> UInt16? {
        try? PortFile.read(from: url)
    }

    public static func probe(port: UInt16, host: String = "127.0.0.1") -> Bool {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { close(s) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    public static func locatePort(
        portFileURL: URL = PortFile.defaultURL,
        launchTimeout: TimeInterval = 2.0
    ) -> UInt16? {
        if let port = readPort(from: portFileURL), probe(port: port) {
            return port
        }
        return launchAndWaitForPort(portFileURL: portFileURL, timeout: launchTimeout)
    }

    public static func launchAndWaitForPort(
        portFileURL: URL = PortFile.defaultURL,
        timeout: TimeInterval = 2.0
    ) -> UInt16? {
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

    public static func postPrompt(
        _ prompt: Prompt,
        to path: String,
        port: UInt16,
        token: String? = nil
    ) throws -> DecisionResponse {
        let body = try JSONEncoder().encode(prompt)
        let response = try post(path: path, port: port, body: body, token: token)
        switch response.status {
        case 200:
            do {
                return try JSONDecoder().decode(DecisionResponse.self, from: response.body)
            } catch {
                throw NudgeClientError.badJSON
            }
        case 408:
            throw NudgeClientError.requestTimedOut
        default:
            throw NudgeClientError.unexpectedStatus(response.status)
        }
    }

    public static func post(
        path: String,
        port: UInt16,
        body: Data,
        host: String = "127.0.0.1",
        token: String? = nil
    ) throws -> HTTPCodec.Response {
        let authToken: String
        if let token {
            authToken = token
        } else {
            authToken = try readAuthToken()
        }
        let raw = try sendRequestAndReadResponse(
            host: host,
            port: port,
            request: makePostRequest(path: path, host: host, port: port, body: body, token: authToken)
        )
        do {
            return try HTTPCodec.parseResponse(raw)
        } catch {
            throw NudgeClientError.malformedResponse
        }
    }

    private static func readAuthToken() throws -> String {
        do {
            return try TokenFile.read()
        } catch {
            throw NudgeClientError.tokenMissing
        }
    }

    private static func makePostRequest(path: String, host: String, port: UInt16, body: Data, token: String) -> Data {
        let requestLines = [
            "POST \(path) HTTP/1.1",
            "Host: \(host):\(port)",
            "Content-Type: application/json",
            "Authorization: Bearer \(token)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            "",
        ]
        var request = Data()
        request.append(requestLines.joined(separator: "\r\n").data(using: .utf8)!)
        request.append(body)
        return request
    }

    private static func sendRequestAndReadResponse(host: String, port: UInt16, request: Data) throws -> Data {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else {
            throw NudgeClientError.connectFailed(errno: errno)
        }
        defer { close(s) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            throw NudgeClientError.connectFailed(errno: errno)
        }

        let writeResult = request.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int in
            var written = 0
            while written < buf.count {
                let n = Darwin.write(s, buf.baseAddress!.advanced(by: written), buf.count - written)
                if n <= 0 { return -1 }
                written += n
            }
            return written
        }
        guard writeResult >= 0 else {
            throw NudgeClientError.writeFailed
        }

        var response = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr in
                Darwin.read(s, ptr.baseAddress, ptr.count)
            }
            if n < 0 {
                throw NudgeClientError.readFailed(errno: errno)
            }
            if n == 0 { break }
            response.append(contentsOf: buf[0..<n])
        }
        return response
    }
}
