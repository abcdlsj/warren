import AppKit
import SwiftUI

enum WarrenDesktopTabActivityDragGesture {
    static let threshold: CGFloat = 5
    static let hitTargetSize = CGSize(width: 22, height: 28)

    static func hasExceededThreshold(from origin: CGPoint, to current: CGPoint) -> Bool {
        hypot(current.x - origin.x, current.y - origin.y) >= threshold
    }
}

enum WarrenDesktopActivityDragPresentation {
    static let previewLabel = "Drag out to dismiss"
    static let previewSize = CGSize(width: 124, height: 24)

    static func isOutside(windowFrame: CGRect, screenPoint: CGPoint) -> Bool {
        !windowFrame.contains(screenPoint)
    }

    static func previewImage() -> NSImage {
        NSImage(size: previewSize, flipped: false) { rect in
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
            NSString(string: previewLabel).draw(
                in: rect.insetBy(dx: 2, dy: 3),
                withAttributes: attributes
            )
            return true
        }
    }
}

/// A native AppKit drag handle for an activity dot. Native dragging sessions
/// continue tracking the pointer after it leaves the Warren window, which is
/// the part SwiftUI's in-window `DragGesture` cannot guarantee.
struct WarrenDesktopTabActivityDragHandle: NSViewRepresentable {
    let onDismiss: () -> Void
    let onClick: () -> Void
    let onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> WarrenDesktopTabActivityDragHandleView {
        let view = WarrenDesktopTabActivityDragHandleView()
        view.onDismiss = onDismiss
        view.onClick = onClick
        view.onHoverChanged = onHoverChanged
        view.toolTip = "Drag outside the window to dismiss activity"
        return view
    }

    func updateNSView(_ nsView: WarrenDesktopTabActivityDragHandleView, context: Context) {
        nsView.onDismiss = onDismiss
        nsView.onClick = onClick
        nsView.onHoverChanged = onHoverChanged
    }
}

final class WarrenDesktopTabActivityDragHandleView: NSView, NSDraggingSource {
    private static let pasteboardType = NSPasteboard.PasteboardType(
        "com.abcdlsj.warren.activity-dismiss"
    )

    var onDismiss: (() -> Void)?
    var onClick: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private weak var dragWindow: NSWindow?
    private var mouseDownPoint: NSPoint?
    private var pendingDismiss: (() -> Void)?
    private var isDragging = false
    private var suppressClickUntil: Date?
    private var hoverTrackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        NSCursor.closedHand.set()
        dragWindow = window
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        suppressClickUntil = nil
        // Freeze the dismissal intent at mouse-down. SwiftUI may update the
        // represented activity while the native drag session is in flight.
        pendingDismiss = onDismiss
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
        if let deadline = suppressClickUntil, Date() < deadline {
            suppressClickUntil = nil
            return
        }
        finishPendingInteraction()
        onClick?()
    }

    private func beginNativeDrag(event: NSEvent) {
        guard dragWindow != nil else { return }
        mouseDownPoint = nil
        isDragging = true

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString("dismiss", forType: Self.pasteboardType)
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let point = convert(event.locationInWindow, from: nil)
        let previewSize = WarrenDesktopActivityDragPresentation.previewSize
        item.setDraggingFrame(
            NSRect(
                x: point.x + 8,
                y: point.y - previewSize.height / 2,
                width: previewSize.width,
                height: previewSize.height
            ),
            contents: WarrenDesktopActivityDragPresentation.previewImage()
        )
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
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
        defer { finishPendingInteraction(suppressClick: true) }
        guard let dragWindow,
              WarrenDesktopActivityDragPresentation.isOutside(
                  windowFrame: dragWindow.frame,
                  screenPoint: screenPoint
              ) else { return }
        pendingDismiss?()
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard let dragWindow else { return }
        let isOutside = WarrenDesktopActivityDragPresentation.isOutside(
            windowFrame: dragWindow.frame,
            screenPoint: screenPoint
        )
        // Inside releases snap the preview back to the dot. Outside releases
        // disappear in place because the activity will be dismissed.
        session.animatesToStartingPositionsOnCancelOrFail = !isOutside
        (isOutside ? NSCursor.disappearingItem : NSCursor.closedHand).set()
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            finishPendingInteraction()
        }
    }

    private func finishPendingInteraction(suppressClick: Bool = false) {
        dragWindow?.invalidateCursorRects(for: self)
        dragWindow = nil
        mouseDownPoint = nil
        pendingDismiss = nil
        suppressClickUntil = suppressClick
            ? Date().addingTimeInterval(0.5)
            : nil
        isDragging = false
    }
}
