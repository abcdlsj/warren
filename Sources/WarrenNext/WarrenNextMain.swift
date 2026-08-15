import AppKit
import SwiftUI
import WarrenDesktop
import WarrenDomain

/// AppKit bootstrap for the macOS app.
///
/// A SwiftUI `WindowGroup` always reserves a system titlebar strip even with
/// `.hiddenTitleBar`. Warren runs a real borderless `NSWindow` instead, so the
/// 40pt chrome and sidebar header form one continuous surface from pixel zero;
/// the traffic lights are drawn inside the sidebar header.
@main
enum WarrenNextMain {
    @MainActor
    static func main() {
        if ProcessInfo.processInfo.environment["WARREN_HEADLESS_ACCEPTANCE"] == "1" {
            runHeadlessAcceptance()
            return
        }
        guard let instanceLock = WarrenSingleInstanceLock() else {
            WarrenSingleInstanceLock.activateExistingApplication()
            return
        }
        let app = NSApplication.shared
        let delegate = WarrenNextAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(instanceLock) {
            app.run()
        }
    }

    @MainActor
    private static func runHeadlessAcceptance() {
        guard let instanceLock = WarrenSingleInstanceLock() else {
            Darwin.exit(73)
        }
        let model = WarrenNextApplicationModel.live()
        Task { @MainActor in
            var sessionID: TerminalSessionID?
            var errorDescription: String?
            await model.start()
            if let rawMilliseconds = ProcessInfo.processInfo.environment[
                "WARREN_HEADLESS_HOLD_MILLISECONDS"
            ], let milliseconds = Int(rawMilliseconds), milliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(milliseconds))
            }
            if let path = ProcessInfo.processInfo.environment["WARREN_HEADLESS_CREATE_SESSION_PATH"],
               !path.isEmpty {
                do {
                    sessionID = try await model.headlessCreateShell(
                        folder: URL(fileURLWithPath: path, isDirectory: true)
                    )
                } catch {
                    errorDescription = String(describing: error)
                }
            }
            await model.shutdown()
            let runtimeAlive = if let sessionID {
                await model.runtimeExists(sessionID: sessionID)
            } else {
                false
            }
            if let reportPath = ProcessInfo.processInfo.environment["WARREN_HEADLESS_REPORT"],
               !reportPath.isEmpty {
                let report = WarrenHeadlessAcceptanceReport(
                    processID: ProcessInfo.processInfo.processIdentifier,
                    sessionID: sessionID?.description,
                    runtimeAliveAfterShutdown: runtimeAlive,
                    error: errorDescription
                )
                if let data = try? JSONEncoder().encode(report) {
                    try? data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
                }
            }
            withExtendedLifetime(instanceLock) {}
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopRun()
    }
}

private struct WarrenHeadlessAcceptanceReport: Codable {
    let processID: Int32
    let sessionID: String?
    let runtimeAliveAfterShutdown: Bool
    let error: String?
}

