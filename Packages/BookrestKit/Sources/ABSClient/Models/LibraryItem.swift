import Foundation

public enum MediaType: String, Codable, Sendable, CaseIterable {
    case book
    case podcast
}

public struct PodcastEpisode: Decodable, Hashable, Identifiable, Sendable {
    public let id: String
    public let libraryItemId: String
    public let index: Int?
    public let season: String?
    public let episode: String?
    public let title: String
    public let subtitle: String?
    public let description: String?
    public let publishedAt: Date?
    public let duration: TimeInterval
    public let size: Int
    public let audioFile: AudioFile?
    public let chapters: [Chapter]

    private enum CodingKeys: String, CodingKey {
        case id, libraryItemId, index, season, episode, title, subtitle
        case description, publishedAt, duration, size, audioFile, chapters
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, default: "")
        libraryItemId = c.lenient(.libraryItemId, default: "")
        index = c.lenient(.index)
        season = c.lenient(.season)
        episode = c.lenient(.episode)
        title = c.lenient(.title, default: "Untitled Episode")
        subtitle = c.lenient(.subtitle)
        description = c.lenient(.description)
        publishedAt = ABSDate.from(milliseconds: c.lenient(.publishedAt))
        duration = c.lenient(.duration, default: 0)
        size = c.lenient(.size, default: 0)
        audioFile = c.lenientValue(.audioFile)
        chapters = c.lenientArray(.chapters)
    }
}

public struct BookMedia: Decodable, Hashable, Sendable {
    public let id: String
    public let metadata: BookMetadata
    public let coverPath: String?
    public let tags: [String]
    public let audioFiles: [AudioFile]
    public let chapters: [Chapter]
    public let duration: TimeInterval
    public let size: Int
    public let numTracks: Int
    public let numAudioFiles: Int
    public let numChapters: Int

    private enum CodingKeys: String, CodingKey {
        case id, metadata, coverPath, tags, audioFiles, chapters
        case duration, size, numTracks, numAudioFiles, numChapters
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, default: "")
        metadata = try c.decode(BookMetadata.self, forKey: .metadata)
        coverPath = c.lenient(.coverPath)
        tags = c.lenientArray(.tags)
        audioFiles = c.lenientArray(.audioFiles)
        chapters = c.lenientArray(.chapters)
        duration = c.lenient(.duration, default: 0)
        size = c.lenient(.size, default: 0)
        // Minified payloads send the counts; expanded ones send the arrays.
        let audioFilesLocal = audioFiles
        let chaptersLocal = chapters
        numTracks = c.lenient(.numTracks) ?? audioFilesLocal.count
        numAudioFiles = c.lenient(.numAudioFiles) ?? audioFilesLocal.count
        numChapters = c.lenient(.numChapters) ?? chaptersLocal.count
    }
}

public struct PodcastMedia: Decodable, Hashable, Sendable {
    public let id: String
    public let metadata: PodcastMetadata
    public let coverPath: String?
    public let tags: [String]
    public let episodes: [PodcastEpisode]
    public let numEpisodes: Int

    private enum CodingKeys: String, CodingKey {
        case id, metadata, coverPath, tags, episodes, numEpisodes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, default: "")
        metadata = try c.decode(PodcastMetadata.self, forKey: .metadata)
        coverPath = c.lenient(.coverPath)
        tags = c.lenientArray(.tags)
        episodes = c.lenientArray(.episodes)
        let episodesLocal = episodes
        numEpisodes = c.lenient(.numEpisodes) ?? episodesLocal.count
    }
}

public enum Media: Hashable, Sendable {
    case book(BookMedia)
    case podcast(PodcastMedia)

    public var book: BookMedia? {
        if case .book(let media) = self { return media }
        return nil
    }

    public var podcast: PodcastMedia? {
        if case .podcast(let media) = self { return media }
        return nil
    }
}

/// Present when a library listing was requested with `collapseseries=1`; the row
/// stands in for a whole series rather than a single book.
public struct CollapsedSeries: Decodable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let libraryItemIds: [String]
    public let numBooks: Int

    private enum CodingKeys: String, CodingKey {
        case id, name, libraryItemIds, numBooks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, default: "")
        name = c.lenient(.name, default: "")
        libraryItemIds = c.lenientArray(.libraryItemIds)
        let ids = libraryItemIds
        numBooks = c.lenient(.numBooks) ?? ids.count
    }
}

