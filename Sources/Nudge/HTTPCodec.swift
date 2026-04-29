import Foundation

enum HTTPCodec {
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: [UInt8]
    }

    enum ParseError: Error {
        case malformed
        case needMoreData
    }

    /// Parses one HTTP/1.1 request from `bytes`.
    /// Throws `.needMoreData` if the buffer is incomplete.
    static func parseRequest(_ bytes: [UInt8]) throws -> Request {
        guard let headerEnd = findSequence([0x0D, 0x0A, 0x0D, 0x0A], in: bytes) else {
            throw ParseError.needMoreData
        }
        let headerBytes = Array(bytes[..<headerEnd])
        guard let headerString = String(bytes: headerBytes, encoding: .utf8) else {
            throw ParseError.malformed
        }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { throw ParseError.malformed }
        let parts = firstLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else {
            throw ParseError.malformed
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIx = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colonIx]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: colonIx)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = val
        }
        let bodyStart = headerEnd + 4
        let contentLength = Int(headers["Content-Length"] ?? "0") ?? 0
        guard bytes.count >= bodyStart + contentLength else {
            throw ParseError.needMoreData
        }
        let body = Array(bytes[bodyStart..<bodyStart + contentLength])
        return Request(method: parts[0], path: parts[1], headers: headers, body: body)
    }

    static func writeResponse(status: Int, contentType: String, body: [UInt8]) -> [UInt8] {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 408: reason = "Request Timeout"
        case 500: reason = "Internal Server Error"
        default:  reason = "OK"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"
        return Array(head.utf8) + body
    }

    private static func findSequence(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        for i in 0...(haystack.count - needle.count) {
            if Array(haystack[i..<i + needle.count]) == needle { return i }
        }
        return nil
    }
}
