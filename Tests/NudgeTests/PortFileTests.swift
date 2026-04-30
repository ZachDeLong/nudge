import XCTest
@testable import NudgeCore

final class PortFileTests: XCTestCase {
    func testWriteAndReadRoundTrip() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nudge-port-\(UUID().uuidString)")
        try PortFile.write(port: 12345, to: tmp)
        let read = try PortFile.read(from: tmp)
        XCTAssertEqual(read, 12345)
        try FileManager.default.removeItem(at: tmp)
    }

    func testMissingFileThrows() {
        let tmp = URL(fileURLWithPath: "/tmp/nudge-port-missing-\(UUID().uuidString)")
        XCTAssertThrowsError(try PortFile.read(from: tmp))
    }
}
