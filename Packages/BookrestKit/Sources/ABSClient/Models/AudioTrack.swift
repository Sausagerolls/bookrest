import Foundation

/// One playable track in a playback session. `contentUrl` is server-relative:
/// `/api/items/{itemId}/file/{ino}` for direct play, or an HLS playlist when the
/// server decided to transcode.
public struct AudioTrack: Codable, Hashable, Identifiable, Sendable {
    public let index: Int
    public let startOffset: TimeInterval
    public let duration: TimeInterval
    public let title: String
    public let contentUrl: String
    public let mimeType: String
    public let codec: String?

    public var id: Int { index }

    private enum CodingKeys: String, CodingKey {
        case index, startOffset, duration, title, contentUrl, mimeType, codec
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = c.lenient(.index, default: 0)
        startOffset = c.lenient(.startOffset, default: 0)
        duration = c.lenient(.duration, default: 0)
        title = c.lenient(.title, default: "")
        contentUrl = c.lenient(.contentUrl, default: "")
        mimeType = c.lenient(.mimeType, default: "")
        codec = c.lenient(.codec)
    }

    public init(index: Int, startOffset: TimeInterval, duration: TimeInterval,
                title: String, contentUrl: String, mimeType: String, codec: String? = nil) {
        self.index = index
        self.startOffset = startOffset
        self.duration = duration
        self.title = title
        self.contentUrl = contentUrl
        self.mimeType = mimeType
        self.codec = codec
    }

    public var isHLS: Bool {
        mimeType == "application/vnd.apple.mpegurl" || contentUrl.hasSuffix(".m3u8")
    }

    /// The absolute range this track covers within the whole item's timeline.
    public var timeRange: Range<TimeInterval> {
        startOffset ..< (startOffset + duration)
    }
}