public struct LibraryItem: Decodable, Hashable, Identifiable, Sendable {
    public let id: String
    public let libraryId: String
    public let folderId: String?
    public let addedAt: Date?
    public let updatedAt: Date?
    public let isMissing: Bool
    public let isInvalid: Bool
    public let mediaType: MediaType
    public let media: Media
    public let numFiles: Int?
    public let size: Int?
    /// Some endpoints (personalized shelves, `include=progress`) inline the caller's progress.
    public let userMediaProgress: MediaProgress?
    public let collapsedSeries: CollapsedSeries?
    /// Series listings attach the book's number at the top level of the item, either as
    /// a bare `sequence` or, when filtering by series, as a `series` object.
    private let seriesSequence: String?
    private let filteredSeries: SeriesRef?

    private enum CodingKeys: String, CodingKey {
        case id, libraryId, folderId, addedAt, updatedAt, isMissing, isInvalid
        case mediaType, media, numFiles, size, userMediaProgress, collapsedSeries
        case seriesSequence = "sequence"
        case filteredSeries = "series"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, default: "")
        libraryId = c.lenient(.libraryId, default: "")
        folderId = c.lenient(.folderId)
        addedAt = ABSDate.from(milliseconds: c.lenient(.addedAt))
        updatedAt = ABSDate.from(milliseconds: c.lenient(.updatedAt))
        isMissing = c.lenient(.isMissing, default: false)
        isInvalid = c.lenient(.isInvalid, default: false)
        numFiles = c.lenient(.numFiles)
        size = c.lenient(.size)
        userMediaProgress = c.lenientValue(.userMediaProgress)
        collapsedSeries = c.lenientValue(.collapsedSeries)
        seriesSequence = c.lenient(.seriesSequence)
        filteredSeries = c.lenientValue(.filteredSeries)

        let rawMediaType: String = c.lenient(.mediaType, default: MediaType.book.rawValue)
        let resolvedType = MediaType(rawValue: rawMediaType) ?? .book
        mediaType = resolvedType

        switch resolvedType {
        case .book:
            media = .book(try c.decode(BookMedia.self, forKey: .media))
        case .podcast:
            media = .podcast(try c.decode(PodcastMedia.self, forKey: .media))
        }
    }
}

// MARK: - Unified display surface
//
// The UI shouldn't have to branch on book vs podcast for routine presentation,
// so every common field is projected here once.

extension LibraryItem {
    public var title: String {
        switch media {
        case .book(let media): media.metadata.title
        case .podcast(let media): media.metadata.title
        }
    }

    public var sortTitle: String {
        switch media {
        case .book(let media): media.metadata.sortTitle
        case .podcast(let media): media.metadata.title
        }
    }

    public var subtitle: String? {
        media.book?.metadata.subtitle
    }

    public var authorDisplay: String? {
        switch media {
        case .book(let media): media.metadata.authorDisplay
        case .podcast(let media): media.metadata.author?.nilIfEmpty
        }
    }

    public var narratorDisplay: String? { media.book?.metadata.narratorDisplay }

    public var seriesRefs: [SeriesRef] { media.book?.metadata.series ?? [] }

    public var seriesDisplay: String? { media.book?.metadata.seriesDisplay }

    /// Book number within the given series, from whichever field the payload carried.
    public func sequence(inSeries seriesId: String, named seriesName: String? = nil) -> String? {
        media.book?.metadata.sequence(inSeries: seriesId, named: seriesName)
            ?? filteredSeries.flatMap { $0.id == seriesId ? $0.sequence?.nilIfEmpty : nil }
            ?? seriesSequence?.nilIfEmpty
    }

    public var itemDescription: String? {
        switch media {
        case .book(let media): media.metadata.description
        case .podcast(let media): media.metadata.description
        }
    }

    public var genres: [String] {
        switch media {
        case .book(let media): media.metadata.genres
        case .podcast(let media): media.metadata.genres
        }
    }

    public var tags: [String] {
        switch media {
        case .book(let media): media.tags
        case .podcast(let media): media.tags
        }
    }

    public var duration: TimeInterval {
        switch media {
        case .book(let media): media.duration
        case .podcast(let media): media.episodes.reduce(0) { $0 + $1.duration }
        }
    }

    public var chapters: [Chapter] { media.book?.chapters ?? [] }

    public var explicit: Bool {
        switch media {
        case .book(let media): media.metadata.explicit
        case .podcast(let media): media.metadata.explicit
        }
    }

    public var publishedYear: String? { media.book?.metadata.publishedYear }

    public var publisher: String? { media.book?.metadata.publisher }

    public var isPlayable: Bool {
        guard !isMissing, !isInvalid else { return false }
        switch media {
        case .book(let media): return media.numTracks > 0 || media.duration > 0
        case .podcast(let media): return media.numEpisodes > 0
        }
    }

    /// A collapsed-series row is a navigation affordance, not something to play.
    public var isCollapsedSeries: Bool { collapsedSeries != nil }
}
