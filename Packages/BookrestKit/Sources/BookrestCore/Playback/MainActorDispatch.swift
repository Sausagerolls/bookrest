import Foundation

/// Runs `body` on the main actor, synchronously when already there.
///
/// System frameworks invoke callbacks on queues they don't document —
/// `MPMediaItemArtwork` uses a private serial queue, and remote-command and CarPlay
/// handlers make no written guarantee either. A closure built inside a `@MainActor`
/// type inherits that isolation and the runtime traps on entry if the guess is
/// wrong, so callbacks are registered as `@Sendable` (non-isolated) and hop through
/// here instead of assuming.
@inline(__always)
public func onMainActor(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        Task { @MainActor in body() }
    }
}
