#if os(iOS)
import Foundation
import XCTest
@testable import WarrenSwiftTermMobileAdapter
import WarrenClientCore
import WarrenDomain
import WarrenProtocol
import WarrenTerminalRenderer

private actor MobileEventCollector {
    private var storage: [TerminalSurfaceEvent] = []

    func append(_ event: TerminalSurfaceEvent) { storage.append(event) }

    func events() -> [TerminalSurfaceEvent] { storage }

    func wait(
        until predicate: @escaping @Sendable ([TerminalSurfaceEvent]) -> Bool,
        timeout: Duration = .seconds(2)
    ) async throws -> [TerminalSurfaceEvent] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if predicate(storage) { return storage }
            try Task.checkCancellation()
            guard clock.now < deadline else { throw EventWaitTimeout() }
            try await clock.sleep(for: .milliseconds(5))
        }
    }
}

private struct EventWaitTimeout: Error {}

@MainActor
final class SwiftTermMobileRendererTests: XCTestCase {
    func testRemoteOutputFeedsViewInByteOrder() async throws {
        let renderer = SwiftTermMobileRenderer()
        let sessionID = TerminalSessionID()
        let surface = try await renderer.createSurface(
            for: TerminalAttachment(sessionID: sessionID, clientID: ClientID()),
            viewport: try XCTUnwrap(TerminalViewport(columns: 80, rows: 24)),
            anchor: RecoveryAnchor(epoch: 2, sequence: 0)
        )

        try await renderer.render(frame(sessionID, epoch: 2, sequence: 0, bytes: [65]), on: surface)
        XCTAssertEqual(renderer.state(for: surface)?.expectedAnchor, RecoveryAnchor(epoch: 2, sequence: 1))

        do {
            try await renderer.render(frame(sessionID, epoch: 2, sequence: 3, bytes: [66]), on: surface)
            XCTFail("Out-of-order output must require reanchor")
        } catch {
            XCTAssertEqual(error as? TerminalRendererError, .outputOutOfOrder(expected: 1, received: 3))
        }
        XCTAssertTrue(renderer.state(for: surface)?.needsReanchor == true)
    }

    func testTerminalViewDelegateForwardsInputInOrder() async throws {
        let collector = MobileEventCollector()
        let renderer = SwiftTermMobileRenderer(eventSink: { event in await collector.append(event) })
        let sessionID = TerminalSessionID()
        let surface = try await renderer.createSurface(
            for: TerminalAttachment(sessionID: sessionID, clientID: ClientID()),
            viewport: try XCTUnwrap(TerminalViewport(columns: 80, rows: 24)),
            anchor: RecoveryAnchor(epoch: 0, sequence: 0)
        )

        // `send` enters SwiftTerm's real TerminalView and is delivered through
        // TerminalViewDelegate.send, rather than injecting an adapter event.
        try await renderer.send(.text("ios"), to: surface)
        try await renderer.send(.arrow(.right), to: surface)

        let events = try await collector.wait { events in
            events.filter { event in
                if case .input(let id, _) = event { return id == surface.id }
                return false
            }.count >= 2
        }
        let inputEvents = events.filter { event in
            if case .input(let id, _) = event { return id == surface.id }
            return false
        }
        XCTAssertEqual(
            inputEvents,
            [
                .input(surface: surface.id, data: Data([105, 111, 115])),
                .input(surface: surface.id, data: Data([0x1B, 0x5B, 0x43])),
            ]
        )
        XCTAssertTrue(events.contains { event in
            if case .resize(let id, _) = event { return id == surface.id }
            return false
        })
    }

    func testTitleAndResizeAreForwarded() async throws {
        let collector = MobileEventCollector()
        let renderer = SwiftTermMobileRenderer(eventSink: { event in await collector.append(event) })
        let sessionID = TerminalSessionID()
        let surface = try await renderer.createSurface(
            for: TerminalAttachment(sessionID: sessionID, clientID: ClientID()),
            viewport: try XCTUnwrap(TerminalViewport(columns: 80, rows: 24)),
            anchor: RecoveryAnchor(epoch: 0, sequence: 0)
        )

        try await renderer.render(
            frame(sessionID, epoch: 0, sequence: 0,
                  bytes: [0x1B, 0x5D, 0x30, 0x3B, 68, 101, 110, 7]),
            on: surface
        )
        let viewport = try XCTUnwrap(TerminalViewport(columns: 100, rows: 30))
        try await renderer.resize(viewport, on: surface)

        let events = try await collector.wait { events in
            let hasTitle = events.contains { event in
                event == .title(surface: surface.id, title: "Warren")
            }
            let hasResize = events.contains { event in
                event == .resize(surface: surface.id, viewport: viewport)
            }
            return hasTitle && hasResize
        }
        let titleIndex = events.firstIndex {
            $0 == .title(surface: surface.id, title: "Warren")
        }
        let resizeIndex = events.firstIndex {
            $0 == .resize(surface: surface.id, viewport: viewport)
        }
        XCTAssertNotNil(titleIndex)
        XCTAssertNotNil(resizeIndex)
    }

    func testContainerDetachesWithoutDisposingSurface() async throws {
        let renderer = SwiftTermMobileRenderer()
        let sessionID = TerminalSessionID()
        let surface = try await renderer.createSurface(
            for: TerminalAttachment(sessionID: sessionID, clientID: ClientID()),
            viewport: try XCTUnwrap(TerminalViewport(columns: 80, rows: 24)),
            anchor: RecoveryAnchor(epoch: 1, sequence: 4)
        )
        let container = SwiftTermMobileSurfaceContainer()
        renderer.attach(surface: surface, to: container, focused: true)
        XCTAssertNotNil(container.attachedTerminalView)
        XCTAssertTrue(renderer.state(for: surface)?.focused == true)

        container.detach()
        XCTAssertNil(container.attachedTerminalView)
        XCTAssertNotNil(renderer.view(for: surface))
        XCTAssertFalse(renderer.state(for: surface)?.focused == true)

        await renderer.dispose(surface)
        renderer.attach(surface: surface, to: container)
        XCTAssertNil(container.attachedTerminalView)
    }

    func testDispatcherReleasesCompletedTasks() async {
        let collector = MobileEventCollector()
        let dispatcher = TerminalSurfaceEventDispatcher(sink: { event in await collector.append(event) })
        let surface = TerminalSurfaceID()
        for byte in UInt8(ascii: "a")...UInt8(ascii: "f") {
            dispatcher.enqueue(.input(surface: surface, data: Data([byte])))
        }
        await dispatcher.drain()

        let pending = Mirror(reflecting: dispatcher).children
            .first { $0.label == "pending" }?.value
        XCTAssertEqual(pending.map { Mirror(reflecting: $0).children.count }, 0)
    }

    private func frame(
        _ sessionID: TerminalSessionID,
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
}
#endif
