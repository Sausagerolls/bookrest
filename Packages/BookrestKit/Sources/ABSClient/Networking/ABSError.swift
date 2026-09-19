import Foundation

public enum ABSError: LocalizedError, Sendable, Equatable {
    case invalidServerURL
    case missingAuthToken
    /// Credentials were rejected, or the session expired and could not be refreshed.
    case unauthorized
    case forbidden
    case notFound
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int, message: String?)
    case decoding(context: String)
    case transport(underlying: String, isOffline: Bool)
    case cancelled
    case noActiveSession
    case nothingToPlay
    /// The server still lists the item, but its files are gone from disk.
    case itemFilesMissing

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            "That doesn't look like a valid server address."
        case .missingAuthToken:
            "The server didn't return a login token."
        case .unauthorized:
            "Your session has expired. Please sign in again."
        case .forbidden:
            "Your account doesn't have permission to do that."
        case .notFound:
            "That item is no longer on the server."
        case .rateLimited:
            "The server is throttling requests. Try again shortly."
        case .server(let status, let message):
            message ?? "The server returned an error (\(status))."
        case .decoding:
            "The server sent a response Bookrest couldn't read."
        case .transport(_, let isOffline):
            isOffline
                ? "You're offline. Downloaded books are still available."
                : "Couldn't reach the server."
        case .cancelled:
            "Cancelled."
        case .noActiveSession:
            "There's no active playback session."
        case .nothingToPlay:
            "This item has no playable audio."
        case .itemFilesMissing:
            "The files for this item are missing from the server."
        }
    }

    /// Whether retrying the same request unchanged could plausibly succeed.
    public var isRetryable: Bool {
        switch self {
        case .transport(_, let isOffline): !isOffline
        case .rateLimited: true
        case .server(let status, _): status >= 500
        default: false
        }
    }

    /// Whether the failure means we should fall back to local/offline content.
    public var isOffline: Bool {
        if case .transport(_, let isOffline) = self { return isOffline }
        return false
    }

    public var requiresReauthentication: Bool {
        self == .unauthorized || self == .missingAuthToken
    }

    static func from(_ error: Error) -> ABSError {
        if let absError = error as? ABSError { return absError }
        if error is CancellationError { return .cancelled }

        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return .transport(underlying: error.localizedDescription, isOffline: false)
        }
        switch nsError.code {
        case NSURLErrorCancelled:
            return .cancelled
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost,
             NSURLErrorDataNotAllowed,
             NSURLErrorTimedOut,
             NSURLErrorInternationalRoamingOff:
            return .transport(underlying: nsError.localizedDescription, isOffline: true)
        default:
            return .transport(underlying: nsError.localizedDescription, isOffline: false)
        }
    }
}
