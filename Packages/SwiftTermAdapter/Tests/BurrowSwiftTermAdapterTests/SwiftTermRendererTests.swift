import Foundation
import XCTest
@testable import BurrowSwiftTermAdapter
import BurrowClientCore
import BurrowDomain
import BurrowProtocol
import BurrowTerminalRenderer

actor EventCollector {
    private var storage: [TerminalSurfaceEvent] = []

    func append(_ event: TerminalSurfaceEvent) { storage.append(event) }
    func events() -> [TerminalSurfaceEvent] { storage }
}

@MainActor
final class SwiftTermRendererTests: XCTestCase {
    func testEmberThemeMatchesSupersetDefaultTerminalColors() throws {
        let theme = SwiftTermTheme.ember
        try assertColor(theme.background, red: 0x15, green: 0x11, blue: 0x10, alpha: 1)
        try assertColor(theme.foreground, red: 0xea, green: 0xe8, blue: 0xe6, alpha: 1)
        try assertColor(theme.cursor, red: 0xe0, green: 0x78, blue: 0x50, alpha: 1)
        try assertColor(theme.selection, red: 0xe0, green: 0x78, blue: 0x50, alpha: 0.25)
        XCTAssertEqual(theme.ansiPalette.count, 16)
        XCTAssertEqual(SwiftTermFont.systemMono.size, 14)
    }

    func testInputEventsAreEncodedAndDeliveredInOrder() async throws {
        let collector = EventCollector()
        let renderer = SwiftTermRenderer(eventSink: { event in await collector.append(event) })
        let sessionID = TerminalSessionID()
        let surface = try await renderer.createSurface(
            for: TerminalAttachment(sessionID: sessionID, clientID: ClientID()),
            viewport: XCTUnwrap(TerminalViewport(columns: 80, rows: 24)),
            anchor: RecoveryAnchor(epoch: 1, sequence: 0)
        )

        try await renderer.send(.text("ok"), to: surface)
        try await renderer.send(.control("c"), to: surface)
        try await renderer.send(.arrow(.up), to: surface)

        let events = await collector.events()
        XCTAssertEqual(
            events,
            [
                .input(surface: surface.id, data: Data([0x6f, 0x6b])),
                .input(surface: surface.id, data: Data([0x03])),
                .input(surface: surface.id, data: Data([0x1b, 0x5b, 0x41])),
            ]
        )
    }

    func testOutputFeedsRemoteTerminalAndRejectsOutOfOrderFrames() async throws {
        let renderer = SwiftTermRenderer()
        let sessionID = TerminalSessionID()
        let surface = try await renderer.createSurface(
            for: TerminalAttachment(sessionID: sessionID, clientID: ClientID()),
            viewport: XCTUnwrap(TerminalViewport(columns: 80, rows: 24)),
            anchor: RecoveryAnchor(epoch: 2, sequence: 0)
        )

        try await renderer.render(frame(sessionID: sessionID, epoch: 2, sequence: 0, bytes: [65]), on: surface)
        XCTAssertEqual(renderer.state(for: surface)?.expectedAnchor, RecoveryAnchor(epoch: 2, sequence: 1))

        do {
            try await renderer.render(frame(sessionID: sessionID, epoch: 2, sequence: 2, bytes: [66]), on: surface)
            XCTFail("out-of-order frame must be rejected")
        } catch {
            XCTAssertEqual(error as? TerminalRendererError, .outputOutOfOrder(expected: 1, received: 2))
        }
        XCTAssertTrue(renderer.state(for: surface)?.needsReanchor == true)
    }

