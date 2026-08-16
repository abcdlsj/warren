import AppKit
import Darwin
import Foundation

/// Process-level ownership for the foreground Warren application.
///
/// Bundle identifiers are not stable when launching a SwiftPM executable, so
/// AppKit's normal application lookup is used only to raise the existing
/// window. The non-blocking advisory lock is the source of truth.
final class WarrenSingleInstanceLock {
    private let descriptor: Int32

    convenience init?() {
        if let override = ProcessInfo.processInfo.environment["WARREN_INSTANCE_LOCK"],
           !override.isEmpty {
            self.init(fileURL: URL(fileURLWithPath: override).standardizedFileURL)
            return
        }
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("Warren", isDirectory: true)
        guard let directory else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            return nil
        }
        self.init(fileURL: directory.appendingPathComponent("application.lock"))
    }

    init?(fileURL: URL) {
        let descriptor = open(fileURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        self.descriptor = descriptor

        let processID = "\(ProcessInfo.processInfo.processIdentifier)\n"
        _ = ftruncate(descriptor, 0)
        _ = processID.withCString { pointer in
            Darwin.write(descriptor, pointer, strlen(pointer))
        }
        _ = fsync(descriptor)
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    static func activateExistingApplication() {
        let current = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier
        let executableName = Bundle.main.executableURL?.lastPathComponent
        let application = NSWorkspace.shared.runningApplications.first { candidate in
            guard candidate.processIdentifier != current else { return false }
            if let bundleID, candidate.bundleIdentifier == bundleID { return true }
            return candidate.executableURL?.lastPathComponent == executableName
        }
        guard let application else { return }
        // The existing instance restores its main window in
        // `applicationDidBecomeActive`/`applicationShouldHandleReopen`, so
        // activating it is enough even when it currently has no visible window.
        application.unhide()
        application.activate(options: [.activateAllWindows])
    }
}
