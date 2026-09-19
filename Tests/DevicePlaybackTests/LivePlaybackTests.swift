import XCTest
import AVFoundation
@testable import BookrestCore
@testable import ABSClient

/// Reproduces playback on a real iOS runtime, against the real server.
///
/// macOS has no `AVAudioSession` and seeks local files instantly, so the two bugs
/// that reached the device — an unconfigurable audio session, and a resume seek that
/// never completes — were both invisible everywhere else. These run on the simulator
/// so that class of bug is reproducible here instead of on a phone.
///
/// Credentials come from the environment; the tests skip without them and never
/// modify server-side progress.
@MainActor
final class LivePlaybackTests: XCTestCase {

    private var serverURL: URL!
    private var username: String!
    private var password: String!

    /// Credentials come from a file on the host rather than the environment.
    /// `xcodebuild` does not forward shell variables into the simulator's test
    /// process, but a simulator process can read host paths, and keeping them in a
    /// file outside the repo means they are never committed.
    private static let credentialsPath = "/tmp/bookrest-live-test.json"

    override func setUpWithError() throws {
        struct Credentials: Decodable { let url: String; let username: String; let password: String }

        let env = ProcessInfo.processInfo.environment
        var raw = env["ABS_URL"]
        var user = env["ABS_USER"]
        var pass = env["ABS_PASS"]

        if raw == nil || user == nil || pass == nil,
           let data = FileManager.default.contents(atPath: Self.credentialsPath),
           let decoded = try? JSONDecoder().decode(Credentials.self, from: data) {
            raw = decoded.url
            user = decoded.username
            pass = decoded.password
        }

        guard let raw, let user, let pass, let url = ServerConnection.normalize(urlString: raw) else {
            throw XCTSkip("No credentials: set ABS_URL/ABS_USER/ABS_PASS or write \(Self.credentialsPath)")
        }
        serverURL = url
        username = user
        password = pass
    }

    private func signedInClient() async throws -> (AudiobookshelfClient, ServerConnection) {
        // In-memory storage: an unsigned test bundle has no keychain entitlement.
        let client = AudiobookshelfClient(storage: InMemoryCredentialStorage())
        let connection = try await client.signIn(serverURL: serverURL, username: username, password: password)
        return (client, connection)
    }

    /// Builds a context for the longest book available, without touching progress.
    private func makeContext(_ client: AudiobookshelfClient,
                             _ connection: ServerConnection) async throws -> PlaybackContext {
        let library = try await client.libraries().first { $0.mediaType == .book }!
        let page = try await client.items(inLibrary: library.id, limit: 20,
                                          sort: .duration, descending: true)
        let item = try await client.item(page.results.first { $0.isPlayable }!.id)
        let session = try await client.startPlaybackSession(itemId: item.id)

        let tracks: [PlayableTrack] = session.audioTracks.compactMap { track in
            AudiobookshelfClient.streamURL(for: track, session: session, connection: connection).map {
                PlayableTrack(index: track.index, startOffset: track.startOffset,
                              duration: track.duration, url: $0, isLocal: false)
            }
        }
        print("[probe] \(item.title) — \(Int(session.duration))s, \(tracks.count) track(s), playMethod \(session.playMethod)")

        return PlaybackContext(
            key: item.id, itemId: item.id, episodeId: nil, libraryId: item.libraryId,
            title: item.title, author: item.authorDisplay, narrator: nil,
            coverURL: AudiobookshelfClient.coverURL(itemId: item.id, connection: connection, width: 400),
            localCoverURL: nil, chapters: session.chapters, tracks: tracks,
            duration: session.duration, serverSessionId: session.id,
            isOffline: false, serverResumeTime: 0
        )
    }

    private func waitFor(_ label: String, timeout: TimeInterval = 40,
                         _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        print("[probe] TIMED OUT waiting for \(label)")
        return false
    }

    func testAudioSessionConfigures() throws {
        let ok = AudioSessionController.shared.activate()
        print("[probe] audio session active=\(ok) error=\(AudioSessionController.shared.lastError ?? "none")")
        XCTAssertTrue(ok, "audio session must activate: \(AudioSessionController.shared.lastError ?? "")")
    }

