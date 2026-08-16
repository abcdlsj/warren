import AppKit
import Combine
import GhosttyTerminal
import XCTest

/// Guards the vendored Ghostty state contract: grid size and focus changes
/// must not publish from inside a SwiftUI view update. Ghostty reports them
/// synchronously from AppKit layout/NSViewRepresentable updates, so the
/// delegate defers each write one main-actor hop; these tests pin that
/// behavior with a bare `TerminalViewState` (no real surface).
@MainActor
final class TerminalStatePublicationTests: XCTestCase {
    private final class Counter {
        var value = 0
    }

    private func makeMetrics(
        columns: UInt16,
        rows: UInt16
    ) -> TerminalGridMetrics {
        TerminalGridMetrics(
            columns: columns,
            rows: rows,
            widthPixels: UInt32(columns) * 20,
            heightPixels: UInt32(rows) * 20,
            cellWidthPixels: 20,
            cellHeightPixels: 20
        )
    }

    func testResizePublishesAfterMainActorHopAndSkipsIdenticalValue() async throws {
        let state = TerminalViewState()
        let counter = Counter()
        var cancellables: Set<AnyCancellable> = []
        state.objectWillChange.sink { counter.value += 1 }.store(in: &cancellables)

        let initial = makeMetrics(columns: 80, rows: 24)
        let resized = makeMetrics(columns: 120, rows: 40)

        state.terminalDidResize(initial)
        XCTAssertNil(
            state.surfaceSize,
            "resize must not publish synchronously inside a view update"
        )
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(state.surfaceSize, initial)
        XCTAssertEqual(counter.value, 1)

        counter.value = 0
        state.terminalDidResize(resized)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(state.surfaceSize, resized)
        XCTAssertEqual(counter.value, 1)

        counter.value = 0
        state.terminalDidResize(resized)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(
            counter.value,
            0,
            "an identical grid size must not republish"
        )
    }

    func testFocusPublishesAfterMainActorHopAndSkipsIdenticalValue() async throws {
        let state = TerminalViewState()
        let counter = Counter()
        var cancellables: Set<AnyCancellable> = []
        state.objectWillChange.sink { counter.value += 1 }.store(in: &cancellables)

        state.terminalDidChangeFocus(true)
        XCTAssertFalse(
            state.isFocused,
            "focus must not publish synchronously inside a view update"
        )
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(state.isFocused)
        XCTAssertEqual(counter.value, 1)

        counter.value = 0
        state.terminalDidChangeFocus(true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(
            counter.value,
            0,
            "an identical focus value must not republish"
        )

        state.terminalDidChangeFocus(false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(state.isFocused)
        XCTAssertEqual(counter.value, 1)
    }

    func testTitleAndWorkingDirectoryPublishAfterMainActorHop() async throws {
        let state = TerminalViewState()
        let counter = Counter()
        var cancellables: Set<AnyCancellable> = []
        state.objectWillChange.sink { counter.value += 1 }.store(in: &cancellables)

        state.terminalDidChangeTitle("codex")
        state.terminalDidChangeWorkingDirectory("/tmp")
        XCTAssertEqual(
            state.title,
            "",
            "title must not publish synchronously inside a view update"
        )
        XCTAssertNil(
            state.workingDirectory,
            "working directory must not publish synchronously inside a view update"
        )

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(state.title, "codex")
        XCTAssertEqual(state.workingDirectory, "/tmp")
        XCTAssertEqual(counter.value, 2)

        counter.value = 0
        state.terminalDidChangeTitle("codex")
        state.terminalDidChangeWorkingDirectory("/tmp")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(
            counter.value,
            0,
            "identical title/working-directory values must not republish"
        )
    }

    func testColorSchemePublishFromAppKitLifecycleHopsOffViewUpdate() async throws {
        _ = NSApplication.shared
        let state = TerminalViewState()
        let view = AppTerminalView(frame: .zero)
        view.delegate = state
        view.controller = state.controller
        state.adopt(terminalColorScheme: .dark)

        let counter = Counter()
        var cancellables: Set<AnyCancellable> = []
        state.objectWillChange.sink { counter.value += 1 }.store(in: &cancellables)

        view.appearance = NSAppearance(named: .aqua)
        view.viewDidChangeEffectiveAppearance()
        XCTAssertEqual(
            counter.value,
            0,
            "color scheme must not publish synchronously inside a view update"
        )

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(counter.value, 1)
    }
}
