import Testing
import Foundation
import MediaPlayer
@testable import BookrestCore

/// Regression cover for a crash that took the app down on every playback start.
///
/// `MPMediaItemArtwork` invokes its request handler on a private MediaPlayer queue.
/// The handler used to be built inside the `@MainActor` `NowPlayingController`, so it
/// inherited main-actor isolation and the runtime trapped
/// (`dispatch_assert_queue_fail`) the moment the system asked for a JPEG — on macOS,
/// iOS and CarPlay alike.
struct NowPlayingIsolationTests {

    /// A 2×2 PNG; enough for a real image to decode.
    private var pngData: Data {
        Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEklEQVR4nGP8z8Dwn4GBgYEBAA8\
        AAv8B4rZfAAAAAElFTkSuQmCC
        """.replacingOccurrences(of: "\n", with: ""))!
    }

    @Test("Artwork request handler runs off the main actor without trapping")
    func artworkHandlerIsNonisolated() async throws {
        let artwork = try #require(NowPlayingController.makeArtwork(from: pngData))

        // Exactly what MediaPlayer does, from exactly where it does it. If the handler
        // regains main-actor isolation this traps and the test process dies.
        let image = await Task.detached(priority: .userInitiated) {
            artwork.image(at: CGSize(width: 64, height: 64))
        }.value

        #expect(image != nil)
    }

    @Test("Concurrent off-main artwork requests stay stable")
    func repeatedOffMainRequests() async {
        // MPMediaItemArtwork isn't Sendable, so each task builds its own from the
        // raw bytes — which is also closer to how the app creates them per item.
        let data = pngData

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    guard let artwork = NowPlayingController.makeArtwork(from: data) else { return false }
                    return artwork.image(at: CGSize(width: 32, height: 32)) != nil
                }
            }
            for await produced in group { #expect(produced) }
        }
    }

    @Test("Malformed image data is rejected rather than crashing")
    func rejectsGarbage() {
        #expect(NowPlayingController.makeArtwork(from: Data([0x00, 0x01, 0x02])) == nil)
        #expect(NowPlayingController.makeArtwork(from: Data()) == nil)
    }
}
