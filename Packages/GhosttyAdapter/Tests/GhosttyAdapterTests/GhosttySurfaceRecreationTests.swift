import AppKit
import GhosttyTerminal
import SwiftUI
import WarrenDomain
import XCTest
@testable import GhosttyAdapter

/// Reproduces the desktop "empty workspace -> populated workspace" path at the
/// component level: the terminal view is removed from the hierarchy entirely,
/// then re-added. Ghostty must rebuild its native surface on re-entry instead
/// of leaving the pane blank.
@MainActor
final class GhosttySurfaceRecreationTests: XCTestCase {
    private final class HostModel: ObservableObject {
        @Published var showSurface = true
    }

    private struct RecreatedHost: View {
        @ObservedObject var model: HostModel
        let surface: GhosttySurface
        let focusDriver: GhosttyFocusDriver

        var body: some View {
            ZStack {
                if model.showSurface {
                    GhosttyManagedSurface(
                        surface: surface,
                        isActive: true,
                        focusDriver: focusDriver,
                        viewportSize: CGSize(width: 800, height: 600)
                    )
                } else {
                    Color.black
                }
            }
            .frame(width: 800, height: 600)
        }
    }

    func testSurfaceRebuildsAfterViewRemovedAndReadded() async throws {
        _ = NSApplication.shared
        let surface = GhosttySurface(
            id: TerminalSessionID(),
            attachmentID: TerminalAttachmentID(),
            workingDirectory: "/tmp",
            onInput: { _ in },
            onResize: { _, _ in }
        )
        let model = HostModel()
        let focusDriver = GhosttyFocusDriver()
        let hostingView = NSHostingView(
            rootView: RecreatedHost(
                model: model,
                surface: surface,
                focusDriver: focusDriver
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil as Any?) }

        try await waitUntil(timeout: 5) { surface.state.surface != nil }
        XCTAssertTrue(surface.presentNow())

        model.showSurface = false
        hostingView.layoutSubtreeIfNeeded()
        try await waitUntil(timeout: 3) { surface.state.surface == nil }

        model.showSurface = true
        hostingView.layoutSubtreeIfNeeded()
        try await waitUntil(timeout: 5) { surface.state.surface != nil }
        XCTAssertTrue(
            surface.presentNow(),
            "A recreated view must rebuild its Ghostty surface before presenting"
        )
    }

    private func waitUntil(
        timeout: TimeInterval,
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
