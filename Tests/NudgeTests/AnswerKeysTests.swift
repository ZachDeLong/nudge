import XCTest
@testable import NudgeCore

final class AnswerKeysTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    func testUnarmedUntilAPromptShows() {
        XCTAssertFalse(AnswerKeys().isArmed(at: t0))
    }

    func testPromptDelayWhenIdle() {
        var keys = AnswerKeys()
        keys.promptShown(at: t0, lastKeyDown: t0.addingTimeInterval(-60))
        XCTAssertFalse(keys.isArmed(at: t0.addingTimeInterval(0.5)))
        XCTAssertTrue(keys.isArmed(at: t0.addingTimeInterval(0.6)))
    }

    func testTypingJustBeforeThePromptHoldsLonger() {
        var keys = AnswerKeys()
        keys.promptShown(at: t0, lastKeyDown: t0.addingTimeInterval(-0.2))
        XCTAssertFalse(keys.isArmed(at: t0.addingTimeInterval(0.7)))
        XCTAssertTrue(keys.isArmed(at: t0.addingTimeInterval(0.8)))
    }

    /// Writing an essay with a prompt up: every keystroke pushes the arming
    /// out, so the Enter at the end of a paragraph doesn't approve anything.
    func testTypingWhilePromptIsUpHoldsKeys() {
        var keys = AnswerKeys()
        keys.promptShown(at: t0, lastKeyDown: t0.addingTimeInterval(-60))
        for i in 0..<20 {
            keys.typed(at: t0.addingTimeInterval(0.5 + Double(i) * 0.2))
        }
        let lastLetter = t0.addingTimeInterval(0.5 + 19 * 0.2)
        XCTAssertFalse(keys.isArmed(at: lastLetter.addingTimeInterval(0.3)))
        XCTAssertTrue(keys.isArmed(at: lastLetter.addingTimeInterval(1.0)))
    }

    func testTypingNeverShortensTheDelay() {
        var keys = AnswerKeys()
        keys.promptShown(at: t0, lastKeyDown: t0.addingTimeInterval(-0.9))
        keys.typed(at: t0.addingTimeInterval(-0.5))
        XCTAssertFalse(keys.isArmed(at: t0.addingTimeInterval(0.55)))
    }
}

final class PrefsTests: XCTestCase {
    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nudge-prefs-\(UUID().uuidString).json")
    }

    /// A prefs.json from before the ⏎/esc switch keeps its settings.
    func testOlderFileWithoutGlobalKeysKeepsItsSettings() throws {
        let url = tempURL()
        try #"{"enabled":false,"skipWhenTerminalFocused":false}"#.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(Prefs.load(from: url), Prefs(enabled: false, skipWhenTerminalFocused: false, globalKeys: true))
    }

    func testRoundTrip() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let prefs = Prefs(enabled: true, skipWhenTerminalFocused: false, globalKeys: false)
        prefs.save(to: url)
        XCTAssertEqual(Prefs.load(from: url), prefs)
    }
}
