import Foundation

public struct ABSUser: Decodable, Hashable, Sendable, Identifiable {
    public let id: String
    public let username: String
    public let type: String?
    public let isActive: Bool
    public let mediaProgress: [MediaProgress]
    public let bookmarks: [Bookmark]

    private enum CodingKeys: String, CodingKey {
        case id, username, type, isActive, mediaProgress, bookmarks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, default: "")
        username = c.lenient(.username, default: "")
        type = c.lenient(.type)
        isActive = c.lenient(.isActive, default: true)
        mediaProgress = c.lenientArray(.mediaProgress)
        bookmarks = c.lenientArray(.bookmarks)
    }

    public var isAdmin: Bool { type == "admin" || type == "root" }
}

public struct Bookmark: Decodable, Hashable, Sendable, Identifiable {
    public let libraryItemId: String
    public let title: String
    public let time: TimeInterval
    public let createdAt: Date?

    public var id: String { "\(libraryItemId)@\(Int(time))" }

    private enum CodingKeys: String, CodingKey {
        case libraryItemId, title, time, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        libraryItemId = c.lenient(.libraryItemId, default: "")
        title = c.lenient(.title, default: "")
        time = c.lenient(.time, default: 0)
        createdAt = ABSDate.from(milliseconds: c.lenient(.createdAt))
    }
}

/// Result of `POST /login`. Servers from 2.26 onward return `accessToken` plus a
/// refresh token; older ones return a long-lived `token`. Both are handled.
public struct LoginResponse: Decodable, Sendable {
    public let user: ABSUser
    public let accessToken: String
    public let refreshToken: String?
    public let userDefaultLibraryId: String?
    public let serverVersion: String?

    private enum RootKeys: String, CodingKey {
        case user, userDefaultLibraryId, serverSettings
    }

    private enum UserKeys: String, CodingKey {
        case token, accessToken, refreshToken
    }

    private enum ServerSettingsKeys: String, CodingKey {
        case version
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: RootKeys.self)
        user = try c.decode(ABSUser.self, forKey: .user)
        userDefaultLibraryId = c.lenient(.userDefaultLibraryId)

        let userContainer = try c.nestedContainer(keyedBy: UserKeys.self, forKey: .user)
        // `accessToken` is the modern field; `token` is the pre-2.26 fallback.
        guard let token: String = userContainer.lenient(.accessToken) ?? userContainer.lenient(.token) else {
            throw ABSError.missingAuthToken
        }
        accessToken = token
        refreshToken = userContainer.lenient(.refreshToken)

        let settings = try? c.nestedContainer(keyedBy: ServerSettingsKeys.self, forKey: .serverSettings)
        serverVersion = settings?.lenient(.version)
    }
}

/// Result of `POST /auth/refresh`.
public struct RefreshResponse: Decodable, Sendable {
    public let accessToken: String
    public let refreshToken: String?

    private enum RootKeys: String, CodingKey { case user }
    private enum UserKeys: String, CodingKey { case accessToken, token, refreshToken }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        let user = try root.nestedContainer(keyedBy: UserKeys.self, forKey: .user)
        guard let token: String = user.lenient(.accessToken) ?? user.lenient(.token) else {
            throw ABSError.missingAuthToken
        }
        accessToken = token
        refreshToken = user.lenient(.refreshToken)
    }
}
