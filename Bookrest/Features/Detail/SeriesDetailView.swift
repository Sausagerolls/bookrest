import SwiftUI
import ABSClient

struct SeriesDetailView: View {
    let series: Series

    @Environment(AppEnvironment.self) private var environment
    @State private var books: [LibraryItem] = []
    @State private var isLoading = true

    /// Prefer books already attached to the series object; only hit the network when
    /// the payload was minified.
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
                                    if let sequence = book.seriesRefs.first(where: { $0.id == series.id })?.sequence {
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
        guard series.books.isEmpty, let libraryId = environment.selectedLibraryId else { return }
        books = (try? await environment.client.books(inSeries: series.id, libraryId: libraryId)) ?? []
    }
}

struct AuthorDetailView: View {
    let author: Author

    @Environment(AppEnvironment.self) private var environment
    @State private var books: [LibraryItem] = []
    @State private var isLoading = true

    private var displayed: [LibraryItem] {
        books.isEmpty ? author.libraryItems : books
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    AvatarImage(url: author.hasImage ? environment.authorImageURL(for: author.id) : nil,
                                name: author.name, size: 88)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(author.name).font(.title3.weight(.semibold))
                        Text("\(author.numBooks) book\(author.numBooks == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if let description = author.description, !description.isEmpty {
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
                            NavigationLink(value: book) { BookCard(item: book, showsAuthor: false) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 30)
        }
        .navigationTitle(author.name)
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .navigationDestination(for: LibraryItem.self) { ItemDetailView(itemId: $0.id, preview: $0) }
    }

    private func load() async {
        defer { isLoading = false }
        guard author.libraryItems.isEmpty, let libraryId = environment.selectedLibraryId else { return }
        books = (try? await environment.client.books(byAuthor: author.id, libraryId: libraryId)) ?? []
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
