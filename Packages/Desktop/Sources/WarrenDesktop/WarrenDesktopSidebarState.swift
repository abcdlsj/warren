import CoreGraphics
import WarrenDesignSystem

/// Device-local Sidebar geometry. An outer app can persist this value without
/// making it part of Host state.
public struct WarrenDesktopSidebarState: Equatable, Sendable {
    public private(set) var width: CGFloat
    public private(set) var isCollapsed: Bool

    public init(
        width: CGFloat = WarrenLayoutMetrics.sidebarExpandedWidth,
        isCollapsed: Bool = false
    ) {
        let normalized = WarrenLayoutMetrics.sidebarWidth(for: width)
        if isCollapsed || normalized == WarrenLayoutMetrics.sidebarCollapsedWidth {
            self.width = WarrenLayoutMetrics.sidebarCollapsedWidth
            self.isCollapsed = true
        } else {
            self.width = normalized
            self.isCollapsed = false
        }
    }

    public var renderedWidth: CGFloat {
        isCollapsed ? WarrenLayoutMetrics.sidebarCollapsedWidth : width
    }

    public mutating func setWidth(_ proposedWidth: CGFloat) {
        let normalized = WarrenLayoutMetrics.sidebarWidth(for: proposedWidth)
        width = normalized
        isCollapsed = normalized == WarrenLayoutMetrics.sidebarCollapsedWidth
    }

    public mutating func toggleCollapsed() {
        if isCollapsed {
            restoreExpanded()
        } else {
            width = WarrenLayoutMetrics.sidebarCollapsedWidth
            isCollapsed = true
        }
    }

    public mutating func restoreExpanded() {
        width = WarrenLayoutMetrics.sidebarExpandedWidth
        isCollapsed = false
    }
}
