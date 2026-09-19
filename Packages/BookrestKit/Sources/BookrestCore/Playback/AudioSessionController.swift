import Foundation
import AVFoundation
import os

#if canImport(UIKit)
import UIKit
#endif

/// Owns the shared audio session on platforms that have one.
///
/// Spoken-audio mode gets Bookrest the right ducking and Bluetooth behaviour in a
/// car, and `.longFormAudio` routing policy is what lets AirPlay and CarPlay treat
/// it as a media app rather than a system sound.
@MainActor
public final class AudioSessionController {
    public static let shared = AudioSessionController()

    private let logger = Logger(subsystem: "com.bookrest.app", category: "audio-session")
    private var isConfigured = false

    /// Fired when the system interrupts playback (a call) and again when it ends.
    /// The Bool says whether the system suggests resuming.
    public var onInterruption: (@MainActor (Bool, Bool) -> Void)?
    /// Fired when headphones are unplugged or a Bluetooth device disconnects.
    public var onRouteLoss: (@MainActor () -> Void)?

    private init() {}

    /// Whether the session is configured and active. Playback cannot proceed on iOS
    /// without this, so failures are surfaced rather than logged and ignored.
    public private(set) var isActive = false
    public private(set) var lastError: String?

    @discardableResult
    public func activate() -> Bool {
        #if os(iOS) || os(tvOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()

        if !isConfigured {
            // Tried in order of preference. `.longFormAudio` is narrowly constrained —
            // it requires the playback category with default mode and no options — so
            // pairing it with `.spokenAudio` throws -50 and leaves the session
            // unconfigured, which strands AVPlayer at
            // `waitingToPlayAtSpecifiedRate` with no audible failure.
            let candidates: [(AVAudioSession.Mode, AVAudioSession.RouteSharingPolicy, String)] = [
                (.spokenAudio, .default, "spokenAudio"),
                (.default, .longFormAudio, "default/longFormAudio"),
                (.default, .default, "default"),
            ]

            for (mode, policy, label) in candidates {
                do {
                    try session.setCategory(.playback, mode: mode, policy: policy, options: [])
                    logger.info("Audio session category set (\(label, privacy: .public))")
                    registerForNotifications()
                    isConfigured = true
                    lastError = nil
                    break
                } catch {
                    logger.error("Category \(label, privacy: .public) rejected: \(error.localizedDescription, privacy: .public)")
                    lastError = error.localizedDescription
                }
            }

            guard isConfigured else {
                logger.error("No audio session category was accepted; playback will not start")
                isActive = false
                return false
            }
        }

        do {
            try session.setActive(true, options: [])
            isActive = true
            lastError = nil
            return true
        } catch {
            logger.error("Audio session activation failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            isActive = false
            return false
        }
        #else
        isActive = true
        return true
        #endif
    }

    public func deactivate() {
        #if os(iOS) || os(tvOS) || os(visionOS)
        isActive = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            logger.info("Audio session deactivation: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    private func registerForNotifications() {
        let center = NotificationCenter.default

        center.addObserver(forName: AVAudioSession.interruptionNotification,
                           object: AVAudioSession.sharedInstance(),
                           queue: .main) { [weak self] notification in
            guard let self else { return }
            let info = notification.userInfo
            let rawType = info?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            let rawOptions = info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let began = AVAudioSession.InterruptionType(rawValue: rawType) == .began
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)

            MainActor.assumeIsolated {
                self.onInterruption?(began, shouldResume)
            }
        }

        center.addObserver(forName: AVAudioSession.routeChangeNotification,
                           object: AVAudioSession.sharedInstance(),
                           queue: .main) { [weak self] notification in
            guard let self else { return }
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            // Pausing when the old device disappears is what users expect from
            // yanked headphones, and matches every other audio app.
            guard AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable else { return }

            MainActor.assumeIsolated {
                self.onRouteLoss?()
            }
        }
    }
    #endif
}
