import Foundation
import AVFoundation
import Observation
import ABSClient
import os

/// The audio engine.
///
/// Audiobookshelf items are frequently split across many audio files, so the engine
/// keeps a single continuous timeline for the whole item and maps it onto an
/// `AVQueuePlayer`'s per-file clock. Everything above this layer — UI, CarPlay,
/// progress reporting — deals only in absolute item time.
@MainActor
@Observable
public final class PlayerEngine {

    // MARK: - Observable state

    public private(set) var context: PlaybackContext?
    public private(set) var status: PlaybackStatus = .idle
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var bufferedTime: TimeInterval = 0
    public private(set) var currentChapter: Chapter?

    public var duration: TimeInterval { context?.duration ?? 0 }

    public var isPlaying: Bool { status == .playing }

    public var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    public private(set) var rate: Float = PlaybackRate.default {
        didSet { if isPlaying { player.rate = rate } }
    }

    // MARK: - Callbacks

    /// Reports the current position on a cadence suitable for persisting.
    public var onProgressTick: (@MainActor (PlaybackContext, TimeInterval, TimeInterval) -> Void)?
    /// Called when the final track finishes.
    public var onPlaybackFinished: (@MainActor (PlaybackContext) -> Void)?
    /// Asked to produce a fresh context when playback fails in a way that a new
    /// server session might fix (expired session, source the device can't decode).
    public var onRecoveryNeeded: (@MainActor (PlaybackContext, Bool) async -> PlaybackContext?)?

    // MARK: - Internals

    private let player = AVQueuePlayer()
    private let logger = Logger(subsystem: "com.bookrest.app", category: "player")

    /// Maps each queued `AVPlayerItem` back to the track it represents.
    private var trackIndexByItem: [ObjectIdentifier: Int] = [:]
    private var currentTrackIndex: Int = 0

    /// Observer registrations live in a non-isolated box so `deinit` can tear them
    /// down; a main-actor `deinit` isn't allowed to touch isolated state.
    private let observers = ObserverBag()
    /// Replaced rather than appended, so switching tracks doesn't accumulate KVO
    /// registrations for items that are already gone.
    private var itemStatusObservation: NSKeyValueObservation?
    /// A requested start position waiting on the current item to become ready.
    private var pendingStart: (offset: TimeInterval, autoPlay: Bool)?
    private var loadWatchdog: Task<Void, Never>?

    private var lastTickTime: TimeInterval = 0
    private var lastTickWallClock: Date = .now
    private var recoveryAttempts = 0
    private var isRecovering = false
    private var resumeAfterInterruption = false

    private var sleepTimerTask: Task<Void, Never>?
    public private(set) var sleepTimerRemaining: TimeInterval?
    public private(set) var sleepTimerStopsAtChapterEnd = false

