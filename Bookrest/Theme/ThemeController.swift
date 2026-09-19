import SwiftUI
import Observation
import BookrestCore

/// Owns the immersive theme: whether it's on, and the palette of whatever is playing.
@MainActor
@Observable
final class ThemeController {
    private enum Keys {
        static let immersive = "com.bookrest.immersiveTheme"
    }

    var isImmersive: Bool {
        didSet {
            UserDefaults.standard.set(isImmersive, forKey: Keys.immersive)
            if !isImmersive { palette = nil }
        }
    }

    private(set) var palette: ArtworkPalette?

    /// Palette only when the theme is switched on, so views can read one property.
    var activePalette: ArtworkPalette? { isImmersive ? palette : nil }

    /// App tint: the cover's accent while immersive, otherwise the asset colour.
    var tint: Color { activePalette?.accent ?? .accentColor }

    /// Scheme the wash demands, or `nil` to follow the system when there's no wash.
    ///
    /// The palette carries this because the wash is always a dark one: without
    /// forcing the scheme to match, the system keeps drawing near-black label
    /// colours over it and the text all but disappears.
    var colorScheme: ColorScheme? {
        guard let palette = activePalette else { return nil }
        return palette.prefersLightText ? .dark : .light
    }

    private var loadedKey: String?
    private var loadTask: Task<Void, Never>?

    init() {
        isImmersive = UserDefaults.standard.bool(forKey: Keys.immersive)
    }

    /// Recomputes the palette for the item now playing.
    func update(for context: PlaybackContext?) {
        guard isImmersive else {
            palette = nil
            loadedKey = nil
            return
        }
        guard let context else {
            palette = nil
            loadedKey = nil
            return
        }
        guard context.key != loadedKey else { return }

        loadedKey = context.key
        loadTask?.cancel()
        // Prefer the downloaded cover: no network, and identical artwork.
        let source = context.localCoverURL ?? context.coverURL

        loadTask = Task { [weak self] in
            guard let source else {
                self?.palette = nil
                return
            }
            let data: Data?
            if source.isFileURL {
                data = try? Data(contentsOf: source)
            } else {
                data = try? await URLSession.shared.data(from: source).0
            }
            guard !Task.isCancelled, let data else { return }

            // Histogramming a thumbnail is cheap, but not main-thread work.
            let extracted = await Task.detached(priority: .utility) {
                PaletteExtractor.palette(from: data)
            }.value

            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.45)) {
                self?.palette = extracted
            }
        }
    }
}

/// Background wash drawn behind the app while the immersive theme is on.
///
/// One view serves both placements so a book's colours are the same everywhere:
/// `.player` is the full-strength gradient behind the now-playing screen, and
/// `.ambient` is the quieter version behind the rest of the app, where lists and
/// materials sit on top of it.
struct ImmersiveBackground: View {
    let palette: ArtworkPalette?
    var style: Style = .player

    enum Style {
        case player
        case ambient

        var opacity: Double {
            switch self {
            case .player: 1
            case .ambient: 0.55
            }
        }
    }

    var body: some View {
        // The ZStack outlives any one palette, which is what lets a change between
        // two books cross-fade instead of snapping: `id` retires the old gradient
        // and the opacity transition dissolves them across each other.
        ZStack {
            if let palette {
                wash(palette)
                    .opacity(style.opacity)
                    .id(palette)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.55), value: palette)
    }

    private func wash(_ palette: ArtworkPalette) -> some View {
        LinearGradient(
            colors: [palette.secondary, palette.base, palette.base],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(alignment: .top) {
            if style == .player {
                // A soft bloom behind the artwork, so the cover appears lit rather
                // than pasted onto a flat gradient.
                RadialGradient(
                    colors: [palette.accent.opacity(0.30), .clear],
                    center: .init(x: 0.5, y: 0.22),
                    startRadius: 0,
                    endRadius: 420
                )
            }
        }
    }
}

extension View {
    /// Lets the wash show through a `List` or `Form`, which otherwise paint their
    /// own opaque background. Left alone when there's no wash, so the standard
    /// grouped background survives with the theme switched off.
    @ViewBuilder
    func immersiveScrollBackground(_ palette: ArtworkPalette?) -> some View {
        scrollContentBackground(palette == nil ? .automatic : .hidden)
    }
}
