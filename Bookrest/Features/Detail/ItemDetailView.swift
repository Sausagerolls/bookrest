import SwiftUI
import ABSClient
import BookrestCore

/// A single book (or podcast). Loads the expanded item so chapters and audio files
/// are available — the grid only ever has the minified form.
struct ItemDetailView: View {
    let itemId: String
    /// The minified item from the listing, shown immediately so the screen never
    /// starts as a spinner.
    var preview: LibraryItem?

    @Environment(AppEnvironment.self) private var environment
    @State private var item: LibraryItem?
    @State private var errorMessage: String?
    @State private var isDescriptionExpanded = false

    private var displayed: LibraryItem? { item ?? preview }

    var body: some View {
        ScrollView {
            if let displayed {
                VStack(alignment: .leading, spacing: 22) {
                    hero(displayed)
                    actions(displayed)
                    if let description = displayed.itemDescription, !description.isEmpty {
                        descriptionSection(description)
                    }
                    metadata(displayed)
                    if !displayed.chapters.isEmpty {
                        chapters(displayed)
                    }
                    if let podcast = displayed.media.podcast {
                        episodes(podcast, item: displayed)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 40)
            } else if let errorMessage {
                InlineErrorView(message: errorMessage) { await load() }
                    .frame(maxWidth: .infinity).padding(.top, 80)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
            }
        }
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle(displayed?.title ?? "")
        .task { await load() }
    }

    // MARK: - Sections

    private func hero(_ item: LibraryItem) -> some View {
        HStack(alignment: .top, spacing: 18) {
            CoverImage(url: environment.coverURL(for: item.id, width: 600),
                       localURL: localCoverURL,
                       cornerRadius: 12)
                .frame(width: 150)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle = item.subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }

                if let authors = item.media.book?.metadata.authors, !authors.isEmpty {
                    ForEach(authors) { author in
                        NavigationLink(value: Author(id: author.id, name: author.name)) {
                            Text(author.name).font(.subheadline).foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)
                    }
                } else if let author = item.authorDisplay {
                    // Minified previews only carry the flattened name until the full item loads.
                    Text(author).font(.subheadline).foregroundStyle(.secondary)
                }

                if let narrator = item.narratorDisplay {
                    Text("Narrated by \(narrator)")
                        .font(.caption).foregroundStyle(.tertiary)
                }

                if !item.seriesRefs.isEmpty {
                    ForEach(item.seriesRefs) { series in
                        NavigationLink(value: Series(id: series.id, name: series.name)) {
                            Text(series.displayLabel)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 10) {
                    Label(Format.duration(item.duration), systemImage: "clock")
                    if item.explicit {
                        Image(systemName: "e.square.fill")
                            .accessibilityLabel("Explicit")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 8)
    }

    private func actions(_ item: LibraryItem) -> some View {
        VStack(spacing: 10) {
            if let progress = environment.progress(for: item.id), progress.isStarted {
                ProgressView(value: progress.progress) {
                    HStack {
                        Text(Format.remaining(progress.duration - progress.currentTime))
                        Spacer()
                        Text(Format.percent(progress.progress))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Button {
                    Task { await environment.player.playOrToggle(item: item) }
                } label: {
                    Label(playButtonTitle(for: item), systemImage: playButtonIcon(for: item))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!item.isPlayable || item.mediaType == .podcast)

                DownloadButton(item: item)
            }

            secondaryActions(item)
        }
    }

    /// What used to be behind the toolbar's overflow menu. These are decisions about
    /// a book, so they belong on the book's page where you can see the state they
    /// act on, rather than hidden a tap deep on both this screen and the player.
    @ViewBuilder
    private func secondaryActions(_ item: LibraryItem) -> some View {
        let progress = environment.progress(for: item.id)
        let isFinished = progress?.isFinished == true

        HStack(spacing: 10) {
            Button {
                Task {
                    await environment.player.markFinished(
                        itemId: item.id, finished: !isFinished, duration: item.duration
                    )
                    await environment.refreshProgressIndex()
                }
            } label: {
                Label(isFinished ? "Unfinished" : "Finished",
                      systemImage: isFinished ? "arrow.uturn.backward" : "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }

            // Nothing to restart until there's a position to throw away, so the
            // button stays out of the way until the book has actually been begun.
            if hasBegun(progress) {
                Button {
                    Task { await restart(item) }
                } label: {
                    Label("Restart", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
            }

            if environment.offlineItem(for: item.id) != nil {
                Button(role: .destructive) {
                    Task { await environment.removeDownload(key: item.id) }
                } label: {
                    Label("Remove", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .buttonStyle(.bordered)
        .font(.footnote)
        .lineLimit(1)
    }

    /// Started, or finished and so started at some point — either way there's
    /// progress to send back to zero.
    private func hasBegun(_ progress: LocalProgress?) -> Bool {
        guard let progress else { return false }
        return progress.isStarted || progress.isFinished
    }

    /// Clears the stored position so the book isn't silently resumed again, and
    /// moves the playhead too when this is the book currently loaded — otherwise
    /// the player would carry on from where the restart just erased.
    private func restart(_ item: LibraryItem) async {
        await environment.player.resetProgress(itemId: item.id, duration: item.duration)
        if environment.player.isCurrent(itemId: item.id) {
            environment.player.seek(to: 0)
        }
        await environment.refreshProgressIndex()
    }

    private func descriptionSection(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(description)
                .font(.callout)
                .lineLimit(isDescriptionExpanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)

            Button(isDescriptionExpanded ? "Show Less" : "More") {
                withAnimation(.smooth) { isDescriptionExpanded.toggle() }
            }
            .font(.caption.weight(.medium))
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
    }

    private func metadata(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !item.genres.isEmpty {
                TagRow(title: "Genres", values: item.genres)
            }
            if !item.tags.isEmpty {
                TagRow(title: "Tags", values: item.tags)
            }

            HStack(spacing: 20) {
                if let year = item.publishedYear { MetadataPair(label: "Published", value: year) }
                if let publisher = item.publisher { MetadataPair(label: "Publisher", value: publisher) }
            }
            .font(.caption)
        }
    }

    private func chapters(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chapters")
                .font(.headline)

            ForEach(item.chapters) { chapter in
                Button {
                    Task {
                        if !environment.player.isCurrent(itemId: item.id) {
                            await environment.player.play(item: item)
                        }
                        environment.player.seek(to: chapter.start)
                    }
                } label: {
                    HStack {
                        Text(chapter.title.isEmpty ? "Chapter \(chapter.id + 1)" : chapter.title)
                            .font(.callout)
                            .lineLimit(1)
                        Spacer()
                        Text(Format.timecode(chapter.start))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 7)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }

    private func episodes(_ podcast: PodcastMedia, item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Episodes").font(.headline)

            ForEach(podcast.episodes.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }) { episode in
                Button {
                    Task { await environment.player.playOrToggle(item: item, episodeId: episode.id) }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(episode.title).font(.callout).lineLimit(2)
                        HStack(spacing: 8) {
                            if let published = Format.relativeDate(episode.publishedAt) {
                                Text(published)
                            }
                            Text(Format.duration(episode.duration))
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 7)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }

    // MARK: - Helpers

    private var localCoverURL: URL? {
        guard let offline = environment.offlineItem(for: itemId), let name = offline.coverFileName else { return nil }
        return StorageLocations.itemFolder(forKey: offline.key).appendingPathComponent(name)
    }

    private func playButtonTitle(for item: LibraryItem) -> String {
        if environment.player.isCurrent(itemId: item.id), environment.player.isPlaying { return "Pause" }
        guard let progress = environment.progress(for: item.id) else { return "Play" }
        if progress.isFinished { return "Play Again" }
        return progress.isStarted ? "Resume" : "Play"
    }

    private func playButtonIcon(for item: LibraryItem) -> String {
        environment.player.isCurrent(itemId: item.id) && environment.player.isPlaying
            ? "pause.fill" : "play.fill"
    }

    private func load() async {
        do {
            item = try await environment.client.item(itemId)
            errorMessage = nil
        } catch {
            // A cached preview is better than an error, so only surface the failure
            // when there's nothing at all to show.
            if preview == nil {
                errorMessage = (error as? ABSError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

private struct MetadataPair: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.secondary)
        }
    }
}

private struct TagRow: View {
    let title: String
    let values: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.tertiary)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(values, id: \.self) { value in
                        Text(value)
                            .font(.caption)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: .capsule)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// Download control that reflects queued, in-progress, failed and completed states.
struct DownloadButton: View {
    let item: LibraryItem
    @Environment(AppEnvironment.self) private var environment

    private var offline: OfflineItem? { environment.offlineItem(for: item.id) }

    var body: some View {
        Button {
            Task { await act() }
        } label: {
            switch offline?.state {
            case .completed:
                Image(systemName: "checkmark.circle.fill")
            case .downloading, .queued:
                ProgressView(value: offline?.progress ?? 0)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            case .paused:
                Image(systemName: "arrow.down.circle.dotted")
            case .failed:
                Image(systemName: "exclamationmark.arrow.circlepath")
            case nil:
                Image(systemName: "arrow.down.circle")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(item.mediaType == .podcast)
        .help(helpText)
    }

    private var helpText: String {
        switch offline?.state {
        case .completed: "Downloaded — tap to remove"
        case .downloading, .queued: "Downloading — tap to cancel"
        case .paused: "Paused — tap to resume"
        case .failed: "Download failed — tap to retry"
        case nil: "Download for offline listening"
        }
    }

    private func act() async {
        switch offline?.state {
        case .completed, .downloading, .queued:
            await environment.removeDownload(key: item.id)
        case .paused, .failed:
            await environment.downloads.resume(key: item.id)
        case nil:
            await environment.download(item: item)
        }
    }
}
