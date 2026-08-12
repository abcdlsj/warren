import XCTest
import BurrowDomain
@testable import GhosttyAdapter

final class GhosttyAdapterTests: XCTestCase {
    @MainActor
    func testSurfaceCarriesSessionIdentity() {
        let sessionID = TerminalSessionID()
        let attachmentID = TerminalAttachmentID()
        let surface = GhosttySurface(
            id: sessionID,
            attachmentID: attachmentID,
            workingDirectory: "/tmp",
            onInput: { _ in },
            onResize: { _, _ in }
        )
        XCTAssertEqual(surface.id, sessionID)
        XCTAssertEqual(surface.attachmentID, attachmentID)
    }
}
