import Foundation
import Observation
import ABSClient
import os

/// The app-facing playback surface. UI and CarPlay both drive this, never the engine
/// directly, so both entry points get identical behaviour.
@MainActor
@Observable
public final class PlaybackController {

    public let engine: PlayerEngine

    private let client: AudiobookshelfClient
    private let offlineStore: OfflineLibraryStore
    private let progressStore: ProgressStore
    private let progressCoordinator: ProgressCoordinator
    private let logger = Logger(subsystem: "com.bookrest.app", category: "playback")

    /// Set while a play request is resolving, so the UI can show the right item as
    /// pending rather than appearing to do nothing.
    public private(set) var preparingKey: String?
    private var prepareTask: Task<Void, Never>?
    public private(set) var lastError: String?

    public var skipForwardInterval: SkipInterval {
        didSet {
            defaults.set(skipForwardInterval.rawValue, forKey: Keys.skipForward)
            configureRemoteCommands()
        }
    }

    public var skipBackwardInterval: SkipInterval {
        didSet {
            defaults.set(skipBackwardInterval.rawValue, forKey: Keys.skipBackward)
            configureRemoteCommands()
        }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let skipForward = "com.bookrest.skipForward"
        static let skipBackward = "com.bookrest.skipBackward"
        static let rate = "com.bookrest.rate"
        static let lastPlayedKey = "com.bookrest.lastPlayed"
    }

    public init(client: AudiobookshelfClient,
                offlineStore: OfflineLibraryStore,
                progressStore: ProgressStore) {
        self.client = client
        self.offlineStore = offlineStore
        self.progressStore = progressStore
        self.progressCoordinator = ProgressCoordinator(client: client, progressStore: progressStore)
        self.engine = PlayerEngine()

        let forward = defaults.integer(forKey: Keys.skipForward)
        let backward = defaults.integer(forKey: Keys.skipBackward)
        self.skipForwardInterval = SkipInterval(rawValue: forward) ?? .thirty
        self.skipBackwardInterval = SkipInterval(rawValue: backward) ?? .fifteen

        let storedRate = defaults.float(forKey: Keys.rate)
        if storedRate > 0 { engine.setRate(storedRate) }

        wireEngine()
        configureRemoteCommands()
    }

    // MARK: - Derived state

    public var context: PlaybackContext? { engine.context }
    public var isPlaying: Bool { engine.isPlaying }
    public var currentTime: TimeInterval { engine.currentTime }
    public var duration: TimeInterval { engine.duration }
    public var status: PlaybackStatus { engine.status }
    public var rate: Float { engine.rate }

    public func isCurrent(itemId: String, episodeId: String? = nil) -> Bool {
        context?.key == MediaProgress.key(itemId: itemId, episodeId: episodeId)
    }

    // MARK: - Starting playback

