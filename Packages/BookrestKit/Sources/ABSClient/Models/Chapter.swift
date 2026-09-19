import Foundation

public struct Chapter: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let start: TimeInterval
    public let end: TimeInterval
    public let title: String

    public init(id: Int, start: TimeInterval, end: TimeInterval, title: String) {
        self.id = id
        self.start = start
        self.end = end
        self.title = title
    }

    private enum CodingKeys: String, CodingKey { case id, start, end, title }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, default: 0)
        start = c.lenient(.start, default: 0)
        end = c.lenient(.end, default: 0)
        title = c.lenient(.title, default: "")
    }

    public var duration: TimeInterval { max(0, end - start) }

    public func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }
}
