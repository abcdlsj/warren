import SwiftUI
import AppKit
import WarrenDesktop

struct WarrenNextApp: App {
    @NSApplicationDelegateAdaptor(WarrenNextAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Warren", id: "main") {
            WarrenNextCompositionRoot()
                .background(WarrenNextWindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        // Superset defaults to the primary display work area. The AppKit
        // configurator applies that dynamic value; this is SwiftUI's fallback
        // before a window has a screen, and is never a persisted app state.
        .defaultSize(
            width: WarrenNextWindowConfiguration.fallbackDefaultSize.width,
            height: WarrenNextWindowConfiguration.fallbackDefaultSize.height
        )
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Session") {
                Button("New Session…") {
                    post(WarrenDesktopCommand.newSession)
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Command Palette…") {
                    post(WarrenDesktopCommand.commandPalette)
                }
                .keyboardShortcut("k", modifiers: .command)

                Divider()

                Button("Toggle Sidebar") {
                    post(WarrenDesktopCommand.toggleSidebar)
                }
                .keyboardShortcut("b", modifiers: .command)

            }
            CommandMenu("Web") {
                Button("Copy Local Web URL") {
                    post(WebCommand.copyLocalURL)
                }
                Divider()
                Button("Start Cloudflare Tunnel") { post(WebCommand.startCloudflare) }
                Button("Stop Cloudflare Tunnel") { post(WebCommand.stopCloudflare) }
                Button("Start Tailscale Serve") { post(WebCommand.startTailscale) }
                Button("Stop Tailscale Serve") { post(WebCommand.stopTailscale) }
                Divider()
                Button("Copy Secure Web URL") { post(WebCommand.copySecureURL) }
            }
        }
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
}

enum WebCommand {
    static let copyLocalURL = Notification.Name("Web.copyLocalURL")
    static let startCloudflare = Notification.Name("Web.startCloudflare")
    static let stopCloudflare = Notification.Name("Web.stopCloudflare")
    static let startTailscale = Notification.Name("Web.startTailscaleServe")
    static let stopTailscale = Notification.Name("Web.stopTailscaleServe")
    static let copySecureURL = Notification.Name("Web.copySecureURL")
}

@MainActor
private final class WarrenNextAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // A SwiftPM executable has no application bundle, so AppKit cannot
        // infer that it should participate as a normal foreground app.
        _ = NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // macOS 14 deprecated ignoringOtherApps. This API keeps activation on
        // the supported system path instead of bypassing normal focus routing.
        NSApplication.shared.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }
}
