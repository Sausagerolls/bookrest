import Foundation

public struct AudioFile: Decodable, Hashable, Sendable {
    public let index: Int
    public let ino: String
    public let duration: TimeInterval
    public let mimeType: String?
    public let codec: String?
    public let filename: String?

    private enum CodingKeys: String, CodingKey {
        case index, ino, duration, mimeType, codec, metadata
    }

    private enum MetadataKeys: String, CodingKey {
        case filename
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = c.lenient(.index, default: 0)
        ino = c.lenient(.ino, default: "")
        duration = c.lenient(.duration, default: 0)
        mimeType = c.lenient(.mimeType)
        codec = c.lenient(.codec)
        let metadata = try? c.nestedContainer(keyedBy: MetadataKeys.self, forKey: .metadata)
        filename = metadata?.lenient(.filename)
    }
}
