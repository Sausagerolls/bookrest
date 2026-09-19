import Foundation

/// The server's view of how far through an item the user is. Podcast progress is
/// per-episode, so `episodeId` participates in identity.
public struct MediaProgress: Decodable, Hashable, Sendable, Identifiable {
    public let id: String
    public let libraryItemId: String
    public let episodeId: String?
    public let duration: TimeInterval
    public let progress: Double
    public let currentTime: TimeInterval
    public let isFinished: Bool
    public let hideFromContinueListening: Bool
    public let lastUpdate: Date?
    public let startedAt: Date?
    public let finishedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, libraryItemId, episodeId, duration, progress, currentTime
        case isFinished, hideFromContinueListening, lastUpdate, startedAt, finishedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        libraryItemId = c.lenient(.libraryItemId, default: "")
        episodeId = c.lenient(.episodeId)
        let itemId = libraryItemId
        let epId = episodeId
        id = c.lenient(.id) ?? MediaProgress.key(itemId: itemId, episodeId: epId)
        duration = c.lenient(.duration, default: 0)
        progress = c.lenient(.progress, default: 0)
        currentTime = c.lenient(.currentTime, default: 0)
        isFinished = c.lenient(.isFinished, default: false)
        hideFromContinueListening = c.lenient(.hideFromContinueListening, default: false)
        lastUpdate = ABSDate.from(milliseconds: c.lenient(.lastUpdate))
        startedAt = ABSDate.from(milliseconds: c.lenient(.startedAt))
        finishedAt = ABSDate.from(milliseconds: c.lenient(.finishedAt))
    }

    public init(libraryItemId: String, episodeId: String?, duration: TimeInterval,
                progress: Double, currentTime: TimeInterval, isFinished: Bool,
                lastUpdate: Date?) {
        self.id = MediaProgress.key(itemId: libraryItemId, episodeId: episodeId)
        self.libraryItemId = libraryItemId
        self.episodeId = episodeId
        self.duration = duration
        self.progress = progress
        self.currentTime = currentTime
        self.isFinished = isFinished
        self.hideFromContinueListening = false
        self.lastUpdate = lastUpdate
        self.startedAt = nil
        self.finishedAt = nil
    }

    /// Stable local key. Podcasts track progress per episode, books per item.
    public static func key(itemId: String, episodeId: String?) -> String {
        if let episodeId, !episodeId.isEmpty { return "\(itemId)/\(episodeId)" }
        return itemId
    }

    public var key: String { MediaProgress.key(itemId: libraryItemId, episodeId: episodeId) }

    /// Treat the last few seconds as finished — matches how the server rounds.
    public var isEffectivelyFinished: Bool {
        isFinished || progress >= 0.99
    }

    public var isStarted: Bool { currentTime > 0 && !isEffectivelyFinished }

    public var remaining: TimeInterval { max(0, duration - currentTime) }
}
