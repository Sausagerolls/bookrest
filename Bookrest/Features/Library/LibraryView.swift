import SwiftUI
import ABSClient
import BookrestCore

/// The full library, browsable by book, series, author or collection.
struct LibraryView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case books, series, authors, collections
        var id: String { rawValue }

        var title: String {
            switch self {
            case .books: "Books"
            case .series: "Series"
            case .authors: "Authors"
            case .collections: "Collections"
            }
        }
    }

    @Environment(AppEnvironment.self) private var environment
    @State private var model = LibraryBrowseModel()
    @State private var mode: Mode = .books

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal)
                .padding(.bottom, 24)
        }
        .navigationTitle("Library")
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .background(.bar)
        }
        .toolbar {
            LibraryPickerToolbar()
            ToolbarItem(placement: .secondaryAction) { sortMenu }
        }
        .refreshable { await model.reload(environment: environment, mode: mode) }
        .task(id: taskKey) { await model.load(environment: environment, mode: mode) }
        .navigationDestination(for: LibraryItem.self) { ItemDetailView(itemId: $0.id, preview: $0) }
        .navigationDestination(for: Series.self) { SeriesDetailView(series: $0) }
        .navigationDestination(for: Author.self) { AuthorDetailView(author: $0) }
        .navigationDestination(for: BookCollection.self) { CollectionDetailView(collection: $0) }
    }

    private var taskKey: String {
        "\(environment.selectedLibraryId ?? "")-\(mode.rawValue)-\(model.sort.rawValue)-\(model.isDescending)-\(model.progressFilter?.rawValue ?? "")"
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
        } else if let error = model.errorMessage, model.isEmpty {
            InlineErrorView(message: error) { await model.reload(environment: environment, mode: mode) }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
        } else if model.isEmpty {
            EmptyStateView(title: "Nothing to show",
                           message: "This library has no \(mode.title.lowercased()) matching the current filter.")
                .padding(.top, 60)
        } else {
            switch mode {
            case .books: bookGrid
            case .series: seriesGrid
            case .authors: authorGrid
            case .collections: collectionList
            }
        }
    }

    private var bookGrid: some View {
        CoverGrid {
            ForEach(model.items) { item in
                NavigationLink(value: item) {
                    BookCard(item: item)
                }
                .buttonStyle(.plain)
                .task {
                    // Prefetch the next page once the tail comes into view.
                    if item.id == model.items.last?.id {
                        await model.loadNextPage(environment: environment)
                    }
                }
            }
        }
    }

    private var seriesGrid: some View {
        CoverGrid(minimumTileWidth: 170) {
            ForEach(model.series) { entry in
                NavigationLink(value: entry) { SeriesCard(series: entry) }
                    .buttonStyle(.plain)
            }
        }
    }

    private var authorGrid: some View {
        CoverGrid(minimumTileWidth: 110) {
            ForEach(model.authors) { author in
                NavigationLink(value: author) { AuthorCard(author: author) }
                    .buttonStyle(.plain)
            }
        }
    }

    private var collectionList: some View {
        LazyVStack(spacing: 10) {
            ForEach(model.collections) { collection in
                NavigationLink(value: collection) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(collection.name).font(.body)
                            Text("\(collection.books.count) book\(collection.books.count == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 10)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }

    @ViewBuilder
    private var sortMenu: some View {
        if mode == .books {
            Menu {
                Picker("Sort By", selection: $model.sort) {
                    ForEach(LibrarySort.allCases.filter { $0 != .seriesSequence }) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                Toggle("Descending", isOn: $model.isDescending)

                Divider()

                Picker("Show", selection: $model.progressFilter) {
                    Text("All Books").tag(LibraryFilter.ProgressState?.none)
                    ForEach(LibraryFilter.ProgressState.allCases) { state in
                        Text(state.displayName).tag(LibraryFilter.ProgressState?.some(state))
                    }
                }
            } label: {
                Label("Sort & Filter", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
    }
}

/// Paged loading state for the library browser.
@MainActor
@Observable
final class LibraryBrowseModel {
    private(set) var items: [LibraryItem] = []
    private(set) var series: [Series] = []
    private(set) var authors: [Author] = []
    private(set) var collections: [BookCollection] = []

    private(set) var isLoading = false
    private(set) var errorMessage: String?

    var sort: LibrarySort = .title {
        didSet { isDescending = sort.defaultsToDescending }
    }
    var isDescending = false
    var progressFilter: LibraryFilter.ProgressState?

    private var page = 0
    private var hasMore = true
    private var loadedMode: LibraryView.Mode?
    private var isLoadingPage = false

    var isEmpty: Bool {
        items.isEmpty && series.isEmpty && authors.isEmpty && collections.isEmpty
    }

    func load(environment: AppEnvironment, mode: LibraryView.Mode) async {
        // The view's task id changes for sort and filter too, so a reload here is
        // the same code path as a pull-to-refresh.
        await reload(environment: environment, mode: mode)
    }

    func reload(environment: AppEnvironment, mode: LibraryView.Mode) async {
        guard let libraryId = environment.selectedLibraryId else { return }
        isLoading = true
        errorMessage = nil
        page = 0
        hasMore = true
        loadedMode = mode
        defer { isLoading = false }

        do {
            switch mode {
            case .books:
                let result = try await environment.client.items(
                    inLibrary: libraryId, page: 0, limit: 60,
                    sort: sort, descending: isDescending, filter: filter
                )
                items = result.results
                hasMore = result.hasMore
                series = []; authors = []; collections = []

            case .series:
                let result = try await environment.client.series(inLibrary: libraryId, limit: 200)
                series = result.results
                items = []; authors = []; collections = []

            case .authors:
                authors = try await environment.client.authors(inLibrary: libraryId)
                items = []; series = []; collections = []

            case .collections:
                collections = try await environment.client.collections(inLibrary: libraryId)
                items = []; series = []; authors = []
            }
            await environment.refreshProgressIndex()
        } catch {
            errorMessage = (error as? ABSError)?.errorDescription ?? error.localizedDescription
        }
    }

    func loadNextPage(environment: AppEnvironment) async {
        guard loadedMode == .books, hasMore, !isLoadingPage,
              let libraryId = environment.selectedLibraryId else { return }
        isLoadingPage = true
        defer { isLoadingPage = false }

        do {
            let next = page + 1
            let result = try await environment.client.items(
                inLibrary: libraryId, page: next, limit: 60,
                sort: sort, descending: isDescending, filter: filter
            )
            // Guard against duplicates if a page boundary shifts under us.
            let existing = Set(items.map(\.id))
            items.append(contentsOf: result.results.filter { !existing.contains($0.id) })
            page = next
            hasMore = result.hasMore
        } catch {
            hasMore = false
        }
    }

    private var filter: LibraryFilter? {
        progressFilter.map { LibraryFilter.progress($0) }
    }
}