    public init() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .advance
        configureObservers()
        configureAudioSessionHandlers()
    }

    // MARK: - Loading

    /// Loads an item and begins playback from `startTime`.
    public func load(_ context: PlaybackContext, startingAt startTime: TimeInterval, autoPlay: Bool = true) {
        guard !context.tracks.isEmpty else {
            status = .failed("This item has no playable audio.")
            return
        }

        self.context = context
        status = .loading
        recoveryAttempts = 0
        currentTime = min(max(0, startTime), max(0, context.duration - 1))
        lastTickTime = currentTime
        lastTickWallClock = .now
        currentChapter = context.chapter(at: currentTime)

        if !AudioSessionController.shared.activate() {
            let reason = AudioSessionController.shared.lastError ?? "The audio session could not be started."
            status = .failed("Audio couldn't start. \(reason)")
            return
        }

        rebuildQueue(startingAt: currentTime, autoPlay: autoPlay)
        startLoadWatchdog()
    }

    /// Reports a start that never progresses.
    ///
    /// Without this, anything that prevents the first frame — an unreachable host, a
    /// stalled session, an item stuck short of `.readyToPlay` — leaves the UI on a
    /// spinner indefinitely with nothing to act on.
    private func startLoadWatchdog() {
        loadWatchdog?.cancel()
        let expected = currentTime
        loadWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard let self, !Task.isCancelled else { return }
            guard self.status == .buffering || self.status == .loading else { return }
            guard self.currentTime <= expected + 0.5 else { return }

            let detail = self.context?.tracks.first?.isLocal == true
                ? "The downloaded file couldn't be played."
                : "The server didn't start sending audio."
            self.logger.error("Playback never started for \(self.context?.key ?? "?", privacy: .public)")

            // Reuse the failure path: a stalled start is usually a dead session or a
            // source the device can't decode, and both are what recovery handles.
            // Only report an error once recovery is exhausted.
            self.handlePlaybackFailure(StalledStartError(detail: detail))
        }
    }

    /// Rebuilds the queue so the item containing `time` is first.
    ///
    /// `AVPlayerItem`s can't be re-enqueued once consumed, so every seek that crosses
    /// a file boundary constructs fresh items. For the common single-file audiobook
    /// this path runs exactly once.
    private func rebuildQueue(startingAt time: TimeInterval, autoPlay: Bool) {
        guard let context else { return }
        guard let startTrack = context.track(at: time) else { return }

        player.pause()
        player.removeAllItems()
        trackIndexByItem.removeAll()

        let ordered = context.tracks.sorted { $0.index < $1.index }
        guard let startPosition = ordered.firstIndex(where: { $0.index == startTrack.index }) else { return }

        for track in ordered[startPosition...] {
            let item = makePlayerItem(for: track)
            trackIndexByItem[ObjectIdentifier(item)] = track.index
            if player.canInsert(item, after: nil) {
                player.insert(item, after: nil)
            }
        }

        currentTrackIndex = startTrack.index
        let offsetInTrack = max(0, time - startTrack.startOffset)

        // Deferred rather than driven from a seek completion. Seeking a freshly
        // inserted item that isn't ready yet may not call back at all, which left
        // playback silently stuck with the transport showing "Play".
        pendingStart = (offset: offsetInTrack, autoPlay: autoPlay)
        status = autoPlay ? .buffering : .paused

        if let item = player.currentItem { observeItemStatus(item) }
        applyPendingStartIfReady()
        updateNowPlaying()
    }

    /// Performs the deferred seek-and-play once the current item can service it.
    ///
    /// Called both immediately (the item may already be ready, in which case the KVO
    /// change notification never arrives) and from the readiness observer.
    private func applyPendingStartIfReady() {
        guard let pending = pendingStart,
              let item = player.currentItem,
              item.status == .readyToPlay
        else { return }

        pendingStart = nil

        let start: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            if pending.autoPlay {
                self.player.rate = self.rate
                self.status = .playing
            } else {
                self.status = .paused
            }
            self.updateNowPlaying()
        }

        // Skip a no-op seek; starting at zero is the common case for a new book.
        if pending.offset > 0.5 {
            seekWithinCurrentItem(to: pending.offset, tolerance: 1, completion: start)
        } else {
            start()
        }
    }

    private func makePlayerItem(for track: PlayableTrack) -> AVPlayerItem {
        let asset = AVURLAsset(url: track.url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
        let item = AVPlayerItem(asset: asset)
        // Left automatic (0). Asking for a large forward buffer here does not make
        // playback more robust — combined with `automaticallyWaitsToMinimizeStalling`
        // it stops playback beginning until that much audio is buffered, which on a
        // phone over cellular reads as an endless spinner. AVFoundation's own
        // heuristics start promptly and keep buffering ahead.
        item.preferredForwardBufferDuration = 0
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        return item
    }

    // MARK: - Transport

    public func play() {
        guard context != nil else { return }
        AudioSessionController.shared.activate()
        player.rate = rate
        status = .playing
        updateNowPlaying()
    }

    public func pause() {
        player.pause()
        if status.isActive { status = .paused }
        flushProgress()
        updateNowPlaying()
    }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    public func stop() {
        flushProgress()
        player.pause()
        player.removeAllItems()
        trackIndexByItem.removeAll()
        cancelSleepTimer()
        loadWatchdog?.cancel()
        loadWatchdog = nil
        pendingStart = nil
        context = nil
        status = .idle
        currentTime = 0
        currentChapter = nil
        NowPlayingController.shared.clear()
        AudioSessionController.shared.deactivate()
    }

    public func setRate(_ newRate: Float) {
        rate = PlaybackRate.clamp(newRate)
        updateNowPlaying()
    }

    /// Seeks to an absolute position in the item's timeline.
    public func seek(to time: TimeInterval, completion: (@MainActor () -> Void)? = nil) {
        guard let context else { return }
        let target = min(max(0, time), max(0, context.duration))
        flushProgress()

        guard let track = context.track(at: target) else { return }

        currentTime = target
        currentChapter = context.chapter(at: target)
        lastTickTime = target
        lastTickWallClock = .now

        if track.index == currentTrackIndex, player.currentItem != nil {
            seekWithinCurrentItem(to: target - track.startOffset) { [weak self] in
                self?.updateNowPlaying()
                completion?()
            }
        } else {
            // Crossing a file boundary: rebuild from the new track.
            let wasPlaying = isPlaying
            rebuildQueue(startingAt: target, autoPlay: wasPlaying)
            completion?()
        }
    }

    /// Seeks the current item, with a tolerance.
    ///
    /// Never zero. Sample-exact seeking forces AVFoundation to fetch and parse its way
    /// to a precise frame, which on a multi-hour compressed file served over HTTP can
    /// take minutes or never complete — resuming a book ten hours in simply hung. A
    /// fraction of a second either side is inaudible in speech and lands promptly.
    private func seekWithinCurrentItem(to offset: TimeInterval,
                                       tolerance: TimeInterval = 0.25,
                                       completion: @escaping @MainActor () -> Void) {
        let target = CMTime(seconds: max(0, offset), preferredTimescale: 600)
        let slack = CMTime(seconds: max(0.05, tolerance), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: slack, toleranceAfter: slack) { _ in
            Task { @MainActor in completion() }
        }
    }

    public func skipForward(_ interval: TimeInterval) {
        seek(to: currentTime + interval)
    }

    public func skipBackward(_ interval: TimeInterval) {
        seek(to: currentTime - interval)
    }

    // MARK: - Chapters

    public func seekToChapter(_ chapter: Chapter) {
        seek(to: chapter.start)
    }

    public func nextChapter() {
        guard let context, let current = context.chapter(at: currentTime) else {
            skipForward(30)
            return
        }
        if let next = context.chapters.first(where: { $0.start > current.start }) {
            seek(to: next.start)
        } else {
            seek(to: context.duration)
        }
    }

    /// Mirrors the familiar music-player behaviour: restart the chapter unless we're
    /// already near its start, in which case jump to the previous one.
    public func previousChapter() {
        guard let context, let current = context.chapter(at: currentTime) else {
            skipBackward(30)
            return
        }
        if currentTime - current.start > 3 {
            seek(to: current.start)
        } else if let previous = context.chapters.last(where: { $0.start < current.start }) {
            seek(to: previous.start)
        } else {
            seek(to: 0)
        }
    }

    // MARK: - Sleep timer

    public func startSleepTimer(duration: TimeInterval) {
        cancelSleepTimer()
        sleepTimerStopsAtChapterEnd = false
        sleepTimerRemaining = duration
        runSleepTimer()
    }

    public func startSleepTimerAtEndOfChapter() {
        cancelSleepTimer()
        guard let context, let chapter = context.chapter(at: currentTime) else { return }
        sleepTimerStopsAtChapterEnd = true
        sleepTimerRemaining = max(0, chapter.end - currentTime)
        runSleepTimer()
    }

    /// Extends a running timer — the "give me a bit longer" gesture.
    public func extendSleepTimer(by interval: TimeInterval) {
        guard let remaining = sleepTimerRemaining else { return }
        sleepTimerStopsAtChapterEnd = false
        sleepTimerRemaining = remaining + interval
    }

    public func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerRemaining = nil
        sleepTimerStopsAtChapterEnd = false
    }

    private func runSleepTimer() {
        sleepTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                guard let remaining = self.sleepTimerRemaining else { return }

                // Only count down while actually playing, so pausing doesn't burn the timer.
                guard self.isPlaying else { continue }

                let next = remaining - 1
                if next <= 0 {
                    self.sleepTimerRemaining = nil
                    self.sleepTimerStopsAtChapterEnd = false
                    await self.fadeOutAndPause()
                    return
                }
                self.sleepTimerRemaining = next
            }
        }
    }

    /// Fades over a second rather than cutting out, which is far less jarring when
    /// someone is falling asleep.
    private func fadeOutAndPause() async {
        let steps = 10
        let startVolume = player.volume
        for step in 0..<steps {
            guard !Task.isCancelled else { break }
            player.volume = startVolume * Float(steps - step - 1) / Float(steps)
            try? await Task.sleep(for: .milliseconds(100))
        }
        pause()
        player.volume = startVolume
    }

    // MARK: - Observation

    private func configureObservers() {
        observers.player = player
        observers.timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleTimeUpdate() }
        }

        observers.keyValue.append(player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.handleCurrentItemChanged() }
        })

        observers.keyValue.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in self?.handleTimeControlStatusChanged(player.timeControlStatus) }
        })

        let center = NotificationCenter.default

        observers.notifications.append(center.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            Task { @MainActor in self?.handleItemDidPlayToEnd(item) }
        })

        observers.notifications.append(center.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in self?.handlePlaybackFailure(error) }
        })

        observers.notifications.append(center.addObserver(
            forName: AVPlayerItem.playbackStalledNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleStall() }
        })
    }

    private func configureAudioSessionHandlers() {
        AudioSessionController.shared.onInterruption = { [weak self] began, shouldResume in
            guard let self else { return }
            if began {
                self.resumeAfterInterruption = self.isPlaying
                self.pause()
            } else if shouldResume, self.resumeAfterInterruption {
                self.resumeAfterInterruption = false
                self.play()
            }
        }

        AudioSessionController.shared.onRouteLoss = { [weak self] in
            self?.pause()
        }
    }

    // MARK: - Event handling

    private func handleTimeUpdate() {
        guard let context, let item = player.currentItem else { return }
        guard let trackIndex = trackIndexByItem[ObjectIdentifier(item)],
              let track = context.tracks.first(where: { $0.index == trackIndex })
        else { return }

        let offset = item.currentTime().seconds
        guard offset.isFinite else { return }

        currentTime = min(context.duration, track.startOffset + offset)
        currentChapter = context.chapter(at: currentTime)
        if offset > 0 { loadWatchdog?.cancel(); loadWatchdog = nil }

        if let range = item.loadedTimeRanges.last?.timeRangeValue {
            let bufferedEnd = (range.start + range.duration).seconds
            if bufferedEnd.isFinite { bufferedTime = track.startOffset + bufferedEnd }
        }

        // Report roughly once a second, with the wall-clock delta so that time spent
        // at 2× counts as the real seconds it occupied.
        let elapsed = Date.now.timeIntervalSince(lastTickWallClock)
        if elapsed >= 1 {
            let listened = min(elapsed, max(0, currentTime - lastTickTime) + 1)
            onProgressTick?(context, currentTime, isPlaying ? listened : 0)
            lastTickTime = currentTime
            lastTickWallClock = .now
        }

        NowPlayingController.shared.updateElapsed(currentTime, rate: isPlaying ? rate : 0)
    }

    private func handleCurrentItemChanged() {
        guard let item = player.currentItem else { return }
        if let index = trackIndexByItem[ObjectIdentifier(item)] {
            currentTrackIndex = index
        }
        observeItemStatus(item)
        applyPendingStartIfReady()
    }

    private func observeItemStatus(_ item: AVPlayerItem) {
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .failed:
                    self.handlePlaybackFailure(item.error)
                case .readyToPlay:
                    self.recoveryAttempts = 0
                    self.applyPendingStartIfReady()
                    if self.pendingStart == nil,
                       self.status == .loading || self.status == .buffering {
                        self.status = self.player.rate > 0 ? .playing : .paused
                    }
                default:
                    break
                }
            }
        }
    }

    private func handleTimeControlStatusChanged(_ newStatus: AVPlayer.TimeControlStatus) {
        switch newStatus {
        case .playing:
            status = .playing
        case .waitingToPlayAtSpecifiedRate:
            if status == .playing { status = .buffering }
        case .paused:
            if status == .playing { status = .paused }
        @unknown default:
            break
        }
        NowPlayingController.shared.updateElapsed(currentTime, rate: isPlaying ? rate : 0)
    }

    private func handleItemDidPlayToEnd(_ item: AVPlayerItem) {
        guard let context, trackIndexByItem[ObjectIdentifier(item)] != nil else { return }

        let isLastTrack = trackIndexByItem[ObjectIdentifier(item)] == context.tracks.map(\.index).max()
        guard isLastTrack else {
            // AVQueuePlayer advances on its own; just keep the rate through the seam.
            player.rate = rate
            return
        }

        currentTime = context.duration
        status = .paused
        flushProgress()
        cancelSleepTimer()
        onPlaybackFinished?(context)
    }

    private func handleStall() {
        guard isPlaying else { return }
        status = .buffering
        logger.info("Playback stalled; waiting for buffer")

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.status == .buffering else { return }
            // Nudging the rate restarts a player that buffered but didn't resume.
            self.player.rate = self.rate
        }
    }

    private func handlePlaybackFailure(_ error: Error?) {
        let message = error?.localizedDescription ?? "Playback failed."
        logger.error("Playback failure: \(message, privacy: .public)")

        guard !isRecovering, let context, recoveryAttempts < 2 else {
            status = .failed(message)
            return
        }

        isRecovering = true
        recoveryAttempts += 1
        status = .buffering

        let resumeAt = currentTime
        // The second attempt asks the server to transcode: a source AVFoundation
        // can't decode will fail identically on a retry, but plays fine as HLS.
        let forceTranscode = recoveryAttempts >= 2

        Task { [weak self] in
            guard let self else { return }
            defer { self.isRecovering = false }

            guard let recovered = await self.onRecoveryNeeded?(context, forceTranscode) else {
                self.status = .failed(message)
                return
            }
            self.load(recovered, startingAt: resumeAt, autoPlay: true)
        }
    }

    private func flushProgress() {
        guard let context else { return }
        let elapsed = Date.now.timeIntervalSince(lastTickWallClock)
        let listened = isPlaying ? min(elapsed, max(0, currentTime - lastTickTime) + 1) : 0
        onProgressTick?(context, currentTime, listened)
        lastTickTime = currentTime
        lastTickWallClock = .now
    }

    private func updateNowPlaying() {
        guard let context else { return }
        NowPlayingController.shared.update(context: context,
                                           elapsed: currentTime,
                                           rate: isPlaying ? rate : 0)
    }
}

/// Holds observer registrations outside the main actor so they can be released in
/// `deinit`, which runs without isolation.
private final class ObserverBag: @unchecked Sendable {
    var player: AVQueuePlayer?
    var timeObserver: Any?
    var keyValue: [NSKeyValueObservation] = []
    var notifications: [NSObjectProtocol] = []

    deinit {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        for token in notifications { NotificationCenter.default.removeObserver(token) }
    }
}


/// Distinguishes a start that never produced audio from an AVFoundation error.
private struct StalledStartError: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}
