import Foundation

/// An Audiobookshelf server the app knows about, plus the tokens for it.
/// Tokens live in the Keychain; this struct is the in-memory view of them.
public struct ServerConnection: Sendable, Hashable, Identifiable, Codable {
    public let id: UUID
    public var baseURL: URL
    public var username: String
    public var userId: String
    public var serverName: String
    public var accessToken: String
    /// Absent on servers older than 2.26, where the access token doesn't expire.
    public var refreshToken: String?
    public var defaultLibraryId: String?

    public init(id: UUID = UUID(), baseURL: URL, username: String, userId: String,
                serverName: String, accessToken: String, refreshToken: String? = nil,
                defaultLibraryId: String? = nil) {
        self.id = id
        self.baseURL = baseURL
        self.username = username
        self.userId = userId
        self.serverName = serverName
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.defaultLibraryId = defaultLibraryId
    }

    public var supportsTokenRefresh: Bool { refreshToken != nil }

    public var displayHost: String { baseURL.host() ?? baseURL.absoluteString }

    /// Accepts what a person would actually type — "myserver.com", "myserver.com:13378",
    /// "http://192.168.1.4:13378" — and normalises it, defaulting to HTTPS.
    public static func normalize(urlString: String) -> URL? {
        var trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }

        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }

        components.scheme = scheme
        // Strip anything after the origin + optional base path; queries and fragments
        // are never part of a server address.
        components.query = nil
        components.fragment = nil
        if components.path == "/" { components.path = "" }

        return components.url
    }
}
