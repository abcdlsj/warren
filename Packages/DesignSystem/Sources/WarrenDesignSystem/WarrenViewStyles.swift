import SwiftUI

/// Applies a semantic foreground-derived wash without introducing a card layer.
public struct WarrenForegroundWashModifier: ViewModifier {
    private let kind: WarrenWashKind
    private let isActive: Bool

    @Environment(\.colorScheme) private var colorScheme

    public init(kind: WarrenWashKind, isActive: Bool = true) {
        self.kind = kind
        self.isActive = isActive
    }

    public func body(content: Content) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        content.background(isActive ? tokens.wash(kind) : .clear)
    }
}

public extension View {
    /// Applies a low-contrast hover, selected, or tertiary foreground wash.
    func denForegroundWash(_ kind: WarrenWashKind, isActive: Bool = true) -> some View {
        modifier(WarrenForegroundWashModifier(kind: kind, isActive: isActive))
    }

    /// Uses the shared semantic background and foreground values.
    func denSurface() -> some View {
        modifier(WarrenSurfaceModifier())
    }
}

private struct WarrenSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        content
            .background(tokens.background)
            .foregroundStyle(tokens.foreground)
    }
}
