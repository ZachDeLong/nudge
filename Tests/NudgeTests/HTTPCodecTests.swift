import XCTest
@testable import NudgeCore

final class HTTPCodecTests: XCTestCase {
    func testParsesValidPostRequest() throws {
        let raw = "POST /prompt HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"hello\":1}"
        let req = try HTTPCodec.parseRequest(Array(raw.utf8))
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/prompt")
        XCTAssertEqual(req.headers["Content-Length"], "11")
        XCTAssertEqual(req.body.count, 11)
    }

    func testRejectsMalformedRequestLine() {
        XCTAssertThrowsError(try HTTPCodec.parseRequest(Array("GARBAGE\r\n\r\n".utf8))) { err in
            guard case HTTPCodec.ParseError.malformed = err else {
                return XCTFail("expected .malformed, got \(err)")
            }
        }
    }

    func testIncompleteRequestThrowsNeedMoreData() {
        let raw = "POST /prompt HTTP/1.1\r\nContent-Length: 100\r\n\r\nshort"
        XCTAssertThrowsError(try HTTPCodec.parseRequest(Array(raw.utf8))) { err in
            guard case HTTPCodec.ParseError.needMoreData = err else {
                return XCTFail("expected .needMoreData, got \(err)")
            }
        }
    }

    // MARK: Content-Length validation (regression)
    //
    // `Content-Length: <Int.max>` used to reach `bodyStart + parsedLength` and
    // trap the process on overflow. Parsing happens before the auth check, so
    // any local process could crash Nudge with one unauthenticated request.

    func testRejectsOverflowingContentLength() {
        let raw = "POST /prompt HTTP/1.1\r\nContent-Length: 9223372036854775807\r\n\r\n"
        XCTAssertThrowsError(try HTTPCodec.parseRequest(Array(raw.utf8))) { err in
            guard case HTTPCodec.ParseError.bodyTooLarge = err else {
                return XCTFail("expected .bodyTooLarge, got \(err)")
            }
        }
    }

    func testRejectsContentLengthAboveCap() {
        let raw = "POST /prompt HTTP/1.1\r\nContent-Length: \(HTTPCodec.maxBodyBytes + 1)\r\n\r\n"
        XCTAssertThrowsError(try HTTPCodec.parseRequest(Array(raw.utf8))) { err in
            guard case HTTPCodec.ParseError.bodyTooLarge = err else {
                return XCTFail("expected .bodyTooLarge, got \(err)")
            }
        }
    }

    func testRejectsNegativeContentLength() {
        let raw = "POST /prompt HTTP/1.1\r\nContent-Length: -1\r\n\r\n"
        XCTAssertThrowsError(try HTTPCodec.parseRequest(Array(raw.utf8))) { err in
            guard case HTTPCodec.ParseError.malformed = err else {
                return XCTFail("expected .malformed, got \(err)")
            }
        }
    }

    /// A non-numeric length is a malformed request, not a zero-length body —
    /// the old `?? 0` fallback silently truncated instead of rejecting.
    func testRejectsNonNumericContentLength() {
        let raw = "POST /prompt HTTP/1.1\r\nContent-Length: abc\r\n\r\n{}"
        XCTAssertThrowsError(try HTTPCodec.parseRequest(Array(raw.utf8))) { err in
            guard case HTTPCodec.ParseError.malformed = err else {
                return XCTFail("expected .malformed, got \(err)")
            }
        }
    }

    func testAcceptsContentLengthAtCap() throws {
        let body = String(repeating: "x", count: HTTPCodec.maxBodyBytes)
        let raw = "POST /prompt HTTP/1.1\r\nContent-Length: \(HTTPCodec.maxBodyBytes)\r\n\r\n" + body
        let req = try HTTPCodec.parseRequest(Array(raw.utf8))
        XCTAssertEqual(req.body.count, HTTPCodec.maxBodyBytes)
    }

    func testMissingContentLengthMeansEmptyBody() throws {
        let raw = "POST /prompt HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let req = try HTTPCodec.parseRequest(Array(raw.utf8))
        XCTAssertEqual(req.body.count, 0)
    }

    func testWritesJSONResponse() {
        let body = "{\"decision\":\"allow\"}".data(using: .utf8)!
        let bytes = HTTPCodec.writeResponse(status: 200, contentType: "application/json", body: Array(body))
        let s = String(bytes: bytes, encoding: .utf8)!
        XCTAssertTrue(s.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(s.contains("Content-Type: application/json\r\n"))
        XCTAssertTrue(s.contains("Content-Length: \(body.count)\r\n"))
        XCTAssertTrue(s.hasSuffix("{\"decision\":\"allow\"}"))
    }

    func testWritesUnauthorizedResponse() {
        let bytes = HTTPCodec.writeResponse(status: 401, contentType: "text/plain", body: Array("unauthorized".utf8))
        let s = String(bytes: bytes, encoding: .utf8)!
        XCTAssertTrue(s.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
    }

    func testWritesPayloadTooLargeResponse() {
        let bytes = HTTPCodec.writeResponse(status: 413, contentType: "text/plain", body: Array("payload too large".utf8))
        let s = String(bytes: bytes, encoding: .utf8)!
        XCTAssertTrue(s.hasPrefix("HTTP/1.1 413 Payload Too Large\r\n"))
    }

    func testParsesHTTPResponse() throws {
        let raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 20\r\n\r\n{\"decision\":\"allow\"}"
        let resp = try HTTPCodec.parseResponse(Data(raw.utf8))
        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(resp.headers["Content-Type"], "application/json")
        XCTAssertEqual(String(data: resp.body, encoding: .utf8), "{\"decision\":\"allow\"}")
    }
}
