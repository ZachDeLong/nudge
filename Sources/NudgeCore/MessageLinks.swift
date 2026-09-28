import Foundation

/// Finds what's clickable in an agent's message: web addresses (bare
/// `localhost:3000` included) and paths to files that exist, relative to the
/// session's folder. Ranges are in `text` as NSString (UTF-16) offsets.
public enum MessageLinks {
    public struct Link: Equatable {
        public let range: NSRange
        public let url: URL
    }

    /// `fileExists` is injectable for tests; it gets absolute paths.
    public static func find(in text: String, cwd: String,
                            fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [Link] {
        let ns = text as NSString
        var links: [Link] = []
        func taken(_ r: NSRange) -> Bool { links.contains { NSIntersectionRange($0.range, r).length > 0 } }

        // Web links, with or without a scheme (www.example.com).
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for m in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let url = m.url, let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else { continue }
                links.append(Link(range: m.range, url: url))
            }
        }

        // Local servers, which the detector skips without a scheme.
        for m in localServer.matches(in: text, range: NSRange(location: 0, length: ns.length)) where !taken(m.range) {
            let raw = ns.substring(with: m.range)
            if let url = URL(string: "http://" + raw) { links.append(Link(range: m.range, url: url)) }
        }

        // Paths: absolute, ~/, or relative with a slash or an extension.
        for m in pathLike.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var range = m.range(at: 1)
            var raw = ns.substring(with: range)
            // Sentence punctuation after a path isn't part of it.
            while let last = raw.last, ".,:;!?)".contains(last) {
                raw.removeLast()
                range.length -= 1
            }
            guard !raw.isEmpty, !taken(range), raw.contains("/") || raw.contains(".") else { continue }
            let expanded = (raw as NSString).expandingTildeInPath
            let absolute = expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded)
            let path = (absolute as NSString).standardizingPath
            guard fileExists(path) else { continue }
            links.append(Link(range: range, url: URL(fileURLWithPath: path)))
        }
        return links.sorted { $0.range.location < $1.range.location }
    }

    private static let localServer = try! NSRegularExpression(
        pattern: #"(?<![\w/.:-])(?:localhost|127\.0\.0\.1|0\.0\.0\.0)(?::\d{2,5})?(?:/[^\s`'")\]]*)?"#,
        options: [.caseInsensitive]
    )

    /// A run of path characters that starts a word (or follows a backtick or
    /// quote), so `a/b.txt` in "see a/b.txt." is found but "e.g" isn't a file.
    private static let pathLike = try! NSRegularExpression(
        pattern: #"(?:^|(?<=[\s`'"(\[]))((?:~|\.{1,2})?/?[\w@%+~-][\w@%+~.\-/]*)"#
    )
}
