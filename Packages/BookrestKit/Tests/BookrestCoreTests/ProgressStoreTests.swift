import Testing
import Foundation
@testable import BookrestCore
@testable import ABSClient

/// Reconciling positions between device and server is the one place a bug loses
/// real user data, so the merge rules are pinned precisely.
struct ProgressStoreTests {

    private func makeStore() -> ProgressStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookrest-tests-\(UUID().uuidString).json")
        return ProgressStore(url: url)
    }

    private func serverProgress(itemId: String, currentTime: TimeInterval,
                                lastUpdate: Date, isFinished: Bool = false) throws -> MediaProgress {
        try JSONDecoder().decode(MediaProgress.self, from: Data("""
        {"id": "mp_\(itemId)", "libraryItemId": "\(itemId)", "duration": 1000,
         "progress": \(currentTime / 1000), "currentTime": \(currentTime),
         "isFinished": \(isFinished), "lastUpdate": \(lastUpdate.timeIntervalSince1970 * 1000)}
        """.utf8))
    }

    @Test("Local playback marks a position as needing sync")
    func recordFlagsForSync() async {
        let store = makeStore()
        await store.record(itemId: "li_1", episodeId: nil, currentTime: 120,
                           duration: 1000, isFinished: false, listenedDelta: 30)

        let entry = await store.progress(itemId: "li_1")
        #expect(entry?.currentTime == 120)
        #expect(entry?.needsSync == true)
        #expect(entry?.pendingTimeListened == 30)
        #expect(entry?.isStarted == true)
    }

    @Test("Listening time accumulates across ticks until synced")
    func listenedTimeAccumulates() async {
        let store = makeStore()
        for _ in 0..<5 {
            await store.record(itemId: "li_1", episodeId: nil, currentTime: 100,
                               duration: 1000, isFinished: false, listenedDelta: 10)
        }
        let entry = await store.progress(itemId: "li_1")
        #expect(entry?.pendingTimeListened == 50)
    }

    @Test("A newer server position overwrites an older local one")
    func serverWinsWhenNewer() async throws {
        let store = makeStore()
        await store.record(itemId: "li_1", episodeId: nil, currentTime: 100,
                           duration: 1000, isFinished: false, listenedDelta: 0)
        // Clear the sync flag so the entry is eligible to be replaced.
        let existing = try #require(await store.progress(itemId: "li_1"))
        await store.markSynced(key: existing.key, asOf: existing.updatedAt, consumedTimeListened: 0)

        let remote = try serverProgress(itemId: "li_1", currentTime: 500,
                                        lastUpdate: .now.addingTimeInterval(60))
        await store.mergeFromServer([remote])

        #expect(await store.progress(itemId: "li_1")?.currentTime == 500)
    }

    @Test("An unsynced local position survives an older server one")
    func localWinsWhenPendingAndNewer() async throws {
        let store = makeStore()
        await store.record(itemId: "li_1", episodeId: nil, currentTime: 900,
                           duration: 1000, isFinished: false, listenedDelta: 0)

        // Listened offline: the server's entry predates this one, so the queued local
        // position has to survive and still be waiting to upload.
        let remote = try serverProgress(itemId: "li_1", currentTime: 10,
                                        lastUpdate: .now.addingTimeInterval(-3600))
        await store.mergeFromServer([remote])

        let entry = await store.progress(itemId: "li_1")
        #expect(entry?.currentTime == 900)
        #expect(entry?.needsSync == true)
    }

    @Test("Another device's newer position wins even over an unsynced local one")
    func serverWinsOverStalePending() async throws {
        let store = makeStore()
        // This device queued a position and never managed to upload it.
        await store.record(itemId: "li_1", episodeId: nil, currentTime: 3942,
                           duration: 52572, isFinished: false, listenedDelta: 120)

        // Another device listened well past it afterwards. Letting the queued write
        // survive is what used to push the older position back over this one.
        let remote = try serverProgress(itemId: "li_1", currentTime: 4800,
                                        lastUpdate: .now.addingTimeInterval(600))
        await store.mergeFromServer([remote])

        let entry = await store.progress(itemId: "li_1")
        #expect(entry?.currentTime == 4800)
        #expect(entry?.needsSync == false, "the superseded position must not be uploaded")
        #expect(await store.pendingSyncs().isEmpty)
    }

    @Test("An older server position is ignored")
    func staleServerIgnored() async throws {
        let store = makeStore()
        let remote = try serverProgress(itemId: "li_1", currentTime: 700, lastUpdate: .now)
        await store.mergeFromServer([remote])
        await store.markSynced(key: "li_1", asOf: .now, consumedTimeListened: 0)

        let stale = try serverProgress(itemId: "li_1", currentTime: 5,
                                       lastUpdate: .now.addingTimeInterval(-7200))
        await store.mergeFromServer([stale])

        #expect(await store.progress(itemId: "li_1")?.currentTime == 700)
    }

    @Test("A position changed mid-upload keeps its pending flag")
    func concurrentUpdateNotLost() async throws {
        let store = makeStore()
        await store.record(itemId: "li_1", episodeId: nil, currentTime: 100,
                           duration: 1000, isFinished: false, listenedDelta: 5)
        let snapshot = try #require(await store.progress(itemId: "li_1"))

        // Playback advances while the upload of the earlier position is in flight.
        try await Task.sleep(for: .milliseconds(10))
        await store.record(itemId: "li_1", episodeId: nil, currentTime: 200,
                           duration: 1000, isFinished: false, listenedDelta: 5)

        // The upload completes, reporting the position it actually sent.
        await store.markSynced(key: snapshot.key, asOf: snapshot.updatedAt, consumedTimeListened: 5)

        let entry = await store.progress(itemId: "li_1")
        #expect(entry?.currentTime == 200)
        #expect(entry?.needsSync == true, "the newer position still needs uploading")
    }

    @Test("Real server progress decodes and wins over an older local position")
    func realServerPayloadMerges() async throws {
        // Captured verbatim from /api/me for Shift on 2026-09-04, including the
        // 13-digit millisecond lastUpdate that the merge depends on.
        let remote = try JSONDecoder().decode(MediaProgress.self, from: Data("""
        {"id": "8c96b7cd-5427-4246-98f7-ebca16035177",
         "libraryItemId": "3713d998-aab6-4a57-b4a6-e43cf2f50b42", "episodeId": null,
         "duration": 52572.282, "progress": 0.04423434325629996,
         "currentTime": 3942.50021273, "isFinished": false,
         "lastUpdate": 1788543811801, "startedAt": 1788527585217, "finishedAt": null}
        """.utf8))

        #expect(remote.lastUpdate != nil, "a nil lastUpdate would silently lose every merge")

        let store = makeStore()
        // Seed an genuinely older local entry. `record` stamps `.now`, which would be
        // later than the captured payload, so seed it through an earlier server entry.
        let earlier = try serverProgress(itemId: "3713d998-aab6-4a57-b4a6-e43cf2f50b42",
                                         currentTime: 1200,
                                         lastUpdate: Date(timeIntervalSince1970: 1788543811.801 - 3600))
        await store.mergeFromServer([earlier])
        #expect(await store.progress(itemId: "3713d998-aab6-4a57-b4a6-e43cf2f50b42")?.currentTime == 1200)

        await store.mergeFromServer([remote])
        let entry = await store.progress(itemId: "3713d998-aab6-4a57-b4a6-e43cf2f50b42")
        #expect(entry?.currentTime == 3942.50021273)
    }

    @Test("Podcast episodes track progress separately from their show")
    func episodeKeying() async {
        let store = makeStore()
        await store.record(itemId: "li_pod", episodeId: "ep_1", currentTime: 30,
                           duration: 300, isFinished: false, listenedDelta: 0)
        await store.record(itemId: "li_pod", episodeId: "ep_2", currentTime: 90,
                           duration: 300, isFinished: false, listenedDelta: 0)

        #expect(await store.progress(itemId: "li_pod", episodeId: "ep_1")?.currentTime == 30)
        #expect(await store.progress(itemId: "li_pod", episodeId: "ep_2")?.currentTime == 90)
        #expect(await store.progress(itemId: "li_pod")  == nil)
    }

    @Test("Pending syncs are returned oldest first")
    func pendingOrdering() async throws {
        let store = makeStore()
        await store.record(itemId: "li_1", episodeId: nil, currentTime: 10,
                           duration: 100, isFinished: false, listenedDelta: 0)
        try await Task.sleep(for: .milliseconds(10))
        await store.record(itemId: "li_2", episodeId: nil, currentTime: 20,
                           duration: 100, isFinished: false, listenedDelta: 0)

        let pending = await store.pendingSyncs()
        #expect(pending.map(\.itemId) == ["li_1", "li_2"])
    }
}

