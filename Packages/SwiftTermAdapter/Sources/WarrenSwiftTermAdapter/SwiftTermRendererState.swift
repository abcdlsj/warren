import WarrenTerminalRenderer
import WarrenDomain

@MainActor
extension SwiftTermRenderer {
    public struct SurfaceState: Hashable, Sendable {
        public let surface: TerminalSurface
        public let viewport: TerminalViewport
        public let expectedAnchor: RecoveryAnchor
        public let needsReanchor: Bool
        public let focused: Bool

        init(
            surface: TerminalSurface,
            viewport: TerminalViewport,
            expectedAnchor: RecoveryAnchor,
            needsReanchor: Bool,
            focused: Bool
        ) {
            self.surface = surface
            self.viewport = viewport
            self.expectedAnchor = expectedAnchor
            self.needsReanchor = needsReanchor
            self.focused = focused
        }
    }
}
