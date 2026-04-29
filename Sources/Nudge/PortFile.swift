import Foundation

enum PortFile {
    static var defaultURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/nudge/port")
    }

    enum FileError: Error {
        case missing
        case malformed
    }

    static func write(port: UInt16, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "\(port)\n".write(to: url, atomically: true, encoding: .utf8)
    }

    static func read(from url: URL = defaultURL) throws -> UInt16 {
        guard FileManager.default.fileExists(atPath: url.path) else { throw FileError.missing }
        let raw = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = UInt16(raw) else { throw FileError.malformed }
        return port
    }
}
