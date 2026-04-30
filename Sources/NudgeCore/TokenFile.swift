import Darwin
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
        case writeFailed(Int32)
    }

    /// Reads the token, validating content shape, file ownership, and that no
    /// group/other access is permitted. Used by hook CLIs — never writes.
    public static func read(from url: URL = defaultURL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { throw FileError.missing }
        try assertOwnerOnlyPerms(at: url)
        let token = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValid(token) else { throw FileError.malformed }
        return token
    }

    /// Server-only seam: creates the token if missing, otherwise validates and
    /// returns the existing one. Hooks use `read()` instead — keeping creation
    /// single-writer avoids the race where hook and server generate different
    /// tokens on first launch.
    public static func ensure(at url: URL = defaultURL) throws -> String {
        if FileManager.default.fileExists(atPath: url.path) {
            return try read(from: url)
        }
        let token = randomToken()
        try write(token, to: url)
        return token
    }

    /// Tightens the umask, writes atomically, then verifies the resulting
    /// permissions actually applied. A filesystem that silently ignores POSIX
    /// modes (some network mounts, FUSE) is caught here instead of leaving a
    /// world-readable token in place.
    static func write(_ token: String, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        let oldMask = umask(0o077)
        defer { umask(oldMask) }

        do {
            try "\(token)\n".write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw FileError.writeFailed(errno)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try assertOwnerOnlyPerms(at: url)
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            fatalError("SecRandomCopyBytes failed: \(status)")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func isValid(_ token: String) -> Bool {
        let hex = "0123456789abcdef"
        return token.count >= 32 && token.allSatisfy { hex.contains($0) }
    }
}
