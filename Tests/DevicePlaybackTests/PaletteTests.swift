import XCTest
import SwiftUI
@testable import ABSClient

/// The immersive theme is only as good as what comes out of the cover, and
/// "averages to grey-brown" is the classic failure. These check real covers from the
/// live library produce colours with actual character.
@MainActor
final class PaletteTests: XCTestCase {

    func testRealCoversYieldColourfulPalettes() async throws {
        struct Credentials: Decodable { let url: String; let username: String; let password: String }
        guard let data = FileManager.default.contents(atPath: "/tmp/bookrest-live-test.json"),
              let creds = try? JSONDecoder().decode(Credentials.self, from: data),
              let serverURL = ServerConnection.normalize(urlString: creds.url)
        else { throw XCTSkip("no credentials") }

        let client = AudiobookshelfClient(storage: InMemoryCredentialStorage())
        let connection = try await client.signIn(serverURL: serverURL,
                                                 username: creds.username,
                                                 password: creds.password)
        let library = try await client.libraries().first { $0.mediaType == .book }!
        let page = try await client.items(inLibrary: library.id, limit: 6)

        var examined = 0
        for item in page.results {
            guard let url = AudiobookshelfClient.coverURL(itemId: item.id, connection: connection, width: 400),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  !data.isEmpty
            else { continue }

            let palette = PaletteProbe.describe(data)
            XCTAssertNotNil(palette, "no palette from \(item.title)")
            guard let palette else { continue }
            print("[palette] \(item.title.prefix(38)) → base \(palette.base) accent \(palette.accent) sat \(String(format: "%.2f", palette.accentSaturation))")

            // A completely grey accent means the extractor collapsed the cover.
            XCTAssertGreaterThan(palette.accentSaturation, 0.05,
                                 "accent for \(item.title) has no colour left in it")
            // The wash has to clear white text by a comfortable margin, and it has
            // to get there from any cover: the previous brightness-scaling approach
            // left dark covers at a near-black luminance of 0.02–0.04, which is how
            // a dark cover ended up as an unreadable screen.
            XCTAssertLessThan(palette.baseLuminance, 0.35,
                              "background for \(item.title) is too light for white text")
            XCTAssertGreaterThan(palette.baseLuminance, 0.12,
                                 "background for \(item.title) collapsed to near-black")
            examined += 1
        }
        XCTAssertGreaterThan(examined, 0, "no covers could be fetched")
    }
}
