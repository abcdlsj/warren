import XCTest
import WarrenDomain
@testable import GhosttyAdapter

final class GhosttyAdapterTests: XCTestCase {
    @MainActor
    func testSemanticSnapshotPreservesANSIStyleAndUnicodeWithoutWindow() {
        let surface = GhosttySurface(
            id: TerminalSessionID(),
            attachmentID: TerminalAttachmentID(),
            workingDirectory: "/tmp",
            onInput: { _ in },
            onResize: { _, _ in }
        )
        surface.receive(Data("plain \u{1b}[1;38;2;224;120;80morange\u{1b}[0m \u{1b}[38;5;42mgreen\u{1b}[0m".utf8))

        let snapshot = surface.semanticSnapshot()
        XCTAssertEqual(snapshot.plainText, "plain orange green")
        XCTAssertTrue(snapshot.containsStyledText)
        XCTAssertEqual(
            snapshot.runs.first { $0.text == "orange" }?.style.foreground,
            .rgb(red: 224, green: 120, blue: 80)
        )
        XCTAssertEqual(snapshot.runs.first { $0.text == "orange" }?.style.bold, true)
        XCTAssertEqual(
            snapshot.runs.first { $0.text == "green" }?.style.foreground,
            .indexed(42)
        )
    }

    @MainActor
    func testCellHeightAdjustmentMatchesWebTerminalLineHeight() {
        let surface = GhosttySurface(
            id: TerminalSessionID(),
            attachmentID: TerminalAttachmentID(),
            workingDirectory: "/tmp",
            onInput: { _ in },
            onResize: { _, _ in }
        )

        XCTAssertNil(surface.state.controller.lastConfigurationIssue)
        XCTAssertTrue(surface.state.renderedConfig.contains("font-thicken = false"))
        XCTAssertTrue(surface.state.renderedConfig.contains("adjust-cell-height = 12%"))
    }

    @MainActor
    func testAppLevelShortcutsAreUnboundFromGhostty() {
        let surface = GhosttySurface(
            id: TerminalSessionID(),
            attachmentID: TerminalAttachmentID(),
            workingDirectory: "/tmp",
            onInput: { _ in },
            onResize: { _, _ in }
        )

        for shortcut in ["super+t", "super+w", "super+x", "super+k", "super+b", "super+q"] {
            XCTAssertTrue(
                surface.state.renderedConfig.contains("keybind = \(shortcut)=unbind"),
                "Expected \(shortcut) to be unbound so Warren shortcuts stay available."
            )
        }
    }
}
