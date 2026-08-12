import AppKit
import SwiftUI
import BurrowDesktop
import BurrowDomain

/// AppKit bootstrap for the macOS app.
///
/// A SwiftUI `WindowGroup` always reserves a system titlebar strip even with
/// `.hiddenTitleBar`. Burrow runs a real borderless `NSWindow` instead, so the
/// 40pt chrome and sidebar header form one continuous surface from pixel zero;
/// the traffic lights are drawn inside the sidebar header.
@main
enum BurrowNextMain {
    @MainActor
    static func main() {
        if ProcessInfo.processInfo.environment["BURROW_HEADLESS_ACCEPTANCE"] == "1" {
            runHeadlessAcceptance()
            return
        }
        guard let instanceLock = BurrowSingleInstanceLock() else {
            BurrowSingleInstanceLock.activateExistingApplication()
            return
        }
        let app = NSApplication.shared
        let delegate = BurrowNextAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(instanceLock) {
            app.run()
        }
    }

    @MainActor
    private static func runHeadlessAcceptance() {
        guard let instanceLock = BurrowSingleInstanceLock() else {
            Darwin.exit(73)
        }
        let model = BurrowNextApplicationModel.live()
        Task { @MainActor in
            var sessionID: TerminalSessionID?
            var errorDescription: String?
            await model.start()
            if let rawMilliseconds = ProcessInfo.processInfo.environment[
                "BURROW_HEADLESS_HOLD_MILLISECONDS"
            ], let milliseconds = Int(rawMilliseconds), milliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(milliseconds))
            }
            if let path = ProcessInfo.processInfo.environment["BURROW_HEADLESS_CREATE_SESSION_PATH"],
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
            if let reportPath = ProcessInfo.processInfo.environment["BURROW_HEADLESS_REPORT"],
               !reportPath.isEmpty {
                let report = BurrowHeadlessAcceptanceReport(
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

private struct BurrowHeadlessAcceptanceReport: Codable {
    let processID: Int32
    let sessionID: String?
    let runtimeAliveAfterShutdown: Bool
    let error: String?
}

@MainActor
private final class BurrowNextAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let model = BurrowNextApplicationModel.live()
    private var isTerminating = false
    private var shutdownTask: Task<Void, Never>?
    private var terminationTimeoutTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = BurrowNextCompositionRoot(model: model)
            .preferredColorScheme(.dark)
            .ignoresSafeArea()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)

        window = BurrowWindow(
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
        Task { await model.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateNow }
        isTerminating = true
        window?.orderOut(nil)
        model.beginShutdown()

        shutdownTask = Task { @MainActor [weak self, weak sender] in
            guard let self else { return }
            await model.shutdown()
            guard !Task.isCancelled, let sender else { return }
            finishTermination(sender)
        }
        terminationTimeoutTask = Task { @MainActor [weak self, weak sender] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let self, let sender else { return }
            finishTermination(sender)
        }
        return .terminateLater
    }

    private func finishTermination(_ sender: NSApplication) {
        shutdownTask?.cancel()
        terminationTimeoutTask?.cancel()
        shutdownTask = nil
        terminationTimeoutTask = nil
        sender.reply(toApplicationShouldTerminate: true)
    }

    @objc private func postCommand(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else { return }
        NotificationCenter.default.post(name: Notification.Name(rawValue), object: nil)
    }

    @objc private func copyLocalWebURL(_ sender: NSMenuItem) {
        model.copyLocalWebURL()
    }

    @objc private func startCloudflareWebAccess(_ sender: NSMenuItem) {
        model.startCloudflareWebAccess()
    }

    @objc private func stopCloudflareWebAccess(_ sender: NSMenuItem) {
        model.stopCloudflareWebAccess()
    }

    @objc private func startTailscaleWebAccess(_ sender: NSMenuItem) {
        model.startTailscaleWebAccess()
    }

    @objc private func stopTailscaleWebAccess(_ sender: NSMenuItem) {
        model.stopTailscaleWebAccess()
    }

    @objc private func copySecureWebURL(_ sender: NSMenuItem) {
        model.copySecureWebURL()
    }

    private static func buildMainMenu(target: AnyObject) -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit Burrow",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        let sessionMenuItem = NSMenuItem()
        mainMenu.addItem(sessionMenuItem)
        let sessionMenu = NSMenu(title: "Session")
        sessionMenu.addItem(
            withTitle: "New Session…",
            action: #selector(BurrowNextAppDelegate.postCommand(_:)),
            keyEquivalent: "t"
        ).target = target
        sessionMenu.addItem(
            withTitle: "Command Palette…",
            action: #selector(BurrowNextAppDelegate.postCommand(_:)),
            keyEquivalent: "k"
        ).target = target
        sessionMenu.addItem(.separator())
        sessionMenu.addItem(
            withTitle: "Toggle Sidebar",
            action: #selector(BurrowNextAppDelegate.postCommand(_:)),
            keyEquivalent: "b"
        ).target = target

        let newSessionItem = sessionMenu.item(at: 0)
        newSessionItem?.representedObject = BurrowDesktopCommand.newSession.rawValue
        let paletteItem = sessionMenu.item(at: 1)
        paletteItem?.representedObject = BurrowDesktopCommand.commandPalette.rawValue
        let sidebarItem = sessionMenu.item(at: 3)
        sidebarItem?.representedObject = BurrowDesktopCommand.toggleSidebar.rawValue

        sessionMenuItem.submenu = sessionMenu

        let webMenuItem = NSMenuItem()
        mainMenu.addItem(webMenuItem)
        let webMenu = NSMenu(title: "Web")
        let copyWebURL = webMenu.addItem(
            withTitle: "Copy Local Web URL",
            action: #selector(BurrowNextAppDelegate.copyLocalWebURL(_:)),
            keyEquivalent: ""
        )
        copyWebURL.target = target
        webMenu.addItem(.separator())
        let startCloudflare = webMenu.addItem(
            withTitle: "Start Cloudflare Tunnel",
            action: #selector(BurrowNextAppDelegate.startCloudflareWebAccess(_:)),
            keyEquivalent: ""
        )
        startCloudflare.target = target
        let stopCloudflare = webMenu.addItem(
            withTitle: "Stop Cloudflare Tunnel",
            action: #selector(BurrowNextAppDelegate.stopCloudflareWebAccess(_:)),
            keyEquivalent: ""
        )
        stopCloudflare.target = target
        let startTailscale = webMenu.addItem(
            withTitle: "Start Tailscale Serve",
            action: #selector(BurrowNextAppDelegate.startTailscaleWebAccess(_:)),
            keyEquivalent: ""
        )
        startTailscale.target = target
        let stopTailscale = webMenu.addItem(
            withTitle: "Stop Tailscale Serve",
            action: #selector(BurrowNextAppDelegate.stopTailscaleWebAccess(_:)),
            keyEquivalent: ""
        )
        stopTailscale.target = target
        webMenu.addItem(.separator())
        let copySecureURL = webMenu.addItem(
            withTitle: "Copy Secure Web URL",
            action: #selector(BurrowNextAppDelegate.copySecureWebURL(_:)),
            keyEquivalent: ""
        )
        copySecureURL.target = target
        webMenuItem.submenu = webMenu
        return mainMenu
    }
}

private final class BurrowWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
