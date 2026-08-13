import Foundation
import XCTest
import WarrenClientCore
import WarrenDomain
import WarrenHost
import WarrenProtocol
@testable import WarrenLocalTransport

final class WarrenLocalTransportTests: XCTestCase {
    private let workspaceID = WorkspaceID(rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
    private let projectID = ProjectID(rawValue: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
    private let clientID = ClientID(rawValue: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!)

    private func workspace() -> Workspace {
        Workspace(id: workspaceID, projectID: projectID, name: "warren", path: "/tmp/warren")
    }

    private func nextEvent(
        _ iterator: inout AsyncThrowingStream<HostTransportEvent, Error>.AsyncIterator
    ) async throws -> HostTransportEvent {
        guard let event = try await iterator.next() else { throw CancellationError() }
        return event
    }

    func testAttachControlInputResizeOutputDetachAndReattach() async throws {
        let runtime = InMemoryTerminalRuntime()
        let coordinator = TerminalSessionCoordinator(runtime: runtime, outputCapacity: 4)
        let session = try await coordinator.createSession(workspace: workspace())
        let transport = InProcessHostTransport(coordinator: coordinator)
        var events = transport.events().makeAsyncIterator()

        try await transport.send(.attach(AttachRequest(sessionID: session.id, clientID: clientID)))
        let attached: AttachedMessage
        switch try await nextEvent(&events) {
        case .control(.attached(let message)):
            attached = message
        default:
            XCTFail("attach must begin with attached")
            return
        }
        _ = try await nextEvent(&events) // initial synced marker
        try await transport.send(.requestControl(ControlRequest(
            sessionID: session.id,
            attachmentID: attached.attachmentID
        )))
        _ = try await nextEvent(&events) // control_changed

        let input = Data("printf ok\\n".utf8)
        let metadata = try XCTUnwrap(InputMetadata(
            sessionID: session.id,
            attachmentID: attached.attachmentID,
            payloadLength: input.count
        ))
        try await transport.sendInput(metadata: metadata, payload: input)
        let writes = await runtime.record(for: session.id)?.writes
        XCTAssertEqual(writes, [input])

        try await transport.send(.resize(ResizeRequest(
            sessionID: session.id,
            attachmentID: attached.attachmentID,
            size: try XCTUnwrap(TerminalSize(columns: 100, rows: 40))
        )))
        let resizeCount = await runtime.record(for: session.id)?.resizes.count
        XCTAssertEqual(resizeCount, 1)

        let output = Data("ok\\n".utf8)
        try await runtime.emitOutput(sessionID: session.id, data: output)
        switch try await nextEvent(&events) {
        case .binary(let frame):
            XCTAssertEqual(frame.header.sequence, 0)
            XCTAssertEqual(frame.payload, output)
        default:
            XCTFail("runtime output must be delivered as a binary event")
        }

        try await transport.send(.detach(DetachRequest(
            sessionID: session.id,
            attachmentID: attached.attachmentID
        )))
        let survivingSession = await coordinator.session(session.id)
        let runtimeIsAlive = await runtime.contains(sessionID: session.id)
        XCTAssertNotNil(survivingSession)
        XCTAssertTrue(runtimeIsAlive)

        try await transport.send(.attach(AttachRequest(
            sessionID: session.id,
            clientID: clientID,
            attachmentID: attached.attachmentID,
            recoveryAnchor: RecoveryAnchor(epoch: 0, sequence: 0)
        )))
        switch try await nextEvent(&events) {
        case .control(.attached(let message)):
            XCTAssertEqual(message.sequence, 0)
        default:
            XCTFail("reattach must begin with attached")
        }
        switch try await nextEvent(&events) {
        case .binary(let frame):
            XCTAssertEqual(frame.payload, output)
        default:
            XCTFail("reattach must replay retained output")
        }
        switch try await nextEvent(&events) {
        case .control(.synced(let message)):
            XCTAssertEqual(message.sequence, UInt64(output.count))
        default:
            XCTFail("reattach must finish with synced")
        }

        await transport.close()
        let survivingAfterClose = await coordinator.session(session.id)
        let runtimeAliveAfterClose = await runtime.contains(sessionID: session.id)
        XCTAssertNotNil(survivingAfterClose)
        XCTAssertTrue(runtimeAliveAfterClose)
    }

    func testProtocolErrorIsStructuredEventAndCloseDoesNotKillSession() async throws {
        let runtime = InMemoryTerminalRuntime()
        let coordinator = TerminalSessionCoordinator(runtime: runtime)
        let session = try await coordinator.createSession(workspace: workspace())
        let transport = InProcessHostTransport(coordinator: coordinator)
        var events = transport.events().makeAsyncIterator()

        try await transport.send(.attach(AttachRequest(sessionID: session.id, clientID: clientID)))
        let attachmentID: TerminalAttachmentID
        switch try await nextEvent(&events) {
        case .control(.attached(let message)):
            attachmentID = message.attachmentID
        default:
            XCTFail("attach must produce attached")
            return
        }
        _ = try await nextEvent(&events)
        let bad = TerminalAttachmentID()
        try await transport.send(.requestControl(ControlRequest(
            sessionID: session.id,
            attachmentID: bad
        )))
        switch try await nextEvent(&events) {
        case .control(.error(let error)):
            XCTAssertEqual(error.code, .attachmentNotFound)
        default:
            XCTFail("bad control request must produce a structured error")
        }
        _ = attachmentID

        await transport.close()
        try await Task.sleep(for: .milliseconds(20))
        let survivingSession = await coordinator.session(session.id)
        let runtimeIsAlive = await runtime.contains(sessionID: session.id)
        XCTAssertNotNil(survivingSession)
        XCTAssertTrue(runtimeIsAlive)
    }

    func testRuntimeEmptyChunkIsIgnoredAndExitTerminatesAttachmentStream() async throws {
        let runtime = InMemoryTerminalRuntime()
        let coordinator = TerminalSessionCoordinator(runtime: runtime)
        let session = try await coordinator.createSession(workspace: workspace())
        let transport = InProcessHostTransport(coordinator: coordinator)
        var events = transport.events().makeAsyncIterator()

        try await transport.send(.attach(AttachRequest(sessionID: session.id, clientID: clientID)))
        let attachmentID: TerminalAttachmentID
        switch try await nextEvent(&events) {
        case .control(.attached(let message)):
            attachmentID = message.attachmentID
        default:
            XCTFail("attach must produce attached")
            return
        }
        _ = try await nextEvent(&events)

        try await runtime.emitOutput(sessionID: session.id, data: Data())
        try await runtime.emitExit(sessionID: session.id, exitCode: 7)
        switch try await nextEvent(&events) {
        case .control(.exit(let message)):
            XCTAssertEqual(message.exitCode, 7)
            XCTAssertEqual(message.sequence, 0)
        default:
            XCTFail("runtime exit must be forwarded")
        }
        // The attachment channel finishes after exit, while the multiplexed
        // transport stream remains open for other sessions.  Closing the
        // transport explicitly terminates that shared stream.
        let survivingSession = await coordinator.session(session.id)
        XCTAssertNotNil(survivingSession)
        _ = attachmentID
        await transport.close()
    }

    func testRecoveryEventsCanBeConsumedByClientSessionStoreInOrder() async throws {
        let runtime = InMemoryTerminalRuntime()
        let coordinator = TerminalSessionCoordinator(runtime: runtime, outputCapacity: 4)
        let session = try await coordinator.createSession(workspace: workspace())
        try await runtime.emitOutput(sessionID: session.id, data: Data("abc".utf8))

        let transport = InProcessHostTransport(coordinator: coordinator)
        let store = ClientSessionStore(sessionID: session.id, clientID: clientID)
        var events = transport.events().makeAsyncIterator()
        try await transport.send(.attach(AttachRequest(
            sessionID: session.id,
            clientID: clientID,
            recoveryAnchor: RecoveryAnchor(epoch: 0, sequence: 0)
        )))

        for _ in 0..<3 {
            let event = try await nextEvent(&events)
            _ = try await store.consume(event)
        }
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.recoveryAnchor, RecoveryAnchor(epoch: 0, sequence: 3))
        XCTAssertEqual(snapshot.connectionState, .attached)
        await transport.close()
    }
}
