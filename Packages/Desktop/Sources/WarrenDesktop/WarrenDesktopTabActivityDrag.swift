import AppKit
import SwiftUI

enum WarrenDesktopTabActivityDragGesture {
    static let hitTargetSize = CGSize(width: 22, height: 28)
}

enum WarrenDesktopActivityDragPresentation {
    static func isOutside(windowFrame: CGRect, screenPoint: CGPoint) -> Bool {
        !windowFrame.contains(screenPoint)
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
    private var pendingDismiss: (() -> Void)?
    private var pendingClick: (() -> Void)?
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
        suppressClickUntil = nil
        // Freeze the dismissal intent at mouse-down. SwiftUI may update the
        // represented activity while the native drag session is in flight.
        pendingDismiss = onDismiss
        pendingClick = onClick
        beginNativeDrag(event: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard !isDragging else { return }
        if let deadline = suppressClickUntil, Date() < deadline {
            suppressClickUntil = nil
            return
        }
        let click = pendingClick
        finishPendingInteraction()
        click?()
    }

    private func beginNativeDrag(event: NSEvent) {
        guard dragWindow != nil else { return }
        isDragging = true

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString("dismiss", forType: Self.pasteboardType)
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        item.setDraggingFrame(bounds, contents: nil)
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
        guard let dragWindow else {
            finishPendingInteraction(suppressClick: true)
            return
        }
        let isOutside = WarrenDesktopActivityDragPresentation.isOutside(
            windowFrame: dragWindow.frame,
            screenPoint: screenPoint
        )
        let action = isOutside ? pendingDismiss : pendingClick
        finishPendingInteraction(suppressClick: true)
        action?()
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard let dragWindow else { return }
        let isOutside = WarrenDesktopActivityDragPresentation.isOutside(
            windowFrame: dragWindow.frame,
            screenPoint: screenPoint
        )
        // Inside releases stay in place. Outside releases use the disappearing
        // cursor because the activity will be dismissed.
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
        pendingDismiss = nil
        pendingClick = nil
        suppressClickUntil = suppressClick
            ? Date().addingTimeInterval(0.5)
            : nil
        isDragging = false
    }
}
