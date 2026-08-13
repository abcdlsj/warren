import Foundation
import WarrenDomain

/// A deterministic runtime substitute used by Host tests and previews.
public actor InMemoryTerminalRuntime: TerminalRuntime {
    public struct Record: Hashable, Sendable {
        public let sessionID: TerminalSessionID
        public let workingDirectory: String
        public var size: TerminalSize
        public var writes: [Data]
        public var resizes: [TerminalSize]
        public let descriptor: TerminalRuntimeDescriptor
        public var isRunning: Bool

        fileprivate init(
            sessionID: TerminalSessionID,
            workingDirectory: String,
            size: TerminalSize,
            descriptor: TerminalRuntimeDescriptor
        ) {
            self.sessionID = sessionID
            self.workingDirectory = workingDirectory
            self.size = size
            self.writes = []
            self.resizes = []
            self.descriptor = descriptor
            self.isRunning = true
        }
    }

    private var records: [TerminalSessionID: Record] = [:]
    private var streams: [TerminalSessionID: [UUID: AsyncStream<TerminalRuntimeEvent>.Continuation]] = [:]

    public init() {}

    public func create(
        sessionID: TerminalSessionID,
        workingDirectory: String,
        size: TerminalSize,
        launchSpec: TerminalRuntimeLaunchSpec
    ) async throws -> TerminalRuntimeDescriptor {
        guard !workingDirectory.isEmpty else {
            throw TerminalRuntimeError.invalidWorkingDirectory
        }
        if let record = records[sessionID], record.isRunning {
            throw TerminalRuntimeError.sessionAlreadyExists
        }
        let descriptor = TerminalRuntimeDescriptor(
            runtime: "in-memory",
            identifier: sessionID.description,
            metadata: [
                "workingDirectory": workingDirectory,
                "launchSpec": String(describing: launchSpec),
            ]
        )
        records[sessionID] = Record(
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            size: size,
            descriptor: descriptor
        )
        return descriptor
    }

    public func adopt(
        sessionID: TerminalSessionID,
        descriptor: TerminalRuntimeDescriptor,
        size: TerminalSize,
        outputOffset: UInt64
    ) async throws {
        guard descriptor.runtime == "in-memory",
              descriptor.identifier == sessionID.description else {
            throw TerminalRuntimeError.operationFailed("The in-memory runtime cannot adopt this descriptor.")
        }
        if let record = records[sessionID], record.isRunning {
            throw TerminalRuntimeError.sessionAlreadyExists
        }
        guard let workingDirectory = descriptor.metadata["workingDirectory"],
              !workingDirectory.isEmpty else {
            throw TerminalRuntimeError.invalidWorkingDirectory
        }
        records[sessionID] = Record(
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            size: size,
            descriptor: descriptor
        )
        _ = outputOffset
    }

    public func presence(sessionID: TerminalSessionID) async -> TerminalRuntimePresence {
        records[sessionID]?.isRunning == true ? .present : .missing
    }

    public func events(for sessionID: TerminalSessionID) async -> AsyncStream<TerminalRuntimeEvent> {
        let (stream, continuation) = AsyncStream<TerminalRuntimeEvent>.makeStream()
        let token = UUID()
        streams[sessionID, default: [:]][token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStream(token, for: sessionID) }
        }
        return stream
    }

    public func write(sessionID: TerminalSessionID, data: Data) async throws {
        guard var record = records[sessionID], record.isRunning else {
            throw TerminalRuntimeError.sessionNotFound
        }
        record.writes.append(data)
        records[sessionID] = record
    }

    public func resize(sessionID: TerminalSessionID, size: TerminalSize) async throws {
        guard var record = records[sessionID], record.isRunning else {
            throw TerminalRuntimeError.sessionNotFound
        }
        record.size = size
        record.resizes.append(size)
        records[sessionID] = record
    }

    public func sendSpecialKey(sessionID: TerminalSessionID, key: TerminalSpecialKey) async throws {
        try await write(sessionID: sessionID, data: Self.bytes(for: key))
    }

    public func inspect(sessionID: TerminalSessionID) async throws -> TerminalRuntimeInspection {
        guard let record = records[sessionID] else { throw TerminalRuntimeError.sessionNotFound }
        return TerminalRuntimeInspection(
            isRunning: record.isRunning,
            descriptor: record.descriptor
        )
    }

    public func terminate(sessionID: TerminalSessionID) async throws {
        try await emitExit(sessionID: sessionID)
    }

    public func record(for sessionID: TerminalSessionID) -> Record? {
        records[sessionID]
    }

    public func contains(sessionID: TerminalSessionID) -> Bool {
        records[sessionID]?.isRunning == true
    }

    public func allRecords() -> [Record] {
        records.values.sorted { $0.sessionID.description < $1.sessionID.description }
    }

    /// Feeds deterministic PTY output to subscribers.  Production adapters
    /// call the same event boundary from their output reader.
    public func emitOutput(sessionID: TerminalSessionID, data: Data) async throws {
        guard records[sessionID]?.isRunning == true else {
            throw TerminalRuntimeError.sessionNotFound
        }
        broadcast(.output(sessionID: sessionID, data: data), for: sessionID)
        // Give a Host runtime-event pump a scheduling turn before this
        // deterministic test helper returns. Real adapters deliver from an
        // independent spool reader; this keeps the in-memory substitute's
        // observable ordering equally deterministic.
        await Task.yield()
    }

    /// Feeds deterministic pane metadata to subscribers. Production adapters
    /// publish the same event after their batched runtime observation pass.
    public func emitMetadata(
        sessionID: TerminalSessionID,
        process: String,
        workingDirectory: String
    ) async throws {
        guard records[sessionID]?.isRunning == true else {
            throw TerminalRuntimeError.sessionNotFound
        }
        broadcast(
            .metadata(
                sessionID: sessionID,
                value: TerminalRuntimeMetadata(
                    process: process,
                    workingDirectory: workingDirectory
                )
            ),
            for: sessionID
        )
        await Task.yield()
    }

    /// Simulates the runtime process exiting without deleting its historical
    /// record, which is useful for Host lifecycle tests.
    public func emitExit(sessionID: TerminalSessionID, exitCode: Int? = nil) async throws {
        guard var record = records[sessionID], record.isRunning else {
            throw TerminalRuntimeError.sessionNotFound
        }
        record.isRunning = false
        records[sessionID] = record
        broadcast(.exited(sessionID: sessionID, exitCode: exitCode), for: sessionID)
        await Task.yield()
    }

    private func broadcast(_ event: TerminalRuntimeEvent, for sessionID: TerminalSessionID) {
        guard let continuations = streams[sessionID] else { return }
        for continuation in continuations.values {
            continuation.yield(event)
        }
        if case .exited = event {
            for continuation in continuations.values {
                continuation.finish()
            }
            streams[sessionID] = nil
        }
    }

    private func removeStream(_ token: UUID, for sessionID: TerminalSessionID) {
        streams[sessionID]?[token] = nil
        if streams[sessionID]?.isEmpty == true {
            streams[sessionID] = nil
        }
    }

    private static func bytes(for key: TerminalSpecialKey) -> Data {
        switch key {
        case .interrupt: Data([0x03])
        case .endOfFile: Data([0x04])
        case .escape: Data([0x1b])
        case .enter: Data([0x0d])
        case .tab: Data([0x09])
        case .backspace: Data([0x7f])
        case .up: Data("\u{1b}[A".utf8)
        case .down: Data("\u{1b}[B".utf8)
        case .right: Data("\u{1b}[C".utf8)
        case .left: Data("\u{1b}[D".utf8)
        }
    }
}
