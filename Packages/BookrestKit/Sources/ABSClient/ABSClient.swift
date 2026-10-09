import Foundation

/// Typed access to the Audiobookshelf HTTP API.
///
/// Every call funnels through `HTTPTransport`, so authentication, refresh and
/// retry behaviour is uniform and nothing here has to think about tokens.
public final class AudiobookshelfClient: Sendable {
    public let transport: HTTPTransport
    public let sessionStore: SessionStore

    public convenience init(storage: CredentialStorage) {
        self.init(sessionStore: SessionStore(storage: storage))
    }

    public init(sessionStore: SessionStore = SessionStore()) {
        self.sessionStore = sessionStore
        self.transport = HTTPTransport(sessionStore: sessionStore)
    }

    public var currentConnection: ServerConnection? {
        get async { await sessionStore.current }
    }

    // MARK: - Authentication

    /// Signs in and persists the resulting connection.
    ///
    /// `x-return-tokens` asks servers from 2.26 onward to include the refresh token
    /// in the JSON body rather than only as a cookie, which keeps token handling
    /// explicit instead of depending on the shared cookie jar.
    @discardableResult
    public func signIn(serverURL: URL, username: String, password: String) async throws -> ServerConnection {
        struct Credentials: Encodable { let username: String; let password: String }

        var endpoint = try Endpoint.encoding(
            Credentials(username: username, password: password),
            to: "/login"
        )
        endpoint.requiresAuth = false
        endpoint.headers["x-return-tokens"] = "true"

        let response = try await transport.sendUnauthenticated(
            endpoint, baseURL: serverURL, as: LoginResponse.self
        )

        let connection = ServerConnection(
            baseURL: serverURL,
            username: response.user.username.isEmpty ? username : response.user.username,
            userId: response.user.id,
            serverName: serverURL.host() ?? "Audiobookshelf",
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            defaultLibraryId: response.userDefaultLibraryId
        )
        try await sessionStore.store(connection)
        return connection
    }

    /// Verifies a server address before asking for credentials, so a typo is caught
    /// on the field rather than reported as a login failure.
    public func ping(serverURL: URL) async throws {
        var endpoint = Endpoint.get("/ping")
        endpoint.requiresAuth = false

        struct PingResponse: Decodable { let success: Bool? }
        _ = try await transport.sendUnauthenticated(endpoint, baseURL: serverURL, as: PingResponse.self)
    }

    public func signOut() async {
        // Best effort: invalidate server-side, but never block sign-out on the network.
        let endpoint = Endpoint.post("/logout")
        _ = try? await transport.send(endpoint, policy: .never)
        await sessionStore.signOut()
    }

    public func me() async throws -> ABSUser {
        try await transport.send(Endpoint.get("/api/me"), as: ABSUser.self)
    }

    // MARK: - Libraries

    public func libraries() async throws -> [Library] {
        let response = try await transport.send(Endpoint.get("/api/libraries"), as: LibrariesResponse.self)
        return response.libraries.sorted { $0.displayOrder < $1.displayOrder }
    }

    public func items(inLibrary libraryId: String,
                      page: Int = 0,
                      limit: Int = 50,
                      sort: LibrarySort = .title,
                      descending: Bool = false,
                      filter: LibraryFilter? = nil,
                      collapseSeries: Bool = false) async throws -> Page<LibraryItem> {
        var query: [URLQueryItem] = [
            .number("limit", limit),
            .number("page", page),
            URLQueryItem(name: "sort", value: sort.apiValue),
            .flag("desc", descending),
            .flag("minified", true),
            .flag("collapseseries", collapseSeries),
            .flag("include", false),
        ]
        query.removeAll { $0.name == "include" }
        if let filter { query.append(URLQueryItem(name: "filter", value: filter.apiValue)) }

        return try await transport.send(
            Endpoint.get("/api/libraries/\(libraryId)/items", query: query),
            as: Page<LibraryItem>.self
        )
    }

    public func item(_ itemId: String, expanded: Bool = true) async throws -> LibraryItem {
        var query: [URLQueryItem] = []
        if expanded { query.append(.flag("expanded", true)) }
        return try await transport.send(
            Endpoint.get("/api/items/\(itemId)", query: query),
            as: LibraryItem.self
        )
    }

    public func personalizedShelves(libraryId: String) async throws -> [PersonalizedShelf] {
        let shelves = try await transport.send(
            Endpoint.get("/api/libraries/\(libraryId)/personalized", query: [.number("limit", 20)]),
            as: [PersonalizedShelf].self
        )
        return shelves.filter { !$0.isEmpty }
    }

    public func itemsInProgress(limit: Int = 25) async throws -> [LibraryItem] {
        struct Response: Decodable { let libraryItems: [LibraryItem]?  }
        let response = try await transport.send(
            Endpoint.get("/api/me/items-in-progress", query: [.number("limit", limit)]),
            as: Response.self
        )
        return response.libraryItems ?? []
    }

    // MARK: - Series, authors, collections

    public func series(inLibrary libraryId: String,
                       page: Int = 0,
                       limit: Int = 50,
                       descending: Bool = false) async throws -> Page<Series> {
        try await transport.send(
            Endpoint.get("/api/libraries/\(libraryId)/series", query: [
                .number("limit", limit),
                .number("page", page),
                URLQueryItem(name: "sort", value: "name"),
                .flag("desc", descending),
            ]),
            as: Page<Series>.self
        )
    }

    /// Books in one series, in reading order.
    public func books(inSeries seriesId: String, named seriesName: String? = nil,
                      libraryId: String) async throws -> [LibraryItem] {
        let page = try await items(
            inLibrary: libraryId,
            limit: 500,
            sort: .seriesSequence,
            filter: .series(seriesId)
        )
        // Don't trust the server's sort alone; older versions ignore it for minified listings.
        return page.results.inSeriesOrder(seriesId: seriesId, seriesName: seriesName)
    }

