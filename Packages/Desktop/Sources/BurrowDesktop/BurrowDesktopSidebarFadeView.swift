import SwiftUI
import BurrowDesignSystem

/// The web implementation uses `OverflowFadeContainer` with a 1.5rem fade at
/// both edges. SwiftUI keeps the same restrained cue without exposing a second
/// scroll surface or stealing pointer events from rows.
struct BurrowDesktopSidebarFade: View {
    enum Edge {
        case top
        case bottom
    }

    let edge: Edge

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = BurrowColorTokens.resolved(for: colorScheme)
        LinearGradient(
            colors: [tokens.sidebarSurface, tokens.sidebarSurface.opacity(0)],
            startPoint: edge == .top ? .top : .bottom,
            endPoint: edge == .top ? .bottom : .top
        )
        .frame(height: BurrowLayoutMetrics.sidebarScrollFadeLength)
        .allowsHitTesting(false)
    }
}
