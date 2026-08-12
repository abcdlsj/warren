import SwiftUI

/// Applies a semantic foreground-derived wash without introducing a card layer.
public struct BurrowForegroundWashModifier: ViewModifier {
    private let kind: BurrowWashKind
    private let isActive: Bool

    @Environment(\.colorScheme) private var colorScheme

    public init(kind: BurrowWashKind, isActive: Bool = true) {
        self.kind = kind
        self.isActive = isActive
    }

    public func body(content: Content) -> some View {
        let tokens = BurrowColorTokens.resolved(for: colorScheme)
        content.background(isActive ? tokens.wash(kind) : .clear)
    }
}

public extension View {
    /// Applies a low-contrast hover, selected, or tertiary foreground wash.
    func denForegroundWash(_ kind: BurrowWashKind, isActive: Bool = true) -> some View {
        modifier(BurrowForegroundWashModifier(kind: kind, isActive: isActive))
    }

    /// Uses the shared semantic background and foreground values.
    func denSurface() -> some View {
        modifier(BurrowSurfaceModifier())
    }
}

private struct BurrowSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let tokens = BurrowColorTokens.resolved(for: colorScheme)
        content
            .background(tokens.background)
            .foregroundStyle(tokens.foreground)
    }
}
