import Testing
import Foundation
@testable import ABSClient

/// Mapping absolute item time onto per-file player time is where multi-file
/// audiobooks break, so the boundaries are pinned here.
struct PlaybackSessionTests {

    private func session(trackDurations: [TimeInterval], playMethod: Int = 0) throws -> PlaybackSession {
        var offset: TimeInterval = 0
        let tracks = trackDurations.enumerated().map { index, duration -> String in
            let json = """
            {"index": \(index + 1), "startOffset": \(offset), "duration": \(duration),
             "title": "t\(index)", "contentUrl": "/api/items/li_1/file/\(100 + index)",
             "mimeType": "audio/mpeg"}
            """
            offset += duration
            return json
        }
        let json = """
        {"id": "play_1", "libraryItemId": "li_1", "mediaType": "book",
         "displayTitle": "Book", "playMethod": \(playMethod), "currentTime": 0,
         "duration": \(offset), "audioTracks": [\(tracks.joined(separator: ","))]}
        """
        return try JSONDecoder().decode(PlaybackSession.self, from: Data(json.utf8))
    }

    @Test("Duration comes from the summed tracks")
    func durationFromTracks() throws {
        let session = try session(trackDurations: [100, 200, 300])
        #expect(session.duration == 600)
    }

    @Test("Absolute time resolves to the right track and offset")
    func trackLookup() throws {
        let session = try session(trackDurations: [100, 200, 300])

        let start = try #require(session.track(at: 0))
        #expect(start.track.index == 1)
        #expect(start.offset == 0)

        // Exactly on a boundary belongs to the later track.
        let boundary = try #require(session.track(at: 100))
        #expect(boundary.track.index == 2)
        #expect(boundary.offset == 0)

        let middle = try #require(session.track(at: 250))
        #expect(middle.track.index == 2)
        #expect(middle.offset == 150)

        let late = try #require(session.track(at: 599))
        #expect(late.track.index == 3)
        #expect(late.offset == 299)
    }

    @Test("Times past the end clamp to the last track instead of failing")
    func pastEndClamps() throws {
        let session = try session(trackDurations: [100, 200])
        // Rounding drift can push the reported position a hair past the total.
        let overrun = try #require(session.track(at: 1_000))
        #expect(overrun.track.index == 2)
        #expect(overrun.offset <= 200)

        let negative = try #require(session.track(at: -50))
        #expect(negative.track.index == 1)
        #expect(negative.offset == 0)
    }

    @Test("HLS tracks are recognised as transcoded")
    func hlsDetection() throws {
        let track = try JSONDecoder().decode(AudioTrack.self, from: Data("""
        {"index": 1, "startOffset": 0, "duration": 10, "title": "t",
         "contentUrl": "/hls/play_1/output.m3u8",
         "mimeType": "application/vnd.apple.mpegurl"}
        """.utf8))
        #expect(track.isHLS)
    }
}

struct StreamURLTests {
    private let connection = ServerConnection(
        baseURL: URL(string: "https://books.example.com")!,
        username: "jo", userId: "u1", serverName: "s",
        accessToken: "TOKEN123"
    )

    private func makeSession(contentUrl: String, mimeType: String) throws -> PlaybackSession {
        try JSONDecoder().decode(PlaybackSession.self, from: Data("""
        {"id": "play_9", "libraryItemId": "li_1", "duration": 10,
         "audioTracks": [{"index": 2, "startOffset": 0, "duration": 10, "title": "t",
                          "contentUrl": "\(contentUrl)", "mimeType": "\(mimeType)"}]}
        """.utf8))
    }

    @Test("Direct play prefers the unauthenticated public session route")
    func publicRoutePreferred() throws {
        let session = try makeSession(contentUrl: "/api/items/li_1/file/9981", mimeType: "audio/mpeg")
        let track = try #require(session.audioTracks.first)
        let url = try #require(AudiobookshelfClient.streamURL(for: track, session: session, connection: connection))

        // No credentials in the URL at all — this route needs none.
        #expect(url.absoluteString == "https://books.example.com/public/session/play_9/track/2")
        #expect(!url.absoluteString.contains("TOKEN123"))
    }

    @Test("Falling back to the API route carries the token as a query item")
    func fallbackCarriesToken() throws {
        let session = try makeSession(contentUrl: "/api/items/li_1/file/9981", mimeType: "audio/mpeg")
        let track = try #require(session.audioTracks.first)
        let url = try #require(AudiobookshelfClient.streamURL(
            for: track, session: session, connection: connection, preferPublicRoute: false
        ))

        #expect(url.path == "/api/items/li_1/file/9981")
        #expect(url.query()?.contains("token=TOKEN123") == true)
    }

    @Test("HLS playlists are used verbatim without a token")
    func hlsUntouched() throws {
        let session = try makeSession(contentUrl: "/hls/play_9/output.m3u8",
                                      mimeType: "application/vnd.apple.mpegurl")
        let track = try #require(session.audioTracks.first)
        let url = try #require(AudiobookshelfClient.streamURL(for: track, session: session, connection: connection))

        // The /hls mount is unauthenticated; adding a token would not propagate to
        // the segment requests anyway.
        #expect(url.absoluteString == "https://books.example.com/hls/play_9/output.m3u8")
    }

    @Test("Servers mounted on a sub-path keep their prefix")
    func subPathBaseURL() throws {
        let proxied = ServerConnection(
            baseURL: URL(string: "https://home.example.com/audiobooks")!,
            username: "jo", userId: "u1", serverName: "s", accessToken: "T"
        )
        let url = try #require(AudiobookshelfClient.coverURL(itemId: "li_1", connection: proxied, width: 400))
        #expect(url.path == "/audiobooks/api/items/li_1/cover")
    }
}
