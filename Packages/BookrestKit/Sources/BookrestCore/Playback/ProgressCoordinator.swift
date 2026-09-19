import Foundation
import ABSClient
import os

/// Keeps listening position consistent between the device and the server.
///
/// The local store is written on every tick and is always authoritative for the UI.
/// The server is updated on a slower cadence, and any update it rejects (or that
/// happens while offline) stays queued until it succeeds — so closing the app in a
/// tunnel never loses a position.
public actor ProgressCoordinator {
    private let client: AudiobookshelfClient
    private let progressStore: ProgressStore
    private let logger = Logger(subsystem: "com.bookrest.app", category: "progress")

    /// How often position is pushed to the server during continuous playback.
    private let serverSyncInterval: TimeInterval = 15

    private var lastServerSync: [String: Date] = [:]
    private var inFlight: Set<String> = []

    public init(client: AudiobookshelfClient, progressStore: ProgressStore) {
        self.client = client
        self.progressStore = progressStore
    }

    /// Records a position from the player. Always persists locally; pushes to the
    /// server only when the cadence is due or the caller forces it.
    public func record(context: PlaybackContext,
                       currentTime: TimeInterval,
                       listenedDelta: TimeInterval,
                       force: Bool = false) async {
        let isFinished = context.duration > 0 && currentTime >= context.duration - 5

        await progressStore.record(
            itemId: context.itemId,
            episodeId: context.episodeId,
            currentTime: currentTime,
            duration: context.duration,
            isFinished: isFinished,
            listenedDelta: listenedDelta
        )

        let key = context.key
        let due = force || lastServerSync[key].map { Date.now.timeIntervalSince($0) >= serverSyncInterval } ?? true
        guard due, !inFlight.contains(key) else { return }

        lastServerSync[key] = .now
        await pushToServer(context: context)
    }

    private func pushToServer(context: PlaybackContext) async {
        let key = context.key
        guard let local = await progressStore.progress(forKey: key), local.needsSync else { return }

        inFlight.insert(key)
        defer { inFlight.remove(key) }

        let timestamp = local.updatedAt
        let listened = local.pendingTimeListened

        do {
            if let sessionId = context.serverSessionId, !context.isOffline {
                // A live session also records listening statistics server-side.
                try await client.syncSession(sessionId, payload: SessionSyncPayload(
                    currentTime: local.currentTime,
                    timeListened: listened,
                    duration: local.duration
                ))
            } else {
                // Offline playback of a downloaded book has no session; patch the
                // position directly so other devices still see it.
                try await client.updateProgress(
                    itemId: context.itemId,
                    episodeId: context.episodeId,
                    payload: ProgressUpdatePayload(
                        currentTime: local.currentTime,
                        duration: local.duration,
                        progress: local.progress,
                        isFinished: local.isFinished
                    )
                )
            }
            await progressStore.markSynced(key: key, asOf: timestamp, consumedTimeListened: listened)
        } catch {
            // Left flagged; `syncPending` will pick it up when the network returns.
            logger.info("Deferred progress sync for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Flushes everything still queued. Called on reconnect, on foreground, and
    /// before the app suspends.
    public func syncPending() async {
        let pending = await progressStore.pendingSyncs()
        guard !pending.isEmpty else { return }
        guard await client.currentConnection != nil else { return }

        for entry in pending where !inFlight.contains(entry.key) {
            inFlight.insert(entry.key)
            do {
                try await client.updateProgress(
                    itemId: entry.itemId,
                    episodeId: entry.episodeId,
                    payload: ProgressUpdatePayload(
                        currentTime: entry.currentTime,
                        duration: entry.duration,
                        progress: entry.progress,
                        isFinished: entry.isFinished
                    )
                )
                await progressStore.markSynced(key: entry.key,
                                               asOf: entry.updatedAt,
                                               consumedTimeListened: entry.pendingTimeListened)
            } catch let error as ABSError where error.isOffline {
                // Still offline — stop trying the rest of the queue this pass.
                inFlight.remove(entry.key)
                break
            } catch {
                logger.info("Progress sync failed for \(entry.key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            inFlight.remove(entry.key)
        }

        await progressStore.flush()
    }

    /// Pulls the server's positions and folds them into the local store.
    public func refreshFromServer() async {
        do {
            let user = try await client.me()
            await progressStore.mergeFromServer(user.mediaProgress)
        } catch {
            logger.info("Could not refresh progress: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func closeSession(_ sessionId: String, context: PlaybackContext, currentTime: TimeInterval) async {
        let local = await progressStore.progress(forKey: context.key)
        let payload = SessionSyncPayload(
            currentTime: currentTime,
            timeListened: local?.pendingTimeListened ?? 0,
            duration: context.duration
        )
        do {
            try await client.closeSession(sessionId, payload: payload)
            if let local {
                await progressStore.markSynced(key: context.key,
                                               asOf: local.updatedAt,
                                               consumedTimeListened: local.pendingTimeListened)
            }
        } catch {
            logger.info("Session close deferred: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func setFinished(itemId: String, episodeId: String?, finished: Bool, duration: TimeInterval) async {
        await progressStore.setFinished(itemId: itemId, episodeId: episodeId,
                                        finished: finished, duration: duration)
        do {
            try await client.markFinished(itemId: itemId, episodeId: episodeId, finished: finished)
            let key = MediaProgress.key(itemId: itemId, episodeId: episodeId)
            if let entry = await progressStore.progress(forKey: key) {
                await progressStore.markSynced(key: key, asOf: entry.updatedAt, consumedTimeListened: 0)
            }
        } catch {
            logger.info("Finished-state sync deferred: \(error.localizedDescription, privacy: .public)")
        }
    }
}
