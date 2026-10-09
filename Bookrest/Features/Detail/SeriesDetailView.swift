import SwiftUI
import ABSClient

struct SeriesDetailView: View {
    let series: Series

    @Environment(AppEnvironment.self) private var environment
    @State private var books: [LibraryItem] = []
    @State private var isLoading = true

    /// Show books already attached to the series object straight away, then swap in the
    /// series-filtered listing, which is the only payload that reliably carries book numbers.
    private var displayed: [LibraryItem] {
        books.isEmpty ? series.orderedBooks : books
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let description = series.description, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if isLoading && displayed.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    CoverGrid {
                        ForEach(displayed) { book in
                            NavigationLink(value: book) {
                                VStack(alignment: .leading, spacing: 4) {
                                    BookCard(item: book, showsAuthor: false)
                                    if let sequence = book.sequence(inSeries: series.id, named: series.name) {
                                        Text("Book \(sequence)")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 30)
        }
        .navigationTitle(series.name)
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .navigationDestination(for: LibraryItem.self) { ItemDetailView(itemId: $0.id, preview: $0) }
    }

    private func load() async {
        defer { isLoading = false }
        guard let libraryId = environment.selectedLibraryId else { return }
        books = (try? await environment.client.books(inSeries: series.id, named: series.name, libraryId: libraryId)) ?? []
    }
}

struct AuthorDetailView: View {
    let author: Author

    @Environment(AppEnvironment.self) private var environment
    /// The author fetched with their books grouped into series.
    @State private var loaded: Author?
    /// Fallback when the author endpoint isn't reachable: the flat filtered listing.
    @State private var books: [LibraryItem] = []
    @State private var isLoading = true

    private var displayed: Author { loaded ?? author }

    private var series: [Series] {
        displayed.series.sorted { $0.sortName.localizedStandardCompare($1.sortName) == .orderedAscending }
    }

    private var standalone: [LibraryItem] {
        if loaded != nil { return displayed.standaloneBooks }
        let flat = books.isEmpty ? author.libraryItems : books
        return flat.sorted { $0.sortTitle.localizedStandardCompare($1.sortTitle) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    AvatarImage(url: displayed.hasImage ? environment.authorImageURL(for: displayed.id) : nil,
                                name: displayed.name, size: 88)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayed.name).font(.title3.weight(.semibold))
                        if displayed.numBooks > 0 {
                            Text("\(displayed.numBooks) book\(displayed.numBooks == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }

                if let description = displayed.description, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if isLoading && series.isEmpty && standalone.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    if !series.isEmpty {
                        sectionHeader("Series")
                        CoverGrid {
                            ForEach(series) { series in
                                NavigationLink(value: series) { SeriesCard(series: series) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    if !standalone.isEmpty {
                        if !series.isEmpty { sectionHeader("Other Books") }
                        CoverGrid {
                            ForEach(standalone) { book in
                                NavigationLink(value: book) { BookCard(item: book, showsAuthor: false) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 30)
        }
        .navigationTitle(displayed.name)
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .navigationDestination(for: LibraryItem.self) { ItemDetailView(itemId: $0.id, preview: $0) }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.headline).padding(.top, 4)
    }

    private func load() async {
        defer { isLoading = false }
        guard let libraryId = environment.selectedLibraryId else { return }
        if let fetched = try? await environment.client.author(author.id, libraryId: libraryId) {
            loaded = fetched
        } else if author.libraryItems.isEmpty {
            books = (try? await environment.client.books(byAuthor: author.id, libraryId: libraryId)) ?? []
        }
    }
}

struct CollectionDetailView: View {
    let collection: BookCollection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let description = collection.description, !description.isEmpty {
                    Text(description).font(.callout).foregroundStyle(.secondary)
                }
                CoverGrid {
                    ForEach(collection.books) { book in
                        NavigationLink(value: book) { BookCard(item: book) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 30)
        }
        .navigationTitle(collection.name)
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationDestination(for: LibraryItem.self) { ItemDetailView(itemId: $0.id, preview: $0) }
    }
}
