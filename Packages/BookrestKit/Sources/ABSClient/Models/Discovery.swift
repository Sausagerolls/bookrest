import Foundation

/// One row on the server-built home screen (`/api/libraries/{id}/personalized`).
/// The `type` field decides what the entities actually are.
public struct PersonalizedShelf: Decodable, Identifiable, Sendable, Hashable {
    public enum Content: Hashable, Sendable {
        case items([LibraryItem])
        case series([Series])
        case authors([Author])
    }

    public let id: String
    public let label: String
    public let content: Content

    private enum CodingKeys: String, CodingKey {
        case id, label, type, entities
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, default: UUID().uuidString)
        label = c.lenient(.label, default: "")
        let type: String = c.lenient(.type, default: "book")
        switch type {
        case "series":
            content = .series(c.lenientArray(.entities))
        case "authors":
            content = .authors(c.lenientArray(.entities))
        default:
            content = .items(c.lenientArray(.entities))
        }
    }

    public var isEmpty: Bool {
        switch content {
        case .items(let values): values.isEmpty
        case .series(let values): values.isEmpty
        case .authors(let values): values.isEmpty
        }
    }
}

/// `GET /api/libraries/{id}/search`.
public struct SearchResults: Decodable, Sendable {
    public struct ItemMatch: Decodable, Sendable {
        public let libraryItem: LibraryItem
        public let matchKey: String?
        public let matchText: String?

        private enum CodingKeys: String, CodingKey { case libraryItem, matchKey, matchText }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            libraryItem = try c.decode(LibraryItem.self, forKey: .libraryItem)
            matchKey = c.lenient(.matchKey)
            matchText = c.lenient(.matchText)
        }
    }

    public struct SeriesMatch: Decodable, Sendable {
        public let series: Series
        public let books: [LibraryItem]

        private enum CodingKeys: String, CodingKey { case series, books }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            series = try c.decode(Series.self, forKey: .series)
            books = c.lenientArray(.books)
        }
    }

    public let books: [ItemMatch]
    public let podcasts: [ItemMatch]
    public let authors: [Author]
    public let series: [SeriesMatch]
    public let tags: [String]

    private enum CodingKeys: String, CodingKey {
        case book, podcast, authors, series, tags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        books = c.lenientArray(.book)
        podcasts = c.lenientArray(.podcast)
        authors = c.lenientArray(.authors)
        series = c.lenientArray(.series)
        tags = c.lenientArray(.tags)
    }

    public var isEmpty: Bool {
        books.isEmpty && podcasts.isEmpty && authors.isEmpty && series.isEmpty && tags.isEmpty
    }

    public static let empty = SearchResults()

    private init() {
        books = []
        podcasts = []
        authors = []
        series = []
        tags = []
    }
}
