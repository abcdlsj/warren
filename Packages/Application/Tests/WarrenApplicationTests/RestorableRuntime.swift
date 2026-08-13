import Foundation
import WarrenDomain
import WarrenHost

actor RestorableRuntime: TerminalRuntime {
    struct Record: Hashable, Sendable {
        let descriptor: TerminalRuntimeDescriptor
        var writes: [Data] = []
        var resizes: [TerminalSize] = []
        var output = Data()
        var size: TerminalSize
        var running = true
    }

    private var records: [TerminalSessionID: Record] = [:]
    private var streams: [TerminalSessionID: [UUID: AsyncStream<TerminalRuntimeEvent>.Continuation]] = [:]
    private var adoptionCounts: [TerminalSessionID: Int] = [:]
    private var adoptionOffsets: [TerminalSessionID: UInt64] = [:]

    func create(
        sessionID: TerminalSessionID,
        workingDirectory: String,
        size: TerminalSize,
        launchSpec: TerminalRuntimeLaunchSpec
    ) async throws -> TerminalRuntimeDescriptor {
        let descriptor = TerminalRuntimeDescriptor(
            runtime: "test-runtime",
            identifier: sessionID.description,
            metadata: [
                "workingDirectory": workingDirectory,
                "launchSpec": String(describing: launchSpec),
            ]
        )
        records[sessionID] = Record(descriptor: descriptor, size: size)
        return descriptor
    }

    func adopt(sessionID: TerminalSessionID, descriptor: TerminalRuntimeDescriptor, size: TerminalSize, outputOffset: UInt64) async throws {
        guard descriptor.identifier == sessionID.description else { throw TerminalRuntimeError.operationFailed("descriptor") }
        guard var record = records[sessionID], record.running else {
            throw TerminalRuntimeError.sessionNotFound
        }
        guard outputOffset <= UInt64(record.output.count) else {
            throw TerminalRuntimeError.operationFailed("output offset")
        }
        record.size = size
        records[sessionID] = record
        adoptionCounts[sessionID, default: 0] += 1
        adoptionOffsets[sessionID] = outputOffset
        let tail = Data(record.output.dropFirst(Int(outputOffset)))
        if !tail.isEmpty {
            for continuation in streams[sessionID]?.values ?? [:].values {
                continuation.yield(.output(sessionID: sessionID, data: tail))
            }
        }
    }

    func exists(sessionID: TerminalSessionID) async -> Bool { records[sessionID]?.running == true }

    func events(for sessionID: TerminalSessionID) async -> AsyncStream<TerminalRuntimeEvent> {
        let pair = AsyncStream<TerminalRuntimeEvent>.makeStream()
        let token = UUID()
        streams[sessionID, default: [:]][token] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStream(token, sessionID: sessionID) }
        }
        return pair.stream
    }

    func write(sessionID: TerminalSessionID, data: Data) async throws {
        guard var record = records[sessionID], record.running else { throw TerminalRuntimeError.sessionNotFound }
        record.writes.append(data)
        records[sessionID] = record
    }

    func resize(sessionID: TerminalSessionID, size: TerminalSize) async throws {
        guard var record = records[sessionID], record.running else { throw TerminalRuntimeError.sessionNotFound }
        record.resizes.append(size)
        record.size = size
        records[sessionID] = record
    }

    func sendSpecialKey(sessionID: TerminalSessionID, key: TerminalSpecialKey) async throws {
        guard records[sessionID]?.running == true else { throw TerminalRuntimeError.sessionNotFound }
        _ = key
    }

    func inspect(sessionID: TerminalSessionID) async throws -> TerminalRuntimeInspection {
        guard let record = records[sessionID] else { throw TerminalRuntimeError.sessionNotFound }
        return TerminalRuntimeInspection(
            isRunning: record.running,
            descriptor: record.descriptor
        )
    }

    func terminate(sessionID: TerminalSessionID) async throws {
        guard var record = records[sessionID], record.running else {
            throw TerminalRuntimeError.sessionNotFound
        }
        record.running = false
        records[sessionID] = record
        for continuation in streams[sessionID]?.values ?? [:].values {
            continuation.yield(.exited(sessionID: sessionID, exitCode: nil))
            continuation.finish()
        }
        streams[sessionID] = nil
    }

    func record(_ sessionID: TerminalSessionID) -> Record? { records[sessionID] }
    func adoptCount(for sessionID: TerminalSessionID) -> Int { adoptionCounts[sessionID, default: 0] }
    func adoptOffset(for sessionID: TerminalSessionID) -> UInt64? { adoptionOffsets[sessionID] }

    func emitOutput(sessionID: TerminalSessionID, data: Data) async throws {
        guard var record = records[sessionID], record.running else { throw TerminalRuntimeError.sessionNotFound }
        record.output.append(data)
        records[sessionID] = record
        guard let continuations = streams[sessionID]?.values else { return }
        for continuation in continuations {
            continuation.yield(.output(sessionID: sessionID, data: data))
        }
        await Task.yield()
    }

    private func removeStream(_ token: UUID, sessionID: TerminalSessionID) {
        streams[sessionID]?[token] = nil
    }
}
