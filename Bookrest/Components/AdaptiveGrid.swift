import SwiftUI

/// A cover grid that keeps tiles a comfortable size on every device instead of
/// stretching a fixed column count across a 13" iPad.
struct CoverGrid<Content: View>: View {
    var minimumTileWidth: CGFloat = 150
    var spacing: CGFloat = 16
    @ViewBuilder var content: Content

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: minimumTileWidth, maximum: 260), spacing: spacing, alignment: .top)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: spacing * 1.25) {
            content
        }
    }
}

/// Standard empty state so every screen fails the same way.
struct EmptyStateView: View {
    let title: String
    let message: String
    var systemImage: String = "books.vertical"
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Inline error with a retry affordance, used wherever a load can fail.
struct InlineErrorView: View {
    let message: String
    var retry: (() async -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let retry {
                Button("Try Again") { Task { await retry() } }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: 320)
        .padding()
    }
}
