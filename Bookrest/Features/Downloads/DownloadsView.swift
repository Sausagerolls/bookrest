import SwiftUI
import BookrestCore

/// Everything stored on the device, playable with the server unreachable.
struct DownloadsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isShowingRemoveAll = false

    private var active: [OfflineItem] {
        environment.offlineItems.filter { !$0.state.isComplete }
    }

    private var completed: [OfflineItem] {
        environment.offlineItems.filter(\.isPlayableOffline)
    }

    var body: some View {
        List {
            if !active.isEmpty {
                Section("In Progress") {
                    ForEach(active) { item in
                        DownloadProgressRow(item: item)
                    }
                }
            }

            if !completed.isEmpty {
                Section {
                    ForEach(completed) { item in
                        HStack(spacing: 8) {
                            Button {
                                Task { await environment.player.play(offlineItem: item) }
                            } label: {
                                OfflineRow(item: item)
                            }
                            .buttonStyle(.plain)

                            // An explicit control rather than swipe-only: swiping
                            // isn't discoverable, and doesn't exist on the Mac at all.
                            Menu {
                                Button {
                                    Task { await environment.player.play(offlineItem: item) }
                                } label: {
                                    Label("Play", systemImage: "play.fill")
                                }
                                Button(role: .destructive) {
                                    Task { await environment.removeDownload(key: item.key) }
                                } label: {
                                    Label("Remove Download", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 30, height: 30)
                                    .contentShape(.rect)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .accessibilityLabel("Options for \(item.title)")
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await environment.removeDownload(key: item.key) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Downloaded")
                } footer: {
                    Text("\(Format.bytes(completed.reduce(0) { $0 + $1.bytesDownloaded })) on this device")
                }
            }
        }
        .immersiveScrollBackground(environment.theme.activePalette)
        .overlay {
            if environment.offlineItems.isEmpty {
                EmptyStateView(
                    title: "No downloads",
                    message: "Download a book from its detail screen and it will play here without a connection.",
                    systemImage: "arrow.down.circle"
                )
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            if !environment.offlineItems.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Remove All", role: .destructive) { isShowingRemoveAll = true }
                }
            }
        }
        .confirmationDialog("Remove all downloads?", isPresented: $isShowingRemoveAll, titleVisibility: .visible) {
            Button("Remove All", role: .destructive) {
                Task {
                    for item in environment.offlineItems {
                        await environment.removeDownload(key: item.key)
                    }
                }
            }
        } message: {
            Text("Listening positions are kept — only the audio files are deleted.")
        }
    }
}

private struct OfflineRow: View {
    let item: OfflineItem

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(url: nil, localURL: coverURL, cornerRadius: 6)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body).lineLimit(2)
                if let author = item.author {
                    Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text("\(Format.duration(item.duration)) · \(Format.bytes(item.bytesDownloaded))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }

    private var coverURL: URL? {
        guard let name = item.coverFileName else { return nil }
        return StorageLocations.itemFolder(forKey: item.key).appendingPathComponent(name)
    }
}

private struct DownloadProgressRow: View {
    let item: OfflineItem
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.title).font(.callout).lineLimit(1)
                Spacer()
                controls
            }

            ProgressView(value: item.progress)
                .tint(item.state.isFailed ? .orange : .accentColor)

            HStack {
                Text(statusText)
                Spacer()
                Text("\(Format.bytes(item.bytesDownloaded)) of \(Format.bytes(item.expectedBytes))")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 14) {
            switch item.state {
            case .downloading, .queued:
                Button {
                    Task { await environment.downloads.pause(key: item.key) }
                } label: { Image(systemName: "pause.circle") }
            case .paused, .failed:
                Button {
                    Task { await environment.downloads.resume(key: item.key) }
                } label: { Image(systemName: "arrow.clockwise.circle") }
            case .completed:
                EmptyView()
            }

            Button(role: .destructive) {
                Task { await environment.removeDownload(key: item.key) }
            } label: { Image(systemName: "xmark.circle") }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private var statusText: String {
        switch item.state {
        case .queued: "Waiting…"
        case .downloading: Format.percent(item.progress)
        case .paused: "Paused"
        case .completed: "Done"
        case .failed(let reason): reason
        }
    }
}
