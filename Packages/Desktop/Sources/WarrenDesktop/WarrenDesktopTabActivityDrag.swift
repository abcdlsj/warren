import AppKit
import SwiftUI

/// A native AppKit drag handle for an activity dot. Native dragging sessions
/// continue tracking the pointer after it leaves the Warren window, which is
/// the part SwiftUI's in-window `DragGesture` cannot guarantee.
struct WarrenDesktopTabActivityDragHandle: NSViewRepresentable {
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> WarrenDesktopTabActivityDragHandleView {
        let view = WarrenDesktopTabActivityDragHandleView()
        view.onDismiss = onDismiss
        return view
    }

    func updateNSView(_ nsView: WarrenDesktopTabActivityDragHandleView, context: Context) {
        nsView.onDismiss = onDismiss
    }
}

final class WarrenDesktopTabActivityDragHandleView: NSView, NSDraggingSource {
    var onDismiss: (() -> Void)?

    private var dragWindow: NSWindow?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragWindow = window

        let item = NSDraggingItem(
            pasteboardWriter: NSString(string: "warren.activity.dismiss")
        )
        item.setDraggingFrame(bounds, contents: nil)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .delete
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        defer { dragWindow = nil }
        guard let dragWindow,
              !dragWindow.frame.contains(screenPoint) else { return }
        onDismiss?()
    }
}
