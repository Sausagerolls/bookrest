import SwiftUI

/// Cover artwork with a stable placeholder.
///
/// Covers arrive at unpredictable aspect ratios, so everything is normalised to a
/// fixed shape — a grid where every tile is a different height reads as broken.
struct CoverImage: View {
    let url: URL?
    var localURL: URL?
    var aspectRatio: CGFloat = 1
    var cornerRadius: CGFloat = 10

    @State private var didFail = false

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                if let source = localURL ?? url {
                    AsyncImage(url: source, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            placeholder
                        case .empty:
                            ProgressView().controlSize(.small)
                        @unknown default:
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
            }
            .contentShape(.rect(cornerRadius: cornerRadius))
    }

    private var placeholder: some View {
        Image(systemName: "book.closed")
            .font(.system(size: 28, weight: .light))
            .foregroundStyle(.tertiary)
    }
}

/// Circular variant used for authors and narrators.
struct AvatarImage: View {
    let url: URL?
    let name: String
    var size: CGFloat = 72

    var body: some View {
        Circle()
            .fill(.quaternary)
            .frame(width: size, height: size)
            .overlay {
                if let url {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        initials
                    }
                } else {
                    initials
                }
            }
            .clipShape(.circle)
    }

    private var initials: some View {
        Text(Self.initials(from: name))
            .font(.system(size: size * 0.34, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
    }

    private static func initials(from name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}
