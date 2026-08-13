import Foundation
import XCTest
@testable import WarrenDomain

final class WarrenDomainTests: XCTestCase {
    func testStrongIDsRoundTripThroughJSON() throws {
        let id = ProjectID(rawValue: UUID())
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(ProjectID.self, from: data)

        XCTAssertEqual(id, decoded)
        XCTAssertNotEqual(id.rawValue, HostID(rawValue: UUID()).rawValue)
    }

    func testRelationshipsAreRepresentedByDifferentStrongIDs() throws {
        let host = Host(name: "Mac")
        let project = Project(hostID: host.id, name: "Warren", rootPath: "/tmp/warren")
        let workspace = Workspace(projectID: project.id, name: "main", path: "/tmp/warren")
        let session = TerminalSession(workspaceID: workspace.id)
        let client = Client(name: "iPhone")
        let attachment = TerminalAttachment(sessionID: session.id, clientID: client.id)
        let lease = try XCTUnwrap(ControlLease(
            sessionID: session.id,
            attachmentID: attachment.id,
            issuedAt: .distantPast,
            expiresAt: .distantFuture
        ))

        XCTAssertEqual(project.hostID, host.id)
        XCTAssertEqual(workspace.projectID, project.id)
        XCTAssertEqual(attachment.sessionID, session.id)
        XCTAssertEqual(lease.attachmentID, attachment.id)
    }

    func testSizeConstraintsRejectNonPositiveValues() {
        XCTAssertNotNil(LayoutSize(width: 320, height: 240))
        XCTAssertNil(LayoutSize(width: 0, height: 240))
        XCTAssertNil(LayoutSize(width: .infinity, height: 240))
        XCTAssertNotNil(TerminalSize(columns: 80, rows: 24))
        XCTAssertNil(TerminalSize(columns: 0, rows: 24))
    }

    func testRecoveryAnchorAndLeaseAreCodable() throws {
        let anchor = RecoveryAnchor(epoch: 2, sequence: 42)
        let lease = try XCTUnwrap(ControlLease(
            sessionID: TerminalSessionID(),
            attachmentID: TerminalAttachmentID(),
            issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 200)
        ))

        XCTAssertEqual(anchor, try JSONDecoder().decode(
            RecoveryAnchor.self,
            from: JSONEncoder().encode(anchor)
        ))
        XCTAssertEqual(lease, try JSONDecoder().decode(
            ControlLease.self,
            from: JSONEncoder().encode(lease)
        ))
    }

    func testControlLeaseRejectsInvalidIntervalAndHonorsBoundaries() throws {
        let issuedAt = Date(timeIntervalSince1970: 100)
        let expiresAt = Date(timeIntervalSince1970: 200)
        let sessionID = TerminalSessionID()
        let attachmentID = TerminalAttachmentID()

        XCTAssertNil(ControlLease(
            sessionID: sessionID,
            attachmentID: attachmentID,
            issuedAt: issuedAt,
            expiresAt: issuedAt
        ))
        XCTAssertNil(ControlLease(
            sessionID: sessionID,
            attachmentID: attachmentID,
            issuedAt: expiresAt,
            expiresAt: issuedAt
        ))

        let lease = try XCTUnwrap(ControlLease(
            sessionID: sessionID,
            attachmentID: attachmentID,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        ))
        XCTAssertFalse(lease.isActive(at: issuedAt.addingTimeInterval(-0.001)))
        XCTAssertTrue(lease.isActive(at: issuedAt))
        XCTAssertTrue(lease.isActive(at: Date(timeIntervalSince1970: 150)))
        XCTAssertFalse(lease.isActive(at: expiresAt))
        XCTAssertFalse(lease.isActive(at: expiresAt.addingTimeInterval(0.001)))
    }
}
