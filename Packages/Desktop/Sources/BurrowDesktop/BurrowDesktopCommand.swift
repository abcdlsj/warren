import Foundation

/// Cross-process (within the app) command names used by the AppKit menu. The
/// Desktop shell observes these so the host executable can own the menu while
/// the reusable UI package stays free of AppDelegate dependencies.
public enum BurrowDesktopCommand {
    public static let commandPalette = Notification.Name("BurrowDesktopCommand.commandPalette")
    public static let newSession = Notification.Name("BurrowDesktopCommand.newSession")
    public static let toggleSidebar = Notification.Name("BurrowDesktopCommand.toggleSidebar")
    public static let toggleInspector = Notification.Name("BurrowDesktopCommand.toggleInspector")
}