/// Merging the store is only half of cross-device sync: a player that is already
/// loaded has to move onto the merged position too, or the app shows — and resumes
/// from — the position this device was paused at.
struct AdoptedPositionTests {

    private func local(currentTime: TimeInterval, isFinished: Bool = false) -> LocalProgress {
        LocalProgress(key: "li_1", itemId: "li_1", episodeId: nil,
                      currentTime: currentTime, duration: 1000,
                      isFinished: isFinished, updatedAt: .now)
    }

    @Test("Another device's newer position moves the paused playhead")
    func adoptsRemotePosition() {
        let target = PlaybackController.positionToAdopt(stored: local(currentTime: 640),
                                                        playhead: 120)
        #expect(target == 640)
    }

    @Test("A position this device is already at is left alone")
    func ignoresMatchingPosition() {
        #expect(PlaybackController.positionToAdopt(stored: local(currentTime: 300),
                                                   playhead: 300) == nil)
    }

    @Test("Ordinary drift within tolerance does not jog the playhead")
    func ignoresSmallDrift() {
        #expect(PlaybackController.positionToAdopt(stored: local(currentTime: 302),
                                                   playhead: 300) == nil)
    }

    @Test("A finished book is not dragged back to its stored position")
    func ignoresFinished() {
        #expect(PlaybackController.positionToAdopt(stored: local(currentTime: 990, isFinished: true),
                                                   playhead: 10) == nil)
    }

    @Test("Nothing stored means nothing to adopt")
    func ignoresMissingProgress() {
        #expect(PlaybackController.positionToAdopt(stored: nil, playhead: 300) == nil)
    }

    @Test("A remote position earlier than the playhead is still adopted")
    func adoptsEarlierPosition() {
        // The merge already decided the server's entry was the newer one, so going
        // backwards is correct here — another device restarted the book.
        #expect(PlaybackController.positionToAdopt(stored: local(currentTime: 30),
                                                   playhead: 800) == 30)
    }
}

