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
        manager.insert(second)

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
        try await waitUntil { first.state.surface != nil }
        let firstNativeSurface = first.state.surface
        XCTAssertEqual(host.subviews.count, 1)
        XCTAssertTrue(first.mountedTerminalView?.window === window)

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
        surfaces.forEach(manager.insert)

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
            submit(surface.id, to: manager, host: host)
            try await waitUntil { manager.snapshot().activeSessionID == surface.id }
        }

        XCTAssertNil(manager.surface(for: surfaces[0].id))
        XCTAssertNotNil(manager.surface(for: surfaces[1].id))
        XCTAssertNotNil(manager.surface(for: surfaces[2].id))
        XCTAssertEqual(manager.snapshot().retainedSurfaceCount, 2)
        XCTAssertEqual(manager.snapshot().surfaceDisposalCount, 1)
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
