import Foundation
import MediaPlayer
import ABSClient

#if canImport(UIKit)
import UIKit
#endif

/// Publishes the current item to the system: lock screen, Control Centre, the Mac
/// menu bar, AirPods controls and CarPlay's own transport bar all read from here.
@MainActor
public final class NowPlayingController {
    public static let shared = NowPlayingController()

    /// Actions the system can ask for. Wired up once by `PlaybackController`.
    public struct Handlers: Sendable {
        public var play: @MainActor () -> Void = {}
        public var pause: @MainActor () -> Void = {}
        public var toggle: @MainActor () -> Void = {}
        public var skipForward: @MainActor (TimeInterval) -> Void = { _ in }
        public var skipBackward: @MainActor (TimeInterval) -> Void = { _ in }
        public var seek: @MainActor (TimeInterval) -> Void = { _ in }
        public var nextChapter: @MainActor () -> Void = {}
        public var previousChapter: @MainActor () -> Void = {}
        public var setRate: @MainActor (Float) -> Void = { _ in }

        public init() {}
    }

    private var handlers = Handlers()
    private var artworkCache: [String: MPMediaItemArtwork] = [:]
    private var artworkTask: Task<Void, Never>?
    private var currentKey: String?

    private init() {}

    public func configure(handlers: Handlers,
                          skipForwardInterval: TimeInterval,
                          skipBackwardInterval: TimeInterval) {
        self.handlers = handlers

        let center = MPRemoteCommandCenter.shared()

        center.playCommand.removeTarget(nil)
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { @Sendable [weak self] _ in
            onMainActor { self?.handlers.play() }
            return .success
        }

        center.pauseCommand.removeTarget(nil)
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { @Sendable [weak self] _ in
            onMainActor { self?.handlers.pause() }
            return .success
        }

        center.togglePlayPauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { @Sendable [weak self] _ in
            onMainActor { self?.handlers.toggle() }
            return .success
        }

        center.skipForwardCommand.removeTarget(nil)
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForwardInterval)]
        center.skipForwardCommand.addTarget { @Sendable [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? skipForwardInterval
            onMainActor { self?.handlers.skipForward(interval) }
            return .success
        }

        center.skipBackwardCommand.removeTarget(nil)
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBackwardInterval)]
        center.skipBackwardCommand.addTarget { @Sendable [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? skipBackwardInterval
            onMainActor { self?.handlers.skipBackward(interval) }
            return .success
        }

        center.changePlaybackPositionCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            onMainActor { self?.handlers.seek(position) }
            return .success
        }

        // Chapters are the meaningful "track" unit in an audiobook, so the
        // next/previous transport controls move between them.
        center.nextTrackCommand.removeTarget(nil)
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { @Sendable [weak self] _ in
            onMainActor { self?.handlers.nextChapter() }
            return .success
        }

        center.previousTrackCommand.removeTarget(nil)
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { @Sendable [weak self] _ in
            onMainActor { self?.handlers.previousChapter() }
            return .success
        }

        center.changePlaybackRateCommand.removeTarget(nil)
        center.changePlaybackRateCommand.isEnabled = true
        center.changePlaybackRateCommand.supportedPlaybackRates =
            PlaybackRate.options.map { NSNumber(value: $0) }
        center.changePlaybackRateCommand.addTarget { @Sendable [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            let rate = event.playbackRate
            onMainActor { self?.handlers.setRate(rate) }
            return .success
        }

        // Explicitly disabled so the system doesn't offer controls Bookrest ignores.
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
        center.ratingCommand.isEnabled = false
        center.likeCommand.isEnabled = false
        center.dislikeCommand.isEnabled = false
    }

    public func update(context: PlaybackContext, elapsed: TimeInterval, rate: Float) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: context.chapter(at: elapsed)?.title ?? context.title,
            MPMediaItemPropertyAlbumTitle: context.title,
            MPMediaItemPropertyArtist: context.author ?? "",
            MPMediaItemPropertyPlaybackDuration: context.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: rate == 0 ? 1.0 : rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]

        if let artwork = artworkCache[context.key] {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = rate > 0 ? .playing : .paused

        if artworkCache[context.key] == nil, currentKey != context.key {
            currentKey = context.key
            loadArtwork(for: context)
        }
    }

    /// Lightweight update on the periodic tick — rebuilding the whole dictionary
    /// every half second causes visible flicker in Control Centre.
    public func updateElapsed(_ elapsed: TimeInterval, rate: Float) {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = rate > 0 ? .playing : .paused
    }

    public func clear() {
        artworkTask?.cancel()
        currentKey = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func loadArtwork(for context: PlaybackContext) {
        artworkTask?.cancel()
        // Prefer the downloaded cover: it's instant and works with no network.
        let source = context.localCoverURL ?? context.coverURL
        guard let source else { return }

        artworkTask = Task { [weak self] in
            guard let data = await Self.loadImageData(from: source) else { return }
            guard let artwork = Self.makeArtwork(from: data) else { return }
            guard !Task.isCancelled else { return }

            self?.artworkCache[context.key] = artwork
            guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    private nonisolated static func loadImageData(from url: URL) async -> Data? {
        if url.isFileURL { return try? Data(contentsOf: url) }
        return try? await URLSession.shared.data(from: url).0
    }

    /// Must be `nonisolated`.
    ///
    /// MediaPlayer invokes an artwork request handler on its own private serial
    /// queue. Built inside this `@MainActor` type the closure would inherit main-actor
    /// isolation, and the runtime's executor check then traps
    /// (`dispatch_assert_queue_fail`) the first time the system asks for artwork —
    /// which is on every playback start, on iOS and CarPlay as well as the Mac.
    nonisolated static func makeArtwork(from data: Data) -> MPMediaItemArtwork? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        let box = ArtworkBox(image)
        return MPMediaItemArtwork(boundsSize: image.size) { _ in box.image }
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        let box = ArtworkBox(image)
        return MPMediaItemArtwork(boundsSize: image.size) { _ in box.image }
        #else
        return nil
        #endif
    }
}

#if canImport(AppKit)
import AppKit
#endif

/// Carries an immutable platform image into MediaPlayer's non-isolated callback.
private final class ArtworkBox: @unchecked Sendable {
    #if canImport(UIKit)
    let image: UIImage
    init(_ image: UIImage) { self.image = image }
    #elseif canImport(AppKit)
    let image: NSImage
    init(_ image: NSImage) { self.image = image }
    #endif
}
