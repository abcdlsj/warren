import XCTest
import WarrenDomain
import AppKit
import GhosttyKit
import GhosttyTerminal
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
        XCTAssertTrue(surface.state.renderedConfig.contains("copy-on-select = true"))
        XCTAssertTrue(surface.state.renderedConfig.contains("mouse-scroll-multiplier = precision:2"))
        XCTAssertTrue(surface.state.renderedConfig.contains("search-selected-background = #e07850"))
        let theme = surface.state.theme.dark.rendered
        XCTAssertTrue(theme.contains("palette = 0=#151110"))
        XCTAssertTrue(theme.contains("palette = 1=#dc6b6b"))
        XCTAssertTrue(theme.contains("palette = 8=#5c5856"))
        XCTAssertTrue(theme.contains("palette = 15=#ffffff"))
        XCTAssertTrue(theme.contains("cursor-text = #151110"))
        XCTAssertTrue(theme.contains("selection-background = #482b20"))
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

        var shortcuts = ["super+t", "super+w", "super+x", "super+k", "super+b", "super+q"]
        for index in 1...9 {
            shortcuts.append("super+\(index)")
            shortcuts.append("super+digit_\(index)")
        }

        for shortcut in shortcuts {
            XCTAssertTrue(
                surface.state.renderedConfig.contains("keybind = \(shortcut)=unbind"),
                "Expected \(shortcut) to be unbound so Warren shortcuts stay available."
            )
        }
    }

    @MainActor
    func testShiftEnterKeybindEmitsLiteralNewline() async throws {
        let recorder = LockedInputRecorder()
        let surface = GhosttySurface(
            id: TerminalSessionID(),
            attachmentID: TerminalAttachmentID(),
            workingDirectory: "/tmp",
            onInput: { recorder.append($0) },
            onResize: { _, _ in }
        )

        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.delegate = surface.state
        view.controller = surface.state.controller
        view.configuration = surface.state.configuration
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }

        let terminalSurface = try await waitUntilSurfaceAvailable(on: surface.state)
        // tmux requests the kitty keyboard protocol from its outer terminal.
        // Ghostty may then encode Shift+Enter as CSI 13;2u instead of firing
        // the text: keybind, which is exactly what Warren must handle.
        surface.receive(Data("\u{1b}[>1u".utf8))
        try await Task.sleep(for: .milliseconds(100))
        for action in [GHOSTTY_ACTION_PRESS, GHOSTTY_ACTION_RELEASE] {
            var event = ghostty_input_key_s()
            event.action = action
            event.keycode = 0x24 // kVK_Return
            event.mods = GHOSTTY_MODS_SHIFT
            event.consumed_mods = GHOSTTY_MODS_SHIFT
            event.text = nil
            event.unshifted_codepoint = 0x0D
            event.composing = false
            _ = terminalSurface.sendKeyEvent(event)
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while recorder.allBytes().isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            recorder.allBytes(),
            Data([0x0A]),
            "Shift+Enter should emit a literal newline (received bytes)"
        )
    }

    func testDiagnosticSizeFormattingNeverTrapsOnExtremeValues() {
        XCTAssertEqual(
            GhosttyDiagnosticsFormat.finiteSize(
                CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.infinity
                )
            ),
            ">1Mxinf"
        )
        XCTAssertEqual(
            GhosttyDiagnosticsFormat.finiteSize(
                CGSize(width: CGFloat.nan, height: 0)
            ),
            "infx0"
        )
        XCTAssertEqual(
            GhosttyDiagnosticsFormat.finiteSize(CGSize(width: -800, height: 600)),
            "-800x600"
        )
    }

    @MainActor
    func testOutputWriterDrainsFramedAndRawBytesOffMainInOrder() async throws {
        let surface = GhosttySurface(
            id: TerminalSessionID(),
            attachmentID: TerminalAttachmentID(),
            workingDirectory: "/tmp",
            outputRenderBudgetBytes: 4,
            outputRenderYield: .milliseconds(1),
            onInput: { _ in },
            onResize: { _, _ in }
        )

        surface.outputWriter.enqueue(epoch: 1, sequence: 0, payload: Data("abcd".utf8))
        surface.outputWriter.enqueue(epoch: 1, sequence: 4, payload: Data("ef".utf8))
        surface.outputWriter.enqueueRaw(Data("gh".utf8))

        for _ in 0..<100 where surface.renderedSequence < 8 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(surface.semanticSnapshot().plainText, "abcdefgh")
        surface.outputWriter.shutdown()
    }
}

private final class LockedInputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        bytes.append(data)
    }

    func allBytes() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }
}

@MainActor
private func waitUntilSurfaceAvailable(
    on state: TerminalViewState
) async throws -> TerminalSurface {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while state.surface == nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    guard let surface = state.surface else {
        struct SurfaceUnavailable: Error {}
        throw SurfaceUnavailable()
    }
    return surface
}
