#if os(macOS)
import SwiftUI
import BookrestCore

/// Keyboard-driven transport. On the Mac an audio app that can't be controlled from
/// the menu bar and the keyboard doesn't feel finished.
struct BookrestCommands: Commands {
    let environment: AppEnvironment

    var body: some Commands {
        CommandMenu("Playback") {
            Button(environment.player.isPlaying ? "Pause" : "Play") {
                environment.player.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(environment.player.context == nil)

            Divider()

            Button("Skip Forward") { environment.player.skipForward() }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
            Button("Skip Back") { environment.player.skipBackward() }
                .keyboardShortcut(.leftArrow, modifiers: [.command])

            Divider()

            Button("Next Chapter") { environment.player.nextChapter() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
            Button("Previous Chapter") { environment.player.previousChapter() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])

            Divider()

            Button("Increase Speed") {
                environment.player.setRate(environment.player.rate + 0.1)
            }
            .keyboardShortcut("]", modifiers: [.command])
            Button("Decrease Speed") {
                environment.player.setRate(environment.player.rate - 0.1)
            }
            .keyboardShortcut("[", modifiers: [.command])
            Button("Normal Speed") { environment.player.setRate(1.0) }
                .keyboardShortcut("0", modifiers: [.command])
        }

        CommandGroup(replacing: .newItem) {}
    }
}
#endif
