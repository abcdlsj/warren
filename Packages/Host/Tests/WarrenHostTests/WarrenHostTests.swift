import Foundation
import XCTest
import WarrenDomain
import WarrenProtocol
@testable import WarrenHost

final class WarrenHostTests: XCTestCase {
    private let workspaceID = WorkspaceID(rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
    private let clientA = ClientID(rawValue: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
    private let clientB = ClientID(rawValue: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!)

    private func workspace() -> Workspace {
        Workspace(
            id: workspaceID,
            projectID: ProjectID(rawValue: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!),
            name: "warren",
            path: "/tmp/warren"
        )
    }

    private func protocolError(
        _ expression: () async throws -> Void,
        code: ProtocolErrorCode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("Expected ProtocolError (code)", file: file, line: line)
        } catch let error as ProtocolError {
            XCTAssertEqual(error.code, code, file: file, line: line)
        } catch {
            XCTFail("Expected ProtocolError, got \(error)", file: file, line: line)
        }
    }

    func testCreateAndAttachTwoClients() async throws {
        let runtime = InMemoryTerminalRuntime()
        let coordinator = TerminalSessionCoordinator(runtime: runtime)
        let session = try await coordinator.createSession(workspace: workspace())

        XCTAssertEqual(session.workspaceID, workspaceID)
        let runtimeContainsSession = await runtime.contains(sessionID: session.id)
        XCTAssertTrue(runtimeContainsSession)

        let first = try await coordinator.attach(
            AttachRequest(sessionID: session.id, clientID: clientA)
        )
        let second = try await coordinator.attach(
            AttachRequest(sessionID: session.id, clientID: clientB)
        )
        XCTAssertNotEqual(first.attachmentID, second.attachmentID)
        XCTAssertEqual(first.sessionID, second.sessionID)
        XCTAssertNil(first.controllerAttachmentID)
        XCTAssertEqual(first.recovery.plan, .reanchor)
        XCTAssertEqual(second.recovery.result, .reanchor(second.recovery.snapshot))
    }

    func testControlTransferAndControllerOnlyOperations() async throws {
        let runtime = InMemoryTerminalRuntime()
        let coordinator = TerminalSessionCoordinator(runtime: runtime, leaseDuration: 30)
        let session = try await coordinator.createSession(workspace: workspace())
        let first = try await coordinator.attach(
            AttachRequest(sessionID: session.id, clientID: clientA)
        )
        let second = try await coordinator.attach(
            AttachRequest(sessionID: session.id, clientID: clientB)
        )
        let issuedAt = Date(timeIntervalSince1970: 100)
        let leaseA = try await coordinator.requestControl(
            ControlRequest(sessionID: session.id, attachmentID: first.attachmentID),
            now: issuedAt
        )

        let input = Data("pwd\n".utf8)
        try await coordinator.input(
            InputMetadata(
                sessionID: session.id,
                attachmentID: first.attachmentID,
                payloadLength: input.count
            )!,
            data: input,
            now: issuedAt.addingTimeInterval(1)
        )
        let writes = await runtime.record(for: session.id)?.writes
        XCTAssertEqual(writes, [input])

        await protocolError({
            try await coordinator.input(
                InputMetadata(
                    sessionID: session.id,
                    attachmentID: second.attachmentID,
                    payloadLength: input.count
                )!,
                data: input,
                now: issuedAt.addingTimeInterval(1)
            )
        }, code: .controlRequired)
        await protocolError({
            try await coordinator.resize(
                ResizeRequest(
                    sessionID: session.id,
                    attachmentID: second.attachmentID,
                    size: TerminalSize(columns: 100, rows: 40)!
                ),
                now: issuedAt.addingTimeInterval(1)
            )
        }, code: .controlRequired)
        let leaseB = try await coordinator.requestControl(
            ControlRequest(sessionID: session.id, attachmentID: second.attachmentID),
            now: issuedAt.addingTimeInterval(2)
        )
        XCTAssertEqual(leaseB.attachmentID, second.attachmentID)
        await protocolError({
            try await coordinator.releaseControl(
                ReleaseControlRequest(
                    sessionID: session.id,
                    attachmentID: first.attachmentID,
                    leaseID: leaseA.id
                ),
                now: issuedAt.addingTimeInterval(3)
            )
        }, code: .controlRequired)
    }

    func testExpiredLeaseIsStructuredAndDetachKeepsSessionAlive() async throws {
        let runtime = InMemoryTerminalRuntime()
        let coordinator = TerminalSessionCoordinator(runtime: runtime, leaseDuration: 10)
        let session = try await coordinator.createSession(workspace: workspace())
        let attached = try await coordinator.attach(
            AttachRequest(sessionID: session.id, clientID: clientA)
        )
        let issuedAt = Date(timeIntervalSince1970: 500)
        _ = try await coordinator.requestControl(
            ControlRequest(sessionID: session.id, attachmentID: attached.attachmentID),
            now: issuedAt
        )

        await protocolError({
            try await coordinator.input(
                InputMetadata(
                    sessionID: session.id,
                    attachmentID: attached.attachmentID,
                    payloadLength: 1
                )!,
                data: Data([1]),
                now: issuedAt.addingTimeInterval(10)
            )
        }, code: .controlLeaseExpired)

        _ = try await coordinator.detach(
            DetachRequest(sessionID: session.id, attachmentID: attached.attachmentID)
        )
        let survivingSession = await coordinator.session(session.id)
        let runtimeContainsSession = await runtime.contains(sessionID: session.id)
        XCTAssertNotNil(survivingSession)
        XCTAssertTrue(runtimeContainsSession)
        let later = try await coordinator.attach(
            AttachRequest(sessionID: session.id, clientID: clientB)
        )
        XCTAssertEqual(later.sessionID, session.id)
    }

    func testRecoveryExactTailAndReanchor() async throws {
        let runtime = InMemoryTerminalRuntime()
        let coordinator = TerminalSessionCoordinator(runtime: runtime, outputCapacity: 2)
        let session = try await coordinator.createSession(workspace: workspace())
        let first = try await coordinator.recordOutput(
            sessionID: session.id,
            data: Data([0x41, 0x42])
        )
        let second = try await coordinator.recordOutput(
            sessionID: session.id,
            data: Data([0x43, 0x44, 0x45])
        )
        let third = try await coordinator.recordOutput(
            sessionID: session.id,
            data: Data([0x46])
        )
        XCTAssertEqual(first.header.sequence, 0)
        XCTAssertEqual(second.header.sequence, 2)
        XCTAssertEqual(third.header.sequence, 5)
        XCTAssertEqual(first.anchor, RecoveryAnchor(epoch: 0, sequence: 2))
        XCTAssertEqual(second.anchor, RecoveryAnchor(epoch: 0, sequence: 5))
        XCTAssertEqual(third.anchor, RecoveryAnchor(epoch: 0, sequence: 6))

        let exact = try await coordinator.recover(
            sessionID: session.id,
            anchor: RecoveryAnchor(epoch: 0, sequence: 6)
        )
        XCTAssertEqual(exact.plan, .exact)
        XCTAssertTrue(exact.frames.isEmpty)

        let tail = try await coordinator.recover(
            sessionID: session.id,
            anchor: RecoveryAnchor(epoch: 0, sequence: 2)
        )
        XCTAssertEqual(tail.plan, .tail(from: 2))
        XCTAssertEqual(tail.frames.map { $0.payload }, [Data([0x43, 0x44, 0x45]), Data([0x46])])

        let middle = try await coordinator.recover(
            sessionID: session.id,
            anchor: RecoveryAnchor(epoch: 0, sequence: 4)
        )
        XCTAssertEqual(middle.plan, .tail(from: 4))
        XCTAssertEqual(middle.frames.map { $0.header.sequence }, [4, 5])
        XCTAssertEqual(middle.frames.map { $0.payload }, [Data([0x45]), Data([0x46])])

        let evicted = try await coordinator.recover(
            sessionID: session.id,
            anchor: RecoveryAnchor(epoch: 0, sequence: 0)
        )
        XCTAssertEqual(evicted.plan, .reanchor)
        XCTAssertEqual(evicted.frames.map { $0.payload }, [Data([0x43, 0x44, 0x45]), Data([0x46])])

        let newEpoch = try await coordinator.recover(
            sessionID: session.id,
            anchor: RecoveryAnchor(epoch: 99, sequence: 3)
        )
        XCTAssertEqual(newEpoch.plan, .reanchor)

        do {
            _ = try await coordinator.recordOutput(sessionID: session.id, data: Data())
            XCTFail("An empty output payload must be rejected.")
        } catch let error as OutputRingError {
            XCTAssertEqual(error, .emptyPayload)
        }
    }

    func testAdoptionContinuesPersistedSequenceAfterRuntimeRestart() async throws {
        let runtime = InMemoryTerminalRuntime()
        let firstCoordinator = TerminalSessionCoordinator(runtime: runtime)
        let created = try await firstCoordinator.createSessionWithRuntimeDescriptor(
            workspace: workspace()
        )
        let previous = Data("before\n".utf8)
        try await runtime.emitOutput(sessionID: created.session.id, data: previous)
        try await Task.sleep(for: .milliseconds(20))
        let persistedSnapshot = try await firstCoordinator.snapshot(of: created.session.id)
        let persisted = persistedSnapshot.session
        XCTAssertEqual(persisted.sequence, UInt64(previous.count))

        // Simulate the runtime process ending while the Host is restarted;
        // the persisted session record and descriptor remain available.
        try await runtime.emitExit(sessionID: created.session.id)
        let restartedCoordinator = TerminalSessionCoordinator(runtime: runtime)
        _ = try await restartedCoordinator.adoptSession(
            persisted,
            descriptor: created.descriptor,
            size: TerminalSize(columns: 80, rows: 24)!
        )

        let after = Data("after\n".utf8)
        try await runtime.emitOutput(sessionID: persisted.id, data: after)
        try await Task.sleep(for: .milliseconds(20))
        let recovered = try await restartedCoordinator.recover(
            sessionID: persisted.id,
            anchor: RecoveryAnchor(epoch: persisted.epoch, sequence: persisted.sequence)
        )
        XCTAssertEqual(recovered.plan, .tail(from: persisted.sequence))
        XCTAssertEqual(recovered.frames.first?.header.sequence, persisted.sequence)
        XCTAssertEqual(recovered.frames.first?.payload, after)
    }

    func testRuntimeCatchUpIsSplitWithoutLosingSpoolBytes() async throws {
        let runtime = InMemoryTerminalRuntime()
        let coordinator = TerminalSessionCoordinator(runtime: runtime)
        let session = try await coordinator.createSession(workspace: workspace())
        let chunkSize = TerminalSessionCoordinator.defaultRuntimeOutputChunkSize
        let data = Data((0..<(chunkSize * 2 + 17)).map { UInt8($0 % 251) })

        try await runtime.emitOutput(sessionID: session.id, data: data)
        try await Task.sleep(for: .milliseconds(20))

        let snapshot = try await coordinator.snapshot(of: session.id)
        XCTAssertEqual(snapshot.output.frames.count, 3)
        XCTAssertTrue(snapshot.output.frames.allSatisfy { $0.payload.count <= chunkSize })
        XCTAssertEqual(
            Data(snapshot.output.frames.flatMap { $0.payload }),
            data
        )

        var expectedSequence: UInt64 = 0
        for frame in snapshot.output.frames {
            XCTAssertEqual(frame.header.sequence, expectedSequence)
            expectedSequence += UInt64(frame.payload.count)
        }
        XCTAssertEqual(expectedSequence, UInt64(data.count))
        XCTAssertEqual(snapshot.session.sequence, expectedSequence)

        let recovery = try await coordinator.recover(
            sessionID: session.id,
            anchor: RecoveryAnchor(epoch: session.epoch, sequence: 0)
        )
        XCTAssertEqual(recovery.plan, .tail(from: 0))
        XCTAssertEqual(Data(recovery.frames.flatMap { $0.payload }), data)
        let exactRecovery = try await coordinator.recover(
            sessionID: session.id,
            anchor: RecoveryAnchor(epoch: session.epoch, sequence: expectedSequence)
        )
        XCTAssertEqual(exactRecovery.plan, .exact)
    }
}
