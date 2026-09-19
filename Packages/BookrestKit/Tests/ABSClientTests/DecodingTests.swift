import Testing
import Foundation
@testable import ABSClient

/// Audiobookshelf's JSON varies by server version and by whether a response is
/// "minified". These pin the shapes the app actually has to survive.
struct DecodingTests {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test("Expanded book item decodes with chapters and audio files")
    func expandedBook() throws {
        let item = try decode(LibraryItem.self, """
        {
          "id": "li_abc", "libraryId": "lib_1", "mediaType": "book",
          "addedAt": 1650621073750, "updatedAt": 1650621073750,
          "media": {
            "id": "bk_1",
            "metadata": {
              "title": "The Fellowship of the Ring",
              "titleIgnorePrefix": "Fellowship of the Ring, The",
              "authors": [{"id": "aut_1", "name": "J.R.R. Tolkien"}],
              "narrators": ["Rob Inglis"],
              "series": [{"id": "ser_1", "name": "The Lord of the Rings", "sequence": "1"}],
              "genres": ["Fantasy"], "publishedYear": "1954", "explicit": false
            },
            "coverPath": "/covers/1.jpg",
            "audioFiles": [{"index": 1, "ino": "9981", "duration": 1200.5, "mimeType": "audio/mpeg"}],
            "chapters": [
              {"id": 0, "start": 0, "end": 600, "title": "Chapter 1"},
              {"id": 1, "start": 600, "end": 1200.5, "title": "Chapter 2"}
            ],
            "duration": 1200.5, "size": 1234
          }
        }
        """)

        #expect(item.id == "li_abc")
        #expect(item.title == "The Fellowship of the Ring")
        #expect(item.sortTitle == "Fellowship of the Ring, The")
        #expect(item.authorDisplay == "J.R.R. Tolkien")
        #expect(item.narratorDisplay == "Rob Inglis")
        #expect(item.seriesDisplay == "The Lord of the Rings #1")
        #expect(item.chapters.count == 2)
        #expect(item.media.book?.audioFiles.first?.ino == "9981")
        #expect(item.duration == 1200.5)
        #expect(item.isPlayable)
    }

    @Test("Minified item falls back to flattened name strings")
    func minifiedBook() throws {
        // The listing endpoint sends `authorName`/`narratorName` instead of arrays.
        let item = try decode(LibraryItem.self, """
        {
          "id": "li_min", "libraryId": "lib_1", "mediaType": "book",
          "media": {
            "id": "bk_2",
            "metadata": {
              "title": "Dune", "authorName": "Frank Herbert",
              "narratorName": "Scott Brick", "seriesName": "Dune #1"
            },
            "duration": 777, "numTracks": 3
          }
        }
        """)

        #expect(item.authorDisplay == "Frank Herbert")
        #expect(item.narratorDisplay == "Scott Brick")
        #expect(item.seriesDisplay == "Dune #1")
        #expect(item.media.book?.numTracks == 3)
        #expect(item.chapters.isEmpty)
    }

    @Test("Numbers arriving as strings still decode")
    func lenientNumbers() throws {
        let chapter = try decode(Chapter.self, """
        {"id": "3", "start": "12.5", "end": 40, "title": "Odd Types"}
        """)
        #expect(chapter.id == 3)
        #expect(chapter.start == 12.5)
        #expect(chapter.duration == 27.5)
    }

    @Test("Missing and null fields never fail the whole item")
    func missingFields() throws {
        let item = try decode(LibraryItem.self, """
        {
          "id": "li_sparse", "mediaType": "book",
          "media": {"metadata": {"title": "Sparse"}, "tags": null, "chapters": null}
        }
        """)
        #expect(item.title == "Sparse")
        #expect(item.libraryId == "")
        #expect(item.tags.isEmpty)
        #expect(item.chapters.isEmpty)
        #expect(!item.isPlayable)
    }

    @Test("Podcast items decode into episodes")
    func podcast() throws {
        let item = try decode(LibraryItem.self, """
        {
          "id": "li_pod", "libraryId": "lib_2", "mediaType": "podcast",
          "media": {
            "id": "pod_1",
            "metadata": {"title": "A Show", "author": "Someone"},
            "episodes": [
              {"id": "ep_1", "libraryItemId": "li_pod", "title": "Episode One",
               "duration": 300, "publishedAt": 1650621073750,
               "audioFile": {"index": 1, "ino": "77", "duration": 300}}
            ]
          }
        }
        """)

        #expect(item.mediaType == .podcast)
        #expect(item.authorDisplay == "Someone")
        #expect(item.media.podcast?.episodes.first?.title == "Episode One")
        #expect(item.media.podcast?.numEpisodes == 1)
        #expect(item.duration == 300)
    }

    @Test("Login accepts both modern accessToken and legacy token")
    func loginTokens() throws {
        let modern = try decode(LoginResponse.self, """
        {"user": {"id": "u1", "username": "jo", "accessToken": "new", "refreshToken": "r1"},
         "userDefaultLibraryId": "lib_1", "serverSettings": {"version": "2.26.0"}}
        """)
        #expect(modern.accessToken == "new")
        #expect(modern.refreshToken == "r1")
        #expect(modern.serverVersion == "2.26.0")

        // Servers before 2.26 issue a single non-expiring `token`.
        let legacy = try decode(LoginResponse.self, """
        {"user": {"id": "u1", "username": "jo", "token": "old"}}
        """)
        #expect(legacy.accessToken == "old")
        #expect(legacy.refreshToken == nil)
    }

    @Test("Personalized shelves resolve their entity type")
    func shelves() throws {
        let shelves = try decode([PersonalizedShelf].self, """
        [
          {"id": "continue-listening", "label": "Continue", "type": "book",
           "entities": [{"id": "li_1", "mediaType": "book", "media": {"metadata": {"title": "A"}}}]},
          {"id": "recent-series", "label": "Series", "type": "series",
           "entities": [{"id": "ser_1", "name": "S", "books": []}]},
          {"id": "authors", "label": "Authors", "type": "authors",
           "entities": [{"id": "aut_1", "name": "Writer", "numBooks": 4}]}
        ]
        """)

        #expect(shelves.count == 3)
        if case .items(let items) = shelves[0].content { #expect(items.count == 1) } else { Issue.record("expected items") }
        if case .series(let series) = shelves[1].content { #expect(series.first?.name == "S") } else { Issue.record("expected series") }
        if case .authors(let authors) = shelves[2].content { #expect(authors.first?.numBooks == 4) } else { Issue.record("expected authors") }
    }

    @Test("Paging derives hasMore rather than trusting a flag")
    func paging() throws {
        let page = try decode(Page<LibraryItem>.self, """
        {"results": [], "total": 120, "limit": 50, "page": 1}
        """)
        // Pages 0 and 1 cover 100 of 120, so a third page exists.
        #expect(page.hasMore)

        let last = try decode(Page<LibraryItem>.self, """
        {"results": [], "total": 120, "limit": 50, "page": 2}
        """)
        #expect(!last.hasMore)
    }
}
