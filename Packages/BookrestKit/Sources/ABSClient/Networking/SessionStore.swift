import Foundation

/// Owns the signed-in connection and serialises token refreshes.
///
/// Refresh is single-flight: a burst of concurrent 401s (very common when the app
/// wakes and the library, cover images and a playback session all fire at once)
/// produces exactly one `/auth/refresh` call, and everyone else awaits its result.
public actor SessionStore {
    private let storage: CredentialStorage
    private var connection: ServerConnection?
    private var refreshInFlight: Task<String, Error>?

    /// Notified whenever the signed-in state changes, so the app can react to a
    /// refresh failure by returning to the login screen.
    private var observers: [UUID: @Sendable (ServerConnection?) -> Void] = [:]

    public init(storage: CredentialStorage = KeychainCredentialStorage()) {
        self.storage = storage
        self.connection = storage.load()
    }

    public var current: ServerConnection? { connection }

    public var isSignedIn: Bool { connection != nil }

    public func accessToken() -> String? { connection?.accessToken }

    public func baseURL() throws -> URL {
        guard let connection else { throw ABSError.unauthorized }
        return connection.baseURL
    }

    public func store(_ connection: ServerConnection) throws {
        self.connection = connection
        try storage.save(connection)
        notify()
    }

    public func updateDefaultLibrary(_ libraryId: String?) {
        guard var connection else { return }
        connection.defaultLibraryId = libraryId
        self.connection = connection
        try? storage.save(connection)
    }

    public func signOut() {
        refreshInFlight?.cancel()
        refreshInFlight = nil
        connection = nil
        storage.clear()
        notify()
    }

    public func addObserver(_ observer: @escaping @Sendable (ServerConnection?) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func notify() {
        let snapshot = connection
        for observer in observers.values { observer(snapshot) }
    }

    // MARK: - Refresh

    private var refreshGeneration = 0

    /// Exchanges the refresh token for a new access token, collapsing concurrent callers.
    ///
    /// - Parameter staleToken: the access token the caller just failed with. If the
    ///   stored token has already moved on, another task refreshed in the meantime
    ///   and we hand back the fresh one without touching the network.
    public func refreshAccessToken(
        staleToken: String?,
        using refresher: @escaping @Sendable (URL, String) async throws -> RefreshResponse
    ) async throws -> String {
        guard let connection else { throw ABSError.unauthorized }

        if let staleToken, connection.accessToken != staleToken {
            return connection.accessToken
        }

        if let refreshInFlight {
            return try await refreshInFlight.value
        }

        guard let refreshToken = connection.refreshToken else {
            // Pre-2.26 servers issue non-expiring tokens, so a 401 here is terminal.
            signOut()
            throw ABSError.unauthorized
        }

        refreshGeneration += 1
        let generation = refreshGeneration
        let baseURL = connection.baseURL

        let task = Task<String, Error> {
            do {
                let response = try await refresher(baseURL, refreshToken)
                return try self.completeRefresh(generation: generation, result: .success(response))
            } catch {
                return try self.completeRefresh(generation: generation, result: .failure(error))
            }
        }
        // Assigned before the first suspension below, so `completeRefresh` — which can
        // only run once this actor yields — never clears a reference we haven't set.
        refreshInFlight = task
        return try await task.value
    }

    private func completeRefresh(generation: Int, result: Result<RefreshResponse, Error>) throws -> String {
        if generation == refreshGeneration { refreshInFlight = nil }

        switch result {
        case .success(let response):
            guard var updated = connection else { throw ABSError.unauthorized }
            updated.accessToken = response.accessToken
            if let newRefreshToken = response.refreshToken { updated.refreshToken = newRefreshToken }
            try store(updated)
            return response.accessToken

        case .failure(let error):
            let absError = ABSError.from(error)
            // A refresh token the server rejects is unrecoverable — sign out so the UI
            // stops retrying and asks for credentials instead.
            if absError == .unauthorized || absError == .forbidden { signOut() }
            throw absError
        }
    }
}
