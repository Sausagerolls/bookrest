import Testing
import Foundation
@testable import ABSClient

struct ServerConnectionTests {

    @Test("Bare hostnames default to HTTPS", arguments: [
        ("books.example.com", "https://books.example.com"),
        ("  books.example.com/  ", "https://books.example.com"),
        ("http://192.168.1.10:13378", "http://192.168.1.10:13378"),
        ("https://books.example.com/abs", "https://books.example.com/abs"),
        ("books.example.com:8080", "https://books.example.com:8080"),
    ])
    func normalization(input: String, expected: String) {
        #expect(ServerConnection.normalize(urlString: input)?.absoluteString == expected)
    }

    @Test("Nonsense input is rejected rather than producing a broken URL", arguments: [
        "", "   ", "ftp://books.example.com", "https://",
    ])
    func rejectsInvalid(input: String) {
        #expect(ServerConnection.normalize(urlString: input) == nil)
    }

    @Test("Query strings and fragments are stripped from a pasted address")
    func stripsExtras() {
        let url = ServerConnection.normalize(urlString: "https://books.example.com/?foo=1#bar")
        #expect(url?.absoluteString == "https://books.example.com")
    }
}

struct LibraryFilterTests {

    @Test("Filters are base64 encoded the way the server's atob expects")
    func filterEncoding() {
        // "ser_abc123" -> base64
        #expect(LibraryFilter.series("ser_abc123").apiValue == "series.c2VyX2FiYzEyMw==")
        #expect(LibraryFilter.author("aut_1").apiValue == "authors.YXV0XzE=")
        #expect(LibraryFilter.progress(.inProgress).apiValue == "progress.aW4tcHJvZ3Jlc3M=")
        #expect(LibraryFilter.all.apiValue == "all")
    }
}

struct EndpointTests {

    @Test("Paths compose correctly against a root base URL")
    func rootBase() throws {
        let endpoint = Endpoint.get("/api/libraries", query: [.number("limit", 10)])
        let url = try endpoint.url(relativeTo: URL(string: "https://example.com")!)
        #expect(url.absoluteString == "https://example.com/api/libraries?limit=10")
    }

    @Test("A reverse-proxy sub-path is preserved, not overwritten")
    func subPathBase() throws {
        let endpoint = Endpoint.get("/api/me")
        let url = try endpoint.url(relativeTo: URL(string: "https://example.com/abs")!)
        #expect(url.path == "/abs/api/me")
    }

    @Test("A trailing slash on the base URL doesn't double up")
    func trailingSlash() throws {
        let endpoint = Endpoint.get("/api/me")
        let url = try endpoint.url(relativeTo: URL(string: "https://example.com/abs/")!)
        #expect(url.path == "/abs/api/me")
    }
}

struct SeriesOrderingTests {

    @Test("Books order by sequence, with decimals and unnumbered entries handled")
    func ordering() throws {
        let series = try JSONDecoder().decode(Series.self, from: Data("""
        {
          "id": "ser_1", "name": "Series",
          "books": [
            {"id": "b3", "mediaType": "book", "media": {"metadata": {"title": "Third",
              "series": [{"id": "ser_1", "name": "Series", "sequence": "2"}]}}},
            {"id": "b1", "mediaType": "book", "media": {"metadata": {"title": "First",
              "series": [{"id": "ser_1", "name": "Series", "sequence": "1"}]}}},
            {"id": "bx", "mediaType": "book", "media": {"metadata": {"title": "Anthology",
              "series": [{"id": "ser_1", "name": "Series"}]}}},
            {"id": "b2", "mediaType": "book", "media": {"metadata": {"title": "Interlude",
              "series": [{"id": "ser_1", "name": "Series", "sequence": "1.5"}]}}},
            {"id": "b10", "mediaType": "book", "media": {"metadata": {"title": "Tenth",
              "series": [{"id": "ser_1", "name": "Series", "sequence": "10"}]}}}
          ]
        }
        """.utf8))

        let order = series.orderedBooks.map(\.id)
        // 1, 1.5, 2, 10 numerically — then the unnumbered entry last.
        #expect(order == ["b1", "b2", "b3", "b10", "bx"])
    }

