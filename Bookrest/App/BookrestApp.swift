import SwiftUI
import BookrestCore

@main
struct BookrestApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    @State private var environment = AppEnvironment.shared

    var body: some Scene {
        mainWindow

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(environment)
                .frame(width: 520, height: 460)
        }
        #endif
    }

    // Platform differences are resolved here rather than inside the scene builder,
    // which can't mix modifiers and additional scenes inside one `#if`.
    private var mainWindow: some Scene {
        let group = WindowGroup {
            RootView()
                .environment(environment)
                .modifier(ScenePhaseBridge(environment: environment))
                .task { await environment.bootstrap() }
        }

        #if os(macOS)
        return group
            .defaultSize(width: 1100, height: 760)
            .commands { BookrestCommands(environment: environment) }
        #else
        return group
        #endif
    }
}

/// Foreground and background transitions drive progress syncing, so they're handled
/// on the root view where `scenePhase` is available without complicating the scene.
struct ScenePhaseBridge: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let environment: AppEnvironment

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await environment.handleForeground() }
            case .background:
                Task { await environment.handleBackground() }
            default:
                break
            }
        }
    }
}
