import SwiftUI
import BookrestCore

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isShowingPlayer = false

    var body: some View {
        Group {
            if environment.isSignedIn {
                signedInShell
            } else if environment.isBootstrapping {
                ProgressView().controlSize(.large)
            } else {
                OnboardingView()
            }
        }
        .animation(.smooth(duration: 0.25), value: environment.isSignedIn)
    }

    private var signedInShell: some View {
        // `sidebarAdaptable` gives tabs on iPhone and a sidebar on iPad and Mac from
        // one declaration, which is what makes the app feel native on each.
        let tabs = TabView {
            Tab("Home", systemImage: "house") {
                NavigationStack { HomeView() }
            }

            Tab("Library", systemImage: "books.vertical") {
                NavigationStack { LibraryView() }
            }

            Tab("Downloads", systemImage: "arrow.down.circle") {
                NavigationStack { DownloadsView() }
            }

            #if !os(macOS)
            Tab("Settings", systemImage: "gearshape") {
                NavigationStack { SettingsView() }
            }
            #endif

            Tab(role: .search) {
                NavigationStack { SearchView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)

        return hostingMiniPlayer(tabs)
            .background {
                // Behind the whole shell, not just the player, so a book's colours
                // carry across every tab.
                ImmersiveBackground(palette: environment.theme.activePalette,
                                    style: .ambient)
            }
            .preferredColorScheme(environment.theme.colorScheme)
            .tint(environment.theme.tint)
            .task(id: environment.player.context?.key) {
                environment.theme.update(for: environment.player.context)
            }
            .animation(.smooth(duration: 0.3), value: environment.player.context?.key)
            .sheet(isPresented: $isShowingPlayer) {
                PlayerView()
                    .environment(environment)
                    #if os(macOS)
                    .frame(minWidth: 460, minHeight: 640)
                    #endif
            }
            .overlay(alignment: .top) {
                if !environment.network.isConnected {
                    OfflineBanner()
                }
            }
    }

    /// Attaches the mini player the way each OS expects.
    ///
    /// iOS 26's `tabViewBottomAccessory` is the only approach that reserves space
    /// rather than drawing over the tab bar — a `safeAreaInset` on the `TabView`
    /// itself covers the tab items. Older systems fall back to that inset.
    @ViewBuilder
    private func hostingMiniPlayer(_ tabs: some View) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            tabs.tabViewBottomAccessory {
                MiniPlayerContent(isShowingPlayer: $isShowingPlayer)
            }
        } else {
            tabs.safeAreaInset(edge: .bottom, spacing: 0) {
                MiniPlayerBar(isShowingPlayer: $isShowingPlayer)
            }
        }
        #else
        tabs.safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerBar(isShowingPlayer: $isShowingPlayer)
        }
        #endif
    }
}

/// Persistent, unobtrusive indication that the server is unreachable — important
/// because most of the app keeps working from downloads while it's showing.
private struct OfflineBanner: View {
    var body: some View {
        Label("Offline — playing downloads", systemImage: "wifi.slash")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: .capsule)
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
            .padding(.top, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
