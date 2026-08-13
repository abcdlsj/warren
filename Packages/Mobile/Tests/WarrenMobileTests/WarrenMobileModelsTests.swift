import XCTest
@testable import WarrenMobile
import WarrenClientCore
import WarrenDomain

final class WarrenMobileModelsTests: XCTestCase {
    func testSamplePreservesHostWorkspaceSessionHierarchy() throws {
        let fixture = WarrenMobileFixture.sample()
        let host = try XCTUnwrap(fixture.hosts.first)
        let workspaces = fixture.workspaces(for: host.id)

        XCTAssertEqual(workspaces.count, 2)
        XCTAssertEqual(workspaces.flatMap { fixture.sessions(for: $0.id) }.count, 2)
        XCTAssertNotNil(fixture.sessions(for: workspaces[0].id).first)
    }

    func testControllerCanSendInputAndObserverCannot() throws {
        let fixture = WarrenMobileFixture.sample()
        let mainWorkspace = try XCTUnwrap(fixture.workspaces.first)
        let session = try XCTUnwrap(fixture.sessions(for: mainWorkspace.id).first)

        XCTAssertTrue(session.isController)
        XCTAssertTrue(session.canSendInput)
        XCTAssertFalse(session.canRequestControl)
        XCTAssertEqual(session.controlLabel, "Controller")
    }

    func testDisconnectedSessionRetainsReadableStateButDisablesInput() throws {
        let fixture = WarrenMobileFixture.sample()
        let session = try XCTUnwrap(fixture.sessions.first { $0.connectionState == .disconnected })

        XCTAssertEqual(session.connectionLabel, "Disconnected")
        XCTAssertFalse(session.canSendInput)
        XCTAssertFalse(session.canRequestControl)
        XCTAssertTrue(session.canReconnect)
        XCTAssertEqual(session.statusTone, .destructive)
    }

    func testSnapshotConversionRejectsDifferentSession() throws {
        let fixture = WarrenMobileFixture.sample()
        let session = try XCTUnwrap(fixture.sessions.first)
        let otherSessionID = TerminalSessionID()
        let clientID = ClientID()
        let snapshot = ClientSessionSnapshot(
            hostProjection: nil,
            sessionID: otherSessionID,
            clientID: clientID,
            attachment: nil,
            controllerAttachmentID: nil,
            controlLeaseID: nil,
            connectionState: .disconnected,
            recoveryAnchor: nil,
            title: nil,
            capabilities: .core,
            reanchorRequired: false,
            lastError: nil
        )

        XCTAssertNil(WarrenMobileSessionModel(session: session.session, title: "Mismatch", snapshot: snapshot))
    }
}
