import SwiftUI

/// Typography tokens matching the confirmed Superset density hierarchy.
public enum WarrenTypography {
    /// Superset inherits the platform UI sans stack; regular weight carries
    /// most navigation and chrome, with weight reserved for active hierarchy.
    public static let navigationGroup = Font.system(size: 13, weight: .medium)
    public static let navigationItem = Font.system(size: 13, weight: .regular)
    public static let navigationMeta = Font.system(size: 10, weight: .medium)
    public static let shortcut = Font.system(size: 10, weight: .medium, design: .monospaced)
    public static let chromeLabel = Font.system(size: 12, weight: .regular)
    /// Compatibility aliases for clients that have not migrated yet.
    public static let sidebarRow = navigationGroup
    public static let workspaceRow = navigationItem
    /// Section labels are intentionally compact and uppercase in their source.
    public static let sectionLabel = Font.system(size: 10, weight: .semibold)
    /// Superset tab and pane titles use the compact text-xs tier.
    public static let tabTitle = Font.system(size: 12, weight: .regular)
    public static let activeTabTitle = Font.system(size: 12, weight: .medium)
    public static let paneHeader = Font.system(size: 12, weight: .medium)
    public static let badge = Font.system(size: 10, weight: .medium)
    public static let activityChip = Font.system(size: 9, weight: .medium)
    public static let emptyState = Font.system(size: 18, weight: .semibold)
    public static let screenTitle = Font.system(size: 18, weight: .semibold)
    /// Superset settings page headings are `text-xl`.
    public static let pageTitle = Font.system(size: 20, weight: .semibold)
    public static let dialogTitle = Font.system(size: 17, weight: .semibold)
    public static let body = Font.system(size: 13, weight: .regular)
    public static let bodyEmphasis = Font.system(size: 13, weight: .medium)
    public static let supporting = Font.system(size: 11, weight: .regular)
    public static let code = Font.system(size: 12, weight: .regular, design: .monospaced)
    public static let compactCode = Font.system(size: 11, weight: .semibold, design: .monospaced)
}
