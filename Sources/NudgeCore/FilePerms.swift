import Darwin
import Foundation

public enum FilePermsError: Error, Equatable {
    case statFailed(Int32)
    case notOwnerOwned
    case permsTooBroad
}

/// Verifies that `url` is owned by the current user and has no group/other
/// access bits set. Used by both the auth token and per-session metadata
/// readers — anything that ingests trust-bearing JSON from disk should run
/// this first to refuse a planted/leaked file.
public func assertOwnerOnlyPerms(at url: URL) throws {
    var st = stat()
    guard lstat(url.path, &st) == 0 else {
        throw FilePermsError.statFailed(errno)
    }
    guard st.st_uid == getuid() else {
        throw FilePermsError.notOwnerOwned
    }
    if (st.st_mode & 0o077) != 0 {
        throw FilePermsError.permsTooBroad
    }
}