struct OfflineItemTests {

    private func makeItem(tracks: [OfflineTrack], state: OfflineState) -> OfflineItem {
        OfflineItem(key: "li_1", itemId: "li_1", episodeId: nil, libraryId: "lib_1",
                    mediaType: .book, title: "Book", author: nil, narrator: nil,
                    seriesLabel: nil, itemDescription: nil, duration: 100,
                    tracks: tracks, chapters: [], coverFileName: nil,
                    state: state, downloadedAt: .now)
    }

    @Test("An item is only playable offline when every track is complete")
    func playabilityRequiresAllTracks() {
        let complete = OfflineTrack(index: 1, startOffset: 0, duration: 50, fileName: "a.mp3",
                                    mimeType: "audio/mpeg", bytesDownloaded: 10, expectedBytes: 10,
                                    isComplete: true)
        let partial = OfflineTrack(index: 2, startOffset: 50, duration: 50, fileName: "b.mp3",
                                   mimeType: "audio/mpeg", bytesDownloaded: 3, expectedBytes: 10,
                                   isComplete: false)

        #expect(makeItem(tracks: [complete], state: .completed).isPlayableOffline)
        #expect(!makeItem(tracks: [complete, partial], state: .completed).isPlayableOffline)
        // State alone isn't enough — the files have to actually be there.
        #expect(!makeItem(tracks: [complete], state: .downloading).isPlayableOffline)
        #expect(!makeItem(tracks: [], state: .completed).isPlayableOffline)
    }

