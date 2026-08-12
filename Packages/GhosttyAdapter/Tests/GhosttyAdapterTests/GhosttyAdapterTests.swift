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

    @MainActor
    func testSemanticSnapshotPreservesANSIStyleAndUnicodeWithoutWindow() {
        let surface = GhosttySurface(
            id: TerminalSessionID(),
            attachmentID: TerminalAttachmentID(),
            workingDirectory: "/tmp",
            onInput: { _ in },
            onResize: { _, _ in }
        )
        surface.receive(Data("plain \u{1b}[1;38;2;224;120;80m橙色\u{1b}[0m \u{1b}[38;5;42mgreen\u{1b}[0m".utf8))

        let snapshot = surface.semanticSnapshot()
        XCTAssertEqual(snapshot.plainText, "plain 橙色 green")
        XCTAssertTrue(snapshot.containsStyledText)
        XCTAssertEqual(
            snapshot.runs.first { $0.text == "橙色" }?.style.foreground,
            .rgb(red: 224, green: 120, blue: 80)
        )
        XCTAssertEqual(snapshot.runs.first { $0.text == "橙色" }?.style.bold, true)
        XCTAssertEqual(
            snapshot.runs.first { $0.text == "green" }?.style.foreground,
            .indexed(42)
        )
    }
}
