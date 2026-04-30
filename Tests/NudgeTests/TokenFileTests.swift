import XCTest
@testable import NudgeCore

final class TokenFileTests: XCTestCase {
    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nudge-token-\(UUID().uuidString)")
    }

    func testWriteAndReadRoundTrip() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try TokenFile.write(String(repeating: "a", count: 64), to: url)
        XCTAssertEqual(try TokenFile.read(from: url), String(repeating: "a", count: 64))
    }

    func testReadOnMissingFileThrowsMissing() {
        let url = tempURL()
        XCTAssertThrowsError(try TokenFile.read(from: url)) { error in
            XCTAssertEqual(error as? TokenFile.FileError, .missing)
        }
    }

    func testMalformedTokenThrowsMalformed() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // Write directly with permissions so it passes the perms check and
        // fails specifically on content validation.
        try "not-a-valid-token\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertThrowsError(try TokenFile.read(from: url)) { error in
            XCTAssertEqual(error as? TokenFile.FileError, .malformed)
        }
    }

    func testRandomTokenIsUnique() {
        let a = TokenFile.randomToken()
        let b = TokenFile.randomToken()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 64)
        XCTAssertEqual(b.count, 64)
    }

    func testEnsureCreatesAndReturnsSameTokenOnRepeat() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try TokenFile.ensure(at: url)
        let second = try TokenFile.ensure(at: url)
        XCTAssertEqual(first, second, "ensure() must be idempotent")
    }

    func testWriteSetsOwnerOnlyPermissions() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try TokenFile.write(String(repeating: "b", count: 64), to: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600, "token file must be owner-only after write")
    }

    func testReadRejectsWorldReadableFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try String(repeating: "c", count: 64).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertThrowsError(try TokenFile.read(from: url)) { error in
            XCTAssertEqual(error as? TokenFile.FileError, .permsTooBroad)
        }
    }
}
