import Foundation

extension AudiobookshelfClient {

    /// Cover art URL. `/api/` requires authentication, and image loaders can't
    /// attach headers, so the access token rides in the query string — a form the
    /// server explicitly supports for GET requests.
    public func coverURL(itemId: String, width: Int? = nil, height: Int? = nil) async -> URL? {
        guard let connection = await sessionStore.current else { return nil }
        return Self.coverURL(itemId: itemId, connection: connection, width: width, height: height)
    }

    public nonisolated static func coverURL(itemId: String,
                                            connection: ServerConnection,
                                            width: Int? = nil,
                                            height: Int? = nil) -> URL? {
        var query: [URLQueryItem] = [URLQueryItem(name: "token", value: connection.accessToken)]
        if let width { query.append(.number("width", width)) }
        if let height { query.append(.number("height", height)) }
        // `raw=0` lets the server hand back its resized, cached derivative.
        query.append(.flag("raw", false))

        let endpoint = Endpoint.get("/api/items/\(itemId)/cover", query: query)
        return try? endpoint.url(relativeTo: connection.baseURL)
    }

    public nonisolated static func authorImageURL(authorId: String,
                                                  connection: ServerConnection,
                                                  width: Int? = nil) -> URL? {
        var query: [URLQueryItem] = [URLQueryItem(name: "token", value: connection.accessToken)]
        if let width { query.append(.number("width", width)) }
        let endpoint = Endpoint.get("/api/authors/\(authorId)/image", query: query)
        return try? endpoint.url(relativeTo: connection.baseURL)
    }

    /// Resolves the URL AVPlayer should load for one track of a session.
    ///
    /// Preference order matters for reliability:
    /// 1. Transcoded sessions expose an HLS playlist, served from the unauthenticated
    ///    `/hls` mount — hand it over as-is.
    /// 2. Direct play uses `/public/session/{id}/track/{n}`, also unauthenticated, so
    ///    AVFoundation's byte-range requests need no credentials at all. This is what
    ///    makes seeking and background playback dependable.
    /// 3. Older servers without the public route fall back to the track's own
    ///    `contentUrl` with the token in the query string.
    public nonisolated static func streamURL(for track: AudioTrack,
                                             session: PlaybackSession,
                                             connection: ServerConnection,
                                             preferPublicRoute: Bool = true) -> URL? {
        if track.isHLS {
            return absoluteURL(forServerPath: track.contentUrl, connection: connection, token: nil)
        }

        if preferPublicRoute, !session.id.isEmpty {
            let endpoint = Endpoint.get("/public/session/\(session.id)/track/\(track.index)")
            if let url = try? endpoint.url(relativeTo: connection.baseURL) { return url }
        }

        return absoluteURL(forServerPath: track.contentUrl,
                           connection: connection,
                           token: connection.accessToken)
    }

    /// Turns a server-relative path such as `/api/items/x/file/y` into an absolute URL,
    /// preserving any sub-path the server is mounted under.
    public nonisolated static func absoluteURL(forServerPath path: String,
                                               connection: ServerConnection,
                                               token: String?) -> URL? {
        // Some servers already hand back absolute URLs; respect them.
        if let absolute = URL(string: path), absolute.scheme != nil { return absolute }

        var query: [URLQueryItem] = []
        var cleanPath = path
        // Split off any query the server included in contentUrl.
        if let separator = path.firstIndex(of: "?") {
            cleanPath = String(path[path.startIndex..<separator])
            let rawQuery = String(path[path.index(after: separator)...])
            query = URLComponents(string: "?\(rawQuery)")?.queryItems ?? []
        }
        if let token { query.append(URLQueryItem(name: "token", value: token)) }

        let endpoint = Endpoint.get(cleanPath, query: query)
        return try? endpoint.url(relativeTo: connection.baseURL)
    }

    /// Direct file download used by the offline downloader, where an authenticated
    /// `URLSession` can send a proper header instead of a query token.
    public nonisolated static func fileDownloadURL(itemId: String,
                                                   ino: String,
                                                   connection: ServerConnection) -> URL? {
        let endpoint = Endpoint.get("/api/items/\(itemId)/file/\(ino)")
        return try? endpoint.url(relativeTo: connection.baseURL)
    }
}