    /// Plays a library item, preferring a downloaded copy when one exists.
    public func play(item: LibraryItem, episodeId: String? = nil, autoPlay: Bool = true) async {
        let key = MediaProgress.key(itemId: item.id, episodeId: episodeId)

        // Already the current item — treat as a resume rather than a reload, so
        // tapping a playing book doesn't restart its buffering.
        if context?.key == key {
            if autoPlay { engine.play() }
            return
        }

        // A previous request still resolving would otherwise finish last and replace
        // whatever the user just chose.
        prepareTask?.cancel()

        preparingKey = key
        lastError = nil

        // Closing the outgoing session is a courtesy to the server's statistics, not a
        // prerequisite for the next book. Awaiting it put a network round trip in front
        // of every switch.
        closeCurrentSessionDetached()

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let context = try await self.makeContext(item: item, episodeId: episodeId, forceTranscode: false)
                try Task.checkCancellation()
                let startTime = await self.resolveStartTime(for: context)
                try Task.checkCancellation()
                self.engine.load(context, startingAt: startTime, autoPlay: autoPlay)
                self.defaults.set(key, forKey: Keys.lastPlayedKey)
            } catch is CancellationError {
                return
            } catch {
                let message = (error as? ABSError)?.errorDescription ?? error.localizedDescription
                self.lastError = message
                self.logger.error("Failed to start playback for \(key, privacy: .public): \(message, privacy: .public)")
            }
            if self.preparingKey == key { self.preparingKey = nil }
        }
        prepareTask = task
        await task.value
    }

    /// Starts an item, or toggles transport when it's already the current one.
    ///
    /// Screens that show a single play/pause button need this: `play(item:)` alone
    /// resumes but can never pause, so a button rendering "Pause" would do nothing.
    public func playOrToggle(item: LibraryItem, episodeId: String? = nil) async {
        if context != nil, isCurrent(itemId: item.id, episodeId: episodeId) {
            togglePlayPause()
            return
        }
        await play(item: item, episodeId: episodeId)
    }

    /// Plays a downloaded item without needing the server at all.
    public func play(offlineItem: OfflineItem, autoPlay: Bool = true) async {
        preparingKey = offlineItem.key
        lastError = nil
        defer { preparingKey = nil }

        await closeCurrentSession()

        guard let context = await makeOfflineContext(for: offlineItem) else {
            lastError = "The downloaded files for this book are missing."
            return
        }
        let startTime = await resolveStartTime(for: context)
        engine.load(context, startingAt: startTime, autoPlay: autoPlay)
        defaults.set(offlineItem.key, forKey: Keys.lastPlayedKey)
    }

    /// Restores the previously playing item, paused, so the mini player is present
    /// on launch exactly where the user left it.
    public func restoreLastPlayed() async {
        guard context == nil, let key = defaults.string(forKey: Keys.lastPlayedKey) else { return }

        if let offlineItem = await offlineStore.item(forKey: key), offlineItem.isPlayableOffline {
            await play(offlineItem: offlineItem, autoPlay: false)
            return
        }

        let itemId = key.split(separator: "/").first.map(String.init) ?? key
        let episodeId = key.contains("/") ? String(key.split(separator: "/")[1]) : nil
        guard let item = try? await client.item(itemId) else { return }
        await play(item: item, episodeId: episodeId, autoPlay: false)
    }

    // MARK: - Transport

    public func togglePlayPause() { engine.togglePlayPause() }
    public func play() { engine.play() }

    public func pause() {
        engine.pause()
        Task { await flushProgress(force: true) }
    }

    public func seek(to time: TimeInterval) { engine.seek(to: time) }

    public func skipForward() { engine.skipForward(skipForwardInterval.seconds) }
    public func skipBackward() { engine.skipBackward(skipBackwardInterval.seconds) }

    public func nextChapter() { engine.nextChapter() }
    public func previousChapter() { engine.previousChapter() }
    public func seekToChapter(_ chapter: Chapter) { engine.seekToChapter(chapter) }

    public func setRate(_ rate: Float) {
        engine.setRate(rate)
        defaults.set(engine.rate, forKey: Keys.rate)
    }

    public func cycleRate() {
        let options = PlaybackRate.options
        let index = options.firstIndex(of: rate) ?? options.firstIndex(of: 1.0) ?? 0
        setRate(options[(index + 1) % options.count])
    }

    public func stop() async {
        await flushProgress(force: true)
        await closeCurrentSession()
        engine.stop()
        defaults.removeObject(forKey: Keys.lastPlayedKey)
    }

    public func startSleepTimer(minutes: Int) { engine.startSleepTimer(duration: TimeInterval(minutes * 60)) }
    public func startSleepTimerAtEndOfChapter() { engine.startSleepTimerAtEndOfChapter() }
    public func extendSleepTimer(minutes: Int) { engine.extendSleepTimer(by: TimeInterval(minutes * 60)) }
    public func cancelSleepTimer() { engine.cancelSleepTimer() }

    /// Sends a book back to the beginning: clears the stored position, clears the
    /// finished flag, and rewinds if it happens to be the one playing.
    public func resetProgress(itemId: String, episodeId: String? = nil, duration: TimeInterval) async {
        if isCurrent(itemId: itemId, episodeId: episodeId) {
            engine.seek(to: 0)
        }
        await progressCoordinator.setFinished(itemId: itemId, episodeId: episodeId,
                                              finished: false, duration: duration)
    }

    public func markFinished(itemId: String, episodeId: String? = nil, finished: Bool = true, duration: TimeInterval) async {
        await progressCoordinator.setFinished(itemId: itemId, episodeId: episodeId,
                                              finished: finished, duration: duration)
    }

    // MARK: - Lifecycle hooks

    /// Called when the app returns to the foreground or the network comes back.
    public func syncPendingProgress() async {
        await progressCoordinator.syncPending()
    }

    public func refreshProgressFromServer() async {
        await progressCoordinator.refreshFromServer()
        await adoptStoredPosition()
    }

    /// Moves a paused playhead onto whatever the refresh just settled on.
    ///
    /// Merging the store is not enough on its own: when the app returns to the
    /// foreground with a book already loaded, the engine still holds the position it
    /// was paused at, so the screen keeps showing the old time and pressing play
    /// resumes there — and the next tick then writes that stale position back over the
    /// newer one from the other device. A cold launch never showed this because
    /// `restoreLastPlayed` reads the store after the merge.
    ///
    /// Only while paused: during playback this device is the one making the position,
    /// and yanking the playhead mid-listen would be wrong.
    private func adoptStoredPosition() async {
        guard let context, !isPlaying else { return }
        let stored = await progressStore.progress(forKey: context.key)

        guard let target = Self.positionToAdopt(stored: stored, playhead: engine.currentTime) else { return }
        engine.seek(to: target)
    }

    /// Where the playhead should move to after a refresh, or `nil` to leave it alone.
    ///
    /// Pure, and separate from the seek, so the rule can be tested without an engine.
    /// The merge has already decided which side is newer, so any real gap is the other
    /// device's position; the tolerance keeps a second or two of ordinary drift from
    /// jogging the playhead.
    nonisolated static func positionToAdopt(stored: LocalProgress?,
                                            playhead: TimeInterval,
                                            tolerance: TimeInterval = 5) -> TimeInterval? {
        guard let stored, !stored.isFinished else { return nil }
        guard abs(stored.currentTime - playhead) > tolerance else { return nil }
        return stored.currentTime
    }

    /// Called before the app suspends: persist everything immediately.
    public func prepareForSuspension() async {
        await flushProgress(force: true)
        await progressStore.flush()
    }

    // MARK: - Context construction

    private func makeContext(item: LibraryItem, episodeId: String?, forceTranscode: Bool) async throws -> PlaybackContext {
        let key = MediaProgress.key(itemId: item.id, episodeId: episodeId)

        // Downloaded copies win: no session to open, no bytes to spend, works in a tunnel.
        if !forceTranscode,
           let offlineItem = await offlineStore.item(forKey: key),
           offlineItem.isPlayableOffline,
           let context = await makeOfflineContext(for: offlineItem) {
            return context
        }

        guard let connection = await client.currentConnection else { throw ABSError.unauthorized }

        // The server will open a session for an item whose files have gone missing,
        // then serve 404s for every track. Failing here gives an accurate message
        // instead of two silent recovery attempts and a generic error.
        guard !item.isMissing else { throw ABSError.itemFilesMissing }

        let session = try await client.startPlaybackSession(
            itemId: item.id, episodeId: episodeId, forceTranscode: forceTranscode
        )

        let tracks: [PlayableTrack] = session.audioTracks.compactMap { track in
            guard let url = AudiobookshelfClient.streamURL(for: track, session: session, connection: connection) else { return nil }
            return PlayableTrack(index: track.index,
                                 startOffset: track.startOffset,
                                 duration: track.duration,
                                 url: url,
                                 isLocal: false)
        }
        guard !tracks.isEmpty else { throw ABSError.nothingToPlay }

        let chapters = session.chapters.isEmpty ? item.chapters : session.chapters

        return PlaybackContext(
            key: key,
            itemId: item.id,
            episodeId: episodeId,
            libraryId: item.libraryId,
            title: session.displayTitle.isEmpty ? item.title : session.displayTitle,
            author: session.displayAuthor ?? item.authorDisplay,
            narrator: item.narratorDisplay,
            coverURL: AudiobookshelfClient.coverURL(itemId: item.id, connection: connection, width: 600),
            localCoverURL: await offlineStore.coverURL(forKey: key),
            chapters: chapters,
            tracks: tracks,
            duration: session.duration > 0 ? session.duration : item.duration,
            serverSessionId: session.id,
            isOffline: false,
            serverResumeTime: session.currentTime
        )
    }

    private func makeOfflineContext(for offlineItem: OfflineItem) async -> PlaybackContext? {
        guard let localTracks = await offlineStore.localTrackURLs(forKey: offlineItem.key) else { return nil }

        let tracks = localTracks.map { entry in
            PlayableTrack(index: entry.track.index,
                          startOffset: entry.track.startOffset,
                          duration: entry.track.duration,
                          url: entry.url,
                          isLocal: true)
        }
        guard !tracks.isEmpty else { return nil }

        let connection = await client.currentConnection
        let remoteCover = connection.flatMap {
            AudiobookshelfClient.coverURL(itemId: offlineItem.itemId, connection: $0, width: 600)
        }

        return PlaybackContext(
            key: offlineItem.key,
            itemId: offlineItem.itemId,
            episodeId: offlineItem.episodeId,
            libraryId: offlineItem.libraryId,
            title: offlineItem.title,
            author: offlineItem.author,
            narrator: offlineItem.narrator,
            coverURL: remoteCover,
            localCoverURL: await offlineStore.coverURL(forKey: offlineItem.key),
            chapters: offlineItem.chapters,
            tracks: tracks,
            duration: offlineItem.duration > 0 ? offlineItem.duration : tracks.reduce(0) { $0 + $1.duration },
            serverSessionId: nil,
            isOffline: true
        )
    }

    /// Chooses where to resume. The local position wins whenever it exists — it is
    /// either newer than the server's or already reconciled with it.
    private func resolveStartTime(for context: PlaybackContext) async -> TimeInterval {
        context.resumePosition(local: await progressStore.progress(forKey: context.key))
    }

    // MARK: - Engine wiring

    private func wireEngine() {
        engine.onProgressTick = { [weak self] context, time, listened in
            guard let self else { return }
            Task { await self.progressCoordinator.record(context: context, currentTime: time, listenedDelta: listened) }
        }

        engine.onPlaybackFinished = { [weak self] context in
            guard let self else { return }
            Task {
                await self.progressCoordinator.setFinished(
                    itemId: context.itemId, episodeId: context.episodeId,
                    finished: true, duration: context.duration
                )
                await self.closeCurrentSession()
            }
        }

        engine.onRecoveryNeeded = { [weak self] context, forceTranscode in
            guard let self else { return nil }
            return await self.recoverContext(from: context, forceTranscode: forceTranscode)
        }
    }

    /// Rebuilds a context after a playback failure.
    ///
    /// The usual causes are an expired server session (the public track route 404s once
    /// the session closes) and a source AVFoundation can't decode. Re-requesting the
    /// session fixes the first; asking for a transcode fixes the second.
    private func recoverContext(from context: PlaybackContext, forceTranscode: Bool) async -> PlaybackContext? {
        // A local file that fails isn't going to succeed on retry — fall back to streaming.
        if context.isOffline {
            guard let item = try? await client.item(context.itemId) else { return nil }
            return try? await makeContext(item: item, episodeId: context.episodeId, forceTranscode: forceTranscode)
        }

        guard let item = try? await client.item(context.itemId) else { return nil }
        return try? await makeContext(item: item, episodeId: context.episodeId, forceTranscode: forceTranscode)
    }

    private func configureRemoteCommands() {
        var handlers = NowPlayingController.Handlers()
        handlers.play = { [weak self] in self?.play() }
        handlers.pause = { [weak self] in self?.pause() }
        handlers.toggle = { [weak self] in self?.togglePlayPause() }
        handlers.skipForward = { [weak self] interval in self?.engine.skipForward(interval) }
        handlers.skipBackward = { [weak self] interval in self?.engine.skipBackward(interval) }
        handlers.seek = { [weak self] time in self?.engine.seek(to: time) }
        handlers.nextChapter = { [weak self] in self?.engine.nextChapter() }
        handlers.previousChapter = { [weak self] in self?.engine.previousChapter() }
        handlers.setRate = { [weak self] rate in self?.setRate(rate) }

        NowPlayingController.shared.configure(
            handlers: handlers,
            skipForwardInterval: skipForwardInterval.seconds,
            skipBackwardInterval: skipBackwardInterval.seconds
        )
    }

    private func flushProgress(force: Bool) async {
        guard let context else { return }
        await progressCoordinator.record(context: context,
                                         currentTime: engine.currentTime,
                                         listenedDelta: 0,
                                         force: force)
    }

    /// Closes the outgoing session without blocking the caller.
    private func closeCurrentSessionDetached() {
        guard let context, let sessionId = context.serverSessionId else { return }
        let time = engine.currentTime
        Task { [progressCoordinator] in
            await progressCoordinator.closeSession(sessionId, context: context, currentTime: time)
        }
    }

    private func closeCurrentSession() async {
        guard let context, let sessionId = context.serverSessionId else { return }
        await progressCoordinator.closeSession(sessionId, context: context, currentTime: engine.currentTime)
    }
}
