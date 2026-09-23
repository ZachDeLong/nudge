import XCTest
@testable import NudgeCore

/// Regression coverage for "Quit means quit". The agent hook runs on every tool
/// call, so before the marker existed a deliberate Quit was undone by
/// `open -ga Nudge` almost immediately.
final class AutoLaunchTests: XCTestCase {
    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nudge-autolaunch-\(UUID().uuidString)")
    }

    func testSuppressAndAllowRoundTrip() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertFalse(AutoLaunch.isSuppressed(at: url))
        AutoLaunch.suppress(at: url)
        XCTAssertTrue(AutoLaunch.isSuppressed(at: url))
        AutoLaunch.allow(at: url)
        XCTAssertFalse(AutoLaunch.isSuppressed(at: url))
    }

    /// Both run on every quit/launch, so repeats must be harmless.
    func testSuppressAndAllowAreIdempotent() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        AutoLaunch.allow(at: url)
        AutoLaunch.allow(at: url)
        XCTAssertFalse(AutoLaunch.isSuppressed(at: url))

        AutoLaunch.suppress(at: url)
        AutoLaunch.suppress(at: url)
        XCTAssertTrue(AutoLaunch.isSuppressed(at: url))
    }

    /// With no reachable Nudge, a suppressed marker must make `locatePort`
    /// decline immediately rather than spawn `open` and wait out launchTimeout.
    func testLocatePortDeclinesWhileSuppressed() {
        let marker = tempURL()
        let missingPortFile = tempURL()
        defer { try? FileManager.default.removeItem(at: marker) }
        AutoLaunch.suppress(at: marker)

        let started = Date()
        let port = NudgeClient.locatePort(
            portFileURL: missingPortFile,
            launchTimeout: 2.0,
            autoLaunchMarkerURL: marker
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertNil(port)
        XCTAssertLessThan(elapsed, 0.5, "locatePort stalled — it attempted a launch anyway")
    }
}
