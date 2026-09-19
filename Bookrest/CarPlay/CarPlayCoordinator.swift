#if os(iOS)
import CarPlay
import UIKit
import ABSClient
import BookrestCore

/// Builds and maintains the CarPlay template hierarchy.
///
/// Two constraints shape everything here: lists are capped by the connected head
/// unit (`CPListTemplate.maximumItemCount`), and every interaction has to work with
/// no network — so downloads are always reachable and remote sections degrade
/// quietly to whatever is on the device.
@MainActor
final class CarPlayCoordinator {

    private let interfaceController: CPInterfaceController
    private let environment: AppEnvironment

    private var continueTemplate: CPListTemplate?
    private var libraryTemplate: CPListTemplate?
    private var seriesTemplate: CPListTemplate?
    private var downloadsTemplate: CPListTemplate?
    private var imageTasks: [String: Task<Void, Never>] = [:]
    private var refreshTask: Task<Void, Never>?

    init(interfaceController: CPInterfaceController, environment: AppEnvironment) {
        self.interfaceController = interfaceController
        self.environment = environment
    }

    // MARK: - Lifecycle

    func start() async {
        let continueTemplate = CPListTemplate(title: "Continue", sections: [])
        continueTemplate.tabTitle = "Continue"
        continueTemplate.tabImage = UIImage(systemName: "play.circle")

        let libraryTemplate = CPListTemplate(title: "Library", sections: [])
        libraryTemplate.tabTitle = "Library"
        libraryTemplate.tabImage = UIImage(systemName: "books.vertical")

        let seriesTemplate = CPListTemplate(title: "Series", sections: [])
        seriesTemplate.tabTitle = "Series"
        seriesTemplate.tabImage = UIImage(systemName: "square.stack")

        let downloadsTemplate = CPListTemplate(title: "Downloads", sections: [])
        downloadsTemplate.tabTitle = "Downloads"
        downloadsTemplate.tabImage = UIImage(systemName: "arrow.down.circle")

        self.continueTemplate = continueTemplate
        self.libraryTemplate = libraryTemplate
        self.seriesTemplate = seriesTemplate
        self.downloadsTemplate = downloadsTemplate

        let tabBar = CPTabBarTemplate(templates: [
            continueTemplate, libraryTemplate, seriesTemplate, downloadsTemplate
        ])

        _ = try? await interfaceController.setRootTemplate(tabBar, animated: false)

        configureNowPlayingTemplate()
        await refreshAll()

        // Downloads finishing while driving should appear without any interaction.
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                await self?.refreshDownloads()
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        for task in imageTasks.values { task.cancel() }
        imageTasks.removeAll()
    }

    // MARK: - Content

