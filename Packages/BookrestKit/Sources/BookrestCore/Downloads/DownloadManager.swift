import Foundation
import ABSClient
import os

/// Downloads books and episodes for offline playback.
///
/// Uses a background `URLSession`, so transfers continue while the app is suspended
/// and are handed back to a relaunched process by the system. Because the process
/// can be replaced between starting and finishing a transfer, every task carries its
/// routing information in `taskDescription` rather than in memory — after a cold
/// relaunch the delegate can still tell which book a finished file belongs to.
public final class DownloadManager: NSObject, @unchecked Sendable {
    public static let backgroundSessionIdentifier = "com.bookrest.app.downloads"

    private let store: OfflineLibraryStore
    private let client: AudiobookshelfClient
    private let logger = Logger(subsystem: "com.bookrest.app", category: "downloads")
    private let lock = NSLock()

    private var _session: URLSession?
    /// Set by the app delegate when the system wakes us to report finished transfers.
    private var backgroundCompletionHandler: (@Sendable () -> Void)?

    public init(store: OfflineLibraryStore, client: AudiobookshelfClient) {
        self.store = store
        self.client = client
        super.init()
    }

    private var session: URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let _session { return _session }

        let configuration = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = true
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        configuration.httpMaximumConnectionsPerHost = 3

