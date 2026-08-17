import AppKit
import GhosttyKit
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

    func testPresentRequestBeforeActivationIsRetainedByLifecycleTransition() async throws {
        _ = NSApplication.shared
        let manager = TerminalSurfaceManager(warmLimit: 1)
        let surface = makeSurface()
        manager.insert(surface)

        manager.requestPresent(surface.id)
        XCTAssertEqual(manager.snapshot().hiddenRenderAttemptCount, 0)

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

        submit(surface.id, to: manager, host: host)
        try await waitUntil {
            manager.snapshot().activeSessionID == surface.id
                && surface.terminalViewIsPresentable
        }

        XCTAssertNotNil(surface.state.surface)
        XCTAssertEqual(manager.snapshot().hiddenRenderAttemptCount, 0)
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

    func testReattachResyncsViewportToLiveBottom() async throws {
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
        try await waitUntil {
            first.state.surface != nil && first.terminalViewIsPresentable
        }
        let raw = try XCTUnwrap(first.state.surface?.rawValue)

        first.receive(makeLines(start: 0, count: 2000))
        try await Task.sleep(for: .milliseconds(200))
        _ = "scroll_to_row:1000".withCString { pointer in
            ghostty_surface_binding_action(raw, pointer, UInt("scroll_to_row:1000".utf8.count))
        }
        try await waitForViewport(on: first, containing: "line-1000")
        let pinned = try viewportText(on: first)
        XCTAssertFalse(pinned.contains("line-1999"), "pinned viewport must not already be at bottom")

        manager.insert(second)
        submit(second.id, to: manager, host: host)
        try await waitUntil { manager.snapshot().activeSessionID == second.id }

        submit(first.id, to: manager, host: host)
        try await waitUntil {
            manager.snapshot().activeSessionID == first.id && first.terminalViewIsPresentable
        }
        do {
            try await waitForViewport(on: first, containing: "line-1999")
        } catch {
            let text = try viewportText(on: first)
            print("REATTACHED_VIEWPORT=\(text.prefix(300))")
            throw error
        }
    }

    private func makeLines(start: Int, count: Int) -> Data {
        var data = Data()
        for index in start..<(start + count) {
            data.append(Data("line-\(String(format: "%04d", index))\n".utf8))
        }
        return data
    }

    private func viewportText(on surface: GhosttySurface) throws -> String {
        guard let raw = surface.state.surface?.rawValue else {
            struct NoSurface: Error {}
            throw NoSurface()
        }
        let topLeft = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        let selection = ghostty_selection_s(
            top_left: topLeft,
            bottom_right: bottomRight,
            rectangle: false
        )
        var out = ghostty_text_s()
        guard ghostty_surface_read_text(raw, selection, &out) else {
            struct ReadFailed: Error {}
            throw ReadFailed()
        }
        defer { ghostty_surface_free_text(raw, &out) }
        guard let text = out.text, out.text_len > 0 else { return "" }
        let bytes = UnsafeBufferPointer(start: text, count: Int(out.text_len))
            .map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func waitForViewport(
        on surface: GhosttySurface,
        containing needle: String,
        timeout: TimeInterval = 10
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if try viewportText(on: surface).contains(needle) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        struct Timeout: Error {}
        throw Timeout()
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