    @Test("Minified series payloads order by top-level sequence or flattened series name")
    func minifiedOrdering() throws {
        let series = try JSONDecoder().decode(Series.self, from: Data("""
        {
          "id": "ser_1", "name": "Saga",
          "books": [
            {"id": "b3", "sequence": "3", "mediaType": "book",
              "media": {"metadata": {"title": "A Third", "seriesName": "Saga #3"}}},
            {"id": "b1", "mediaType": "book",
              "media": {"metadata": {"title": "Z First", "seriesName": "Other #9, Saga #1"}}},
            {"id": "b2", "sequence": 2, "mediaType": "book",
              "media": {"metadata": {"title": "M Second"}}}
          ]
        }
        """.utf8))

        #expect(series.orderedBooks.map(\.id) == ["b1", "b2", "b3"])
        #expect(series.books.first { $0.id == "b1" }?.sequence(inSeries: "ser_1", named: "Saga") == "1")
    }

    @Test("A single series object, as series-filtered listings send, decodes as one ref")
    func singleSeriesObject() throws {
        let item = try JSONDecoder().decode(LibraryItem.self, from: Data("""
        {"id": "b1", "mediaType": "book", "media": {"metadata": {"title": "One",
          "series": {"id": "ser_1", "name": "Saga", "sequence": "4"}}}}
        """.utf8))
        #expect(item.sequence(inSeries: "ser_1") == "4")
    }

    @Test("Books without numbers keep the server's order instead of sorting by title")
    func unnumberedKeepServerOrder() throws {
        let series = try JSONDecoder().decode(Series.self, from: Data("""
        {
          "id": "ser_1", "name": "Dungeon Crawler Carl",
          "books": [
            {"id": "b1", "mediaType": "book", "media": {"metadata": {"title": "Dungeon Crawler Carl"}}},
            {"id": "b2", "mediaType": "book", "media": {"metadata": {"title": "Carl's Doomsday Scenario"}}},
            {"id": "b3", "mediaType": "book", "media": {"metadata": {"title": "The Dungeon Anarchist's Cookbook"}}}
          ]
        }
        """.utf8))
        #expect(series.orderedBooks.map(\.id) == ["b1", "b2", "b3"])
    }

    @Test("Series-filtered listings carry the number in a top-level series object")
    func topLevelSeriesObject() throws {
        let item = try JSONDecoder().decode(LibraryItem.self, from: Data("""
        {"id": "b2", "mediaType": "book", "series": {"id": "ser_1", "name": "Saga", "sequence": "2"},
          "media": {"metadata": {"title": "Two", "seriesName": ""}}}
        """.utf8))
        #expect(item.sequence(inSeries: "ser_1") == "2")
        #expect(item.sequence(inSeries: "ser_other") == nil)
    }

    @Test("Author payloads group books into ordered series, leaving standalone books apart")
    func authorSeries() throws {
        let author = try JSONDecoder().decode(Author.self, from: Data("""
        {
          "id": "aut_1", "name": "Matt Dinniman",
          "libraryItems": [
            {"id": "b2", "mediaType": "book", "media": {"metadata": {"title": "Carl's Doomsday Scenario"}}},
            {"id": "s1", "mediaType": "book", "media": {"metadata": {"title": "Kaiju"}}},
            {"id": "b1", "mediaType": "book", "media": {"metadata": {"title": "Dungeon Crawler Carl"}}}
          ],
          "series": [{"id": "ser_1", "name": "Dungeon Crawler Carl", "items": [
            {"id": "b2", "mediaType": "book", "media": {"metadata": {"title": "Carl's Doomsday Scenario",
              "series": {"id": "ser_1", "name": "Dungeon Crawler Carl", "sequence": "2"}}}},
            {"id": "b1", "mediaType": "book", "media": {"metadata": {"title": "Dungeon Crawler Carl",
              "series": {"id": "ser_1", "name": "Dungeon Crawler Carl", "sequence": "1"}}}}
          ]}]
        }
        """.utf8))
        #expect(author.series.map(\.id) == ["ser_1"])
        #expect(author.series[0].orderedBooks.map(\.id) == ["b1", "b2"])
        #expect(author.standaloneBooks.map(\.id) == ["s1"])
    }
}