    func testTitleAndResizeAreAsyncEvents() async throws {
        let collector = EventCollector()
        let renderer = SwiftTermRenderer(eventSink: { event in await collector.append(event) })
        let sessionID = TerminalSessionID()
        let surface = try await renderer.createSurface(
            for: TerminalAttachment(sessionID: sessionID, clientID: ClientID()),
            viewport: XCTUnwrap(TerminalViewport(columns: 80, rows: 24)),
            anchor: RecoveryAnchor(epoch: 0, sequence: 0)
        )
        try await renderer.render(frame(sessionID: sessionID, epoch: 0, sequence: 0,
                                        bytes: [0x1b, 0x5d, 0x30, 0x3b, 0x44, 0x65, 0x6e, 0x07]), on: surface)
        try await renderer.resize(XCTUnwrap(TerminalViewport(columns: 100, rows: 30)), on: surface)

        let events = await collector.events()
        XCTAssertEqual(events.first, .title(surface: surface.id, title: "Den"))
        let resizedViewport = try XCTUnwrap(TerminalViewport(columns: 100, rows: 30))
        XCTAssertEqual(events.last, .resize(surface: surface.id, viewport: resizedViewport))
    }

    func testDisposeRemovesOnlySurface() async throws {
        let renderer = SwiftTermRenderer()
        let sessionID = TerminalSessionID()
        let attachment = TerminalAttachment(sessionID: sessionID, clientID: ClientID())
        let surface = try await renderer.createSurface(
            for: attachment,
            viewport: XCTUnwrap(TerminalViewport(columns: 80, rows: 24)),
            anchor: RecoveryAnchor(epoch: 3, sequence: 4)
        )

        XCTAssertNotNil(renderer.view(for: surface))
        await renderer.dispose(surface)
        XCTAssertNil(renderer.view(for: surface))
        XCTAssertEqual(surface.sessionID, sessionID)
        do {
            try await renderer.send(.text("stale"), to: surface)
            XCTFail("disposed surface must reject input")
        } catch {
            XCTAssertEqual(error as? TerminalRendererError, .surfaceDisposed(surface.id))
        }
    }

    func testSwiftUIContainerDetachesAfterSurfaceDispose() async throws {
        let renderer = SwiftTermRenderer()
        let sessionID = TerminalSessionID()
        let surface = try await renderer.createSurface(
            for: TerminalAttachment(sessionID: sessionID, clientID: ClientID()),
            viewport: XCTUnwrap(TerminalViewport(columns: 80, rows: 24)),
            anchor: RecoveryAnchor(epoch: 0, sequence: 0)
        )
        let container = SwiftTermSurfaceContainer()
        renderer.attach(surface: surface, to: container, focused: true)
        XCTAssertNotNil(container.attachedTerminalView)
        XCTAssertTrue(renderer.state(for: surface)?.focused == true)
        renderer.attach(surface: surface, to: container, focused: false)
        XCTAssertFalse(renderer.state(for: surface)?.focused == true)

        await renderer.dispose(surface)
        renderer.attach(surface: surface, to: container)
        XCTAssertNil(container.attachedTerminalView)
    }

