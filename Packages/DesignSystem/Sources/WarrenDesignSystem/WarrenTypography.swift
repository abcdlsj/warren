import SwiftUI

/// Typography tokens matching the confirmed Superset density hierarchy.
public enum WarrenTypography {
    /// Superset inherits the platform UI sans stack; regular weight carries
    /// most navigation and chrome, with weight reserved for active hierarchy.
    public static let sidebarRow = Font.system(size: 12, weight: .regular)
    public static let workspaceRow = Font.system(size: 12, weight: .medium)
    /// Section labels are intentionally compact and uppercase in their source.
    public static let sectionLabel = Font.system(size: 10, weight: .medium)
    /// Superset tab and pane titles use the compact text-xs tier.
    public static let tabTitle = Font.system(size: 12, weight: .regular)
    public static let activeTabTitle = Font.system(size: 12, weight: .medium)
    public static let paneHeader = Font.system(size: 12, weight: .medium)
    public static let badge = Font.system(size: 10, weight: .medium)
    public static let activityChip = Font.system(size: 9, weight: .medium)
    public static let emptyState = Font.system(size: 14, weight: .regular)
    public static let screenTitle = Font.system(size: 18, weight: .semibold)
    public static let dialogTitle = Font.system(size: 17, weight: .semibold)
    public static let body = Font.system(size: 13, weight: .regular)
    public static let bodyEmphasis = Font.system(size: 13, weight: .medium)
    public static let supporting = Font.system(size: 11, weight: .regular)
    public static let code = Font.system(size: 12, weight: .regular, design: .monospaced)
    public static let compactCode = Font.system(size: 11, weight: .semibold, design: .monospaced)
}
