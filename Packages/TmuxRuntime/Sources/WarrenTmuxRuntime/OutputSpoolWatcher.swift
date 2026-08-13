import Foundation
import Darwin

/// Reads an append-only spool from its current byte offset whenever the file
/// changes.  Dispatch vnode notifications may be coalesced; every handler
/// drains to EOF, so coalescing cannot discard bytes and no truncation polling
/// is involved.
final class OutputSpoolWatcher: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let source: DispatchSourceFileSystemObject
    private let queue: DispatchQueue
    private let onBytes: @Sendable (Data) -> Void
    private let stateLock = NSLock()
    private var started = false
    private var cancelled = false

    init(
        fileURL: URL,
        initialOffset: UInt64,
        onBytes: @escaping @Sendable (Data) -> Void
    ) throws {
        let path = fileURL.path
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: path) {
            guard fileManager.createFile(atPath: path, contents: Data()) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path])
            }
        }

        let fileSize = try Self.fileSize(at: fileURL)
        guard initialOffset <= fileSize else {
            throw TmuxRuntimeError.outputOffsetUnavailable(
                path: path,
                offset: initialOffset,
                fileSize: fileSize,
                recovery: "Clear the invalid output spool, or reset the recovery anchor to the current spool size before adoption."
            )
        }

        do {
            fileHandle = try FileHandle(forReadingFrom: fileURL)
            try fileHandle.seek(toOffset: initialOffset)
        } catch {
            throw TmuxRuntimeError.outputSpoolUnavailable(
                path: path,
                reason: String(describing: error),
                recovery: "Ensure Warren can read the output directory, then delete it and retry the session."
            )
        }

        self.onBytes = onBytes
        let fd = fileHandle.fileDescriptor
        let queue = DispatchQueue(label: "dev.warren.tmux-output.\(UUID().uuidString)")
        self.queue = queue
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.drain()
        }
        source.setCancelHandler { [fileHandle] in
            try? fileHandle.close()
        }
    }

    func start() {
        stateLock.lock()
        guard !started, !cancelled else {
            stateLock.unlock()
            return
        }
        started = true
        stateLock.unlock()
        source.resume()
        // A vnode notification is not guaranteed for bytes appended before
        // the source was resumed. Drain once on the same serial queue as
        // event handlers so adoption catches up without waiting for a new
        // write and never races FileHandle reads.
        queue.async { [weak self] in
            self?.drain()
        }
    }

    func cancel() {
        stateLock.lock()
        guard !cancelled else {
            stateLock.unlock()
            return
        }
        cancelled = true
        let shouldCancelSource = started
        stateLock.unlock()
        if shouldCancelSource {
            source.cancel()
        } else {
            try? fileHandle.close()
        }
    }

    private func drain() {
        stateLock.lock()
        let isCancelled = cancelled
        stateLock.unlock()
        guard !isCancelled else { return }
        let data = fileHandle.readDataToEndOfFile()
        guard !data.isEmpty else { return }
        onBytes(data)
    }

    private static func fileSize(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw TmuxRuntimeError.outputSpoolUnavailable(
                path: url.path,
                reason: "File size is unavailable.",
                recovery: "Ensure the output spool is a regular file, not a replaced special file."
            )
        }
        return size.uint64Value
    }
}
