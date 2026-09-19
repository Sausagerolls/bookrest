import SwiftUI
import ABSClient

/// Search across books, series and authors, debounced so typing doesn't hammer
/// the server with a request per keystroke.
struct SearchView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var query = ""
    @State private var results = SearchResults.empty
    @State private var isSearching = false

    var body: some View {
        List {
            if !results.books.isEmpty {
                Section("Books") {
                    ForEach(results.books, id: \.libraryItem.id) { match in
                        NavigationLink(value: match.libraryItem) {
                            BookRow(item: match.libraryItem, subtitleOverride: subtitle(for: match))
                        }
                    }
                }
            }

            if !results.series.isEmpty {
                Section("Series") {
                    ForEach(results.series, id: \.series.id) { match in
                        NavigationLink(value: match.series) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(match.series.name)
                                Text("\(match.books.count) book\(match.books.count == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if !results.authors.isEmpty {
                Section("Authors") {
                    ForEach(results.authors) { author in
                        NavigationLink(value: author) {
                            HStack(spacing: 10) {
                                AvatarImage(url: author.hasImage ? environment.authorImageURL(for: author.id) : nil,
                                            name: author.name, size: 36)
                                Text(author.name)
                            }
                        }
                    }
                }
            }

            if !results.podcasts.isEmpty {
                Section("Podcasts") {
                    ForEach(results.podcasts, id: \.libraryItem.id) { match in
                        NavigationLink(value: match.libraryItem) { BookRow(item: match.libraryItem) }
                    }
                }
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #else
        .listStyle(.insetGrouped)
        #endif
        .immersiveScrollBackground(environment.theme.activePalette)
        .overlay {
            if query.isEmpty {
                EmptyStateView(title: "Search your library",
                               message: "Find books by title, author, narrator, series or genre.",
                               systemImage: "magnifyingglass")
            } else if results.isEmpty && !isSearching {
                EmptyStateView(title: "No results",
                               message: "Nothing in this library matches “\(query)”.",
                               systemImage: "magnifyingglass")
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Books, authors, series")
        .task(id: query) { await search() }
        .navigationDestination(for: LibraryItem.self) { ItemDetailView(itemId: $0.id, preview: $0) }
        .navigationDestination(for: Series.self) { SeriesDetailView(series: $0) }
        .navigationDestination(for: Author.self) { AuthorDetailView(author: $0) }
    }

    private func subtitle(for match: SearchResults.ItemMatch) -> String? {
        // Show why a result matched when it wasn't the title — otherwise a hit on a
        // narrator or series looks arbitrary.
        guard let key = match.matchKey, key != "title", let text = match.matchText else {
            return match.libraryItem.authorDisplay
        }
        return "\(key.capitalized): \(text)"
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = .empty
            return
        }
        guard let libraryId = environment.selectedLibraryId else { return }

        // Debounce: `task(id:)` cancels this on the next keystroke before the sleep
        // completes, so only the last query in a burst reaches the server.
        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return
        }

        isSearching = true
        defer { isSearching = false }
        results = (try? await environment.client.search(libraryId: libraryId, query: trimmed)) ?? .empty
    }
}
