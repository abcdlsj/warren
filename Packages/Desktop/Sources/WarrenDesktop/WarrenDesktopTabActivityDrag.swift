import AppKit
import SwiftUI

enum WarrenDesktopTabActivityDragGesture {
    static let threshold: CGFloat = 5

    static func hasExceededThreshold(from origin: CGPoint, to current: CGPoint) -> Bool {
        hypot(current.x - origin.x, current.y - origin.y) >= threshold
    }
}

/// A native AppKit drag handle for an activity dot. Native dragging sessions
/// continue tracking the pointer after it leaves the Warren window, which is
/// the part SwiftUI's in-window `DragGesture` cannot guarantee.
struct WarrenDesktopTabActivityDragHandle: NSViewRepresentable {
    let onDismiss: () -> Void
    let onClick: () -> Void

    func makeNSView(context: Context) -> WarrenDesktopTabActivityDragHandleView {
        let view = WarrenDesktopTabActivityDragHandleView()
        view.onDismiss = onDismiss
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: WarrenDesktopTabActivityDragHandleView, context: Context) {
        nsView.onDismiss = onDismiss
        nsView.onClick = onClick
    }
}

final class WarrenDesktopTabActivityDragHandleView: NSView, NSDraggingSource {
    var onDismiss: (() -> Void)?
    var onClick: (() -> Void)?

    private var dragWindow: NSWindow?
    private var mouseDownPoint: NSPoint?
    private var isDragging = false

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragWindow = window
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard WarrenDesktopTabActivityDragGesture.hasExceededThreshold(
            from: origin,
            to: point
        ) else { return }

        beginNativeDrag(event: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard !isDragging else { return }
        finishPendingInteraction()
        onClick?()
    }

    private func beginNativeDrag(event: NSEvent) {
        guard dragWindow != nil else { return }
        mouseDownPoint = nil
        isDragging = true

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
        defer { finishPendingInteraction() }
        guard let dragWindow,
              !dragWindow.frame.contains(screenPoint) else { return }
        onDismiss?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            finishPendingInteraction()
        }
    }

    private func finishPendingInteraction() {
        dragWindow = nil
        mouseDownPoint = nil
        isDragging = false
    }
}