        let created = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        _session = created
        return created
    }

    public func setBackgroundCompletionHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        backgroundCompletionHandler = handler
        lock.unlock()
    }

    /// Whether cellular data may be used. Applied to newly created tasks.
    public var allowsCellularAccess: Bool {
        get { session.configuration.allowsCellularAccess }
        set { session.configuration.allowsCellularAccess = newValue }
    }

    // MARK: - Queueing

    /// Queues a book (or one podcast episode) for offline playback.
    ///
    /// The item must be the expanded form — the minified listing payload omits
    /// `audioFiles`, and there is nothing to download without them.
    @discardableResult
    public func download(item: LibraryItem, episodeId: String? = nil) async throws -> OfflineItem {
        guard let connection = await client.currentConnection else { throw ABSError.unauthorized }

        let key = MediaProgress.key(itemId: item.id, episodeId: episodeId)
        let sources = try Self.downloadSources(for: item, episodeId: episodeId)
        guard !sources.isEmpty else { throw ABSError.nothingToPlay }

        StorageLocations.ensureDirectories()
        let folder = store.folderURL(forKey: key)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let offlineItem = OfflineItem(
            key: key,
            itemId: item.id,
            episodeId: episodeId,
            libraryId: item.libraryId,
            mediaType: item.mediaType,
            title: Self.title(for: item, episodeId: episodeId),
            author: item.authorDisplay,
            narrator: item.narratorDisplay,
            seriesLabel: item.seriesDisplay,
            itemDescription: item.itemDescription,
            duration: sources.reduce(0) { $0 + $1.track.duration },
            tracks: sources.map(\.track),
            chapters: Self.chapters(for: item, episodeId: episodeId),
            coverFileName: nil,
            state: .queued,
            downloadedAt: .now
        )
        await store.upsert(offlineItem)

        // Cover first and separately: it's small, and having artwork immediately makes
        // the queued row look right while the audio is still arriving.
        Task { await self.downloadCover(itemId: item.id, key: key, connection: connection) }

        for source in sources {
            startTask(key: key, track: source.track, ino: source.ino, connection: connection)
        }
        await store.setState(key: key, .downloading)
        return offlineItem
    }

    public func cancel(key: String) async {
        let tasks = await session.allTasks
        for task in tasks where TaskRoute(taskDescription: task.taskDescription)?.key == key {
            task.cancel()
        }
        await store.remove(key: key)
    }

    public func pause(key: String) async {
        let tasks = await session.allTasks
        for task in tasks where TaskRoute(taskDescription: task.taskDescription)?.key == key {
            task.cancel()
        }
        await store.setState(key: key, .paused)
    }

    /// Restarts anything left incomplete — after a pause, a failure, or a relaunch.
    public func resume(key: String) async {
        guard let item = await store.item(forKey: key),
              let connection = await client.currentConnection else { return }

        let liveTrackIndexes = Set(
            (await session.allTasks)
                .compactMap { TaskRoute(taskDescription: $0.taskDescription) }
                .filter { $0.key == key }
                .map(\.trackIndex)
        )

        var restarted = false
        for track in item.tracks where !track.isComplete && !liveTrackIndexes.contains(track.index) {
            guard let ino = Self.ino(from: track.fileName) else { continue }
            startTask(key: key, track: track, ino: ino, connection: connection)
            restarted = true
        }

        if restarted || !liveTrackIndexes.isEmpty {
            await store.setState(key: key, .downloading)
        } else {
            await finishIfComplete(key: key)
        }
    }

    /// Called at launch: picks up anything the previous process left unfinished.
    public func resumeInterruptedDownloads() async {
        await store.reconcileWithDisk()
        for item in await store.allItems() where item.state.isActive || item.state.isFailed {
            await resume(key: item.key)
        }
    }

    // MARK: - Task plumbing

    private func startTask(key: String, track: OfflineTrack, ino: String, connection: ServerConnection) {
        guard let url = AudiobookshelfClient.fileDownloadURL(itemId: itemId(fromKey: key), ino: ino, connection: connection) else {
            logger.error("Could not build download URL for \(key, privacy: .public)")
            return
        }

        var request = URLRequest(url: url)
        // A background session can send headers, so the token never has to appear in
        // a URL that might be logged by a proxy.
        request.setValue("Bearer \(connection.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(DeviceIdentity.userAgent, forHTTPHeaderField: "User-Agent")

        let task = session.downloadTask(with: request)
        task.taskDescription = TaskRoute(key: key, trackIndex: track.index, fileName: track.fileName).encoded
        task.resume()
    }

    private func itemId(fromKey key: String) -> String {
        key.split(separator: "/").first.map(String.init) ?? key
    }

    private func downloadCover(itemId: String, key: String, connection: ServerConnection) async {
        guard let url = AudiobookshelfClient.coverURL(itemId: itemId, connection: connection, width: 800) else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), !data.isEmpty else { return }
            let fileName = "cover.jpg"
            let destination = store.fileURL(forKey: key, fileName: fileName)
            try data.write(to: destination, options: .atomic)
            await store.setCoverFileName(key: key, fileName: fileName)
        } catch {
            logger.info("Cover download skipped for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    fileprivate func handleFinishedDownload(route: TaskRoute, temporaryURL: URL, response: HTTPURLResponse?) {
        // The temp file is deleted the moment this delegate call returns, so it must
        // be moved synchronously — before any await.
        let destination = store.fileURL(forKey: route.key, fileName: route.fileName)
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: temporaryURL, to: destination)
        } catch {
            logger.error("Failed to store \(route.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            Task { await self.store.setState(key: route.key, .failed(reason: error.localizedDescription), error: error.localizedDescription) }
            return
        }

        let size = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)??.int64Value ?? 0
        let statusCode = response?.statusCode ?? 200

        Task {
            guard (200...299).contains(statusCode) else {
                try? fileManager.removeItem(at: destination)
                await self.store.setState(key: route.key,
                                          .failed(reason: "Server returned \(statusCode)."),
                                          error: "Server returned \(statusCode).")
                return
            }
            await self.store.markTrackComplete(key: route.key, trackIndex: route.trackIndex, bytes: size)
            await self.finishIfComplete(key: route.key)
        }
    }

    private func finishIfComplete(key: String) async {
        guard let item = await store.item(forKey: key) else { return }
        guard item.tracks.allSatisfy(\.isComplete) else { return }
        await store.mutate(key: key) { item in
            item.state = .completed
            item.lastError = nil
            item.downloadedAt = .now
        }
        await store.flush()
        logger.info("Completed offline download \(key, privacy: .public)")
    }

    // MARK: - Building the track list

    private struct Source {
        let track: OfflineTrack
        let ino: String
    }

    /// Derives the offline track list from an item's audio files.
    ///
    /// Audiobookshelf doesn't put `startOffset` on `audioFiles` (only on the tracks in
    /// a playback session), so offsets are accumulated in index order here — the same
    /// way the server builds them.
    private static func downloadSources(for item: LibraryItem, episodeId: String?) throws -> [Source] {
        var audioFiles: [AudioFile]

        switch item.media {
        case .book(let media):
            audioFiles = media.audioFiles
        case .podcast(let media):
            guard let episodeId else { throw ABSError.nothingToPlay }
            guard let episode = media.episodes.first(where: { $0.id == episodeId }),
                  let file = episode.audioFile else { throw ABSError.nothingToPlay }
            audioFiles = [file]
        }

        audioFiles.sort { $0.index < $1.index }
        guard !audioFiles.isEmpty else { throw ABSError.nothingToPlay }

        var offset: TimeInterval = 0
        return audioFiles.map { file in
            let track = OfflineTrack(
                index: file.index,
                startOffset: offset,
                duration: file.duration,
                fileName: fileName(for: file),
                mimeType: file.mimeType ?? "audio/mpeg"
            )
            offset += file.duration
            return Source(track: track, ino: file.ino)
        }
    }

    /// Embeds the source `ino` in the filename so a download can be resumed after a
    /// relaunch without needing the original server payload again.
    private static func fileName(for file: AudioFile) -> String {
        let ext = (file.filename as NSString?)?.pathExtension.lowercased()
        let resolved = (ext?.isEmpty == false ? ext! : extensionForMimeType(file.mimeType))
        return String(format: "%04d-%@.%@", file.index, file.ino, resolved)
    }

    private static func ino(from fileName: String) -> String? {
        let base = (fileName as NSString).deletingPathExtension
        let parts = base.split(separator: "-", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return String(parts[1])
    }

    private static func extensionForMimeType(_ mimeType: String?) -> String {
        switch mimeType {
        case "audio/mp4", "audio/x-m4a", "audio/m4b", "audio/x-m4b": "m4b"
        case "audio/aac": "aac"
        case "audio/flac": "flac"
        case "audio/ogg", "audio/opus": "ogg"
        case "audio/wav", "audio/x-wav": "wav"
        default: "mp3"
        }
    }

    private static func title(for item: LibraryItem, episodeId: String?) -> String {
        guard let episodeId,
              let episode = item.media.podcast?.episodes.first(where: { $0.id == episodeId })
        else { return item.title }
        return episode.title
    }

    private static func chapters(for item: LibraryItem, episodeId: String?) -> [Chapter] {
        guard let episodeId else { return item.chapters }
        return item.media.podcast?.episodes.first(where: { $0.id == episodeId })?.chapters ?? []
    }
}

