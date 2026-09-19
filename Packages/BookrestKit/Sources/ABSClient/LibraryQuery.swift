import Foundation

public enum LibrarySort: String, Sendable, CaseIterable, Identifiable {
    case title
    case author
    case addedAt
    case publishedYear
    case duration
    case seriesSequence
    case size

    public var id: String { rawValue }

    var apiValue: String {
        switch self {
        case .title: "media.metadata.titleIgnorePrefix"
        case .author: "media.metadata.authorNameLF"
        case .addedAt: "addedAt"
        case .publishedYear: "media.metadata.publishedYear"
        case .duration: "media.duration"
        case .seriesSequence: "sequence"
        case .size: "size"
        }
    }

    public var displayName: String {
        switch self {
        case .title: "Title"
        case .author: "Author"
        case .addedAt: "Recently Added"
        case .publishedYear: "Publish Year"
        case .duration: "Duration"
        case .seriesSequence: "Series Order"
        case .size: "File Size"
        }
    }

    /// Newest-first and longest-first read better as defaults than their ascending forms.
    public var defaultsToDescending: Bool {
        self == .addedAt || self == .duration || self == .size
    }
}

/// Audiobookshelf encodes filters as `group.base64(value)`.
public enum LibraryFilter: Sendable, Hashable {
    case series(String)
    case author(String)
    case genre(String)
    case tag(String)
    case narrator(String)
    case progress(ProgressState)
    case all

    public enum ProgressState: String, Sendable, CaseIterable, Identifiable {
        case finished
        case inProgress = "in-progress"
        case notStarted = "not-started"
        case notFinished = "not-finished"

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .finished: "Finished"
            case .inProgress: "In Progress"
            case .notStarted: "Not Started"
            case .notFinished: "Not Finished"
            }
        }
    }

    var apiValue: String {
        switch self {
        case .series(let value): "series.\(Self.encode(value))"
        case .author(let value): "authors.\(Self.encode(value))"
        case .genre(let value): "genres.\(Self.encode(value))"
        case .tag(let value): "tags.\(Self.encode(value))"
        case .narrator(let value): "narrators.\(Self.encode(value))"
        case .progress(let state): "progress.\(Self.encode(state.rawValue))"
        case .all: "all"
        }
    }

    /// The server decodes these with `atob`, so standard padded base64 is required.
    private static func encode(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }
}
