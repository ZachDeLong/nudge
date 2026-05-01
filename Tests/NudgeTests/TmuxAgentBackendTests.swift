import XCTest
@testable import NudgeCore

final class TmuxAgentBackendTests: XCTestCase {
    func testSessionSummaryDecodesOldMetadataWithoutIsEnded() throws {
        let json = """
        {
          "id": "claude-1",
          "kind": "claude",
          "title": "claude - app",
          "cwd": "/tmp/app",
          "tmuxSession": "nudge-claude-1",
          "createdAt": "2026-05-01T12:00:00Z",
          "isAttached": false
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let session = try decoder.decode(AgentSessionSummary.self, from: Data(json.utf8))

        XCTAssertFalse(session.isEnded)
    }

    func testSanitizedPasteTextPreservesNewlinesAndTabs() {
        let raw = "first\r\nsecond\tcolumn\u{001B}]52;c;bad\u{0007}\u{0085}done"

        let sanitized = TmuxAgentBackend.sanitizedPasteText(raw)

        XCTAssertTrue(sanitized.contains("first\nsecond\tcolumn"))
        XCTAssertTrue(sanitized.contains("]52;c;baddone"))
        XCTAssertFalse(sanitized.unicodeScalars.contains { $0.value == 0x1B })
        XCTAssertFalse(sanitized.unicodeScalars.contains { $0.value == 0x07 })
        XCTAssertFalse(sanitized.unicodeScalars.contains { $0.value == 0x85 })
    }

    func testCleanTranscriptStripsCsiOscAndDcsSequences() {
        let raw = [
            "\u{001B}[31mred\u{001B}[0m",
            "\u{001B}]8;;https://example.com\u{0007}link\u{001B}]8;;\u{0007}",
            "\u{001B}Pignored\u{001B}\\visible   ",
            "\u{2500}\u{2500}\u{2500}\u{2500}",
        ].joined(separator: "\n")

        let clean = TmuxAgentBackend.cleanTranscript(raw)

        XCTAssertTrue(clean.contains("red"))
        XCTAssertTrue(clean.contains("link"))
        XCTAssertTrue(clean.contains("visible"))
        XCTAssertFalse(clean.contains("https://example.com"))
        XCTAssertFalse(clean.contains("ignored"))
        XCTAssertFalse(clean.contains("\u{001B}"))
        XCTAssertFalse(clean.contains("visible   "))
        XCTAssertFalse(clean.contains("\u{2500}\u{2500}\u{2500}\u{2500}"))
    }
}
