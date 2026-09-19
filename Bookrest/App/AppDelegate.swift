import Foundation
import BookrestCore

#if canImport(UIKit)
import UIKit

/// Exists for two things SwiftUI's lifecycle doesn't cover: handing background
/// download completion back to the system, and letting the CarPlay scene be matched
/// from the Info.plist scene manifest.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == DownloadManager.backgroundSessionIdentifier else {
            completionHandler()
            return
        }

        // UIKit hands this over as a plain (non-Sendable) closure, but it's only ever
        // invoked on the main thread, so carrying it across the boundary is safe.
        let handler = MainThreadCompletion(completionHandler)
        MainActor.assumeIsolated {
            AppEnvironment.shared.downloads.setBackgroundCompletionHandler {
                handler.callAsFunction()
            }
        }
    }
}

/// Carries UIKit's completion handler into a `@Sendable` context.
private final class MainThreadCompletion: @unchecked Sendable {
    private let body: () -> Void

    init(_ body: @escaping () -> Void) {
        self.body = body
    }

    func callAsFunction() {
        if Thread.isMainThread {
            body()
        } else {
            let box = self
            Task { @MainActor in box.body() }
        }
    }
}
#endif
