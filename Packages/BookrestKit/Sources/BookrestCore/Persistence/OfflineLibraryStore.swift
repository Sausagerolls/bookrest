import Foundation
import ABSClient
import os

/// The catalogue of downloaded items, and the files behind them.
public actor OfflineLibraryStore {
    private let store: JSONFileStore<[String: OfflineItem]>
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "com.bookrest.app", category: "offline")

    /// Emitted after any change so observers can refresh without polling.
    private var changeObservers: [UUID: @Sendable ([OfflineItem]) -> Void] = [:]

    public init(url: URL = StorageLocations.indexFile) {
        self.store = JSONFileStore(url: url) { [:] }
        StorageLocations.ensureDirectories()
    }

    // MARK: - Reading

    public func allItems() async -> [OfflineItem] {
        await store.load().values.sorted { $0.downloadedAt > $1.downloadedAt }
    }

    public func completedItems() async -> [OfflineItem] {
        await allItems().filter(\.isPlayableOffline)
    }

    public func item(forKey key: String) async -> OfflineItem? {
        await store.load()[key]
    }

    public func item(itemId: String, episodeId: String? = nil) async -> OfflineItem? {
        await item(forKey: MediaProgress.key(itemId: itemId, episodeId: episodeId))
    }

    public func isDownloaded(itemId: String, episodeId: String? = nil) async -> Bool {
        await item(itemId: itemId, episodeId: episodeId)?.isPlayableOffline == true
    }

    public func totalBytesOnDisk() async -> Int64 {
        await allItems().reduce(0) { $0 + $1.bytesDownloaded }
    }

    // MARK: - File locations

    public nonisolated func folderURL(forKey key: String) -> URL {
        StorageLocations.itemFolder(forKey: key)
    }

    public nonisolated func fileURL(forKey key: String, fileName: String) -> URL {
        folderURL(forKey: key).appendingPathComponent(fileName)
    }

    public func coverURL(forKey key: String) async -> URL? {
        guard let item = await item(forKey: key), let coverFileName = item.coverFileName else { return nil }
        let url = fileURL(forKey: key, fileName: coverFileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Local URLs for an item's tracks, in playback order. Returns nil if any file is
    /// missing, so the player never starts a book it can only partially play.
    public func localTrackURLs(forKey key: String) async -> [(track: OfflineTrack, url: URL)]? {
        guard let item = await item(forKey: key), item.isPlayableOffline else { return nil }
        var result: [(OfflineTrack, URL)] = []
        for track in item.tracks.sorted(by: { $0.index < $1.index }) {
            let url = fileURL(forKey: key, fileName: track.fileName)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            result.append((track, url))
        }
        return result
    }

    // MARK: - Writing

    public func upsert(_ item: OfflineItem) async {
        _ = await store.update { $0[item.key] = item }
        await notifyObservers()
    }

    public func mutate(key: String, _ transform: @Sendable @escaping (inout OfflineItem) -> Void) async {
        _ = await store.update { table in
            guard var item = table[key] else { return }
            transform(&item)
            table[key] = item
        }
        await notifyObservers()
    }

    public func setState(key: String, _ state: OfflineState, error: String? = nil) async {
        await mutate(key: key) { item in
            item.state = state
            item.lastError = error
        }
    }

    public func recordTrackProgress(key: String, trackIndex: Int,
                                    bytesDownloaded: Int64, expectedBytes: Int64) async {
        await mutate(key: key) { item in
            guard let position = item.tracks.firstIndex(where: { $0.index == trackIndex }) else { return }
            item.tracks[position].bytesDownloaded = bytesDownloaded
            if expectedBytes > 0 { item.tracks[position].expectedBytes = expectedBytes }
        }
    }

    public func markTrackComplete(key: String, trackIndex: Int, bytes: Int64) async {
        await mutate(key: key) { item in
            guard let position = item.tracks.firstIndex(where: { $0.index == trackIndex }) else { return }
            item.tracks[position].isComplete = true
            item.tracks[position].bytesDownloaded = bytes
            item.tracks[position].expectedBytes = max(bytes, item.tracks[position].expectedBytes)
        }
    }

    public func setCoverFileName(key: String, fileName: String?) async {
        await mutate(key: key) { $0.coverFileName = fileName }
    }

    /// Removes an item's index entry and every byte it owns on disk.
    public func remove(key: String) async {
        let folder = folderURL(forKey: key)
        try? fileManager.removeItem(at: folder)
        _ = await store.update { $0[key] = nil }
        await notifyObservers()
    }

    public func removeAll() async {
        try? fileManager.removeItem(at: StorageLocations.offlineRoot)
        StorageLocations.ensureDirectories()
        await store.replace(with: [:])
        await notifyObservers()
    }

    /// Reconciles the index against the filesystem at launch. Files can vanish when
    /// the user offloads the app or restores a backup, and an index that claims a
    /// book is playable when it isn't produces a much worse failure than re-downloading.
    public func reconcileWithDisk() async {
        let snapshot = await store.load()
        var repaired: [String: OfflineItem] = [:]

        for (key, item) in snapshot {
            var item = item
            var changed = false

            for position in item.tracks.indices {
                let url = fileURL(forKey: key, fileName: item.tracks[position].fileName)
                let attributes = try? fileManager.attributesOfItem(atPath: url.path)
                let size = (attributes?[.size] as? NSNumber)?.int64Value

                if let size, size > 0 {
                    if item.tracks[position].bytesDownloaded != size {
                        item.tracks[position].bytesDownloaded = size
                        changed = true
                    }
                } else if item.tracks[position].isComplete {
                    item.tracks[position].isComplete = false
                    item.tracks[position].bytesDownloaded = 0
                    changed = true
                }
            }

            let allPresent = item.tracks.allSatisfy(\.isComplete)
            if item.state == .completed && !allPresent {
                item.state = .failed(reason: "Downloaded files are missing.")
                changed = true
            }
            // A download interrupted by a crash is resumed rather than left dangling.
            if item.state == .downloading {
                item.state = allPresent ? .completed : .queued
                changed = true
            }

            if let coverFileName = item.coverFileName {
                let coverURL = fileURL(forKey: key, fileName: coverFileName)
                if !fileManager.fileExists(atPath: coverURL.path) {
                    item.coverFileName = nil
                    changed = true
                }
            }

            repaired[key] = item
            if changed { logger.info("Repaired offline entry \(key, privacy: .public)") }
        }

        await store.replace(with: repaired)
        await notifyObservers()
    }

    public func flush() async {
        await store.flush()
    }

    // MARK: - Observation

    public func addChangeObserver(_ observer: @escaping @Sendable ([OfflineItem]) -> Void) -> UUID {
        let id = UUID()
        changeObservers[id] = observer
        return id
    }

    public func removeChangeObserver(_ id: UUID) {
        changeObservers[id] = nil
    }

    private func notifyObservers() async {
        guard !changeObservers.isEmpty else { return }
        let items = await allItems()
        for observer in changeObservers.values { observer(items) }
    }
}
