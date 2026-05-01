import Darwin
import Foundation

public enum AgentKind: String, Codable, Equatable, Sendable {
    case claude
    case codex
    case cursor
    case custom
}

public struct AgentSessionSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: AgentKind
    public var title: String
    public let cwd: String
    public let tmuxSession: String
    public let createdAt: Date
    public var isAttached: Bool
    public var isEnded: Bool
    public var customTitle: String?

    public init(
        id: String,
        kind: AgentKind,
        title: String,
        cwd: String,
        tmuxSession: String,
        createdAt: Date,
        isAttached: Bool,
        isEnded: Bool = false,
        customTitle: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.cwd = cwd
        self.tmuxSession = tmuxSession
        self.createdAt = createdAt
        self.isAttached = isAttached
        self.isEnded = isEnded
        self.customTitle = customTitle
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case cwd
        case tmuxSession
        case createdAt
        case isAttached
        case isEnded
        case customTitle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(AgentKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        cwd = try container.decode(String.self, forKey: .cwd)
        tmuxSession = try container.decode(String.self, forKey: .tmuxSession)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isAttached = try container.decode(Bool.self, forKey: .isAttached)
        isEnded = try container.decodeIfPresent(Bool.self, forKey: .isEnded) ?? false
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(tmuxSession, forKey: .tmuxSession)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(isAttached, forKey: .isAttached)
        try container.encode(isEnded, forKey: .isEnded)
        try container.encodeIfPresent(customTitle, forKey: .customTitle)
    }

    public var projectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }
}

public struct AgentSessionDetail: Codable, Equatable, Identifiable, Sendable {
    public let summary: AgentSessionSummary
    public let transcript: String

    public init(summary: AgentSessionSummary, transcript: String) {
        self.summary = summary
        self.transcript = transcript
    }

    public var id: String { summary.id }
}

public enum AgentSessionFiles {
    public static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/nudge/sessions")
    }

    public static func metadataURL(for id: String) -> URL {
        directoryURL.appendingPathComponent("\(id).json")
    }

    public static func write(_ session: AgentSessionSummary) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )

        let oldMask = umask(0o077)
        defer { umask(oldMask) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        let url = metadataURL(for: session.id)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try assertOwnerOnlyPerms(at: url)
    }

    /// Skips any file the chat UI shouldn't trust — wrong owner, group/other
    /// access bits set, or undecodable. A planted JSON in `~/.config/nudge/
    /// sessions/` would otherwise show up as a fake session and route the
    /// user's "send" calls to the attacker's tmux pane.
    public static func readAll() throws -> [AgentSessionSummary] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .compactMap { url in
            guard (try? assertOwnerOnlyPerms(at: url)) != nil else { return nil }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(AgentSessionSummary.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    public static func remove(id: String) {
        try? FileManager.default.removeItem(at: metadataURL(for: id))
    }

    /// Updates a single session's metadata in place. Used by rename — preserves
    /// other sessions and the perm-validated read path.
    public static func setCustomTitle(id: String, title: String?) throws {
        let url = metadataURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw FileError.missing }
        try assertOwnerOnlyPerms(at: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: url)
        var session = try decoder.decode(AgentSessionSummary.self, from: data)
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        session.customTitle = (trimmed?.isEmpty == false) ? trimmed : nil
        try write(session)
    }

    public enum FileError: Error, Equatable {
        case missing
    }
}