    func testPlaybackStartsFromZero() async throws {
        let (client, connection) = try await signedInClient()
        let context = try await makeContext(client, connection)

        let engine = PlayerEngine()
        engine.load(context, startingAt: 0, autoPlay: true)

        let playing = await waitFor("playback from 0") { engine.currentTime > 1 }
        print("[probe] from 0: status=\(engine.status) t=\(engine.currentTime)")
        XCTAssertTrue(playing, "never started from 0 (status \(engine.status))")
        engine.stop()
    }

    /// The switch case: resuming deep into a long book.
    func testPlaybackStartsDeepIntoBook() async throws {
        let (client, connection) = try await signedInClient()
        let context = try await makeContext(client, connection)

        // Ten hours in, matching a genuinely part-finished audiobook.
        let resume = min(36_000, max(0, context.duration - 600))
        print("[probe] resuming at \(Int(resume))s of \(Int(context.duration))s")

        let engine = PlayerEngine()
        let started = Date()
        engine.load(context, startingAt: resume, autoPlay: true)

        let playing = await waitFor("playback deep into book") { engine.currentTime > resume + 1 }
        print("[probe] deep resume: status=\(engine.status) t=\(engine.currentTime) after \(Int(Date().timeIntervalSince(started)))s")
        XCTAssertTrue(playing, "never started at \(Int(resume))s (status \(engine.status))")
        engine.stop()
    }

    /// Closest mirror of the app: server progress synced first, so both books resume
    /// deep rather than starting at zero, then a switch between them.
    func testSwitchingBetweenPartFinishedBooks() async throws {
        let (client, _) = try await signedInClient()

        let progress = ProgressStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-\(UUID().uuidString).json"))
        let controller = PlaybackController(client: client,
                                            offlineStore: OfflineLibraryStore(),
                                            progressStore: progress)

        // What AppEnvironment.bootstrap does: pull every server position locally.
        await controller.refreshProgressFromServer()
        let synced = await progress.all()
        let started = synced.values.filter { $0.isStarted && $0.currentTime > 600 }
            .sorted { $0.currentTime > $1.currentTime }
        print("[probe] \(synced.count) positions synced, \(started.count) part-finished")
        try XCTSkipIf(started.count < 2, "need two part-finished books on the server")

        for (index, entry) in started.prefix(2).enumerated() {
            let item = try await client.item(entry.itemId)
            print("[probe] book \(index + 1): \(item.title) resuming at \(Int(entry.currentTime))s")
            let began = Date()
            await controller.play(item: item)
            let ok = await waitFor("book \(index + 1)") { controller.currentTime > entry.currentTime + 1 }
            print("[probe] book \(index + 1): status=\(controller.status) t=\(Int(controller.currentTime)) after \(Int(Date().timeIntervalSince(began)))s")
            XCTAssertTrue(ok, "book \(index + 1) never resumed (status \(controller.status))")
        }
        await controller.stop()
    }

    /// Switching books is what actually fails in the app.
    func testSwitchingBetweenBooks() async throws {
        let (client, connection) = try await signedInClient()
        let library = try await client.libraries().first { $0.mediaType == .book }!
        let page = try await client.items(inLibrary: library.id, limit: 40, sort: .duration, descending: true)
        let playable = page.results.filter(\.isPlayable).prefix(2).map(\.id)
        XCTAssertEqual(playable.count, 2, "need two playable books")

        let offline = OfflineLibraryStore()
        let progress = ProgressStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-progress-\(UUID().uuidString).json"))
        let controller = PlaybackController(client: client, offlineStore: offline, progressStore: progress)

        for (index, id) in playable.enumerated() {
            let item = try await client.item(id)
            print("[probe] switching to book \(index + 1): \(item.title)")
            await controller.play(item: item)
            let ok = await waitFor("book \(index + 1) playing") { controller.currentTime > 1 }
            print("[probe] book \(index + 1): status=\(controller.status) t=\(controller.currentTime)")
            XCTAssertTrue(ok, "book \(index + 1) never played (status \(controller.status))")
        }
        await controller.stop()
    }
}
