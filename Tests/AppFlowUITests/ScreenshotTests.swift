import XCTest

/// Captures App Store screenshots from the real app against a live server.
///
/// Reads the same `/tmp/bookrest-live-test.json` as the flow tests, plus a
/// `screenshotDir` key naming a host directory to write PNGs into. Simulator-only:
/// the test process writes straight to the Mac's filesystem.
final class ScreenshotTests: XCTestCase {

    private struct Config: Decodable {
        let url: String
        let username: String
        let password: String
        let screenshotDir: String
    }

    private var app: XCUIApplication!
    private var config: Config!

    override func setUpWithError() throws {
        guard let data = FileManager.default.contents(atPath: "/tmp/bookrest-live-test.json"),
              let config = try? JSONDecoder().decode(Config.self, from: data)
        else { throw XCTSkip("Write /tmp/bookrest-live-test.json with screenshotDir to capture screenshots") }

        self.config = config
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testCaptureStoreScreenshots() throws {
        try signInIfNeeded()

        let libraryTab = app.buttons["Library"].firstMatch
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 45), "never reached the signed-in shell")
        settle(8)
        try capture("01-home")

        libraryTab.tap()
        let firstBook = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'by'")).firstMatch
        XCTAssertTrue(firstBook.waitForExistence(timeout: 45), "library never populated")
        settle(6)
        try capture("02-library")

        firstBook.tap()
        let play = app.buttons.matching(
            NSPredicate(format: "label IN {'Play', 'Resume', 'Play Again'}")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30), "no play button on the detail screen")
        settle(4)
        try capture("03-detail")

        play.tap()
        let miniPlayer = app.otherElements.matching(
            NSPredicate(format: "label BEGINSWITH 'Now playing'")).firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 45), "playback never started")
        settle(3)
        // Tap the cover end, clear of the play and skip buttons.
        miniPlayer.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
        if !app.buttons["Playback speed"].waitForExistence(timeout: 15) {
            try? capture("debug-player")
            XCTFail("full player never opened")
        }
        settle(4)
        try capture("04-player")

        // Leave the demo account paused rather than playing indefinitely.
        app.buttons["Pause"].firstMatch.tap()
    }

    private func signInIfNeeded() throws {
        let serverField = app.textFields["audiobooks.example.com"]
        guard serverField.waitForExistence(timeout: 10) else { return }

        serverField.tap()
        serverField.typeText(config.url)
        app.buttons["Continue"].firstMatch.tap()

        let userField = app.textFields["Username"]
        if !userField.waitForExistence(timeout: 20) {
            try? capture("debug-credentials-step")
            XCTFail("credentials step never appeared")
        }
        userField.tap()
        userField.typeText(config.username)

        let passwordField = app.secureTextFields["Password"]
        passwordField.tap()
        passwordField.typeText(config.password)
        app.buttons["Sign In"].firstMatch.tap()

        // The system offers to save the password; it must not appear in screenshots.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for source in [app!, springboard] {
            let notNow = source.buttons["Not Now"]
            if notNow.waitForExistence(timeout: 8) { notNow.tap(); break }
        }
    }

    /// Gives covers and shelves time to load before capturing.
    private func settle(_ seconds: TimeInterval) {
        _ = app.wait(for: .runningForeground, timeout: 1)
        Thread.sleep(forTimeInterval: seconds)
    }

    private func capture(_ name: String) throws {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let dir = URL(fileURLWithPath: config.screenshotDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