    func testRepeatedSwiftUIUpdateDoesNotStealFocusAndClickReclaimsIt() async throws {
        let renderer = SwiftTermRenderer()
        let sessionID = TerminalSessionID()
        let surface = try await renderer.createSurface(
            for: TerminalAttachment(sessionID: sessionID, clientID: ClientID()),
            viewport: XCTUnwrap(TerminalViewport(columns: 80, rows: 24)),
            anchor: RecoveryAnchor(epoch: 0, sequence: 0)
        )
        let container = SwiftTermSurfaceContainer(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let otherControl = FocusableTestView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        container.addSubview(otherControl)
        let window = NSWindow(
            contentRect: container.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        renderer.attach(surface: surface, to: container, focused: true)
        container.layoutSubtreeIfNeeded()
        let terminal = try XCTUnwrap(container.attachedTerminalView)

        XCTAssertTrue(window.makeFirstResponder(otherControl))
        renderer.attach(surface: surface, to: container, focused: true)
        XCTAssertTrue(window.firstResponder === otherControl)

        let recognizer = try XCTUnwrap(
            terminal.gestureRecognizers.compactMap { $0 as? NSClickGestureRecognizer }.first
        )
        XCTAssertFalse(recognizer.delaysPrimaryMouseButtonEvents)
        XCTAssertTrue(container.focusTerminal())
        XCTAssertTrue(window.firstResponder === terminal)
    }

    func testTerminalMouseDragSelectsTextAndCopyUsesTheSelection() async throws {
        let renderer = SwiftTermRenderer()
        let sessionID = TerminalSessionID()
        let surface = try await renderer.createSurface(
            for: TerminalAttachment(sessionID: sessionID, clientID: ClientID()),
            viewport: XCTUnwrap(TerminalViewport(columns: 80, rows: 24)),
            anchor: RecoveryAnchor(epoch: 0, sequence: 0)
        )
        let container = SwiftTermSurfaceContainer(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let window = NSWindow(
            contentRect: container.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        renderer.attach(surface: surface, to: container, focused: true)
        container.layoutSubtreeIfNeeded()
        let terminal = try XCTUnwrap(container.attachedTerminalView)

        try await renderer.render(
            frame(sessionID: sessionID, epoch: 0, sequence: 0, bytes: Array("hello".utf8)),
            on: surface
        )

        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 4, y: terminal.bounds.maxY - 4),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1
        ))
        let dragStart = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 4, y: terminal.bounds.maxY - 4),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 3,
            clickCount: 1,
            pressure: 1
        ))
        let dragEnd = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 5 * 10, y: terminal.bounds.maxY - 4),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.015,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 4,
            clickCount: 1,
            pressure: 1
        ))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 5 * 10, y: terminal.bounds.maxY - 4),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.02,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 5,
            clickCount: 1,
            pressure: 1
        ))

        // Drive the complete mouse sequence through SwiftTerm. The window
        // configuration separately disables background dragging, so AppKit
        // cannot steal this sequence while it crosses terminal cells.
        window.isMovableByWindowBackground = false
        terminal.mouseDown(with: down)
        terminal.mouseDragged(with: dragStart)
        terminal.mouseDragged(with: dragEnd)
        terminal.mouseUp(with: up)

        XCTAssertEqual(terminal.getSelection(), "hello")

        let pasteboard = NSPasteboard.general
        let previousClipboard = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let previousClipboard {
                pasteboard.setString(previousClipboard, forType: .string)
            }
        }
        terminal.copy(terminal)
        XCTAssertEqual(pasteboard.string(forType: .string), "hello")
    }

    func testCompletedDelegateInputsDoNotAccumulateTasks() async throws {
        let collector = EventCollector()
        let surfaceID = TerminalSurfaceID()
        let dispatcher = TerminalSurfaceEventDispatcher(sink: { event in await collector.append(event) })

        for byte in UInt8(ascii: "a")...UInt8(ascii: "f") {
            dispatcher.enqueue(.input(surface: surfaceID, data: Data([byte])))
        }
        await dispatcher.drain()

        let pendingValue = Mirror(reflecting: dispatcher).children
            .first { $0.label == "pending" }?.value
        let pendingCount = pendingValue.map { Mirror(reflecting: $0).children.count }
        XCTAssertEqual(pendingCount, 0)
        let events = await collector.events()
        XCTAssertEqual(
            events.compactMap { event in
                if case .input(_, let data) = event { return data }
                return nil
            },
            [Data([97]), Data([98]), Data([99]), Data([100]), Data([101]), Data([102])]
        )
    }

    private func frame(
        sessionID: TerminalSessionID,
        epoch: UInt64,
        sequence: UInt64,
        bytes: [UInt8]
    ) -> BinaryOutputFrame {
        let header = BinaryOutputFrameHeader(
            sessionID: sessionID,
            epoch: epoch,
            sequence: sequence,
            payloadLength: bytes.count
        )!
        return BinaryOutputFrame(header: header, payload: Data(bytes))
    }

    private func assertColor(
        _ color: NSColor,
        red: Int,
        green: Int,
        blue: Int,
        alpha: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let resolved = try XCTUnwrap(color.usingColorSpace(.sRGB), file: file, line: line)
        XCTAssertEqual(resolved.redComponent, CGFloat(red) / 255, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(resolved.greenComponent, CGFloat(green) / 255, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(resolved.blueComponent, CGFloat(blue) / 255, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(resolved.alphaComponent, alpha, accuracy: 0.001, file: file, line: line)
    }
}

private final class FocusableTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
