import SwiftUI
import ABSClient
import BookrestCore

struct PlayerView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var scrubTime: TimeInterval?
    @State private var isShowingChapters = false
    @State private var isShowingSleepTimer = false

    private var player: PlaybackController { environment.player }

    var body: some View {
        Group {
            if let context = player.context {
                content(context)
            } else {
                EmptyStateView(title: "Nothing playing",
                               message: "Choose a book to start listening.",
                               systemImage: "play.circle")
            }
        }
        #if !os(macOS)
        .presentationDragIndicator(.visible)
        #endif
    }

    private func content(_ context: PlaybackContext) -> some View {
        VStack(spacing: 0) {
            header

            Spacer(minLength: 12)

            CoverImage(url: context.coverURL, localURL: context.localCoverURL, cornerRadius: 14)
                .frame(maxWidth: 320)
                .shadow(color: .black.opacity(0.25), radius: 22, y: 10)
                .scaleEffect(player.isPlaying ? 1 : 0.94)
                .animation(.smooth(duration: 0.35), value: player.isPlaying)
                .padding(.horizontal, 32)

            Spacer(minLength: 16)

            VStack(spacing: 4) {
                Text(context.title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if let author = context.author {
                    Text(author).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)

            scrubber(context)
                .padding(.horizontal, 28)
                .padding(.top, 20)

            transport
                .padding(.top, 12)

            secondaryControls(context)
                .padding(.top, 22)
                .padding(.bottom, 24)
        }
        .background {
            ImmersiveBackground(palette: environment.theme.activePalette)
        }
        .preferredColorScheme(environment.theme.colorScheme)
        .sheet(isPresented: $isShowingChapters) {
            ChapterListView(context: context)
                .environment(environment)
        }
        .sheet(isPresented: $isShowingSleepTimer) {
            SleepTimerView().environment(environment)
        }
    }

    /// Deliberately sparse: the chapter name used to sit here and duplicated the
    /// scrubber's own chapter context, the downloaded badge has moved down to the
    /// secondary controls where the other status-y items live, and restart and
    /// mark-as-finished now live on the book's own page — they're things you decide
    /// about a book, not controls you reach for mid-listen.
    private var header: some View {
        HStack {
            #if os(macOS)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            #endif

            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.top, 8)
        .frame(minHeight: 28)
    }

    private func scrubber(_ context: PlaybackContext) -> some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { scrubTime ?? player.currentTime },
                    set: { scrubTime = $0 }
                ),
                in: 0...max(1, context.duration),
                onEditingChanged: { isEditing in
                    // Commit only when the drag ends: seeking on every value change
                    // makes streaming playback stutter badly.
                    if !isEditing, let target = scrubTime {
                        player.seek(to: target)
                        scrubTime = nil
                    }
                }
            )

            HStack {
                Text(Format.timecode(scrubTime ?? player.currentTime))
                Spacer()
                if case .buffering = player.status {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                Text("−\(Format.timecode(max(0, context.duration - (scrubTime ?? player.currentTime))))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 28) {
            Button { player.previousChapter() } label: {
                Image(systemName: "backward.end.fill").font(.title3)
            }

            Button { player.skipBackward() } label: {
                Image(systemName: "gobackward.\(player.skipBackwardInterval.rawValue)")
                    .font(.title)
            }

            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 62))
                    .symbolRenderingMode(.hierarchical)
            }
            .contentTransition(.symbolEffect(.replace))

            Button { player.skipForward() } label: {
                Image(systemName: "goforward.\(player.skipForwardInterval.rawValue)")
                    .font(.title)
            }

            Button { player.nextChapter() } label: {
                Image(systemName: "forward.end.fill").font(.title3)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private func secondaryControls(_ context: PlaybackContext) -> some View {
        HStack(spacing: 34) {
            Button { player.cycleRate() } label: {
                Text(PlaybackRate.format(player.rate))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 40)
            }
            .accessibilityLabel("Playback speed")

            Button { isShowingChapters = true } label: {
                Image(systemName: "list.bullet")
            }
            .disabled(context.chapters.isEmpty)
            .accessibilityLabel("Chapters")

            Button { isShowingSleepTimer = true } label: {
                Image(systemName: player.engine.sleepTimerRemaining == nil ? "moon" : "moon.fill")
            }
            .accessibilityLabel("Sleep timer")

            #if !os(macOS)
            AirPlayButton()
                .frame(width: 26, height: 26)
            #endif

            if context.isOffline {
                Image(systemName: "arrow.down.circle.fill")
                    .accessibilityLabel("Playing a download")
                    .help("Playing from a download")
            }
        }
        .buttonStyle(.plain)
        .font(.title3)
        .foregroundStyle(.secondary)
        .overlay(alignment: .bottom) {
            if let remaining = player.engine.sleepTimerRemaining {
                Text("Sleeping in \(Format.timecode(remaining))")
                    .font(.caption2)
                    .foregroundStyle(.tint)
                    .offset(y: 22)
            }
        }
    }
}

private struct ChapterListView: View {
    let context: PlaybackContext
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(context.chapters) { chapter in
                Button {
                    environment.player.seekToChapter(chapter)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chapter.title.isEmpty ? "Chapter \(chapter.id + 1)" : chapter.title)
                                .foregroundStyle(isCurrent(chapter) ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                            Text(Format.duration(chapter.duration))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isCurrent(chapter) {
                            Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(.tint)
                        }
                        Text(Format.timecode(chapter.start))
                            .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Chapters")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func isCurrent(_ chapter: Chapter) -> Bool {
        environment.player.engine.currentChapter?.id == chapter.id
    }
}

private struct SleepTimerView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    private let options = [5, 10, 15, 30, 45, 60, 90]

    var body: some View {
        NavigationStack {
            List {
                if environment.player.engine.sleepTimerRemaining != nil {
                    Section {
                        Button("Add 5 Minutes") { environment.player.extendSleepTimer(minutes: 5) }
                        Button("Turn Off Timer", role: .destructive) {
                            environment.player.cancelSleepTimer()
                            dismiss()
                        }
                    }
                }

                Section("Stop After") {
                    ForEach(options, id: \.self) { minutes in
                        Button("\(minutes) minutes") {
                            environment.player.startSleepTimer(minutes: minutes)
                            dismiss()
                        }
                    }
                    Button("End of Chapter") {
                        environment.player.startSleepTimerAtEndOfChapter()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Sleep Timer")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(width: 320, height: 420)
        #endif
    }
}

#if !os(macOS)
import AVKit

/// Wraps the system route picker so AirPlay behaves exactly as users expect.
private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif
