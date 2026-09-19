import SwiftUI
import BookrestCore

/// Compact transport for iOS 26's `tabViewBottomAccessory`.
///
/// The system draws the glass container and reserves the space, and it only reserves
/// a row's worth — so this stays deliberately minimal and supplies no background of
/// its own, or it fights the system material. Platforms without the accessory get
/// `MiniPlayerBar` below, which has room to be a proper player.
struct MiniPlayerContent: View {
    @Binding var isShowingPlayer: Bool

    @Environment(AppEnvironment.self) private var environment

    private var player: PlaybackController { environment.player }

    var body: some View {
        if let context = player.context {
            HStack(spacing: 10) {
                CoverImage(url: context.coverURL,
                           localURL: context.localCoverURL,
                           cornerRadius: 5)
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 0) {
                    Text(context.title)
                        .font(.subheadline)
                        .lineLimit(1)
                    if let secondary = secondaryLine(context) {
                        Text(secondary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                // Just play/pause and a skip, matching the system's own compact
                // transports. Anything more crowds a 30pt row.
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17))
                        .frame(width: 26, height: 26)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                Button {
                    player.skipForward()
                } label: {
                    Image(systemName: "goforward.\(player.skipForwardInterval.rawValue)")
                        .font(.system(size: 16))
                        .frame(width: 26, height: 26)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip forward")
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
            .onTapGesture { isShowingPlayer = true }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Now playing: \(context.title)")
        }
    }

    /// Chapter when there is one — it's the most useful thing to see mid-book —
    /// otherwise the author.
    private func secondaryLine(_ context: PlaybackContext) -> String? {
        if let chapter = player.engine.currentChapter, !chapter.title.isEmpty {
            return chapter.title
        }
        return context.author
    }
}

/// Bar presentation for platforms without the system accessory — macOS and pre-26 iOS.
///
/// Given a window's worth of room rather than a tab bar's, this is a real transport
/// rather than a shrunken one: the cover is big enough to actually read at a glance,
/// the transport sits centred, and the scrubber gets its own row so the position is
/// visible and draggable without opening the full player.
struct MiniPlayerBar: View {
    @Binding var isShowingPlayer: Bool
    @Environment(AppEnvironment.self) private var environment

    /// Non-nil only while a drag is in flight, so the row tracks the finger without
    /// fighting the playhead.
    @State private var scrubTime: TimeInterval?

    private var player: PlaybackController { environment.player }

    private let coverSize: CGFloat = 56

    var body: some View {
        if let context = player.context {
            VStack(spacing: 7) {
                HStack(spacing: 14) {
                    nowPlaying(context)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // The flexible frames on the groups either side are what hold the
                    // transport in the centre of the bar, rather than letting it drift
                    // with the length of the title.
                    transport

                    trailing
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                scrubber(context)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            .overlay(alignment: .top) {
                Divider().opacity(0.5)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Now playing: \(context.title)")
        }
    }

    /// Cover and titles. Only this part opens the full player — putting the gesture on
    /// the whole bar would swallow drags meant for the scrubber.
    private func nowPlaying(_ context: PlaybackContext) -> some View {
        HStack(spacing: 12) {
            CoverImage(url: context.coverURL,
                       localURL: context.localCoverURL,
                       cornerRadius: 6)
                .frame(width: coverSize, height: coverSize)
                .shadow(color: .black.opacity(0.22), radius: 5, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(context.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let secondary = secondaryLine(context) {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(.rect)
        .onTapGesture { isShowingPlayer = true }
        .help("Open the player")
    }

    private var transport: some View {
        HStack(spacing: 16) {
            Button { player.previousChapter() } label: {
                Image(systemName: "backward.end.fill").font(.footnote)
            }
            .accessibilityLabel("Previous chapter")

            Button { player.skipBackward() } label: {
                Image(systemName: "gobackward.\(player.skipBackwardInterval.rawValue)")
                    .font(.title3)
            }
            .accessibilityLabel("Skip backward")

            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 38))
                    .symbolRenderingMode(.hierarchical)
            }
            .contentTransition(.symbolEffect(.replace))
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Button { player.skipForward() } label: {
                Image(systemName: "goforward.\(player.skipForwardInterval.rawValue)")
                    .font(.title3)
            }
            .accessibilityLabel("Skip forward")

            Button { player.nextChapter() } label: {
                Image(systemName: "forward.end.fill").font(.footnote)
            }
            .accessibilityLabel("Next chapter")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    /// Speed is the one setting worth reaching for mid-listen without opening the
    /// player; the sleep timer only appears once it's actually running.
    private var trailing: some View {
        HStack(spacing: 14) {
            if let remaining = player.engine.sleepTimerRemaining {
                Label(Format.timecode(remaining), systemImage: "moon.fill")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Sleeping in \(Format.timecode(remaining))")
            }

            Button { player.cycleRate() } label: {
                Text(PlaybackRate.format(player.rate))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Playback speed")
            .help("Playback speed")
        }
    }

    private func scrubber(_ context: PlaybackContext) -> some View {
        HStack(spacing: 8) {
            Text(Format.timecode(scrubTime ?? player.currentTime))

            Slider(
                value: Binding(
                    get: { scrubTime ?? player.currentTime },
                    set: { scrubTime = $0 }
                ),
                in: 0...max(1, context.duration),
                onEditingChanged: { isEditing in
                    // Same reason as the full player: seeking on every value change
                    // makes streaming playback stutter.
                    if !isEditing, let target = scrubTime {
                        player.seek(to: target)
                        scrubTime = nil
                    }
                }
            )
            .controlSize(.mini)

            Text("−\(Format.timecode(max(0, context.duration - (scrubTime ?? player.currentTime))))")
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    /// Chapter when there is one — the most useful thing to see mid-book — otherwise
    /// the author.
    private func secondaryLine(_ context: PlaybackContext) -> String? {
        if let chapter = player.engine.currentChapter, !chapter.title.isEmpty {
            return chapter.title
        }
        return context.author
    }
}
