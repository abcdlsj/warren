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

    private let healthURL = URL(string: "http://127.0.0.1:8789/healthz")!
    private let stateURL = URL(string: "http://127.0.0.1:8789/v1/state")!
    private var statusItem: NSStatusItem!
    private var daemonProcess: Process?
    private var pollTask: Task<Void, Never>?
    private var autoStartDisabled = false
    private var state: DaemonState = .checking {
        didSet { updateStatusItem() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = warrenBrandImage() {
            image.size = NSSize(width: 18, height: 18)
            statusItem.button?.image = image
            statusItem.button?.imageScaling = .scaleProportionallyDown
            statusItem.button?.imagePosition = .imageOnly
        } else {
            statusItem.button?.title = "W"
        }
        statusItem.button?.toolTip = "Warren headless daemon"
        statusItem.menu = makeMenu()
        updateStatusItem()
        ensureDaemon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTask?.cancel()
    }

    @objc private func restartDaemon() {
        autoStartDisabled = false
        stopDaemon()
        ensureDaemon()
    }

    @objc private func stopDaemonAction() {
        autoStartDisabled = true
        stopDaemon()
    }

    @objc private func quitMenuBar() {
        NSApp.terminate(nil)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let status = NSMenuItem(title: "Headless: Checking…", action: nil, keyEquivalent: "")
        status.tag = 1
        status.isEnabled = false
        menu.addItem(status)
        let endpoint = NSMenuItem(title: "Endpoint: 127.0.0.1:8789", action: nil, keyEquivalent: "")
        endpoint.tag = 2
        endpoint.isEnabled = false
        menu.addItem(endpoint)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Restart Headless", action: #selector(restartDaemon), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Stop Headless", action: #selector(stopDaemonAction), keyEquivalent: "s"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Warren Menu Bar", action: #selector(quitMenuBar), keyEquivalent: "q"))
        return menu
    }

    private func ensureDaemon() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await reconcileDaemon()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func reconcileDaemon() async {
        if autoStartDisabled {
            state = .stopped
            return
        }
        if await isDaemonHealthy() {
            state = .running
            return
        }

        // A daemon can remain alive while its token file is temporarily
        // unavailable (for example, when ~/.warren was removed). Check the
        // unauthenticated health endpoint before starting another process so
        // the existing daemon has time to restore its token.
        if await isDaemonReachable() {
            state = .checking
            await waitUntilHealthy()
            return
        }

        if let process = daemonProcess, process.isRunning {
            state = .checking
            await waitUntilHealthy()
            return
        }
        daemonProcess = nil
        startDaemonProcess()
        await waitUntilHealthy()
    }

    private func waitUntilHealthy() async {
        for _ in 0..<30 where !Task.isCancelled {
            if await isDaemonHealthy() {
                state = .running
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        state = .failed("Headless did not become ready")
    }

    private func startDaemonProcess() {
        guard daemonProcess == nil else { return }
        let process = Process()
        process.executableURL = daemonExecutableURL()
        process.arguments = []
        var childEnvironment = ProcessInfo.processInfo.environment
        childEnvironment["PATH"] = executableSearchPath(from: childEnvironment["PATH"])
        process.environment = childEnvironment
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
        let environment = ProcessInfo.processInfo.environment
        let tokenURL: URL
        if let configured = environment["WARREN_TOKEN_FILE"], !configured.isEmpty {
            tokenURL = URL(fileURLWithPath: configured)
        } else {
            tokenURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".warren/token")
        }
        guard let token = try? String(contentsOf: tokenURL, encoding: .utf8),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        var request = URLRequest(url: stateURL)
        request.timeoutInterval = 1
        request.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func isDaemonReachable() async -> Bool {
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 0.4
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

    private func executableSearchPath(from value: String?) -> String {
        var entries = (value ?? "").split(separator: ":").map(String.init)
        for path in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] where !entries.contains(path) {
            entries.append(path)
        }
        return entries.joined(separator: ":")
    }

    private func warrenBrandImage() -> NSImage? {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [URL] = []
        if let configured = environment["WARREN_BRAND_ICON_PATH"], !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: configured))
        }
        if let bundled = Bundle.main.url(forResource: "Warren", withExtension: "icns") {
            candidates.append(bundled)
        }
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        candidates.append(executableDirectory.appendingPathComponent("../Resources/Warren.icns").standardizedFileURL)
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Assets/Brand/Warren.icns"))
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            if let image = NSImage(contentsOf: candidate) { return image }
        }
        return nil
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
        if button.image != nil { button.title = "" }
        button.toolTip = switch state {
        case .checking: "Warren headless: Checking"
        case .running: "Warren headless: Running"
        case .stopped: "Warren headless: Stopped"
        case .failed: "Warren headless: Failed"
        }
        if let status = statusItem.menu?.item(withTag: 1) {
            switch state {
            case .checking: status.title = "Headless: Checking…"
            case .running: status.title = "Headless: Running"
            case .stopped: status.title = "Headless: Stopped"
            case .failed(let reason): status.title = "Headless: \(reason)"
            }
        }
        if let endpoint = statusItem.menu?.item(withTag: 2) {
            endpoint.title = switch state {
            case .running: "Endpoint: 127.0.0.1:8789 · Web: 8789"
            case .checking: "Endpoint: 127.0.0.1:8789 · Checking…"
            case .stopped: "Endpoint: 127.0.0.1:8789 · Offline"
            case .failed: "Endpoint: 127.0.0.1:8789 · Unavailable"
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
