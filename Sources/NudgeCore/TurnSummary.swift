import Foundation

/// What Claude did since your last message, for the finished panel's subtitle:
/// "4 files +120 −30 · 3m", or "Done in 3m" when nothing was edited. Read from
/// the session transcript Claude Code names in the Stop hook's
/// `transcript_path`.
///
/// The turn runs from your last message to now: the prompt, or your reply from
/// Nudge (a "Stop hook feedback" entry, which keeps the prompt's `promptId`),
/// whichever came last. Other entries sharing the `promptId` that carry text
/// (skill bodies and the like, marked `isMeta`) don't restart it. Edits are
/// Edit/MultiEdit/Write results: each carries `filePath`, plus a
/// `structuredPatch` whose lines start with + or -; a new file's lines are in
/// `content`. Subagents' edits live in their own transcripts and aren't
/// counted.
public struct TurnSummary: Equatable {
    public var files: Int
    public var added: Int
    public var removed: Int
    /// Nil when the turn's start wasn't found.
    public var seconds: Int?

    public init(files: Int, added: Int, removed: Int, seconds: Int?) {
        self.files = files
        self.added = added
        self.removed = removed
        self.seconds = seconds
    }

    /// Only the transcript's tail is read; a turn longer than this is
    /// summarized from what's in it, without a duration.
    public static let tailBytes = 8 << 20

    public static func read(transcriptAt path: String, now: Date = Date()) -> TurnSummary? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return nil }
        return summarize(transcript: data, now: now, isPartial: start > 0)
    }

    /// `transcript` is JSONL. With `isPartial`, its first line may be cut.
    public static func summarize(transcript: Data, now: Date, isPartial: Bool = false) -> TurnSummary? {
        var lines = transcript.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if isPartial, !lines.isEmpty { lines.removeFirst() }

        // Newest first, back to the turn's start.
        var promptID: String?
        var startedAt: Date?
        var edits: [[String: Any]] = []
        var foundStart = false
        for line in lines.reversed() {
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            if let id = entry["promptId"] as? String {
                if promptID == nil { promptID = id } else if id != promptID { foundStart = true; break }
            }
            guard entry["type"] as? String == "user" else { continue }
            if let result = entry["toolUseResult"] as? [String: Any] {
                if result["filePath"] is String, result["structuredPatch"] != nil { edits.append(result) }
                continue
            }
            guard let text = userText(entry) else { continue }
            if entry["isMeta"] as? Bool == true, !text.hasPrefix("Stop hook feedback:") {
                // Its own turn when it opens the promptId (a message from
                // another session); otherwise text injected mid-turn.
                startedAt = timestamp(entry)
                continue
            }
            startedAt = timestamp(entry)
            foundStart = true
            break
        }
        guard promptID != nil || foundStart else { return nil }

        var paths = Set<String>()
        var added = 0, removed = 0
        for edit in edits {
            guard let path = edit["filePath"] as? String else { continue }
            let hunks = edit["structuredPatch"] as? [[String: Any]] ?? []
            if hunks.isEmpty, edit["type"] as? String == "create", let content = edit["content"] as? String {
                added += lineCount(content)
            } else if hunks.isEmpty {
                continue // an edit that changed nothing
            }
            for hunk in hunks {
                for line in hunk["lines"] as? [String] ?? [] {
                    if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
                }
            }
            paths.insert(path)
        }
        let seconds = startedAt.map { max(0, Int(now.timeIntervalSince($0))) }
        return TurnSummary(files: paths.count, added: added, removed: removed, seconds: seconds)
    }

    /// "4 files +120 −30 · 3m", "1 file +2 · 42s", "Done in 3m", or nil when
    /// there's nothing to say.
    public var text: String? {
        let time = seconds.map(Self.duration)
        guard files > 0 else { return time.map { "Done in \($0)" } }
        var parts = ["\(files) \(files == 1 ? "file" : "files")"]
        if added > 0 { parts.append("+\(added)") }
        if removed > 0 { parts.append("\u{2212}\(removed)") }
        let changes = parts.joined(separator: " ")
        return time.map { "\(changes) · \($0)" } ?? changes
    }

    /// "42s", "3m", "1h", "1h 5m".
    public static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    private static func userText(_ entry: [String: Any]) -> String? {
        let content = (entry["message"] as? [String: Any])?["content"]
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return nil }
        if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
        let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        return text.isEmpty ? nil : text.joined(separator: "\n")
    }

    private static func timestamp(_ entry: [String: Any]) -> Date? {
        guard let raw = entry["timestamp"] as? String else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let newlines = text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        return text.hasSuffix("\n") ? newlines : newlines + 1
    }
}
