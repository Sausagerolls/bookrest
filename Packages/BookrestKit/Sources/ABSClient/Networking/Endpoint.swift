import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case patch = "PATCH"
    case put = "PUT"
    case delete = "DELETE"
}

struct Endpoint: Sendable {
    var path: String
    var method: HTTPMethod = .get
    var query: [URLQueryItem] = []
    var body: Data?
    var headers: [String: String] = [:]
    var requiresAuth: Bool = true
    /// Endpoints that must not be retried automatically because replaying them
    /// could double-count listening time or reopen a closed session.
    var isIdempotent: Bool = true

    static func get(_ path: String, query: [URLQueryItem] = []) -> Endpoint {
        Endpoint(path: path, method: .get, query: query.filter { $0.value != nil })
    }

    static func post(_ path: String, body: Data? = nil, idempotent: Bool = false) -> Endpoint {
        Endpoint(path: path, method: .post, body: body, isIdempotent: idempotent)
    }

    static func patch(_ path: String, body: Data? = nil) -> Endpoint {
        Endpoint(path: path, method: .patch, body: body, isIdempotent: true)
    }

    static func encoding<T: Encodable>(_ value: T, to path: String,
                                       method: HTTPMethod = .post,
                                       idempotent: Bool = false) throws -> Endpoint {
        let encoder = JSONEncoder()
        var endpoint = Endpoint(path: path, method: method, body: try encoder.encode(value))
        endpoint.headers["Content-Type"] = "application/json"
        endpoint.isIdempotent = idempotent
        return endpoint
    }

    func url(relativeTo baseURL: URL) throws -> URL {
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ABSError.invalidServerURL
        }
        // Servers behind a reverse proxy are often mounted on a sub-path, so the
        // base path has to be preserved rather than replaced.
        components.path = components.path.hasSuffix("/")
            ? String(components.path.dropLast()) + normalizedPath
            : components.path + normalizedPath
        if !query.isEmpty { components.queryItems = query }

        guard let url = components.url else { throw ABSError.invalidServerURL }
        return url
    }
}

extension URLQueryItem {
    static func optional(_ name: String, _ value: String?) -> URLQueryItem {
        URLQueryItem(name: name, value: value)
    }

    static func flag(_ name: String, _ value: Bool) -> URLQueryItem {
        URLQueryItem(name: name, value: value ? "1" : "0")
    }

    static func number(_ name: String, _ value: Int) -> URLQueryItem {
        URLQueryItem(name: name, value: String(value))
    }
}
