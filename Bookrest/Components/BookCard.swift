import SwiftUI
import ABSClient
import BookrestCore

/// A cover-first grid tile. Progress and download state are drawn on the artwork so
/// the grid stays scannable at a glance without a second line of chrome.
struct BookCard: View {
    let item: LibraryItem
    var showsAuthor: Bool = true

    @Environment(AppEnvironment.self) private var environment

    private var progress: LocalProgress? {
        environment.progress(for: item.id)
    }

    private var offline: OfflineItem? {
        environment.offlineItem(for: item.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottom) {
                CoverImage(url: environment.coverURL(for: item.id, width: 400))

                if let progress, progress.currentTime > 0, !progress.isFinished {
                    ProgressView(value: progress.progress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                        .frame(height: 3)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                }
            }
            .overlay(alignment: .topTrailing) { badges }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if showsAuthor, let author = item.authorDisplay {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            if progress?.isFinished == true {
                Badge(systemImage: "checkmark", tint: .green)
            }
            if let offline {
                switch offline.state {
                case .completed:
                    Badge(systemImage: "arrow.down.circle.fill", tint: .accentColor)
                case .queued, .downloading:
                    Badge(systemImage: "arrow.down.circle", tint: .secondary)
                case .failed:
                    Badge(systemImage: "exclamationmark.circle.fill", tint: .orange)
                case .paused:
                    Badge(systemImage: "pause.circle.fill", tint: .secondary)
                }
            }
        }
        .padding(6)
    }

    private var accessibilityLabel: String {
        var parts = [item.title]
        if let author = item.authorDisplay { parts.append("by \(author)") }
        if let progress, progress.isFinished {
            parts.append("Finished")
        } else if let progress, progress.currentTime > 0 {
            parts.append("\(Format.percent(progress.progress)) listened")
        }
        return parts.joined(separator: ", ")
    }
}

private struct Badge: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(4)
            .background(.thinMaterial, in: .circle)
    }
}

/// Horizontal row used in lists, Continue Listening, and search results.
struct BookRow: View {
    let item: LibraryItem
    var subtitleOverride: String?

    @Environment(AppEnvironment.self) private var environment

    private var progress: LocalProgress? { environment.progress(for: item.id) }

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(url: environment.coverURL(for: item.id, width: 200), cornerRadius: 6)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body)
                    .lineLimit(2)

                if let subtitle = subtitleOverride ?? item.authorDisplay {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let progress, progress.currentTime > 0, !progress.isFinished {
                    HStack(spacing: 6) {
                        ProgressView(value: progress.progress)
                            .frame(maxWidth: 90)
                        Text(Format.remaining(progress.duration - progress.currentTime))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if item.duration > 0 {
                    Text(Format.duration(item.duration))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }
}
