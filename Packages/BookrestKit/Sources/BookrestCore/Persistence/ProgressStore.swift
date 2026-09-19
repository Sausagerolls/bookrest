import Foundation
import ABSClient

/// Local listening positions, and the queue of positions the server hasn't seen yet.
///
/// The device is authoritative while offline; on reconnect, positions are merged
/// last-write-wins by timestamp so listening on a phone and a laptop converges
/// instead of one silently clobbering the other.
public actor ProgressStore {
    private let store: JSONFileStore<[String: LocalProgress]>

    public init(url: URL = StorageLocations.progressFile) {
        self.store = JSONFileStore(url: url) { [:] }
    }

    public func progress(forKey key: String) async -> LocalProgress? {
        await store.load()[key]
    }

    public func progress(itemId: String, episodeId: String? = nil) async -> LocalProgress? {
        await progress(forKey: MediaProgress.key(itemId: itemId, episodeId: episodeId))
    }

    public func all() async -> [String: LocalProgress] {
        await store.load()
    }

    /// Records a position produced by local playback. Always wins over whatever is
    /// stored, because it is by definition the newest thing that happened here.
    ///
    /// NOTE: this unconditionally re-stamps `updatedAt`, so a flush that changes
    /// nothing (pause, and every app suspend) still marks the position as the newest
    /// write anywhere — which defeats cross-device merging. The obvious fix, skipping
    /// the re-stamp when the position is unchanged, broke playback in build
    /// 202609042005 and was reverted pending a proper diagnosis. Do not reapply it
    /// without reproducing that failure first.
    public func record(itemId: String, episodeId: String?, currentTime: TimeInterval,
                       duration: TimeInterval, isFinished: Bool,
                       listenedDelta: TimeInterval) async {
        let key = MediaProgress.key(itemId: itemId, episodeId: episodeId)
        _ = await store.update { table in
            var entry = table[key] ?? LocalProgress(
                key: key, itemId: itemId, episodeId: episodeId,
                currentTime: currentTime, duration: duration,
                isFinished: isFinished, updatedAt: .now
            )
            entry.currentTime = currentTime
            if duration > 0 { entry.duration = duration }
            entry.isFinished = isFinished
            entry.updatedAt = .now
            entry.pendingTimeListened += max(0, listenedDelta)
            entry.needsSync = true
            table[key] = entry
        }
    }

    /// Folds the server's view of progress in. The newer timestamp wins, full stop.
    ///
    /// A queued local write used to win automatically, on the reasoning that it had
    /// not been uploaded yet. That is wrong once a second device is involved: if this
    /// device has an old position still waiting to sync, another device can have
    /// listened long after it was queued, and letting the queued write survive means
    /// it gets pushed later and destroys the newer position. Comparing timestamps is
    /// what actually makes two devices converge, which is what this store promises.
    ///
    /// Adopting the server's entry drops any `pendingTimeListened` accumulated against
    /// the superseded position. That statistic is worth less than the position being
    /// right, and pushing it would carry the stale position along with it.
    public func mergeFromServer(_ serverProgress: [MediaProgress]) async {
        _ = await store.update { table in
            for remote in serverProgress {
                let incoming = LocalProgress(server: remote)
                guard let existing = table[incoming.key] else {
                    table[incoming.key] = incoming
                    continue
                }
                guard incoming.updatedAt > existing.updatedAt else { continue }
                table[incoming.key] = incoming
            }
        }
    }

    public func pendingSyncs() async -> [LocalProgress] {
        await store.load().values.filter(\.needsSync).sorted { $0.updatedAt < $1.updatedAt }
    }

    /// Clears the sync flag, but only if nothing changed while the upload was in
    /// flight — otherwise the newer local position would be dropped.
    public func markSynced(key: String, asOf timestamp: Date, consumedTimeListened: TimeInterval) async {
        _ = await store.update { table in
            guard var entry = table[key] else { return }
            guard entry.updatedAt <= timestamp else { return }
            entry.needsSync = false
            entry.pendingTimeListened = max(0, entry.pendingTimeListened - consumedTimeListened)
            table[key] = entry
        }
    }

    public func setFinished(itemId: String, episodeId: String?, finished: Bool, duration: TimeInterval) async {
        let key = MediaProgress.key(itemId: itemId, episodeId: episodeId)
        _ = await store.update { table in
            var entry = table[key] ?? LocalProgress(
                key: key, itemId: itemId, episodeId: episodeId,
                currentTime: finished ? duration : 0, duration: duration,
                isFinished: finished, updatedAt: .now
            )
            entry.isFinished = finished
            entry.currentTime = finished ? max(entry.duration, duration) : 0
            entry.updatedAt = .now
            entry.needsSync = true
            table[key] = entry
        }
    }

    public func remove(key: String) async {
        _ = await store.update { $0[key] = nil }
    }

    public func flush() async {
        await store.flush()
    }
}
