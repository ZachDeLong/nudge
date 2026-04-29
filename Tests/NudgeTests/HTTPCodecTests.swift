import XCTest
@testable import Nudge

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

    func testWritesJSONResponse() {
        let body = "{\"decision\":\"allow\"}".data(using: .utf8)!
        let bytes = HTTPCodec.writeResponse(status: 200, contentType: "application/json", body: Array(body))
        let s = String(bytes: bytes, encoding: .utf8)!
        XCTAssertTrue(s.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(s.contains("Content-Type: application/json\r\n"))
        XCTAssertTrue(s.contains("Content-Length: \(body.count)\r\n"))
        XCTAssertTrue(s.hasSuffix("{\"decision\":\"allow\"}"))
    }
}
