import CoreGraphics

/// Superset parity measurements and the small set of shared layout values used
/// by both clients. Keep these values in one place so semantic frame contracts
/// can change a token instead of chasing literals through view code.
public enum WarrenLayoutMetrics {
    // Superset workspace sidebar state.
    public static let sidebarExpandedWidth: CGFloat = 280
    public static let sidebarCollapsedWidth: CGFloat = 52
    public static let sidebarMinimumWidth: CGFloat = 220
    public static let sidebarMaximumWidth: CGFloat = 400
    public static let sidebarSnapThreshold: CGFloat = 120

    // Superset chrome and pane measurements.
    /// The desktop workspace chrome is a 48pt row above the session tabs.
    public static let workspaceBarHeight: CGFloat = 48
    public static let workspaceBarProjectWidth: CGFloat = 160
    public static let workspaceBarWorkspaceWidth: CGFloat = 240
    public static let topBarHeight: CGFloat = 48
    public static let tabBarHeight: CGFloat = 40
    /// Superset's pinned command preset row is `h-8`.
    public static let presetBarHeight: CGFloat = 32
    public static let tabWidth: CGFloat = 160
    /// Superset keeps the add-tab affordance in a fixed `w-10` slot.
    public static let tabAddButtonSlotWidth: CGFloat = 40
    /// The close control is a 20pt button inside a 28pt accessory column.
    public static let tabCloseButtonSize: CGFloat = 20
    public static let tabAccessoryColumnWidth: CGFloat = 28
    public static let paneHeaderHeight: CGFloat = 28
    public static let paneMinimumWidth: CGFloat = 260
    public static let paneMinimumHeight: CGFloat = 160
    /// Superset's v2 right workspace sidebar defaults to 340pt and can be
    /// resized independently by its host shell.
    public static let inspectorDefaultWidth: CGFloat = 340
    public static let inspectorMinimumWidth: CGFloat = 240
    public static let inspectorMaximumWidth: CGFloat = 640

    // Sidebar row geometry from DashboardSidebar's Tailwind classes.
    public static let sidebarProjectRowHeight: CGFloat = 28
    public static let sidebarWorkspaceRowHeight: CGFloat = 26
    public static let sidebarSectionLabelHeight: CGFloat = 28
    public static let sidebarRowIconSlotSize: CGFloat = 18
    public static let sidebarActionButtonSize: CGFloat = 24
    /// `OverflowFadeContainer` uses a 1.5rem edge fade in Superset.
    public static let sidebarScrollFadeLength: CGFloat = 24

    // Confirmed interaction hit areas from Superset's resizable panel.
    public static let sidebarResizeHitWidth: CGFloat = 20
    public static let sidebarDividerWidth: CGFloat = 4
    public static let splitHandleHitWidth: CGFloat = 4

    // Chrome alignment values from the macOS implementation.
    public static let macTrafficLightInset: CGFloat = 80
    public static let expandedSidebarChromeInset: CGFloat = 16
    /// Superset's macOS traffic-light/navigation row is `h-8`.
    public static let sidebarTrafficRowHeight: CGFloat = 32
    public static let sidebarHeaderRowHeight: CGFloat = 32
    public static let sidebarHeaderTopPadding: CGFloat = 8
    public static let sidebarHeaderBottomGap: CGFloat = 12

    /// Returns the width Superset's resize policy would display for a drag.
    /// Values below the snap threshold collapse the rail; other values are
    /// clamped to the expanded range.
    public static func sidebarWidth(for proposedWidth: CGFloat) -> CGFloat {
        guard proposedWidth.isFinite else { return sidebarExpandedWidth }
        guard proposedWidth >= sidebarSnapThreshold else {
            return sidebarCollapsedWidth
        }
        return min(max(proposedWidth, sidebarMinimumWidth), sidebarMaximumWidth)
    }
}

/// Shared spacing values. The named values describe intent; components should
/// prefer these tokens over scattering unrelated padding literals.
public enum WarrenSpacing {
    public static let hairline: CGFloat = 1
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let small: CGFloat = 6
    public static let compact: CGFloat = 8
    public static let medium: CGFloat = 12
    public static let standard: CGFloat = 16
    public static let large: CGFloat = 24
}

/// Shared corner-radius tokens. `base` is the confirmed Superset radius
/// fallback (`0.625rem`, i.e. 10px); the smaller values cover confirmed row
/// hit areas and compact controls.
public enum WarrenRadius {
    public static let row: CGFloat = 6
    public static let small: CGFloat = 6
    public static let medium: CGFloat = 8
    public static let base: CGFloat = 10
    public static let large: CGFloat = 12
}