    private func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.refreshContinue() }
            group.addTask { await self.refreshLibrary() }
            group.addTask { await self.refreshSeries() }
            group.addTask { await self.refreshDownloads() }
        }
    }

    private func refreshContinue() async {
        guard let template = continueTemplate else { return }

        var items: [CPListItem] = []

        if environment.isSignedIn, environment.network.isConnected,
           let inProgress = try? await environment.client.itemsInProgress(limit: 20) {
            items = inProgress.map { makeListItem(for: $0) }
        }

        if items.isEmpty {
            // Offline, or nothing started on the server: fall back to downloads with
            // a saved position, which is the most likely thing to want in a car.
            items = environment.offlineItems
                .filter(\.isPlayableOffline)
                .compactMap { offline -> (OfflineItem, LocalProgress)? in
                    guard let progress = environment.progress(for: offline.itemId, episodeId: offline.episodeId),
                          progress.isStarted else { return nil }
                    return (offline, progress)
                }
                .sorted { $0.1.updatedAt > $1.1.updatedAt }
                .map { makeListItem(for: $0.0) }
        }

        template.updateSections([
            CPListSection(items: capped(items))
        ])
        setEmptyText(on: template,
                     when: items.isEmpty,
                     message: "Start a book on your phone and it will appear here.")
    }

    private func refreshLibrary() async {
        guard let template = libraryTemplate else { return }
        guard environment.isSignedIn, environment.network.isConnected,
              let libraryId = environment.selectedLibraryId else {
            template.updateSections([])
            setEmptyText(on: template, when: true, message: "Connect to your server to browse.")
            return
        }

        guard let page = try? await environment.client.items(
            inLibrary: libraryId, limit: 60, sort: .addedAt, descending: true
        ) else { return }

        let items = page.results.filter(\.isPlayable).map { makeListItem(for: $0) }
        template.updateSections([CPListSection(items: capped(items), header: "Recently Added", sectionIndexTitle: nil)])
    }

    private func refreshSeries() async {
        guard let template = seriesTemplate else { return }
        guard environment.isSignedIn, environment.network.isConnected,
              let libraryId = environment.selectedLibraryId else {
            template.updateSections([])
            setEmptyText(on: template, when: true, message: "Connect to your server to browse series.")
            return
        }

        guard let page = try? await environment.client.series(inLibrary: libraryId, limit: 100) else { return }

        let items: [CPListItem] = page.results.map { series in
            let item = CPListItem(text: series.name,
                                  detailText: "\(series.bookCount) book\(series.bookCount == 1 ? "" : "s")")
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    await self?.pushSeries(series, libraryId: libraryId)
                    completion()
                }
            }
            return item
        }

        template.updateSections([CPListSection(items: capped(items))])
    }

    private func refreshDownloads() async {
        guard let template = downloadsTemplate else { return }
        let items = environment.offlineItems
            .filter(\.isPlayableOffline)
            .map { makeListItem(for: $0) }

        template.updateSections([CPListSection(items: capped(items))])
        setEmptyText(on: template,
                     when: items.isEmpty,
                     message: "Downloaded books play here without a connection.")
    }

    private func pushSeries(_ series: Series, libraryId: String) async {
        let books = series.books.isEmpty
            ? ((try? await environment.client.books(inSeries: series.id, libraryId: libraryId)) ?? [])
            : series.orderedBooks

        let template = CPListTemplate(
            title: series.name,
            sections: [CPListSection(items: books.map { makeListItem(for: $0) })]
        )
        _ = try? await interfaceController.pushTemplate(template, animated: true)
    }

    // MARK: - List items

    private func makeListItem(for item: LibraryItem) -> CPListItem {
        let progress = environment.progress(for: item.id)
        let listItem = CPListItem(
            text: item.title,
            detailText: detailText(author: item.authorDisplay, duration: item.duration, progress: progress),
            image: nil
        )
        // The bar is the clearest at-a-glance cue at driving distances.
        listItem.isPlaying = environment.player.isCurrent(itemId: item.id)
        listItem.playbackProgress = progress.map { CGFloat($0.progress) } ?? 0

        listItem.handler = { [weak self] _, completion in
            Task { @MainActor in
                guard let self else { completion(); return }
                await self.environment.player.play(item: item)
                await self.presentNowPlaying()
                completion()
            }
        }

        loadImage(for: listItem, itemId: item.id, offlineKey: MediaProgress.key(itemId: item.id, episodeId: nil))
        return listItem
    }

    private func makeListItem(for offline: OfflineItem) -> CPListItem {
        let progress = environment.progress(for: offline.itemId, episodeId: offline.episodeId)
        let listItem = CPListItem(
            text: offline.title,
            detailText: detailText(author: offline.author, duration: offline.duration, progress: progress),
            image: nil
        )
        listItem.isPlaying = environment.player.context?.key == offline.key
        listItem.playbackProgress = progress.map { CGFloat($0.progress) } ?? 0

        listItem.handler = { [weak self] _, completion in
            Task { @MainActor in
                guard let self else { completion(); return }
                await self.environment.player.play(offlineItem: offline)
                await self.presentNowPlaying()
                completion()
            }
        }

        loadImage(for: listItem, itemId: offline.itemId, offlineKey: offline.key)
        return listItem
    }

    private func detailText(author: String?, duration: TimeInterval, progress: LocalProgress?) -> String {
        var parts: [String] = []
        if let author { parts.append(author) }
        if let progress, progress.isStarted {
            parts.append("\(Format.duration(progress.duration - progress.currentTime)) left")
        } else if duration > 0 {
            parts.append(Format.duration(duration))
        }
        return parts.joined(separator: " · ")
    }

    /// Loads artwork off the main path and applies it when it arrives. A downloaded
    /// cover is used when present so the list fills in instantly with no signal.
    private func loadImage(for listItem: CPListItem, itemId: String, offlineKey: String) {
        let localURL = environment.offlineItems.first { $0.key == offlineKey }
            .flatMap { offline -> URL? in
                guard let name = offline.coverFileName else { return nil }
                return StorageLocations.itemFolder(forKey: offline.key).appendingPathComponent(name)
            }
        let remoteURL = environment.coverURL(for: itemId, width: 200)
        guard let source = localURL ?? remoteURL else { return }

        imageTasks[itemId]?.cancel()
        imageTasks[itemId] = Task { [weak listItem] in
            let data: Data?
            if source.isFileURL {
                data = try? Data(contentsOf: source)
            } else {
                data = try? await URLSession.shared.data(from: source).0
            }
            guard !Task.isCancelled, let data, let image = UIImage(data: data) else { return }
            listItem?.setImage(image)
        }
    }

    /// CarPlay caps how many rows a list template may contain; exceeding it throws.
    private func capped(_ items: [CPListItem]) -> [CPListItem] {
        Array(items.prefix(CPListTemplate.maximumItemCount))
    }

    private func setEmptyText(on template: CPListTemplate, when isEmpty: Bool, message: String) {
        template.emptyViewSubtitleVariants = isEmpty ? [message] : []
    }

    // MARK: - Now Playing

    private func presentNowPlaying() async {
        let nowPlaying = CPNowPlayingTemplate.shared
        guard interfaceController.topTemplate !== nowPlaying else { return }
        _ = try? await interfaceController.pushTemplate(nowPlaying, animated: true)
    }

    private func configureNowPlayingTemplate() {
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.isUpNextButtonEnabled = false
        nowPlaying.isAlbumArtistButtonEnabled = false

        let speedButton = CPNowPlayingPlaybackRateButton { @Sendable [weak self] _ in
            onMainActor { self?.environment.player.cycleRate() }
        }

        // Chapter navigation matters more than track navigation in an audiobook, and
        // CarPlay's transport buttons are already mapped to skip intervals.
        let chapterButton = CPNowPlayingImageButton(
            image: UIImage(systemName: "list.bullet") ?? UIImage()
        ) { @Sendable [weak self] _ in
            onMainActor { self?.presentChapters() }
        }

        nowPlaying.updateNowPlayingButtons([speedButton, chapterButton])
    }

    private func presentChapters() {
        guard let context = environment.player.context, !context.chapters.isEmpty else { return }

        let items = context.chapters.map { chapter -> CPListItem in
            let title = chapter.title.isEmpty ? "Chapter \(chapter.id + 1)" : chapter.title
            let item = CPListItem(text: title, detailText: Format.timecode(chapter.start))
            // CarPlay hands `completion` in as a plain non-Sendable closure, so this
            // stays main-actor isolated like the other list handlers rather than
            // becoming @Sendable. List selections are UI events and arrive on the main
            // thread; the undocumented-queue problem is specific to artwork requests.
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.environment.player.seekToChapter(chapter)
                    _ = try? await self?.interfaceController.popTemplate(animated: true)
                    completion()
                }
            }
            return item
        }

        let template = CPListTemplate(title: "Chapters",
                                      sections: [CPListSection(items: Array(items.prefix(CPListTemplate.maximumItemCount)))])
        Task { _ = try? await interfaceController.pushTemplate(template, animated: true) }
    }
}
#endif
