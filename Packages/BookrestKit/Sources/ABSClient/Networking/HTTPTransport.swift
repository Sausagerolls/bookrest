import Foundation
import os

/// Performs authenticated requests against an Audiobookshelf server.
///
/// Three things make this resilient enough to sit under playback:
/// 1. A 401 triggers exactly one token refresh (see `SessionStore`) and one replay.
/// 2. Transient failures back off exponentially with jitter, but only for requests
///    that are safe to repeat — a session sync is never blindly replayed.
/// 3. Offline transport errors are surfaced distinctly so callers can fall back to
///    downloaded content instead of showing a generic failure.
public final class HTTPTransport: Sendable {
    public struct RetryPolicy: Sendable {
        public var maxAttempts: Int
        public var baseDelay: TimeInterval
        public var maxDelay: TimeInterval

        public init(maxAttempts: Int = 3, baseDelay: TimeInterval = 0.4, maxDelay: TimeInterval = 6) {
            self.maxAttempts = maxAttempts
            self.baseDelay = baseDelay
            self.maxDelay = maxDelay
        }

        public static let standard = RetryPolicy()
        public static let never = RetryPolicy(maxAttempts: 1)
    }

    let sessionStore: SessionStore
    private let urlSession: URLSession
    private let retryPolicy: RetryPolicy
    private let decoder: JSONDecoder
    private let logger = Logger(subsystem: "com.bookrest.app", category: "network")

    public init(sessionStore: SessionStore,
                urlSession: URLSession? = nil,
                retryPolicy: RetryPolicy = .standard) {
        self.sessionStore = sessionStore
        self.retryPolicy = retryPolicy
        self.decoder = JSONDecoder()

        if let urlSession {
            self.urlSession = urlSession
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 120
            configuration.waitsForConnectivity = false
            configuration.httpMaximumConnectionsPerHost = 6
            configuration.requestCachePolicy = .reloadRevalidatingCacheData
            self.urlSession = URLSession(configuration: configuration)
        }
    }

    // MARK: - Public API

    func send<T: Decodable>(_ endpoint: Endpoint, as type: T.Type,
                            policy: RetryPolicy? = nil) async throws -> T {
        let data = try await data(for: endpoint, policy: policy)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            logger.error("Decode failed for \(endpoint.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw ABSError.decoding(context: "\(type) from \(endpoint.path)")
        }
    }

    @discardableResult
    func send(_ endpoint: Endpoint, policy: RetryPolicy? = nil) async throws -> Data {
        try await data(for: endpoint, policy: policy)
    }

    /// Issues a request against an explicit base URL with no stored credentials —
    /// used for login and token refresh, before a session exists.
    func sendUnauthenticated<T: Decodable>(_ endpoint: Endpoint, baseURL: URL,
                                           as type: T.Type) async throws -> T {
        var request = URLRequest(url: try endpoint.url(relativeTo: baseURL))
        request.httpMethod = endpoint.method.rawValue
        request.httpBody = endpoint.body
        for (key, value) in endpoint.headers { request.setValue(value, forHTTPHeaderField: key) }
        applyStandardHeaders(to: &request)

        let (data, response) = try await perform(request)
        try validate(response: response, data: data)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ABSError.decoding(context: "\(type) from \(endpoint.path)")
        }
    }

    // MARK: - Request execution

    private func data(for endpoint: Endpoint, policy: RetryPolicy?) async throws -> Data {
        let policy = policy ?? (endpoint.isIdempotent ? retryPolicy : .never)
        var attempt = 0
        var hasRefreshed = false

        while true {
            attempt += 1
            try Task.checkCancellation()

            let token = endpoint.requiresAuth ? await sessionStore.accessToken() : nil
            if endpoint.requiresAuth && token == nil { throw ABSError.unauthorized }

            let baseURL = try await sessionStore.baseURL()
            var request = URLRequest(url: try endpoint.url(relativeTo: baseURL))
            request.httpMethod = endpoint.method.rawValue
            request.httpBody = endpoint.body
            for (key, value) in endpoint.headers { request.setValue(value, forHTTPHeaderField: key) }
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            applyStandardHeaders(to: &request)

            do {
                let (data, response) = try await perform(request)
                try validate(response: response, data: data)
                return data
            } catch let error as ABSError {
                // One refresh-and-replay per request, and only when a refresh token exists.
                if error == .unauthorized, endpoint.requiresAuth, !hasRefreshed {
                    hasRefreshed = true
                    _ = try await refreshToken(stale: token)
                    continue
                }

                guard error.isRetryable, attempt < policy.maxAttempts else { throw error }
                try await backOff(attempt: attempt, policy: policy, error: error)
            }
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await urlSession.data(for: request)
        } catch {
            throw ABSError.from(error)
        }
    }

    private func refreshToken(stale: String?) async throws -> String {
        try await sessionStore.refreshAccessToken(staleToken: stale) { [weak self] baseURL, refreshToken in
            guard let self else { throw ABSError.cancelled }
            var endpoint = Endpoint(path: "/auth/refresh", method: .post, requiresAuth: false)
            // Sending the token as a header (rather than relying on the cookie jar)
            // makes the server return the rotated refresh token in the JSON body.
            endpoint.headers["x-refresh-token"] = refreshToken
            return try await self.sendUnauthenticated(endpoint, baseURL: baseURL, as: RefreshResponse.self)
        }
    }

    private func backOff(attempt: Int, policy: RetryPolicy, error: ABSError) async throws {
        var delay = min(policy.maxDelay, policy.baseDelay * pow(2, Double(attempt - 1)))
        if case .rateLimited(let retryAfter) = error, let retryAfter {
            delay = min(policy.maxDelay, retryAfter)
        }
        // Jitter keeps a screen full of simultaneously-failing cover requests from
        // retrying in lockstep.
        let jittered = delay * Double.random(in: 0.7...1.3)
        try await Task.sleep(for: .seconds(jittered))
    }

    private func applyStandardHeaders(to request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(DeviceIdentity.userAgent, forHTTPHeaderField: "User-Agent")
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ABSError.transport(underlying: "Malformed response", isOffline: false)
        }
        switch http.statusCode {
        case 200...299:
            return
        case 401:
            throw ABSError.unauthorized
        case 403:
            throw ABSError.forbidden
        case 404:
            throw ABSError.notFound
        case 429:
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            throw ABSError.rateLimited(retryAfter: retryAfter)
        default:
            throw ABSError.server(status: http.statusCode, message: Self.errorMessage(from: data))
        }
    }

    /// Audiobookshelf returns errors as a bare string or `{"error": "..."}`.
    private static func errorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["error", "message"] {
                if let value = object[key] as? String, !value.isEmpty { return value }
            }
        }
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count < 300
        else { return nil }
        return text
    }
}
