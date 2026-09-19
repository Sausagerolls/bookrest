import XCTest

/// Exercises the shipped UI, not the engine underneath it.
///
/// Every engine-level test passes against the live server, so a failure the user sees
/// but the harness doesn't must live in the view layer — the play button, the
/// navigation, or the mini player. This drives the real screens to find it.
final class PlaybackFlowUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        struct Credentials: Decodable { let url: String; let username: String; let password: String }
        guard let data = FileManager.default.contents(atPath: "/tmp/bookrest-live-test.json"),
              let creds = try? JSONDecoder().decode(Credentials.self, from: data)
        else { throw XCTSkip("Write /tmp/bookrest-live-test.json to run UI flow tests") }

        continueAfterFailure = false
        app = XCUIApplication()
        // XCUITest can pass these through, unlike plain xcodebuild env vars.
        app.launchEnvironment["BOOKREST_UITEST_SERVER"] = creds.url
        app.launchEnvironment["BOOKREST_UITEST_USER"] = creds.username
        app.launchEnvironment["BOOKREST_UITEST_PASSWORD"] = creds.password
        app.launch()
    }

    /// Signs in through the real onboarding screen if the app isn't already signed in.
    private func signInIfNeeded() throws {
        let serverField = app.textFields["audiobooks.example.com"]
        guard serverField.waitForExistence(timeout: 10) else { return }  // already signed in

        struct Credentials: Decodable { let url: String; let username: String; let password: String }
        let data = FileManager.default.contents(atPath: "/tmp/bookrest-live-test.json")!
        let creds = try JSONDecoder().decode(Credentials.self, from: data)

        serverField.tap()
        serverField.typeText(creds.url)
        app.buttons["Continue"].firstMatch.tap()

        let userField = app.textFields["Username"]
        XCTAssertTrue(userField.waitForExistence(timeout: 20), "credentials step never appeared")
        userField.tap()
        userField.typeText(creds.username)

        let passwordField = app.secureTextFields["Password"]
        passwordField.tap()
        passwordField.typeText(creds.password)
        app.buttons["Sign In"].firstMatch.tap()
    }

    func testCanReachLibraryAndStartPlayback() throws {
        try signInIfNeeded()

        // Home should populate from the server's personalized shelves.
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 45), "never reached the signed-in shell")

        app.buttons["Library"].firstMatch.tap()

        // Any book cell in the grid.
        let firstBook = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'by'")).firstMatch
        XCTAssertTrue(firstBook.waitForExistence(timeout: 45), "library never populated")
        print("[ui] opening: \(firstBook.label)")
        firstBook.tap()

        // The detail screen's primary action.
        let play = app.buttons.matching(NSPredicate(format: "label IN {'Play', 'Resume', 'Play Again'}")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30), "no play button on the detail screen")
        print("[ui] tapping: \(play.label)")
        play.tap()

        // The mini player is the visible proof that playback engaged.
        let miniPlayer = app.otherElements.matching(
            NSPredicate(format: "label BEGINSWITH 'Now playing'")).firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 45),
                      "mini player never appeared — playback did not start")
        print("[ui] mini player: \(miniPlayer.label)")
    }
}
