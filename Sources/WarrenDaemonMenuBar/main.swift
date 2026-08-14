import AppKit
import Foundation
import Darwin

@main
enum WarrenDaemonMenuBarMain {
    @MainActor
    static func main() {
        guard WarrenDaemonMenuBarLock.acquire() else { return }
        let application = NSApplication.shared
        let delegate = WarrenDaemonMenuBarDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
private final class WarrenDaemonMenuBarDelegate: NSObject, NSApplicationDelegate {
    private enum DaemonState {
        case checking
        case running
        case stopped
        case failed(String)
    }

    private let listenURL = URL(string: "http://127.0.0.1:8789/healthz")!
    private var statusItem: NSStatusItem!
    private var daemonProcess: Process?
    private var pollTask: Task<Void, Never>?
    private var state: DaemonState = .checking {
        didSet { updateStatusItem() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Warren daemon")
        statusItem.menu = makeMenu()
        updateStatusItem()
        ensureDaemon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTask?.cancel()
    }

    @objc private func restartDaemon() {
        stopDaemon()
        ensureDaemon()
    }

    @objc private func stopDaemonAction() {
        stopDaemon()
    }

    @objc private func quitMenuBar() {
        NSApp.terminate(nil)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let status = NSMenuItem(title: "Daemon: Checking…", action: nil, keyEquivalent: "")
        status.tag = 1
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Restart Daemon", action: #selector(restartDaemon), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Stop Daemon", action: #selector(stopDaemonAction), keyEquivalent: "s"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Warren Daemon Menu Bar", action: #selector(quitMenuBar), keyEquivalent: "q"))
        return menu
    }

    private func ensureDaemon() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if await isDaemonHealthy() {
                state = .running
            } else {
                startDaemonProcess()
                await waitUntilHealthy()
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                state = await isDaemonHealthy() ? .running : .stopped
            }
        }
    }

    private func waitUntilHealthy() async {
        for _ in 0..<30 where !Task.isCancelled {
            if await isDaemonHealthy() {
                state = .running
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        state = .failed("Daemon did not become ready")
    }

    private func startDaemonProcess() {
        guard daemonProcess == nil else { return }
        let process = Process()
        process.executableURL = daemonExecutableURL()
        process.arguments = []
        process.environment = ProcessInfo.processInfo.environment
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.daemonProcess = nil
                if case .running = self?.state { self?.state = .stopped }
            }
        }
        do {
            try process.run()
            daemonProcess = process
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func stopDaemon() {
        daemonProcess?.terminate()
        daemonProcess = nil
        state = .stopped
    }

    private func isDaemonHealthy() async -> Bool {
        var request = URLRequest(url: listenURL)
        request.timeoutInterval = 1
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func daemonExecutableURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["WARREN_HEADLESS_PATH"], !configured.isEmpty {
            return URL(fileURLWithPath: configured)
        }
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let sibling = executableDirectory.appendingPathComponent("warren-headless")
        if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        let bundleBinary = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/warren-headless")
        return bundleBinary
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        switch state {
        case .checking:
            button.title = " Warren …"
        case .running:
            button.title = " Warren ●"
        case .stopped:
            button.title = " Warren ○"
        case .failed:
            button.title = " Warren !"
        }
        if let status = statusItem.menu?.item(withTag: 1) {
            switch state {
            case .checking: status.title = "Daemon: Checking…"
            case .running: status.title = "Daemon: Running"
            case .stopped: status.title = "Daemon: Stopped"
            case .failed(let reason): status.title = "Daemon: \(reason)"
            }
        }
    }
}

@MainActor
private enum WarrenDaemonMenuBarLock {
    private static var descriptor: Int32 = -1

    static func acquire() -> Bool {
        let path = "/tmp/warren-daemon-menubar.lock"
        descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            descriptor = -1
            return false
        }
        return true
    }
}