    public func authors(inLibrary libraryId: String) async throws -> [Author] {
        let response = try await transport.send(
            Endpoint.get("/api/libraries/\(libraryId)/authors"),
            as: AuthorsResponse.self
        )
        return response.authors.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func author(_ authorId: String, libraryId: String) async throws -> Author {
        try await transport.send(
            Endpoint.get("/api/authors/\(authorId)", query: [
                URLQueryItem(name: "library", value: libraryId),
                URLQueryItem(name: "include", value: "items,series"),
            ]),
            as: Author.self
        )
    }

    public func books(byAuthor authorId: String, libraryId: String) async throws -> [LibraryItem] {
        let page = try await items(inLibrary: libraryId, limit: 500, sort: .title, filter: .author(authorId))
        return page.results
    }

    public func collections(inLibrary libraryId: String) async throws -> [BookCollection] {
        let response = try await transport.send(
            Endpoint.get("/api/libraries/\(libraryId)/collections", query: [.number("limit", 200)]),
            as: CollectionsResponse.self
        )
        return response.collections
    }

    public func search(libraryId: String, query: String, limit: Int = 12) async throws -> SearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        return try await transport.send(
            Endpoint.get("/api/libraries/\(libraryId)/search", query: [
                URLQueryItem(name: "q", value: trimmed),
                .number("limit", limit),
            ]),
            as: SearchResults.self
        )
    }

    // MARK: - Playback

    /// Opens a playback session. `forceTranscode` is the escape hatch for sources
    /// AVFoundation reports as unplayable despite the server offering direct play.
    public func startPlaybackSession(itemId: String,
                                     episodeId: String? = nil,
                                     forceTranscode: Bool = false) async throws -> PlaybackSession {
        let request = PlayRequest(
            deviceInfo: DeviceIdentity.playRequestDeviceInfo,
            supportedMimeTypes: DeviceIdentity.supportedMimeTypes,
            mediaPlayer: "AVPlayer",
            forceDirectPlay: false,
            forceTranscode: forceTranscode
        )

        var path = "/api/items/\(itemId)/play"
        if let episodeId, !episodeId.isEmpty { path += "/\(episodeId)" }

        // Opening a session is safe to retry: the server keys sessions on device id,
        // so a replayed request resumes rather than duplicating.
        let endpoint = try Endpoint.encoding(request, to: path, idempotent: true)
        let session = try await transport.send(endpoint, as: PlaybackSession.self)
        guard !session.audioTracks.isEmpty else { throw ABSError.nothingToPlay }
        return session
    }

    /// Reports listening progress. Never retried automatically — a replayed sync
    /// would double-count `timeListened` in the server's statistics.
    public func syncSession(_ sessionId: String, payload: SessionSyncPayload) async throws {
        let endpoint = try Endpoint.encoding(payload, to: "/api/session/\(sessionId)/sync")
        try await transport.send(endpoint, policy: .never)
    }

    public func closeSession(_ sessionId: String, payload: SessionSyncPayload?) async throws {
        let endpoint: Endpoint = if let payload {
            try Endpoint.encoding(payload, to: "/api/session/\(sessionId)/close")
        } else {
            Endpoint.post("/api/session/\(sessionId)/close")
        }
        try await transport.send(endpoint, policy: .never)
    }

    // MARK: - Progress

    public func updateProgress(itemId: String,
                               episodeId: String? = nil,
                               payload: ProgressUpdatePayload) async throws {
        var path = "/api/me/progress/\(itemId)"
        if let episodeId, !episodeId.isEmpty { path += "/\(episodeId)" }
        let endpoint = try Endpoint.encoding(payload, to: path, method: .patch, idempotent: true)
        try await transport.send(endpoint)
    }

    public func markFinished(itemId: String, episodeId: String? = nil, finished: Bool = true) async throws {
        try await updateProgress(
            itemId: itemId,
            episodeId: episodeId,
            payload: ProgressUpdatePayload(progress: finished ? 1 : 0, isFinished: finished)
        )
    }

    /// Pushes progress accumulated while offline. The server merges by timestamp,
    /// so the most recently updated position wins across devices.
    public func syncLocalSessions(_ sessions: [LocalSessionSync]) async throws {
        struct Payload: Encodable { let sessions: [LocalSessionSync] }
        guard !sessions.isEmpty else { return }
        let endpoint = try Endpoint.encoding(Payload(sessions: sessions), to: "/api/session/local-all")
        try await transport.send(endpoint, policy: .never)
    }
}

/// A listening session recorded on-device while offline, replayed on reconnect.
public struct LocalSessionSync: Encodable, Sendable {
    public let id: String
    public let libraryItemId: String
    public let episodeId: String?
    public let mediaPlayer: String
    public let deviceInfo: PlayRequest.DeviceInfo
    public let currentTime: TimeInterval
    public let timeListening: TimeInterval
    public let duration: TimeInterval
    public let startedAt: Int
    public let updatedAt: Int

    public init(id: String, libraryItemId: String, episodeId: String?,
                currentTime: TimeInterval, timeListening: TimeInterval,
                duration: TimeInterval, startedAt: Date, updatedAt: Date) {
        self.id = id
        self.libraryItemId = libraryItemId
        self.episodeId = episodeId
        self.mediaPlayer = "AVPlayer"
        self.deviceInfo = DeviceIdentity.playRequestDeviceInfo
        self.currentTime = currentTime
        self.timeListening = timeListening
        self.duration = duration
        self.startedAt = Int(startedAt.timeIntervalSince1970 * 1000)
        self.updatedAt = Int(updatedAt.timeIntervalSince1970 * 1000)
    }
}