@MainActor
private final class WarrenNextAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var daemonMenuBarProcess: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchDaemonMenuBar()
        let root = WarrenNextCompositionRoot()
            .preferredColorScheme(.dark)
            .ignoresSafeArea()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)

        window = WarrenWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1280, height: 800),
            styleMask: [.borderless, .resizable, .miniaturizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 640, height: 420)
        window.isMovableByWindowBackground = false
        window.backgroundColor = NSColor(
            srgbRed: 21 / 255,
            green: 17 / 255,
            blue: 16 / 255,
            alpha: 1
        )
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeKey()
        window.orderFrontRegardless()

        NSApp.mainMenu = Self.buildMainMenu(target: self)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func launchDaemonMenuBar() {
        guard daemonMenuBarProcess == nil else { return }
        let environment = ProcessInfo.processInfo.environment
        let executable: URL?
        if let configured = environment["WARREN_DAEMON_MENUBAR_PATH"], !configured.isEmpty {
            executable = URL(fileURLWithPath: configured)
        } else {
            let sibling = URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent().appendingPathComponent("WarrenDaemonMenuBar")
            let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/WarrenDaemonMenuBar")
            executable = FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling
                : (FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil)
        }
        guard let executable else { return }
        let process = Process()
        process.executableURL = executable
        var childEnvironment = environment
        if childEnvironment["WARREN_HEADLESS_PATH"] == nil {
            let sibling = executable.deletingLastPathComponent().appendingPathComponent("warren-headless")
            if FileManager.default.isExecutableFile(atPath: sibling.path) {
                childEnvironment["WARREN_HEADLESS_PATH"] = sibling.path
            }
        }
        if childEnvironment["WARREN_WEB_ROOT"] == nil {
            let bundledResources = executable.deletingLastPathComponent()
                .appendingPathComponent("../Resources").standardizedFileURL
            let developmentResources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Web/dist")
            let resources = FileManager.default.fileExists(atPath: bundledResources.path)
                ? bundledResources : developmentResources
            if FileManager.default.fileExists(atPath: resources.appendingPathComponent("index.html").path) {
                childEnvironment["WARREN_WEB_ROOT"] = resources.path
            }
        }
        process.environment = childEnvironment
        do {
            try process.run()
            daemonMenuBarProcess = process
        } catch {
            NSLog("Unable to launch WarrenDaemonMenuBar: %@", error.localizedDescription)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        window?.orderOut(nil)
        return .terminateNow
    }

    @objc private func postCommand(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else { return }
        NotificationCenter.default.post(name: Notification.Name(rawValue), object: nil)
    }

    @objc private func copyLocalWebURL(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: WebCommand.copyLocalURL, object: nil)
    }

    @objc private func startCloudflareWebAccess(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: WebCommand.startCloudflare, object: nil)
    }

    @objc private func stopCloudflareWebAccess(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: WebCommand.stopCloudflare, object: nil)
    }

    @objc private func startTailscaleWebAccess(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: WebCommand.startTailscale, object: nil)
    }

    @objc private func stopTailscaleWebAccess(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: WebCommand.stopTailscale, object: nil)
    }

    @objc private func copySecureWebURL(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: WebCommand.copySecureURL, object: nil)
    }

    private static func buildMainMenu(target: AnyObject) -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit Warren",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        let sessionMenuItem = NSMenuItem()
        mainMenu.addItem(sessionMenuItem)
        let sessionMenu = NSMenu(title: "Session")
        let newSessionItem = sessionMenu.addItem(
            withTitle: "New Session…",
            action: #selector(WarrenNextAppDelegate.postCommand(_:)),
            keyEquivalent: "t"
        )
        newSessionItem.target = target
        newSessionItem.representedObject = WarrenDesktopCommand.newSession.rawValue

        let nextTabItem = sessionMenu.addItem(
            withTitle: "Next Tab",
            action: #selector(WarrenNextAppDelegate.postCommand(_:)),
            keyEquivalent: "x"
        )
        nextTabItem.target = target
        nextTabItem.keyEquivalentModifierMask = [.command]
        nextTabItem.representedObject = WarrenDesktopCommand.nextTab.rawValue

        let previousTabItem = sessionMenu.addItem(
            withTitle: "Previous Tab",
            action: #selector(WarrenNextAppDelegate.postCommand(_:)),
            keyEquivalent: "x"
        )
        previousTabItem.target = target
        previousTabItem.keyEquivalentModifierMask = [.command, .shift]
        previousTabItem.representedObject = WarrenDesktopCommand.previousTab.rawValue

        let closeTabItem = sessionMenu.addItem(
            withTitle: "Close Tab",
            action: #selector(WarrenNextAppDelegate.postCommand(_:)),
            keyEquivalent: "w"
        )
        closeTabItem.target = target
        closeTabItem.representedObject = WarrenDesktopCommand.closeTab.rawValue

        sessionMenu.addItem(.separator())
        let paletteItem = sessionMenu.addItem(
            withTitle: "Command Palette…",
            action: #selector(WarrenNextAppDelegate.postCommand(_:)),
            keyEquivalent: "k"
        )
        paletteItem.target = target
        paletteItem.representedObject = WarrenDesktopCommand.commandPalette.rawValue

        sessionMenu.addItem(.separator())
        let sidebarItem = sessionMenu.addItem(
            withTitle: "Toggle Sidebar",
            action: #selector(WarrenNextAppDelegate.postCommand(_:)),
            keyEquivalent: "b"
        )
        sidebarItem.target = target
        sidebarItem.representedObject = WarrenDesktopCommand.toggleSidebar.rawValue
        sessionMenuItem.submenu = sessionMenu

        let webMenuItem = NSMenuItem()
        mainMenu.addItem(webMenuItem)
        let webMenu = NSMenu(title: "Web")
        let copyWebURL = webMenu.addItem(
            withTitle: "Copy Local Web URL",
            action: #selector(WarrenNextAppDelegate.copyLocalWebURL(_:)),
            keyEquivalent: ""
        )
        copyWebURL.target = target
        webMenu.addItem(.separator())
        let startCloudflare = webMenu.addItem(
            withTitle: "Start Cloudflare Tunnel",
            action: #selector(WarrenNextAppDelegate.startCloudflareWebAccess(_:)),
            keyEquivalent: ""
        )
        startCloudflare.target = target
        let stopCloudflare = webMenu.addItem(
            withTitle: "Stop Cloudflare Tunnel",
            action: #selector(WarrenNextAppDelegate.stopCloudflareWebAccess(_:)),
            keyEquivalent: ""
        )
        stopCloudflare.target = target
        let startTailscale = webMenu.addItem(
            withTitle: "Start Tailscale Serve",
            action: #selector(WarrenNextAppDelegate.startTailscaleWebAccess(_:)),
            keyEquivalent: ""
        )
        startTailscale.target = target
        let stopTailscale = webMenu.addItem(
            withTitle: "Stop Tailscale Serve",
            action: #selector(WarrenNextAppDelegate.stopTailscaleWebAccess(_:)),
            keyEquivalent: ""
        )
        stopTailscale.target = target
        webMenu.addItem(.separator())
        let copySecureURL = webMenu.addItem(
            withTitle: "Copy Secure Web URL",
            action: #selector(WarrenNextAppDelegate.copySecureWebURL(_:)),
            keyEquivalent: ""
        )
        copySecureURL.target = target
        webMenuItem.submenu = webMenu
        return mainMenu
    }
}

private final class WarrenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
