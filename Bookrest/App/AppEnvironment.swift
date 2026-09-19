import Foundation
import Observation
import SwiftUI
import ABSClient
import BookrestCore

/// The app's single dependency container and shared state.
///
/// Both the SwiftUI scene and the CarPlay scene resolve everything from here, so a
/// book started in the car and one started on the phone go through identical code.
@MainActor
@Observable
final class AppEnvironment {
    static let shared = AppEnvironment()

    let client: AudiobookshelfClient
    let offlineStore: OfflineLibraryStore
    let progressStore: ProgressStore
    let downloads: DownloadManager
    let player: PlaybackController
    let network = NetworkMonitor()
    let theme = ThemeController()

    private(set) var connection: ServerConnection?
    private(set) var libraries: [Library] = []
    private(set) var offlineItems: [OfflineItem] = []
    private(set) var progressIndex: [String: LocalProgress] = [:]
    private(set) var isBootstrapping = true

    var selectedLibraryId: String? {
        didSet {
            guard selectedLibraryId != oldValue else { return }
            UserDefaults.standard.set(selectedLibraryId, forKey: Keys.selectedLibrary)
        }
    }

    var isSignedIn: Bool { connection != nil }

    var selectedLibrary: Library? {
        libraries.first { $0.id == selectedLibraryId } ?? libraries.first
    }

    private enum Keys {
        static let selectedLibrary = "com.bookrest.selectedLibrary"
    }

    private var offlineObserverToken: UUID?

    private init() {
        let sessionStore = SessionStore()
        let client = AudiobookshelfClient(sessionStore: sessionStore)
        let offlineStore = OfflineLibraryStore()
        let progressStore = ProgressStore()

        self.client = client
        self.offlineStore = offlineStore
        self.progressStore = progressStore
        self.downloads = DownloadManager(store: offlineStore, client: client)
        self.player = PlaybackController(client: client,
                                         offlineStore: offlineStore,
                                         progressStore: progressStore)
        self.selectedLibraryId = UserDefaults.standard.string(forKey: Keys.selectedLibrary)
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        network.onReconnect = { [weak self] in
            Task { await self?.handleReconnect() }
        }
        network.start()

        connection = await client.currentConnection

        offlineObserverToken = await offlineStore.addChangeObserver { [weak self] items in
            Task { @MainActor in self?.offlineItems = items }
        }

        await offlineStore.reconcileWithDisk()
        offlineItems = await offlineStore.allItems()
        progressIndex = await progressStore.all()

        if isSignedIn {
            await refreshLibraries()
            await player.refreshProgressFromServer()
            progressIndex = await progressStore.all()
            await player.restoreLastPlayed()
        }

        await downloads.resumeInterruptedDownloads()
        isBootstrapping = false
    }

    /// Pull before push, always.
    ///
    /// The other order lets a position this device queued earlier reach the server
    /// before it has heard what another device did since — which is exactly how a
    /// tablet's older position ends up overwriting a phone's newer one. Merging first
    /// means anything still pending afterwards is genuinely the newest thing anyone
    /// has, and is safe to upload.
    func handleForeground() async {
        guard isSignedIn else { return }
        await player.refreshProgressFromServer()
        await player.syncPendingProgress()
        progressIndex = await progressStore.all()
    }

    func handleBackground() async {
        await player.prepareForSuspension()
    }

    private func handleReconnect() async {
        guard isSignedIn else { return }
        // Same order as foregrounding: hear the server out before uploading. Genuinely
        // newer offline listening still wins, because the merge compares timestamps.
        await player.refreshProgressFromServer()
        await player.syncPendingProgress()
        progressIndex = await progressStore.all()
        await refreshLibraries()
    }

    // MARK: - Authentication

    func signIn(serverURL: URL, username: String, password: String) async throws {
        let connection = try await client.signIn(serverURL: serverURL,
                                                 username: username,
                                                 password: password)
        self.connection = connection
        await refreshLibraries()
        if selectedLibraryId == nil {
            selectedLibraryId = connection.defaultLibraryId ?? libraries.first?.id
        }
        await player.refreshProgressFromServer()
        progressIndex = await progressStore.all()
    }

    func signOut() async {
        await player.stop()
        await client.signOut()
        connection = nil
        libraries = []
        selectedLibraryId = nil
        UserDefaults.standard.removeObject(forKey: Keys.selectedLibrary)
    }

    // MARK: - Data

    func refreshLibraries() async {
        guard isSignedIn else { return }
        do {
            let loaded = try await client.libraries()
            libraries = loaded
            if selectedLibraryId == nil || !loaded.contains(where: { $0.id == selectedLibraryId }) {
                selectedLibraryId = connection?.defaultLibraryId ?? loaded.first?.id
            }
        } catch {
            // Offline or transient: keep whatever we already had on screen.
        }
    }

    func refreshProgressIndex() async {
        progressIndex = await progressStore.all()
    }

    func progress(for itemId: String, episodeId: String? = nil) -> LocalProgress? {
        progressIndex[MediaProgress.key(itemId: itemId, episodeId: episodeId)]
    }

    func offlineItem(for itemId: String, episodeId: String? = nil) -> OfflineItem? {
        let key = MediaProgress.key(itemId: itemId, episodeId: episodeId)
        return offlineItems.first { $0.key == key }
    }

    func coverURL(for itemId: String, width: Int = 400) -> URL? {
        guard let connection else { return nil }
        return AudiobookshelfClient.coverURL(itemId: itemId, connection: connection, width: width)
    }

    func authorImageURL(for authorId: String, width: Int = 300) -> URL? {
        guard let connection else { return nil }
        return AudiobookshelfClient.authorImageURL(authorId: authorId, connection: connection, width: width)
    }

    // MARK: - Downloads

    func download(item: LibraryItem, episodeId: String? = nil) async {
        do {
            // The listing payload is minified and has no audio files; fetch the full
            // item before queueing so the track list is complete.
            let expanded = try await client.item(item.id)
            try await downloads.download(item: expanded, episodeId: episodeId)
        } catch {
            // Surfaced through the item's own state in the offline store.
        }
    }

    func removeDownload(key: String) async {
        await downloads.cancel(key: key)
    }
}
