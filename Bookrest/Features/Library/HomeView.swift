import SwiftUI
import ABSClient
import BookrestCore

/// The server-built home screen: Continue Listening, Recently Added, and whatever
/// else the library is configured to surface.
struct HomeView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var shelves: [PersonalizedShelf] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if isLoading && shelves.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                } else if let errorMessage, shelves.isEmpty {
                    offlineFallback(message: errorMessage)
                } else if shelves.isEmpty {
                    EmptyStateView(
                        title: "Nothing here yet",
                        message: "Add books to your Audiobookshelf library and they'll show up here.",
                        actionTitle: "Refresh",
                        action: { Task { await load() } }
                    )
                    .padding(.top, 60)
                } else {
                    ForEach(shelves) { shelf in
                        ShelfSection(shelf: shelf)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .navigationTitle(environment.selectedLibrary?.name ?? "Home")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar { LibraryPickerToolbar() }
        .refreshable { await load() }
        .task(id: environment.selectedLibraryId) { await load() }
        .navigationDestination(for: LibraryItem.self) { ItemDetailView(itemId: $0.id, preview: $0) }
        .navigationDestination(for: Series.self) { SeriesDetailView(series: $0) }
        .navigationDestination(for: Author.self) { AuthorDetailView(author: $0) }
    }

    /// With no network, the downloaded shelf is the only useful thing to show — and
    /// it's more useful than an error.
    @ViewBuilder
    private func offlineFallback(message: String) -> some View {
        if !environment.offlineItems.filter(\.isPlayableOffline).isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Downloaded")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal)
                OfflineShelf()
            }
        } else {
            InlineErrorView(message: message) { await load() }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        }
    }

    private func load() async {
        guard let libraryId = environment.selectedLibraryId else {
            isLoading = false
            return
        }
        errorMessage = nil
        defer { isLoading = false }

        do {
            shelves = try await environment.client.personalizedShelves(libraryId: libraryId)
            await environment.refreshProgressIndex()
        } catch {
            errorMessage = (error as? ABSError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct ShelfSection: View {
    let shelf: PersonalizedShelf

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(shelf.label)
                .font(.title3.weight(.semibold))
                .padding(.horizontal)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    switch shelf.content {
                    case .items(let items):
                        ForEach(items) { item in
                            NavigationLink(value: item) {
                                BookCard(item: item)
                                    .frame(width: 140)
                            }
                            .buttonStyle(.plain)
                        }
                    case .series(let series):
                        ForEach(series) { entry in
                            NavigationLink(value: entry) {
                                SeriesCard(series: entry)
                                    .frame(width: 140)
                            }
                            .buttonStyle(.plain)
                        }
                    case .authors(let authors):
                        ForEach(authors) { author in
                            NavigationLink(value: author) {
                                AuthorCard(author: author)
                                    .frame(width: 110)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }
}

private struct OfflineShelf: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(environment.offlineItems.filter(\.isPlayableOffline)) { item in
                    Button {
                        Task { await environment.player.play(offlineItem: item) }
                    } label: {
                        OfflineCard(item: item).frame(width: 140)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
    }
}

struct SeriesCard: View {
    let series: Series
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A short stack of the first few covers reads as "a series" much faster
            // than a single cover with a label under it.
            ZStack(alignment: .leading) {
                ForEach(Array(series.orderedBooks.prefix(3).enumerated().reversed()), id: \.offset) { index, book in
                    CoverImage(url: environment.coverURL(for: book.id, width: 300))
                        .frame(width: 110)
                        .offset(x: CGFloat(index) * 14)
                        .zIndex(Double(-index))
                }
            }
            .frame(width: 140, height: 110, alignment: .leading)

            Text(series.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            Text("\(series.bookCount) book\(series.bookCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct AuthorCard: View {
    let author: Author
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(spacing: 8) {
            AvatarImage(
                url: author.hasImage ? environment.authorImageURL(for: author.id) : nil,
                name: author.name,
                size: 96
            )
            Text(author.name)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
    }
}

struct OfflineCard: View {
    let item: OfflineItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverImage(url: nil, localURL: StorageLocations.itemFolder(forKey: item.key)
                .appendingPathComponent(item.coverFileName ?? "cover.jpg"))

            Text(item.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            if let author = item.author {
                Text(author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Library switcher, shown only when there's more than one library to switch to.
struct LibraryPickerToolbar: ToolbarContent {
    @Environment(AppEnvironment.self) private var environment

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if environment.libraries.count > 1 {
                Menu {
                    Picker("Library", selection: Binding(
                        get: { environment.selectedLibraryId ?? "" },
                        set: { environment.selectedLibraryId = $0 }
                    )) {
                        ForEach(environment.libraries) { library in
                            Label(library.name, systemImage: library.systemImage).tag(library.id)
                        }
                    }
                } label: {
                    Label("Library", systemImage: "square.stack.3d.up")
                }
            }
        }
    }
}
