import Testing
import Foundation
import AVFoundation
@testable import BookrestCore

/// Behavioural contract for starting, pausing and resuming playback.
///
/// These pin what the engine must do; they do **not** reproduce the bug that
/// prompted them. `load(autoPlay: true)` used to begin playing only from the initial
/// seek's completion handler, which never fires on an item that isn't ready yet —
/// so the first tap did nothing and the second appeared to start it. A local file
/// becomes ready almost immediately, so the old code passes these too; the race
/// needs a network-backed item and was verified against a live server instead.
///
/// Reproducing it hermetically would need a local HTTP server that stalls before
/// serving byte ranges. Worth adding if this area changes again.
@MainActor
struct PlayerEngineStartTests {

    /// Writes a real, decodable PCM WAV so `AVPlayer` has genuine media to load.
    private func makeSilentTrack(seconds: Int) throws -> URL {
        let sampleRate = 8000, channels = 1, bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let dataBytes = byteRate * seconds

        var wav = Data()
        func append(_ string: String) { wav.append(contentsOf: string.utf8) }
        func append32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { wav.append(contentsOf: $0) } }
        func append16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { wav.append(contentsOf: $0) } }

        append("RIFF"); append32(36 + dataBytes); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(channels)
        append32(sampleRate); append32(byteRate)
        append16(channels * bitsPerSample / 8); append16(bitsPerSample)
        append("data"); append32(dataBytes)
        wav.append(Data(count: dataBytes))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookrest-test-\(UUID().uuidString).wav")
        try wav.write(to: url)
        return url
    }

    private func context(url: URL, duration: TimeInterval) -> PlaybackContext {
        PlaybackContext(
            key: "test", itemId: "test", episodeId: nil, libraryId: "lib",
            title: "Test", author: nil, narrator: nil, coverURL: nil, localCoverURL: nil,
            chapters: [],
            tracks: [PlayableTrack(index: 1, startOffset: 0, duration: duration, url: url, isLocal: true)],
            duration: duration, serverSessionId: nil, isOffline: true, serverResumeTime: 0
        )
    }

    /// Polls rather than sleeping a fixed time, so the test isn't tied to how fast
    /// AVFoundation happens to make an item ready.
    private func waitUntil(timeout: Duration = .seconds(10),
                           _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    @Test("autoPlay actually starts playback from a cold load")
    func autoPlayStarts() async throws {
        let url = try makeSilentTrack(seconds: 30)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = PlayerEngine()
        engine.load(context(url: url, duration: 30), startingAt: 0, autoPlay: true)

        #expect(await waitUntil { engine.isPlaying }, "engine never reached .playing")
        #expect(await waitUntil { engine.currentTime > 0.4 }, "clock never advanced")
        engine.stop()
    }

    @Test("autoPlay false loads without starting")
    func loadPausedStaysPaused() async throws {
        let url = try makeSilentTrack(seconds: 30)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = PlayerEngine()
        engine.load(context(url: url, duration: 30), startingAt: 5, autoPlay: false)

        #expect(await waitUntil { engine.status == .paused })
        try await Task.sleep(for: .seconds(1))
        #expect(!engine.isPlaying)
        #expect(engine.currentTime < 6.5, "should sit at the requested offset, not run on")
        engine.stop()
    }

    @Test("a resumed position is honoured on a cold load")
    func startsAtOffset() async throws {
        let url = try makeSilentTrack(seconds: 30)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = PlayerEngine()
        engine.load(context(url: url, duration: 30), startingAt: 12, autoPlay: true)

        #expect(await waitUntil { engine.isPlaying })
        #expect(await waitUntil { engine.currentTime >= 12 }, "did not land at the resume point")
        #expect(engine.currentTime < 20, "overshot the resume point")
        engine.stop()
    }

    @Test("pause stops the clock and play resumes it")
    func pauseAndResume() async throws {
        let url = try makeSilentTrack(seconds: 30)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = PlayerEngine()
        engine.load(context(url: url, duration: 30), startingAt: 0, autoPlay: true)
        #expect(await waitUntil { engine.currentTime > 0.4 })

        engine.pause()
        #expect(await waitUntil(timeout: .seconds(2)) { !engine.isPlaying })
        try await Task.sleep(for: .milliseconds(300))
        let frozen = engine.currentTime
        try await Task.sleep(for: .seconds(1))
        #expect(abs(engine.currentTime - frozen) < 0.35, "clock kept running while paused")

        engine.play()
        #expect(await waitUntil { engine.currentTime > frozen + 0.4 }, "did not resume")
        engine.stop()
    }
}
