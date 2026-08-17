import AppKit
import WarrenDomain
import XCTest
@testable import GhosttyAdapter

@MainActor
final class TerminalSurfaceManagerTests: XCTestCase {
    func testManagerParksWarmViewAndReattachesSameNativeSurface() async throws {
        _ = NSApplication.shared
        let manager = TerminalSurfaceManager(warmLimit: 2)
        let first = makeSurface()
        let second = makeSurface()
        manager.insert(first)

        let host = TerminalHostContainerView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer {
            manager.shutdown()
            window.orderOut(nil as Any?)
        }

        submit(first.id, to: manager, host: host)
        XCTAssertTrue(host.subviews.isEmpty, "Submitting intent must not mutate AppKit synchronously")
        XCTAssertNil(first.state.surface, "Submitting intent must not create Ghostty synchronously")
        try await waitUntil { first.state.surface != nil }
        let firstNativeSurface = first.state.surface
        XCTAssertEqual(host.subviews.count, 1)
        XCTAssertTrue(first.mountedTerminalView?.window === window)

        manager.insert(second)
        submit(second.id, to: manager, host: host)
        try await waitUntil { second.state.surface != nil }
        XCTAssertEqual(host.subviews.count, 1)
        XCTAssertNil(first.mountedTerminalView?.window)
        XCTAssertNotNil(first.state.surface)
        XCTAssertEqual(manager.snapshot().warmSessionIDs, [first.id])

        submit(first.id, to: manager, host: host)
        try await waitUntil { first.mountedTerminalView?.window === window }
        XCTAssertTrue(first.state.surface === firstNativeSurface)
        XCTAssertEqual(host.subviews.count, 1)
        XCTAssertEqual(manager.snapshot().activeSessionID, first.id)
    }

    func testManagerEvictsLeastRecentlyUsedWarmSurface() async throws {
        _ = NSApplication.shared
        let manager = TerminalSurfaceManager(warmLimit: 1)
        let surfaces = (0..<3).map { _ in makeSurface() }

        let host = TerminalHostContainerView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer {
            manager.shutdown()
            window.orderOut(nil as Any?)
        }

        for surface in surfaces {
            manager.insert(surface)
            submit(surface.id, to: manager, host: host)
            try await waitUntil { manager.snapshot().activeSessionID == surface.id }
        }

        XCTAssertNil(manager.surface(for: surfaces[0].id))
        XCTAssertNotNil(manager.surface(for: surfaces[1].id))
        XCTAssertNotNil(manager.surface(for: surfaces[2].id))
        XCTAssertEqual(manager.snapshot().retainedSurfaceCount, 2)
        XCTAssertEqual(manager.snapshot().surfaceDisposalCount, 1)
    }

    func testManagerMaintainsSingleHostAcrossFiveHundredSwitches() {
        _ = NSApplication.shared
        let manager = TerminalSurfaceManager(warmLimit: 1)
        let first = makeSurface()
        let second = makeSurface()
        manager.insert(first)
        let host = TerminalHostContainerView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer {
            manager.shutdown()
            window.orderOut(nil as Any?)
        }

        submit(first.id, to: manager, host: host)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        manager.insert(second)
        submit(second.id, to: manager, host: host)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        for index in 0..<500 {
            let sessionID = index.isMultiple(of: 2) ? first.id : second.id
            submit(sessionID, to: manager, host: host)
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            XCTAssertLessThanOrEqual(host.subviews.count, 1)
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let snapshot = manager.snapshot()
        XCTAssertEqual(snapshot.activeSessionID, second.id)
        XCTAssertEqual(snapshot.retainedSurfaceCount, 2)
        XCTAssertEqual(host.subviews.count, 1)
        XCTAssertEqual(snapshot.hiddenRenderAttemptCount, 0)
    }

    private func makeSurface() -> GhosttySurface {
        GhosttySurface(
            id: TerminalSessionID(),
            attachmentID: TerminalAttachmentID(),
            workingDirectory: "/tmp",
            onInput: { _ in },
            onResize: { _, _ in }
        )
    }

    private func submit(
        _ sessionID: TerminalSessionID,
        to manager: TerminalSurfaceManager,
        host: TerminalHostContainerView
    ) {
        manager.submit(
            host: host,
            intent: TerminalPresentationIntent(
                activeSessionID: sessionID,
                viewportSize: host.bounds.size,
                wantsTerminalFocus: false
            ),
            onFocused: { _, _ in },
            onBlurred: { _ in }
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard condition() else {
            struct Timeout: Error {}
            throw Timeout()
        }
    }
}
