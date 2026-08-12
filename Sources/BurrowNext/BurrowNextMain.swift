import AppKit
import SwiftUI
import BurrowDesktop
import WebRelay

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

    @objc private func openWebAccess() {
        guard let url = WebRelayServer.webPageURLWithToken else { return }
        NSWorkspace.shared.open(url)
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
        sessionMenu.addItem(
            withTitle: "Open Web Access…",
            action: #selector(BurrowNextAppDelegate.openWebAccess),
            keyEquivalent: ""
        ).target = target
        sessionMenu.addItem(
            withTitle: "Start Web Tunnel (cloudflared)",
            action: #selector(BurrowNextAppDelegate.postCommand(_:)),
            keyEquivalent: ""
        ).target = target
        sessionMenu.addItem(
            withTitle: "Stop Web Tunnel",
            action: #selector(BurrowNextAppDelegate.postCommand(_:)),
            keyEquivalent: ""
        ).target = target
        sessionMenu.addItem(
            withTitle: "Copy Web URL",
            action: #selector(BurrowNextAppDelegate.postCommand(_:)),
            keyEquivalent: ""
        ).target = target
        sessionMenu.addItem(
            withTitle: "Start Tailscale Tunnel",
            action: #selector(BurrowNextAppDelegate.postCommand(_:)),
            keyEquivalent: ""
        ).target = target
        sessionMenu.addItem(
            withTitle: "Stop Tailscale Tunnel",
            action: #selector(BurrowNextAppDelegate.postCommand(_:)),
            keyEquivalent: ""
        ).target = target
        sessionMenu.addItem(
            withTitle: "Start Tailscale Funnel",
            action: #selector(BurrowNextAppDelegate.postCommand(_:)),
            keyEquivalent: ""
        ).target = target
        sessionMenu.addItem(
            withTitle: "Stop Tailscale Funnel",
            action: #selector(BurrowNextAppDelegate.postCommand(_:)),
            keyEquivalent: ""
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
        sessionMenu.item(at: 3)?.representedObject = WebRelayServer.startTunnel.rawValue
        sessionMenu.item(at: 4)?.representedObject = WebRelayServer.stopTunnel.rawValue
        sessionMenu.item(at: 5)?.representedObject = WebRelayServer.copyWebURL.rawValue
        sessionMenu.item(at: 6)?.representedObject = WebRelayServer.startTailscale.rawValue
        sessionMenu.item(at: 7)?.representedObject = WebRelayServer.stopTailscale.rawValue
        sessionMenu.item(at: 8)?.representedObject = WebRelayServer.startFunnel.rawValue
        sessionMenu.item(at: 9)?.representedObject = WebRelayServer.stopFunnel.rawValue
        let sidebarItem = sessionMenu.item(at: 11)
        sidebarItem?.representedObject = BurrowDesktopCommand.toggleSidebar.rawValue

        sessionMenuItem.submenu = sessionMenu
        return mainMenu
    }
}

private final class BurrowWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