/// Routing information carried on the URL task itself, so it survives app relaunch.
struct TaskRoute {
    let key: String
    let trackIndex: Int
    let fileName: String

    private static let separator = "\u{1}"

    var encoded: String {
        [key, String(trackIndex), fileName].joined(separator: Self.separator)
    }

    init(key: String, trackIndex: Int, fileName: String) {
        self.key = key
        self.trackIndex = trackIndex
        self.fileName = fileName
    }

    init?(taskDescription: String?) {
        guard let taskDescription else { return nil }
        let parts = taskDescription.components(separatedBy: Self.separator)
        guard parts.count == 3, let index = Int(parts[1]) else { return nil }
        key = parts[0]
        trackIndex = index
        fileName = parts[2]
    }
}

// MARK: - URLSession delegate

extension DownloadManager: URLSessionDownloadDelegate {

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        guard let route = TaskRoute(taskDescription: downloadTask.taskDescription) else { return }
        handleFinishedDownload(route: route,
                               temporaryURL: location,
                               response: downloadTask.response as? HTTPURLResponse)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        guard let route = TaskRoute(taskDescription: downloadTask.taskDescription) else { return }
        Task {
            await store.recordTrackProgress(key: route.key,
                                            trackIndex: route.trackIndex,
                                            bytesDownloaded: totalBytesWritten,
                                            expectedBytes: max(0, totalBytesExpectedToWrite))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let route = TaskRoute(taskDescription: task.taskDescription) else { return }

        let nsError = error as NSError
        // A cancellation is a user action (pause/delete), not a failure to report.
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }

        logger.error("Download failed for \(route.key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        Task {
            await store.setState(key: route.key,
                                 .failed(reason: error.localizedDescription),
                                 error: error.localizedDescription)
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        lock.unlock()
        // The system requires this on the main thread.
        Task { @MainActor in handler?() }
    }
}
