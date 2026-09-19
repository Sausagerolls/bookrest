import Foundation
import ImageIO
import CoreGraphics

/// Test-side view of the palette maths.
///
/// `PaletteExtractor` lives in the app target, which a unit-test bundle can't import,
/// so this reproduces the same histogram and reports the two properties worth
/// asserting: whether the accent kept any colour, and where the background wash
/// landed — it has to stay dark enough for light text without collapsing to black.
enum PaletteProbe {
    struct Description {
        let base: String
        let accent: String
        let accentSaturation: Double
        let baseLuminance: Double
    }

    static func describe(_ data: Data) -> Description? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 64,
              ] as CFDictionary)
        else { return nil }

        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var buckets: [Int: (r: Int, g: Int, b: Int, n: Int)] = [:]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            guard pixels[index + 3] > 128 else { continue }
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            let key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
            var entry = buckets[key] ?? (0, 0, 0, 0)
            entry = (entry.r + r, entry.g + g, entry.b + b, entry.n + 1)
            buckets[key] = entry
        }

        struct Swatch { let r: Double, g: Double, b: Double; let n: Int
            var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
            var saturation: Double {
                let mx = max(r, g, b), mn = min(r, g, b)
                return mx > 0 ? (mx - mn) / mx : 0
            }
        }
        let swatches = buckets.values.map {
            Swatch(r: Double($0.r) / Double($0.n) / 255,
                   g: Double($0.g) / Double($0.n) / 255,
                   b: Double($0.b) / Double($0.n) / 255, n: $0.n)
        }
        let bodied = swatches.filter { $0.luminance > 0.06 && $0.luminance < 0.95 }
        let pool = bodied.isEmpty ? swatches : bodied
        guard let dominant = pool.max(by: { $0.n < $1.n }) else { return nil }

        let accent = pool.max { lhs, rhs in
            func score(_ s: Swatch) -> Double {
                let frequency = Double(s.n) / Double(max(1, dominant.n))
                let fit = 1 - abs(s.luminance - 0.55) * 1.4
                return s.saturation * 2.2 + max(0, fit) * 0.8 + frequency * 0.5
            }
            return score(lhs) < score(rhs)
        } ?? dominant

        // Mirrors `Swatch.washed`: desaturate, then offset every channel by a
        // constant so the result lands at the target luminance.
        func washed(_ s: Swatch, luminance target: Double, saturation: Double) -> (Double, Double, Double) {
            let average = (s.r + s.g + s.b) / 3
            let r = average + (s.r - average) * saturation
            let g = average + (s.g - average) * saturation
            let b = average + (s.b - average) * saturation
            let delta = target - (0.2126 * r + 0.7152 * g + 0.0722 * b)
            func channel(_ value: Double) -> Double { min(1, max(0, value + delta)) }
            return (channel(r), channel(g), channel(b))
        }

        func hex(_ rgb: (Double, Double, Double)) -> String {
            String(format: "#%02X%02X%02X",
                   Int(rgb.0 * 255), Int(rgb.1 * 255), Int(rgb.2 * 255))
        }

        let base = washed(dominant, luminance: 0.20, saturation: 0.55)
        return Description(base: hex(base),
                           accent: hex((min(1, accent.r * (accent.luminance < 0.35 ? 1.9 : 1.05)),
                                        min(1, accent.g * (accent.luminance < 0.35 ? 1.9 : 1.05)),
                                        min(1, accent.b * (accent.luminance < 0.35 ? 1.9 : 1.05)))),
                           accentSaturation: accent.saturation,
                           baseLuminance: 0.2126 * base.0 + 0.7152 * base.1 + 0.0722 * base.2)
    }
}