    @Test("Progress falls back to counting files when no content length was sent")
    func progressWithoutContentLength() {
        let done = OfflineTrack(index: 1, startOffset: 0, duration: 50, fileName: "a.mp3",
                                mimeType: "audio/mpeg", isComplete: true)
        let pending = OfflineTrack(index: 2, startOffset: 50, duration: 50, fileName: "b.mp3",
                                   mimeType: "audio/mpeg", isComplete: false)
        #expect(makeItem(tracks: [done, pending], state: .downloading).progress == 0.5)
    }

    @Test("Byte progress is used when the server reported sizes")
    func progressFromBytes() {
        let a = OfflineTrack(index: 1, startOffset: 0, duration: 50, fileName: "a.mp3",
                             mimeType: "audio/mpeg", bytesDownloaded: 100, expectedBytes: 100,
                             isComplete: true)
        let b = OfflineTrack(index: 2, startOffset: 50, duration: 50, fileName: "b.mp3",
                             mimeType: "audio/mpeg", bytesDownloaded: 25, expectedBytes: 100)
        #expect(makeItem(tracks: [a, b], state: .downloading).progress == 0.625)
    }
}

/// Where a book starts playing is the one thing a listener notices immediately if
/// it's wrong, so each branch is pinned.
struct ResumePositionTests {

    private func context(duration: TimeInterval, serverResumeTime: TimeInterval) -> PlaybackContext {
        PlaybackContext(
            key: "li_1", itemId: "li_1", episodeId: nil, libraryId: "lib_1",
            title: "Book", author: nil, narrator: nil, coverURL: nil, localCoverURL: nil,
            chapters: [], tracks: [PlayableTrack(index: 1, startOffset: 0, duration: duration,
                                                 url: URL(string: "https://x/1")!, isLocal: false)],
            duration: duration, serverSessionId: "s1", isOffline: false,
            serverResumeTime: serverResumeTime
        )
    }

    private func local(currentTime: TimeInterval, isFinished: Bool = false) -> LocalProgress {
        LocalProgress(key: "li_1", itemId: "li_1", episodeId: nil, currentTime: currentTime,
                      duration: 54_026, isFinished: isFinished, updatedAt: .now)
    }

    @Test("With no local position, the server's resume point is used")
    func fallsBackToServer() {
        // Regression: this previously returned 0 and restarted a part-finished book.
        let context = context(duration: 54_026, serverResumeTime: 38_051)
        #expect(context.resumePosition(local: nil) == 38_051)
    }

    @Test("A local position always beats the server's")
    func localWins() {
        let context = context(duration: 54_026, serverResumeTime: 38_051)
        #expect(context.resumePosition(local: local(currentTime: 100)) == 100)
    }

    @Test("An empty local entry still defers to the server")
    func emptyLocalDefersToServer() {
        let context = context(duration: 54_026, serverResumeTime: 38_051)
        #expect(context.resumePosition(local: local(currentTime: 0)) == 38_051)
    }

    @Test("A finished book restarts from the beginning")
    func finishedRestarts() {
        let context = context(duration: 54_026, serverResumeTime: 53_000)
        #expect(context.resumePosition(local: local(currentTime: 54_000, isFinished: true)) == 0)
    }

    @Test("Resume points are clamped inside the item")
    func clamping() {
        let context = context(duration: 1_000, serverResumeTime: 999_999)
        #expect(context.resumePosition(local: nil) == 999)
        #expect(context.resumePosition(local: local(currentTime: 999_999)) == 999)
    }
}
