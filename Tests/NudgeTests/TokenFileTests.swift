import XCTest
@testable import NudgeCore

final class TokenFileTests: XCTestCase {
    func testWriteAndReadRoundTrip() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nudge-token-\(UUID().uuidString)")
        try TokenFile.write(String(repeating: "a", count: 64), to: tmp)
        let read = try TokenFile.read(from: tmp)
        XCTAssertEqual(read, String(repeating: "a", count: 64))
        try FileManager.default.removeItem(at: tmp)
    }

    func testMalformedTokenThrows() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nudge-token-bad-\(UUID().uuidString)")
        try "not-a-valid-token\n".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertThrowsError(try TokenFile.read(from: tmp))
    }
}
