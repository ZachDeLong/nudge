import Foundation

/// Minimal semver-ish parser. Accepts `v` prefix, `MAJOR.MINOR.PATCH`,
/// drops anything after a `-` or `+` (pre-release / build metadata).
/// Returns nil for anything that doesn't yield three integers.
public struct Version: Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // Drop pre-release/build metadata.
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            s = String(s[..<cut])
        }
        let parts = s.split(separator: ".").map { Int($0) }
        guard parts.count == 3, let M = parts[0], let m = parts[1], let p = parts[2] else { return nil }
        self.major = M
        self.minor = m
        self.patch = p
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (a: Version, b: Version) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        return a.patch < b.patch
    }

    public static func == (a: Version, b: Version) -> Bool {
        a.major == b.major && a.minor == b.minor && a.patch == b.patch
    }
}
