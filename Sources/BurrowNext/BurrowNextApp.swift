import SwiftUI
import AppKit
import BurrowDesktop

struct BurrowNextApp: App {
    @NSApplicationDelegateAdaptor(BurrowNextAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Burrow", id: "main") {
            BurrowNextCompositionRoot()
                .background(BurrowNextWindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        // Superset defaults to the primary display work area. The AppKit
        // configurator applies that dynamic value; this is SwiftUI's fallback
        // before a window has a screen, and is never a persisted app state.
        .defaultSize(
            width: BurrowNextWindowConfiguration.fallbackDefaultSize.width,
            height: BurrowNextWindowConfiguration.fallbackDefaultSize.height
        )
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Session") {
                Button("New Session…") {
                    post(BurrowDesktopCommand.newSession)
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Command Palette…") {
                    post(BurrowDesktopCommand.commandPalette)
                }
                .keyboardShortcut("k", modifiers: .command)

                Divider()

                Button("Toggle Sidebar") {
                    post(BurrowDesktopCommand.toggleSidebar)
                }
                .keyboardShortcut("b", modifiers: .command)

            }
            CommandMenu("Web") {
                Button("Copy Local Web URL") {
                    post(WebRelayCommand.copyLocalURL)
                }
                Divider()
                Button("Start Cloudflare Tunnel") { post(WebRelayCommand.startCloudflare) }
                Button("Stop Cloudflare Tunnel") { post(WebRelayCommand.stopCloudflare) }
                Button("Start Tailscale Serve") { post(WebRelayCommand.startTailscale) }
                Button("Stop Tailscale Serve") { post(WebRelayCommand.stopTailscale) }
                Divider()
                Button("Copy Secure Web URL") { post(WebRelayCommand.copySecureURL) }
            }
        }
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
}

enum WebRelayCommand {
    static let copyLocalURL = Notification.Name("WebRelay.copyLocalURL")
    static let startCloudflare = Notification.Name("WebRelay.startCloudflare")
    static let stopCloudflare = Notification.Name("WebRelay.stopCloudflare")
    static let startTailscale = Notification.Name("WebRelay.startTailscaleServe")
    static let stopTailscale = Notification.Name("WebRelay.stopTailscaleServe")
    static let copySecureURL = Notification.Name("WebRelay.copySecureURL")
}

@MainActor
private final class BurrowNextAppDelegate: NSObject, NSApplicationDelegate {
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
