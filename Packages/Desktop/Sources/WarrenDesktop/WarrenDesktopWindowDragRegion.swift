#if os(macOS)
import AppKit
import SwiftUI

/// A leaf-only macOS window drag surface.
///
/// Superset marks only empty chrome fillers as draggable. Keeping this as a
/// dedicated view makes it impossible for a terminal, tab, or button subtree
/// to inherit window-drag behavior.
struct WarrenDesktopWindowDragRegion: NSViewRepresentable {
    private let identifier: String?

    init(identifier: String? = nil) {
        self.identifier = identifier
    }

    func makeNSView(context: Context) -> WarrenDesktopWindowDragView {
        let view = WarrenDesktopWindowDragView()
        applyIdentifier(to: view)
        return view
    }

    func updateNSView(_ nsView: WarrenDesktopWindowDragView, context: Context) {
        applyIdentifier(to: nsView)
    }

    private func applyIdentifier(to view: WarrenDesktopWindowDragView) {
        view.identifier = identifier.map(NSUserInterfaceItemIdentifier.init(rawValue:))
    }
}

final class WarrenDesktopWindowDragView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }

    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {}

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            // Match the green traffic light: double-clicking empty chrome
            // toggles Spaces full screen instead of zooming the window.
            window?.toggleFullScreen(nil)
        } else {
            window?.performDrag(with: event)
        }
    }
}
#endif
