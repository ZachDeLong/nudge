import Foundation

/// Decides when global ⏎/esc may answer a permission prompt. The key monitor
/// sees keys typed into *any* app, so a stray Enter in an essay or a browser
/// form must not approve a command nobody read. A key only counts once the
/// prompt has been up a moment and you've stopped typing elsewhere.
public struct AnswerKeys {
    /// How long a prompt must be on screen first. Same idea as the delay on
    /// browser install dialogs.
    public static let promptDelay: TimeInterval = 0.6

    /// How long after your last other keystroke. Enter at the end of a
    /// paragraph comes a beat after the last letter; answering Nudge comes
    /// after reading it.
    public static let typingPause: TimeInterval = 1.0

    public private(set) var armedAt: Date = .distantFuture

    public init() {}

    /// A prompt appeared (or the panel moved on to the next one).
    /// `lastKeyDown` is the last keystroke anywhere, from before the monitor
    /// was listening.
    public mutating func promptShown(at now: Date, lastKeyDown: Date) {
        armedAt = max(now.addingTimeInterval(Self.promptDelay),
                      lastKeyDown.addingTimeInterval(Self.typingPause))
    }

    /// Any keystroke other than a bare ⏎/esc: you're typing somewhere.
    public mutating func typed(at now: Date) {
        armedAt = max(armedAt, now.addingTimeInterval(Self.typingPause))
    }

    public func isArmed(at now: Date) -> Bool {
        now >= armedAt
    }
}
