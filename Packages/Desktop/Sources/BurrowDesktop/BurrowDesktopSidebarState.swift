import CoreGraphics
import BurrowDesignSystem

/// Device-local Sidebar geometry. An outer app can persist this value without
/// making it part of Host state.
public struct BurrowDesktopSidebarState: Equatable, Sendable {
    public private(set) var width: CGFloat
    public private(set) var isCollapsed: Bool

    public init(
        width: CGFloat = BurrowLayoutMetrics.sidebarExpandedWidth,
        isCollapsed: Bool = false
    ) {
        let normalized = BurrowLayoutMetrics.sidebarWidth(for: width)
        if isCollapsed || normalized == BurrowLayoutMetrics.sidebarCollapsedWidth {
            self.width = BurrowLayoutMetrics.sidebarCollapsedWidth
            self.isCollapsed = true
        } else {
            self.width = normalized
            self.isCollapsed = false
        }
    }

    public var renderedWidth: CGFloat {
        isCollapsed ? BurrowLayoutMetrics.sidebarCollapsedWidth : width
    }

    public mutating func setWidth(_ proposedWidth: CGFloat) {
        let normalized = BurrowLayoutMetrics.sidebarWidth(for: proposedWidth)
        width = normalized
        isCollapsed = normalized == BurrowLayoutMetrics.sidebarCollapsedWidth
    }

    public mutating func toggleCollapsed() {
        if isCollapsed {
            restoreExpanded()
        } else {
            width = BurrowLayoutMetrics.sidebarCollapsedWidth
            isCollapsed = true
        }
    }

    public mutating func restoreExpanded() {
        width = BurrowLayoutMetrics.sidebarExpandedWidth
        isCollapsed = false
    }
}
