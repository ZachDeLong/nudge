import CryptoKit
import Foundation

/// SHA-256 helpers for the updater's integrity check.
///
/// Lives in NudgeCore rather than beside `nudge-update` so it's reachable from
/// tests: a parser that's too forgiving here silently turns "verified" back
/// into "downloaded whatever," which is the exact failure the check exists to
/// prevent.
public enum Checksum {
    /// Streams the file so a large asset isn't held in memory just to hash it.
    public static func sha256Hex(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Parses `shasum -a 256` output — a hex digest, whitespace, then the
    /// filename. Returns nil unless the first field is exactly 64 hex chars, so
    /// a truncated file or an HTML error page can't pass as a checksum.
    public static func parseShasumOutput(_ raw: String) -> String? {
        guard let field = raw.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        let digest = field.lowercased()
        let hex = Set("0123456789abcdef")
        guard digest.count == 64, digest.allSatisfy({ hex.contains($0) }) else { return nil }
        return digest
    }

    public static func readExpected(from url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseShasumOutput(raw)
    }
}
