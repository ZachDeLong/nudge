import Foundation
import Security

public enum TokenFile {
    public static var defaultURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/nudge/token")
    }

    public enum FileError: Error, Equatable {
        case missing
        case malformed
        case randomFailed(OSStatus)
    }

    public static func read(from url: URL = defaultURL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { throw FileError.missing }
        let token = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValid(token) else { throw FileError.malformed }
        return token
    }

    public static func readOrCreate(at url: URL = defaultURL) throws -> String {
        if let existing = try? read(from: url) {
            return existing
        }
        let token = try randomToken()
        try write(token, to: url)
        return token
    }

    public static func write(_ token: String, to url: URL = defaultURL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try "\(token)\n".write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw FileError.randomFailed(status)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func isValid(_ token: String) -> Bool {
        let hex = "0123456789abcdefABCDEF"
        return token.count >= 32 && token.allSatisfy { hex.contains($0) }
    }
}
