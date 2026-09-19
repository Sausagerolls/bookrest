import Foundation
import ABSClient

/// One continuous audio file within an item's timeline, already resolved to a
/// playable URL — either a server stream or a downloaded file.
public struct PlayableTrack: Sendable, Hashable, Identifiable {
    public let index: Int
    public let startOffset: TimeInterval
    public let duration: TimeInterval
    public let url: URL
    public let isLocal: Bool

    public var id: Int { index }
    public var timeRange: Range<TimeInterval> { startOffset ..< (startOffset + duration) }

    public init(index: Int, startOffset: TimeInterval, duration: TimeInterval, url: URL, isLocal: Bool) {
        self.index = index
        self.startOffset = startOffset
        self.duration = duration
        self.url = url
        self.isLocal = isLocal
    }
}

/// Everything the player needs to present and play one item.
public struct PlaybackContext: Sendable, Hashable, Identifiable {
    public let key: String
    public let itemId: String
    public let episodeId: String?
    public let libraryId: String
    public let title: String
    public let author: String?
    public let narrator: String?
    public let coverURL: URL?
    public let localCoverURL: URL?
    public let chapters: [Chapter]
    public let tracks: [PlayableTrack]
    public let duration: TimeInterval
    /// Nil for offline playback; otherwise the server session to report progress against.
    public let serverSessionId: String?
    public let isOffline: Bool
    /// Where the server thinks the listener is. Used only when there's no local
    /// position — on a fresh install, or when a progress refresh hasn't landed yet.
    public let serverResumeTime: TimeInterval

    public var id: String { key }

    public init(key: String, itemId: String, episodeId: String?, libraryId: String,
                title: String, author: String?, narrator: String?, coverURL: URL?,
                localCoverURL: URL?, chapters: [Chapter], tracks: [PlayableTrack],
                duration: TimeInterval, serverSessionId: String?, isOffline: Bool,
                serverResumeTime: TimeInterval = 0) {
        self.key = key
        self.itemId = itemId
        self.episodeId = episodeId
        self.libraryId = libraryId
        self.title = title
        self.author = author
        self.narrator = narrator
        self.coverURL = coverURL
        self.localCoverURL = localCoverURL
        self.chapters = chapters
        self.tracks = tracks
        self.duration = duration
        self.serverSessionId = serverSessionId
        self.isOffline = isOffline
        self.serverResumeTime = serverResumeTime
    }

    public func chapter(at time: TimeInterval) -> Chapter? {
        chapters.first { $0.contains(time) } ?? chapters.last { $0.start <= time }
    }

    /// Where playback should start.
    ///
    /// A real local position always wins — it's the newest thing that happened on
    /// this device. Only when there is none does the server's position apply, which
    /// matters on a fresh install or before the first progress refresh lands.
    public func resumePosition(local: LocalProgress?) -> TimeInterval {
        let cap = max(0, duration - 1)
        guard let local else { return min(max(0, serverResumeTime), cap) }
        if local.isFinished { return 0 }
        guard local.currentTime > 0 else { return min(max(0, serverResumeTime), cap) }
        return min(local.currentTime, cap)
    }

    public func track(at time: TimeInterval) -> PlayableTrack? {
        let clamped = min(max(0, time), max(0, duration - 0.01))
        if let match = tracks.first(where: { $0.timeRange.contains(clamped) }) { return match }
        return tracks.last
    }
}

public enum PlaybackStatus: Sendable, Equatable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case buffering
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .idle, .failed: false
        default: true
        }
    }
}

/// Playback speed, constrained to values that stay intelligible.
public struct PlaybackRate: Sendable, Hashable {
    public static let options: [Float] = [0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    public static let `default`: Float = 1.0

    public static func clamp(_ value: Float) -> Float {
        min(max(0.5, value), 3.0)
    }

    public static func format(_ value: Float) -> String {
        value == value.rounded() ? String(format: "%.0f×", value) : String(format: "%g×", value)
    }
}

public enum SkipInterval: Int, Sendable, CaseIterable, Identifiable {
    case ten = 10
    case fifteen = 15
    case twenty = 20
    case thirty = 30
    case sixty = 60

    public var id: Int { rawValue }
    public var seconds: TimeInterval { TimeInterval(rawValue) }
    public var displayName: String { "\(rawValue)s" }
}
