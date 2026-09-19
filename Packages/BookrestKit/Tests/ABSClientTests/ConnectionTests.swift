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
}
