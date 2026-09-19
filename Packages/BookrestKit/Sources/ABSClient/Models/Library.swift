import Foundation

public struct Library: Decodable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let displayOrder: Int
    public let icon: String?
    public let mediaType: MediaType
    public let provider: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, displayOrder, icon, mediaType, provider
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, default: "")
        name = c.lenient(.name, default: "Library")
        displayOrder = c.lenient(.displayOrder, default: 0)
        icon = c.lenient(.icon)
        let raw: String = c.lenient(.mediaType, default: MediaType.book.rawValue)
        mediaType = MediaType(rawValue: raw) ?? .book
        provider = c.lenient(.provider)
    }

    /// Maps the server's icon name onto an SF Symbol, since they don't line up.
    public var systemImage: String {
        switch icon {
        case "audiobookshelf", "books-1", "books-2", "book-1": "books.vertical"
        case "podcast": "antenna.radiowaves.left.and.right"
        case "microphone-1", "microphone-2": "mic"
        case "radio": "radio"
        case "database": "externaldrive"
        case "file-picture": "photo"
        case "rocket": "paperplane"
        case "power": "bolt"
        case "star": "star"
        case "heart": "heart"
        default: mediaType == .podcast ? "antenna.radiowaves.left.and.right" : "books.vertical"
        }
    }
}

/// Standard paged envelope used by items, series and collections endpoints.
public struct Page<Element: Decodable & Sendable>: Decodable, Sendable {
    public let results: [Element]
    public let total: Int
    public let limit: Int
    public let page: Int

    private enum CodingKeys: String, CodingKey {
        case results, total, limit, page
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = c.lenientArray(.results)
        let count = results.count
        total = c.lenient(.total) ?? count
        limit = c.lenient(.limit, default: count)
        page = c.lenient(.page, default: 0)
    }

    public init(results: [Element], total: Int, limit: Int, page: Int) {
        self.results = results
        self.total = total
        self.limit = limit
        self.page = page
    }

    /// Whether another page exists, derived rather than trusted from a flag the
    /// server doesn't always send.
    public var hasMore: Bool {
        guard limit > 0 else { return false }
        return (page + 1) * limit < total
    }

    public static var empty: Page<Element> { Page(results: [], total: 0, limit: 0, page: 0) }
}

public struct Series: Decodable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let nameIgnorePrefix: String?
    public let description: String?
    public let books: [LibraryItem]
    public let totalDuration: TimeInterval
    public let addedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, name, nameIgnorePrefix, description, books, totalDuration, addedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, default: "")
        name = c.lenient(.name, default: "")
        nameIgnorePrefix = c.lenient(.nameIgnorePrefix)
        description = c.lenient(.description)
        books = c.lenientArray(.books)
        let loaded = books
        totalDuration = c.lenient(.totalDuration) ?? loaded.reduce(0) { $0 + $1.duration }
        addedAt = ABSDate.from(milliseconds: c.lenient(.addedAt))
    }

    public var sortName: String { nameIgnorePrefix ?? name }
    public var bookCount: Int { books.count }

    /// Series order as the author intended: by sequence number where present,
    /// then by title for the unnumbered stragglers.
    public var orderedBooks: [LibraryItem] {
        books.sorted { lhs, rhs in
            let l = lhs.seriesRefs.first(where: { $0.id == id })?.sortValue
            let r = rhs.seriesRefs.first(where: { $0.id == id })?.sortValue
            switch (l, r) {
            case let (l?, r?) where l != r: return l < r
            case (nil, .some): return false
            case (.some, nil): return true
            default: return lhs.sortTitle.localizedStandardCompare(rhs.sortTitle) == .orderedAscending
            }
        }
    }
}

public struct Author: Decodable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let imagePath: String?
    public let numBooks: Int
    public let libraryItems: [LibraryItem]

    private enum CodingKeys: String, CodingKey {
        case id, name, description, imagePath, numBooks, libraryItems
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, default: "")
        name = c.lenient(.name, default: "")
        description = c.lenient(.description)
        imagePath = c.lenient(.imagePath)
        libraryItems = c.lenientArray(.libraryItems)
        let items = libraryItems
        numBooks = c.lenient(.numBooks) ?? items.count
    }

    public var hasImage: Bool { !(imagePath ?? "").isEmpty }
}

public struct AuthorsResponse: Decodable, Sendable {
    public let authors: [Author]

    private enum CodingKeys: String, CodingKey { case authors }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        authors = c.lenientArray(.authors)
    }
}

public struct LibrariesResponse: Decodable, Sendable {
    public let libraries: [Library]

    private enum CodingKeys: String, CodingKey { case libraries }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        libraries = c.lenientArray(.libraries)
    }
}

public struct BookCollection: Decodable, Hashable, Identifiable, Sendable {
    public let id: String
    public let libraryId: String
    public let name: String
    public let description: String?
    public let books: [LibraryItem]

    private enum CodingKeys: String, CodingKey {
        case id, libraryId, name, description, books
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, default: "")
        libraryId = c.lenient(.libraryId, default: "")
        name = c.lenient(.name, default: "")
        description = c.lenient(.description)
        books = c.lenientArray(.books)
    }
}

public struct CollectionsResponse: Decodable, Sendable {
    public let collections: [BookCollection]

    private enum CodingKeys: String, CodingKey { case results, collections }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Older servers return `collections`, newer ones the paged `results`.
        let paged: [BookCollection] = c.lenientArray(.results)
        collections = paged.isEmpty ? c.lenientArray(.collections) : paged
    }
}
