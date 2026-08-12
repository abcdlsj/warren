import Foundation
import XCTest
import BurrowDomain
import BurrowProtocol
@testable import BurrowClientCore

final class BurrowClientCoreTests: XCTestCase {
    private let sessionID = TerminalSessionID(rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
    private let clientID = ClientID(rawValue: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
    private let attachmentID = TerminalAttachmentID(rawValue: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!)

    func testLayoutMutationsDoNotSendWireMessages() async throws {
        let transport = InMemoryHostTransport()
        let layouts = ClientLayoutStore()

        await layouts.setSidebarCollapsed(true, for: clientID)
        await layouts.upsertTab(ClientTab(id: "tab-1", title: "Shell", sessionID: sessionID), select: true, for: clientID)
        await layouts.setNavigationPath([.session(sessionID)], for: clientID)

        let layout = await layouts.snapshot(for: clientID)
        XCTAssertTrue(layout.sidebarCollapsed)
        XCTAssertEqual(layout.selectedTabID, "tab-1")
        XCTAssertEqual(layout.navigationPath, [.session(sessionID)])
        let messages = await transport.sentMessages
        XCTAssertTrue(messages.isEmpty)
    }

    func testInMemoryTransportObservesBinaryInputAndRejectsLengthMismatch() async throws {
        let transport = InMemoryHostTransport()
        let metadata = try XCTUnwrap(
            InputMetadata(sessionID: sessionID, attachmentID: attachmentID, payloadLength: 3)
        )
        try await transport.sendInput(metadata: metadata, payload: Data([1, 2, 3]))
        let sentInputs = await transport.sentInputs
        XCTAssertEqual(sentInputs.count, 1)
        XCTAssertEqual(sentInputs[0].metadata, metadata)
        XCTAssertEqual(sentInputs[0].payload, Data([1, 2, 3]))

        do {
            try await transport.sendInput(metadata: metadata, payload: Data([1]))
            XCTFail("an input length mismatch must be rejected")
        } catch let error as HostTransportError {
            XCTAssertEqual(
                error,
                .inputPayloadLengthMismatch(expected: 3, actual: 1)
            )
        }
    }

    func testDisconnectPreservesProjectionAndReconnectCarriesAnchor() async throws {
        let host = BurrowDomain.Host(name: "Mac")
        let store = ClientSessionStore(host: host, sessionID: sessionID, clientID: clientID)
        let attached = AttachedMessage(
            sessionID: sessionID,
            attachmentID: attachmentID,
            epoch: 7,
            sequence: 42
        )
        _ = try await store.consume(.attached(attached))
        await store.markDisconnected()

        let beforeReconnect = await store.snapshot()
        XCTAssertEqual(beforeReconnect.host, host)
        XCTAssertEqual(beforeReconnect.recoveryAnchor, RecoveryAnchor(epoch: 7, sequence: 42))
        XCTAssertEqual(beforeReconnect.connectionState, .disconnected)

        let transport = InMemoryHostTransport()
        let coordinator = ReconnectCoordinator()
        let request = try await coordinator.reconnect(through: transport, store: store)
        XCTAssertEqual(request.recoveryAnchor, RecoveryAnchor(epoch: 7, sequence: 42))
        XCTAssertEqual(request.attachmentID, attachmentID)

        let sent = await transport.sentMessages
        XCTAssertEqual(sent, [.attach(request)])
    }

    func testControlChangedProjectsControllerAndLease() async throws {
        let store = ClientSessionStore(sessionID: sessionID, clientID: clientID)
        _ = try await store.consume(.attached(
            AttachedMessage(sessionID: sessionID, attachmentID: attachmentID, epoch: 1, sequence: 0)
        ))
        let leaseID = ControlLeaseID()
        _ = try await store.consume(.controlChanged(
            ControlChangedMessage(
                sessionID: sessionID,
                controllerAttachmentID: attachmentID,
                leaseID: leaseID
            )
        ))

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.controllerAttachmentID, attachmentID)
        XCTAssertEqual(snapshot.controlLeaseID, leaseID)
    }

    func testOutOfOrderAndEpochChangedBinaryHeadersAreRejected() async throws {
        let store = ClientSessionStore(sessionID: sessionID, clientID: clientID)
        _ = try await store.consume(.attached(
            AttachedMessage(sessionID: sessionID, attachmentID: attachmentID, epoch: 3, sequence: 10)
        ))

        let acceptedHeader = try XCTUnwrap(
            BinaryOutputFrameHeader(sessionID: sessionID, epoch: 3, sequence: 10, payloadLength: 4)
        )
        _ = try await store.consume(binaryHeader: acceptedHeader)
        let acceptedSnapshot = await store.snapshot()
        XCTAssertEqual(acceptedSnapshot.recoveryAnchor, RecoveryAnchor(epoch: 3, sequence: 14))

        let outOfOrder = try XCTUnwrap(
            BinaryOutputFrameHeader(sessionID: sessionID, epoch: 3, sequence: 15, payloadLength: 1)
        )
        do {
            _ = try await store.consume(binaryHeader: outOfOrder)
            XCTFail("An out-of-order frame must be rejected")
        } catch {
            // Expected.
        }
        let outOfOrderSnapshot = await store.snapshot()
        XCTAssertTrue(outOfOrderSnapshot.reanchorRequired)

        _ = try await store.consume(.attached(
            AttachedMessage(sessionID: sessionID, attachmentID: attachmentID, epoch: 3, sequence: 20)
        ))
        let changedEpoch = try XCTUnwrap(
            BinaryOutputFrameHeader(sessionID: sessionID, epoch: 4, sequence: 20, payloadLength: 1)
        )
        do {
            _ = try await store.consume(binaryHeader: changedEpoch)
            XCTFail("A frame from another epoch must be rejected")
        } catch {
            // Expected.
        }
        let changedEpochSnapshot = await store.snapshot()
        XCTAssertTrue(changedEpochSnapshot.reanchorRequired)
    }

    func testHeaderOnlyAcceptsLargeLegalLengthWithoutAllocatingPayload() async throws {
        let store = ClientSessionStore(sessionID: sessionID, clientID: clientID)
        _ = try await store.consume(.attached(
            AttachedMessage(sessionID: sessionID, attachmentID: attachmentID, epoch: 8, sequence: 0)
        ))
        let hugeHeader = try XCTUnwrap(
            BinaryOutputFrameHeader(
                sessionID: sessionID,
                epoch: 8,
                sequence: 0,
                payloadLength: Int.max
            )
        )

        _ = try await store.consume(binaryHeader: hugeHeader)
        let snapshot = await store.snapshot()
        XCTAssertEqual(
            snapshot.recoveryAnchor,
            RecoveryAnchor(epoch: 8, sequence: UInt64(Int.max))
        )
    }

    func testSidebarWidthRejectsNonFiniteAndNonPositiveValues() async throws {
        let layouts = ClientLayoutStore()
        let initial = await layouts.snapshot(for: clientID)
        for width: Double in [0, -1, Double.infinity, -Double.infinity, Double.nan] {
            do {
                try await layouts.setSidebarWidth(width, for: clientID)
                XCTFail("Invalid sidebar width should be rejected: \(width)")
            } catch let error as ClientLayoutStoreError {
                guard case .invalidSidebarWidth(let received) = error else {
                    XCTFail("Unexpected layout error: \(error)")
                    continue
                }
                if width.isNaN {
                    XCTAssertTrue(received.isNaN)
                } else {
                    XCTAssertEqual(received, width)
                }
            }
        }
        let unchanged = await layouts.snapshot(for: clientID)
        XCTAssertEqual(unchanged.sidebarWidth, initial.sidebarWidth)
        XCTAssertNil(ClientLayoutSnapshot(clientID: clientID, sidebarWidth: 0))
    }
}
