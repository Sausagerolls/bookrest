import Foundation
import ABSClient

/// A single audio file that has been (or is being) downloaded for offline playback.
public struct OfflineTrack: Codable, Sendable, Hashable, Identifiable {
    public let index: Int
    public let startOffset: TimeInterval
    public let duration: TimeInterval
    /// Name of the file inside the item's offline folder.
    public let fileName: String
    public let mimeType: String
    public var bytesDownloaded: Int64
    public var expectedBytes: Int64
    public var isComplete: Bool

    public var id: Int { index }

    public init(index: Int, startOffset: TimeInterval, duration: TimeInterval,
                fileName: String, mimeType: String, bytesDownloaded: Int64 = 0,
                expectedBytes: Int64 = 0, isComplete: Bool = false) {
        self.index = index
        self.startOffset = startOffset
        self.duration = duration
        self.fileName = fileName
        self.mimeType = mimeType
        self.bytesDownloaded = bytesDownloaded
        self.expectedBytes = expectedBytes
        self.isComplete = isComplete
    }

    public var timeRange: Range<TimeInterval> { startOffset ..< (startOffset + duration) }
}

public enum OfflineState: Codable, Sendable, Hashable {
    case queued
    case downloading
    case paused
    case completed
    case failed(reason: String)

    public var isActive: Bool { self == .queued || self == .downloading }
    public var isComplete: Bool { self == .completed }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Everything needed to browse and play an item with no server reachable.
public struct OfflineItem: Codable, Sendable, Hashable, Identifiable {
    /// `itemId` for books, `itemId/episodeId` for podcast episodes.
    public let key: String
    public let itemId: String
    public let episodeId: String?
    public let libraryId: String
    public let mediaType: MediaType

    public var title: String
    public var author: String?
    public var narrator: String?
    public var seriesLabel: String?
    public var itemDescription: String?
    public var duration: TimeInterval

    public var tracks: [OfflineTrack]
    public var chapters: [Chapter]
    public var coverFileName: String?

    public var state: OfflineState
    public var downloadedAt: Date
    public var lastError: String?

    public var id: String { key }

    public init(key: String, itemId: String, episodeId: String?, libraryId: String,
                mediaType: MediaType, title: String, author: String?, narrator: String?,
                seriesLabel: String?, itemDescription: String?, duration: TimeInterval,
                tracks: [OfflineTrack], chapters: [Chapter], coverFileName: String?,
                state: OfflineState, downloadedAt: Date, lastError: String? = nil) {
        self.key = key
        self.itemId = itemId
        self.episodeId = episodeId
        self.libraryId = libraryId
        self.mediaType = mediaType
        self.title = title
        self.author = author
        self.narrator = narrator
        self.seriesLabel = seriesLabel
        self.itemDescription = itemDescription
        self.duration = duration
        self.tracks = tracks
        self.chapters = chapters
        self.coverFileName = coverFileName
        self.state = state
        self.downloadedAt = downloadedAt
        self.lastError = lastError
    }

    public var bytesDownloaded: Int64 { tracks.reduce(0) { $0 + $1.bytesDownloaded } }
    public var expectedBytes: Int64 { tracks.reduce(0) { $0 + max($1.expectedBytes, $1.bytesDownloaded) } }

    public var progress: Double {
        // Fall back to counting finished files when the server sent no content length.
        let expected = expectedBytes
        guard expected > 0 else {
            guard !tracks.isEmpty else { return 0 }
            return Double(tracks.filter(\.isComplete).count) / Double(tracks.count)
        }
        return min(1, Double(bytesDownloaded) / Double(expected))
    }

    public var isPlayableOffline: Bool {
        state == .completed && !tracks.isEmpty && tracks.allSatisfy(\.isComplete)
    }
}

/// Listening position held on-device. This is the source of truth while offline and
/// is reconciled with the server by `ProgressCoordinator`.
public struct LocalProgress: Codable, Sendable, Hashable, Identifiable {
    public let key: String
    public let itemId: String
    public let episodeId: String?
    public var currentTime: TimeInterval
    public var duration: TimeInterval
    public var isFinished: Bool
    public var updatedAt: Date
    /// Listening time accumulated since the last successful server sync.
    public var pendingTimeListened: TimeInterval
    /// Set when the position changed locally and the server hasn't accepted it yet.
    public var needsSync: Bool

    public var id: String { key }

    public init(key: String, itemId: String, episodeId: String?, currentTime: TimeInterval,
                duration: TimeInterval, isFinished: Bool, updatedAt: Date,
                pendingTimeListened: TimeInterval = 0, needsSync: Bool = false) {
        self.key = key
        self.itemId = itemId
        self.episodeId = episodeId
        self.currentTime = currentTime
        self.duration = duration
        self.isFinished = isFinished
        self.updatedAt = updatedAt
        self.pendingTimeListened = pendingTimeListened
        self.needsSync = needsSync
    }

    public var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    /// Begun but not finished — the state that earns a "Resume" button.
    public var isStarted: Bool { currentTime > 0 && !isFinished }

    public var remaining: TimeInterval { max(0, duration - currentTime) }

    public init(server: MediaProgress) {
        self.init(
            key: server.key,
            itemId: server.libraryItemId,
            episodeId: server.episodeId,
            currentTime: server.currentTime,
            duration: server.duration,
            isFinished: server.isEffectivelyFinished,
            updatedAt: server.lastUpdate ?? .distantPast,
            pendingTimeListened: 0,
            needsSync: false
        )
    }
}
