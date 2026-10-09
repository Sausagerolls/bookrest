import Foundation

public struct AuthorRef: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String

    private enum CodingKeys: String, CodingKey { case id, name }

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, default: "")
        name = c.lenient(.name, default: "")
    }
}

public struct SeriesRef: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    /// Book number within the series. A string because Audiobookshelf allows "1.5", "II", etc.
    public let sequence: String?

    private enum CodingKeys: String, CodingKey { case id, name, sequence }

    public init(id: String, name: String, sequence: String?) {
        self.id = id
        self.name = name
        self.sequence = sequence
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, default: "")
        name = c.lenient(.name, default: "")
        sequence = c.lenient(.sequence)
    }

    /// Sorts "1.5" before "2" and "10" after "9", falling back to alphabetical.
    public var sortValue: Double? {
        guard let sequence else { return nil }
        return Double(sequence.trimmingCharacters(in: .whitespaces))
    }

    public var displayLabel: String {
        guard let sequence, !sequence.isEmpty else { return name }
        return "\(name) #\(sequence)"
    }
}

public struct BookMetadata: Decodable, Hashable, Sendable {
    public let title: String
    public let titleIgnorePrefix: String?
    public let subtitle: String?
    public let authors: [AuthorRef]
    public let narrators: [String]
    public let series: [SeriesRef]
    public let genres: [String]
    public let publishedYear: String?
    public let publisher: String?
    public let description: String?
    public let isbn: String?
    public let asin: String?
    public let language: String?
    public let explicit: Bool
    public let abridged: Bool

    /// Minified payloads send flattened name strings instead of the object arrays.
    private let authorNameFallback: String?
    private let narratorNameFallback: String?
    private let seriesNameFallback: String?

    private enum CodingKeys: String, CodingKey {
        case title, titleIgnorePrefix, subtitle, authors, narrators, series, genres
        case publishedYear, publisher, description, isbn, asin, language, explicit, abridged
        case authorName, narratorName, seriesName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.lenient(.title, default: "Untitled")
        titleIgnorePrefix = c.lenient(.titleIgnorePrefix)
        subtitle = c.lenient(.subtitle)
        authors = c.lenientArray(.authors)
        narrators = c.lenientArray(.narrators)
        // Series-filtered listings send a single object for the series being browsed.
        let seriesList: [SeriesRef] = c.lenientArray(.series)
        series = seriesList.isEmpty ? (c.lenientValue(.series) as SeriesRef?).map { [$0] } ?? [] : seriesList
        genres = c.lenientArray(.genres)
        publishedYear = c.lenient(.publishedYear)
        publisher = c.lenient(.publisher)
        description = c.lenient(.description)
        isbn = c.lenient(.isbn)
        asin = c.lenient(.asin)
        language = c.lenient(.language)
        explicit = c.lenient(.explicit, default: false)
        abridged = c.lenient(.abridged, default: false)
        authorNameFallback = c.lenient(.authorName)
        narratorNameFallback = c.lenient(.narratorName)
        seriesNameFallback = c.lenient(.seriesName)
    }

    /// Display author, preferring the structured list and falling back to the
    /// flattened string that minified responses provide.
    public var authorDisplay: String? {
        if !authors.isEmpty { return authors.map(\.name).joined(separator: ", ") }
        return authorNameFallback?.nilIfEmpty
    }

    public var narratorDisplay: String? {
        if !narrators.isEmpty { return narrators.joined(separator: ", ") }
        return narratorNameFallback?.nilIfEmpty
    }

    public var seriesDisplay: String? {
        if !series.isEmpty { return series.map(\.displayLabel).joined(separator: ", ") }
        return seriesNameFallback?.nilIfEmpty
    }

    /// Book number within one series. Falls back to parsing the flattened
    /// "Name #3, Other #1" string that minified payloads carry instead of `series`.
    public func sequence(inSeries seriesId: String, named seriesName: String?) -> String? {
        if let ref = series.first(where: { $0.id == seriesId }) { return ref.sequence?.nilIfEmpty }
        guard let seriesName, !seriesName.isEmpty, let flattened = seriesNameFallback,
              let marker = flattened.range(of: "\(seriesName) #") else { return nil }
        let rest = flattened[marker.upperBound...]
        let sequence = rest.prefix { $0 != "," }.trimmingCharacters(in: .whitespaces)
        return sequence.nilIfEmpty
    }

    /// Title used for alphabetical sorting; the server precomputes a version with
    /// leading articles moved to the end.
    public var sortTitle: String { titleIgnorePrefix ?? title }
}

public struct PodcastMetadata: Decodable, Hashable, Sendable {
    public let title: String
    public let author: String?
    public let description: String?
    public let genres: [String]
    public let feedUrl: String?
    public let language: String?
    public let explicit: Bool

    private enum CodingKeys: String, CodingKey {
        case title, author, description, genres, feedUrl, language, explicit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.lenient(.title, default: "Untitled")
        author = c.lenient(.author)
        description = c.lenient(.description)
        genres = c.lenientArray(.genres)
        feedUrl = c.lenient(.feedUrl)
        language = c.lenient(.language)
        explicit = c.lenient(.explicit, default: false)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
