import Foundation
import GhosttyTerminal

/// Opt-in terminal presentation diagnostics for workspace/tab switch black
/// screen investigations.
///
/// Enabled by `WARREN_TERMINAL_DIAGNOSTICS=1` (or the `--terminal-diagnostics`
/// launch argument). Writes JSON lines plus the vendored GhosttyTerminal debug
/// log to `~/Library/Logs/Warren/terminal-diagnostics-<pid>.log` so a repro
/// can be correlated end to end: workspace selection, attach, presentNow,
/// view mount, and render ticks.
public enum TerminalDiagnostics {
    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var enabled = false
        var handle: FileHandle?
        var fileURL: URL?
    }

    private static let store = Store()

    public static var isEnabled: Bool {
        store.lock.lock()
        defer { store.lock.unlock() }
        return store.enabled
    }

    public static func configure(
        environment: [String: String],
        arguments: [String]
    ) {
        let requested = environment["WARREN_TERMINAL_DIAGNOSTICS"] == "1"
            || arguments.contains("--terminal-diagnostics")
        store.lock.lock()
        guard requested, !store.enabled else {
            store.lock.unlock()
            return
        }

        let defaultDirectory = NSHomeDirectory() + "/Library/Logs/Warren"
        let directory = URL(
            fileURLWithPath: environment["WARREN_TERMINAL_DIAGNOSTICS_DIR"]
                ?? defaultDirectory,
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory.appendingPathComponent(
            "terminal-diagnostics-\(ProcessInfo.processInfo.processIdentifier).log"
        )
        try? FileManager.default.removeItem(at: fileURL)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        store.fileURL = fileURL
        store.handle = try? FileHandle(forWritingTo: fileURL)
        store.enabled = true
        store.lock.unlock()

        TerminalDebugLog.enable(.all)
        TerminalDebugLog.sink = { message in
            Self.writeRaw(message)
        }
        log("diagnostics_start", [
            "pid": String(ProcessInfo.processInfo.processIdentifier),
            "file": fileURL.path,
        ])
    }

    public static func log(_ event: String, _ fields: [String: String] = [:]) {
        store.lock.lock()
        defer { store.lock.unlock() }
        guard store.enabled, let handle = store.handle else { return }

        var payload: [String: String] = [
            "time": String(format: "%.3f", Date().timeIntervalSince1970),
            "pid": String(ProcessInfo.processInfo.processIdentifier),
            "event": event,
        ]
        for (key, value) in fields {
            payload[key] = value
        }
        let line: String
        if let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ), let text = String(data: data, encoding: .utf8) {
            line = text
        } else {
            line = payload
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
        }
        append(line + "\n", to: handle)
    }

    private static func writeRaw(_ message: String) {
        store.lock.lock()
        defer { store.lock.unlock() }
        guard store.enabled, let handle = store.handle else { return }
        append(message + "\n", to: handle)
    }

    private static func append(_ line: String, to handle: FileHandle) {
        guard let data = line.data(using: .utf8) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
    }
}
