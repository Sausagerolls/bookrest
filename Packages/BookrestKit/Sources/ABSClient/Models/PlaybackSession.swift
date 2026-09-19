import Foundation

public enum PlayMethod: Int, Decodable, Sendable {
    case directPlay = 0
    case transcode = 1
    case directStream = 2
    case local = 3

    public init(from decoder: Decoder) throws {
        let value = try? decoder.singleValueContainer().decode(Int.self)
        self = PlayMethod(rawValue: value ?? 0) ?? .directPlay
    }
}

/// The server's answer to "play this item": an ordered track list plus the
/// position to resume from. Everything the player needs comes from here.
public struct PlaybackSession: Decodable, Hashable, Identifiable, Sendable {
    public let id: String
    public let libraryItemId: String
    public let episodeId: String?
    public let mediaType: MediaType
    public let displayTitle: String
    public let displayAuthor: String?
    public let coverPath: String?
    public let duration: TimeInterval
    public let currentTime: TimeInterval
    public let playMethod: PlayMethod
    public let audioTracks: [AudioTrack]
    public let chapters: [Chapter]
    public let libraryId: String?

    private enum CodingKeys: String, CodingKey {
        case id, libraryItemId, episodeId, mediaType, displayTitle, displayAuthor
        case coverPath, duration, currentTime, playMethod, audioTracks, chapters, libraryId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, default: "")
        libraryItemId = c.lenient(.libraryItemId, default: "")
        episodeId = c.lenient(.episodeId)
        let raw: String = c.lenient(.mediaType, default: MediaType.book.rawValue)
        mediaType = MediaType(rawValue: raw) ?? .book
        displayTitle = c.lenient(.displayTitle, default: "")
        displayAuthor = c.lenient(.displayAuthor)
        coverPath = c.lenient(.coverPath)
        currentTime = c.lenient(.currentTime, default: 0)
        playMethod = c.lenientValue(.playMethod) ?? .directPlay
        audioTracks = c.lenientArray(.audioTracks)
        chapters = c.lenientArray(.chapters)
        libraryId = c.lenient(.libraryId)

        // Prefer the summed track durations: on a transcoded session the top-level
        // duration is occasionally rounded, and seeking maths must match the tracks.
        let tracks = audioTracks
        let trackTotal = tracks.reduce(0) { $0 + $1.duration }
        let declared: TimeInterval = c.lenient(.duration, default: 0)
        duration = trackTotal > 0 ? max(trackTotal, declared) : declared
    }

    public var isTranscoded: Bool { playMethod == .transcode }

    /// Locates the track containing an absolute item time, plus the offset into it.
    public func track(at time: TimeInterval) -> (track: AudioTrack, offset: TimeInterval)? {
        guard !audioTracks.isEmpty else { return nil }
        let clamped = min(max(0, time), max(0, duration - 0.001))
        if let match = audioTracks.first(where: { $0.timeRange.contains(clamped) }) {
            return (match, clamped - match.startOffset)
        }
        // Past the end of the last track (rounding drift) — pin to its final moment.
        guard let last = audioTracks.max(by: { $0.startOffset < $1.startOffset }) else { return nil }
        return (last, max(0, clamped - last.startOffset))
    }
}

/// Body for `POST /api/items/{id}/play`.
public struct PlayRequest: Encodable, Sendable {
    public struct DeviceInfo: Encodable, Sendable {
        public let deviceId: String
        public let clientName: String
        public let clientVersion: String
        public let manufacturer: String
        public let model: String
        public let sdkVersion: String?
    }

    public let deviceInfo: DeviceInfo
    public let supportedMimeTypes: [String]
    public let mediaPlayer: String
    public let forceDirectPlay: Bool
    public let forceTranscode: Bool

    public init(deviceInfo: DeviceInfo, supportedMimeTypes: [String],
                mediaPlayer: String, forceDirectPlay: Bool, forceTranscode: Bool) {
        self.deviceInfo = deviceInfo
        self.supportedMimeTypes = supportedMimeTypes
        self.mediaPlayer = mediaPlayer
        self.forceDirectPlay = forceDirectPlay
        self.forceTranscode = forceTranscode
    }
}

/// Body for `POST /api/session/{id}/sync` and `/close`.
public struct SessionSyncPayload: Encodable, Sendable {
    public let currentTime: TimeInterval
    public let timeListened: TimeInterval
    public let duration: TimeInterval

    public init(currentTime: TimeInterval, timeListened: TimeInterval, duration: TimeInterval) {
        self.currentTime = currentTime
        self.timeListened = timeListened
        self.duration = duration
    }
}

/// Body for `PATCH /api/me/progress/{libraryItemId}`.
public struct ProgressUpdatePayload: Encodable, Sendable {
    public let currentTime: TimeInterval?
    public let duration: TimeInterval?
    public let progress: Double?
    public let isFinished: Bool?

    public init(currentTime: TimeInterval? = nil, duration: TimeInterval? = nil,
                progress: Double? = nil, isFinished: Bool? = nil) {
        self.currentTime = currentTime
        self.duration = duration
        self.progress = progress
        self.isFinished = isFinished
    }
}
