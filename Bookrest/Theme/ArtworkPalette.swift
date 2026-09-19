import SwiftUI
import ImageIO
import CoreGraphics

/// Colours pulled from a book's cover, used to tint the app while it plays.
struct ArtworkPalette: Equatable, Hashable, Sendable {
    /// Deepest of the cover's colours — the base of the background wash.
    var base: Color
    /// A second colour for the gradient, so the background has depth.
    var secondary: Color
    /// The most characterful colour, used for controls and progress.
    var accent: Color
    /// Whether text should be light. Driven by the background's luminance.
    var prefersLightText: Bool

    static let neutral = ArtworkPalette(
        base: Color(red: 0.17, green: 0.17, blue: 0.19),
        secondary: Color(red: 0.27, green: 0.26, blue: 0.29),
        accent: Color.accentColor,
        prefersLightText: true
    )
}

/// Extracts a palette from cover artwork.
///
/// Cover art is the only strong colour signal the app has, so the whole immersive
/// theme derives from it. The image is reduced to a thumbnail and histogrammed
/// rather than averaged — averaging a cover almost always yields mud.
enum PaletteExtractor {

    /// Luminance the two ends of the background gradient are pulled to.
    ///
    /// Both sit in the dark half so light text stays legible, but well clear of
    /// black — the gap between them is what gives the wash its depth.
    private enum Wash {
        static let base = 0.20
        static let secondary = 0.32
    }

    private struct Swatch {
        let red: Double, green: Double, blue: Double
        let count: Int

        var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }

        var saturation: Double {
            let maximum = max(red, green, blue), minimum = min(red, green, blue)
            guard maximum > 0 else { return 0 }
            return (maximum - minimum) / maximum
        }

        var color: Color { Color(red: red, green: green, blue: blue) }

        func adjusted(brightness: Double, saturation saturationScale: Double = 1) -> Color {
            let average = (red + green + blue) / 3
            func channel(_ value: Double) -> Double {
                let saturated = average + (value - average) * saturationScale
                return min(1, max(0, saturated * brightness))
            }
            return Color(red: channel(red), green: channel(green), blue: channel(blue))
        }

        /// Lands the swatch at a known luminance, whatever it started at.
        ///
        /// Scaling brightness (the obvious approach) leaves an already-dark cover
        /// almost black, which is how the wash used to end up unreadable. Offsetting
        /// every channel by a constant moves luminance by exactly that constant —
        /// the weights sum to 1 — so every cover produces a wash of the same depth
        /// while keeping its hue.
        func washed(luminance target: Double, saturation saturationScale: Double) -> Color {
            let average = (red + green + blue) / 3
            let r = average + (red - average) * saturationScale
            let g = average + (green - average) * saturationScale
            let b = average + (blue - average) * saturationScale
            let delta = target - (0.2126 * r + 0.7152 * g + 0.0722 * b)
            func channel(_ value: Double) -> Double { min(1, max(0, value + delta)) }
            return Color(red: channel(r), green: channel(g), blue: channel(b))
        }
    }

    static func palette(from data: Data) -> ArtworkPalette? {
        guard let swatches = swatches(from: data), !swatches.isEmpty else { return nil }

        // Dominant colour by pixel count, ignoring near-black and near-white, which
        // are usually background or type rather than the cover's identity.
        let bodied = swatches.filter { $0.luminance > 0.06 && $0.luminance < 0.95 }
        let pool = bodied.isEmpty ? swatches : bodied
        guard let dominant = pool.max(by: { $0.count < $1.count }) else { return nil }

        // The accent wants character, so weight saturation heavily against frequency.
        let accent = pool.max {
            score($0, dominant: dominant) < score($1, dominant: dominant)
        } ?? dominant

        // Every cover is washed to the same depth rather than scaled from wherever it
        // started: a dark cover no longer produces a near-black screen, and a bright
        // one doesn't glare. Held just dark enough that light text clears 4.5:1.
        let base = dominant.washed(luminance: Wash.base, saturation: 0.55)
        let secondary = (pool.count > 1 ? pool.sorted { $0.count > $1.count }[1] : dominant)
            .washed(luminance: Wash.secondary, saturation: 0.6)

        // Lift a dim accent so controls stay visible against that wash.
        let accentColor = accent.luminance < 0.35
            ? accent.adjusted(brightness: 1.9, saturation: 1.25)
            : accent.adjusted(brightness: 1.05, saturation: 1.15)

        return ArtworkPalette(base: base,
                              secondary: secondary,
                              accent: accentColor,
                              prefersLightText: Wash.base < 0.5)
    }

    private static func score(_ swatch: Swatch, dominant: Swatch) -> Double {
        let frequency = Double(swatch.count) / Double(max(1, dominant.count))
        // Mid-luminance reads best as an accent; penalise the extremes.
        let brightnessFit = 1 - abs(swatch.luminance - 0.55) * 1.4
        return swatch.saturation * 2.2 + max(0, brightnessFit) * 0.8 + frequency * 0.5
    }

    /// Reduces the artwork to a coarse colour histogram.
    private static func swatches(from data: Data) -> [Swatch]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 64,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }

        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 5 bits per channel: enough to separate a cover's real colours without
        // splitting a single gradient across dozens of buckets.
        var buckets: [Int: (r: Int, g: Int, b: Int, n: Int)] = [:]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[index + 3])
            guard alpha > 128 else { continue }
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            let key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
            var entry = buckets[key] ?? (0, 0, 0, 0)
            entry = (entry.r + r, entry.g + g, entry.b + b, entry.n + 1)
            buckets[key] = entry
        }

        return buckets.values.map { entry in
            Swatch(red: Double(entry.r) / Double(entry.n) / 255,
                   green: Double(entry.g) / Double(entry.n) / 255,
                   blue: Double(entry.b) / Double(entry.n) / 255,
                   count: entry.n)
        }
    }
}
