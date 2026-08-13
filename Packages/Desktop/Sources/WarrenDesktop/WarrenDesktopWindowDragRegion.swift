#if os(macOS)
import AppKit
import SwiftUI

/// A leaf-only macOS window drag surface.
///
/// Superset marks only empty chrome fillers as draggable. Keeping this as a
/// dedicated view makes it impossible for a terminal, tab, or button subtree
/// to inherit window-drag behavior.
struct WarrenDesktopWindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> WarrenDesktopWindowDragView {
        WarrenDesktopWindowDragView()
    }

    func updateNSView(_ nsView: WarrenDesktopWindowDragView, context: Context) {}
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
        window?.performDrag(with: event)
    }
}
#endif
