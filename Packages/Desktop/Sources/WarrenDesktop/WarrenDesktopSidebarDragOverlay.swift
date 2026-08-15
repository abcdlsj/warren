import AppKit
import SwiftUI
import WarrenDesignSystem
import WarrenDomain

/// Payload format shared between the sidebar drag overlay and the drop
/// handlers in `WarrenDesktopSidebarRows`.
enum WarrenSidebarDragPayload {
    static let projectPrefix = "project:"
    static let workspacePrefix = "workspace:"

    static func project(_ id: ProjectID) -> String {
        projectPrefix + id.description
    }

    static func workspace(_ id: WorkspaceID) -> String {
        workspacePrefix + id.description
    }
}

/// Named coordinate space shared by the row frame preferences and the drag
/// overlay. Rows report frames in this space; the overlay covers the same
/// bounds, so AppKit-local points convert directly to those frames.
enum WarrenSidebarRowsDragCoordinateSpace {
    static let name = "WarrenSidebarRowsDrag"
}

struct WarrenSidebarRowDragFrame: Equatable, Sendable {
    let info: WarrenSidebarRowDragInfo
    let frame: CGRect
}

struct WarrenSidebarRowDragFramesKey: PreferenceKey {
    static let defaultValue: [String: WarrenSidebarRowDragFrame] = [:]

    static func reduce(
        value: inout [String: WarrenSidebarRowDragFrame],
        nextValue: () -> [String: WarrenSidebarRowDragFrame]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Metadata for one sidebar row. Workspace rows carry their containing
/// project so a drop can be validated without cross-view lookups.
struct WarrenSidebarRowDragInfo: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case project(ProjectID)
        case workspace(WorkspaceID, projectID: ProjectID)
    }

    let id: String
    let kind: Kind
    let name: String
    let isLastOfList: Bool

    var projectID: ProjectID {
        switch kind {
        case .project(let projectID):
            return projectID
        case .workspace(_, let projectID):
            return projectID
        }
    }

    var isProjectRow: Bool {
        if case .project = kind { return true }
        return false
    }
}

/// Tracks the Command modifier and the active drag session. The Command state
/// never reaches SwiftUI, so holding Command cannot change layout.
@MainActor
final class WarrenDesktopSidebarDragSession {
    private(set) var commandHeld = false
    private(set) var isActive = false

    private var flagsMonitor: Any?
    private var clients = 0

    func addClient() {
        clients += 1
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.commandHeld = event.modifierFlags.contains(.command)
            return event
        }
    }

    func removeClient() {
        clients = max(0, clients - 1)
        guard clients == 0, let flagsMonitor else { return }
        NSEvent.removeMonitor(flagsMonitor)
        self.flagsMonitor = nil
        commandHeld = false
        isActive = false
    }

    func setActive(_ active: Bool) {
        isActive = active
    }
}

/// A transparent AppKit surface covering the sidebar rows. It only intercepts
/// a left mouse press while Command is held and the press lands on a row, then
/// starts a native drag session. The session's own `movedTo`/`endedAt`
/// callbacks drive the drop highlight and resolve the final row, so the drag
/// works even when AppKit cannot find a SwiftUI-backed drop destination.
struct WarrenDesktopSidebarDragOverlay: NSViewRepresentable {
    let session: WarrenDesktopSidebarDragSession
    let rows: [String: WarrenSidebarRowDragFrame]
    let onDropProject: (String, ProjectID?) -> Bool
    let onDropWorkspace: (String, WorkspaceID?, ProjectID?) -> Bool
    let onProjectDragBegan: () -> Void
    let onProjectDragEnded: () -> Void
    let onDragSourceChanged: (String?) -> Void

    func makeNSView(context: Context) -> WarrenDesktopSidebarDragOverlayView {
        let view = WarrenDesktopSidebarDragOverlayView(session: session)
        view.rows = rows
        view.onDropProject = onDropProject
        view.onDropWorkspace = onDropWorkspace
        view.onProjectDragBegan = onProjectDragBegan
        view.onProjectDragEnded = onProjectDragEnded
        view.onDragSourceChanged = onDragSourceChanged
        return view
    }

    func updateNSView(_ nsView: WarrenDesktopSidebarDragOverlayView, context: Context) {
        nsView.rows = rows
        nsView.onDropProject = onDropProject
        nsView.onDropWorkspace = onDropWorkspace
        nsView.onProjectDragBegan = onProjectDragBegan
        nsView.onProjectDragEnded = onProjectDragEnded
        nsView.onDragSourceChanged = onDragSourceChanged
    }
}

final class WarrenDesktopSidebarDragOverlayView: NSView, NSDraggingSource {
    var rows: [String: WarrenSidebarRowDragFrame] = [:] {
        didSet {
            needsDisplay = true
        }
    }

    var onDropProject: ((String, ProjectID?) -> Bool)?
    var onDropWorkspace: ((String, WorkspaceID?, ProjectID?) -> Bool)?
    var onProjectDragBegan: (() -> Void)?
    var onProjectDragEnded: (() -> Void)?
    var onDragSourceChanged: ((String?) -> Void)?

    private let session: WarrenDesktopSidebarDragSession
    private var highlightRect: NSRect?
    private var attachedToWindow = false
    private var currentPayload: String?
    private var escapePressed = false
    private var escapeMonitor: Any?
    private var suppressClickUntil: Date?

    init(session: WarrenDesktopSidebarDragSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, !attachedToWindow {
            attachedToWindow = true
            session.addClient()
        } else if window == nil, attachedToWindow {
            attachedToWindow = false
            session.removeClient()
        }
    }

    deinit {
        if attachedToWindow {
            MainActor.assumeIsolated {
                session.removeClient()
            }
        }
    }

    // MARK: - Event interception

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if session.isActive {
            return self
        }
        guard session.commandHeld,
              NSApp.currentEvent?.type == .leftMouseDown,
              rowFrame(at: local) != nil
        else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard session.commandHeld, let row = rowFrame(at: point) else {
            super.mouseDown(with: event)
            return
        }
        suppressClickUntil = nil
        onDragSourceChanged?(row.info.id)
        if row.info.isProjectRow {
            onProjectDragBegan?()
        }
        let item = NSDraggingItem(
            pasteboardWriter: NSString(string: Self.payload(for: row.info))
        )
        item.setDraggingFrame(row.frame, contents: snapshotRow(row.frame))
        currentPayload = Self.payload(for: row.info)
        escapePressed = false
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.escapePressed = true
            }
            return event
        }
        session.setActive(true)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if let deadline = suppressClickUntil, Date() < deadline {
            // A drag that ends without a system drop target can re-deliver the
            // mouseUp as a plain click; swallow only that immediate event.
            suppressClickUntil = nil
            return
        }
        super.mouseUp(with: event)
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        if !escapePressed, let payload = currentPayload, let window {
            let local = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
            let zone = dropZone(at: local, payload: payload)
            _ = performDrop(payload, zone: zone)
        }
        onDragSourceChanged?(nil)
        onProjectDragEnded?()
        suppressClickUntil = Date().addingTimeInterval(0.5)
        escapePressed = false
        currentPayload = nil
        self.session.setActive(false)
        clearHighlight()
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard let payload = currentPayload, let window else { return }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let local = convert(windowPoint, from: nil)
        updateHighlight(payload: payload, at: local)
    }

    // MARK: - Drop zones

    private enum DropZone: Equatable {
        case beforeWorkspace(rowID: String, y: CGFloat)
        case beforeProject(rowID: String, y: CGFloat)
        case endOfWorkspaces(projectID: ProjectID, y: CGFloat)
        case endOfProjects(y: CGFloat)

        var insertionY: CGFloat {
            switch self {
            case .beforeWorkspace(_, let y),
                 .beforeProject(_, let y),
                 .endOfWorkspaces(_, let y),
                 .endOfProjects(let y):
                return y
            }
        }
    }

    private func rowFrame(at point: NSPoint) -> WarrenSidebarRowDragFrame? {
        rows.values.first { $0.frame.contains(point) }
    }

    private func dropZone(at point: NSPoint, payload: String) -> DropZone? {
        let ordered = rows.values.sorted { $0.frame.minY < $1.frame.minY }
        guard let first = ordered.first, let last = ordered.last else { return nil }
        guard point.y >= first.frame.minY, point.y <= last.frame.maxY else { return nil }

        let isWorkspacePayload = payload.hasPrefix(WarrenSidebarDragPayload.workspacePrefix)
        var candidates: [DropZone] = []
        for row in ordered {
            if isWorkspacePayload {
                guard !row.info.isProjectRow else { continue }
                candidates.append(.beforeWorkspace(rowID: row.info.id, y: row.frame.minY))
                if row.info.isLastOfList {
                    candidates.append(
                        .endOfWorkspaces(projectID: row.info.projectID, y: row.frame.maxY)
                    )
                }
            } else {
                guard row.info.isProjectRow else { continue }
                candidates.append(.beforeProject(rowID: row.info.id, y: row.frame.minY))
                if row.info.isLastOfList {
                    candidates.append(.endOfProjects(y: row.frame.maxY))
                }
            }
        }
        guard !candidates.isEmpty else { return nil }
        return candidates.min {
            abs($0.insertionY - point.y) < abs($1.insertionY - point.y)
        }
    }

    private func performDrop(_ payload: String, zone: DropZone?) -> Bool {
        guard let zone else { return false }
        if payload.hasPrefix(WarrenSidebarDragPayload.projectPrefix) {
            let sourceID = String(payload.dropFirst(WarrenSidebarDragPayload.projectPrefix.count))
            guard ProjectID(uuidString: sourceID) != nil else { return false }
            switch zone {
            case .beforeProject(let rowID, _):
                guard let projectID = ProjectID(uuidString: rowID) else { return false }
                return onDropProject?(payload, projectID) ?? false
            case .endOfProjects:
                return onDropProject?(payload, nil) ?? false
            case .beforeWorkspace, .endOfWorkspaces:
                return false
            }
        } else {
            let sourceID = String(payload.dropFirst(WarrenSidebarDragPayload.workspacePrefix.count))
            guard WorkspaceID(uuidString: sourceID) != nil else { return false }
            switch zone {
            case .beforeWorkspace(let rowID, _):
                guard let target = WorkspaceID(uuidString: rowID) else {
                    return false
                }
                return onDropWorkspace?(payload, target, nil) ?? false
            case .endOfWorkspaces(let projectID, _):
                return onDropWorkspace?(payload, nil, projectID) ?? false
            case .beforeProject, .endOfProjects:
                return false
            }
        }
    }

    private func updateHighlight(payload: String, at point: NSPoint) {
        let zone = dropZone(at: point, payload: payload)
        let rect = zone.map { insertionRect(for: $0) }
        if highlightRect != rect {
            highlightRect = rect
            needsDisplay = true
        }
    }

    private func clearHighlight() {
        guard highlightRect != nil else { return }
        highlightRect = nil
        needsDisplay = true
    }

    private func insertionRect(for zone: DropZone) -> NSRect {
        let lineHeight: CGFloat = 2.5
        return NSRect(
            x: WarrenSpacing.compact,
            y: zone.insertionY - lineHeight / 2,
            width: max(0, bounds.width - WarrenSpacing.compact * 2),
            height: lineHeight
        )
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let highlightRect else { return }
        let path = NSBezierPath(
            roundedRect: highlightRect,
            xRadius: highlightRect.height / 2,
            yRadius: highlightRect.height / 2
        )
        NSColor.controlAccentColor.setFill()
        path.fill()
    }

    // MARK: - Helpers

    private static func payload(for info: WarrenSidebarRowDragInfo) -> String {
        switch info.kind {
        case .project(let projectID):
            return WarrenSidebarDragPayload.project(projectID)
        case .workspace(let workspaceID, _):
            return WarrenSidebarDragPayload.workspace(workspaceID)
        }
    }

    /// Captures the row exactly as it is rendered on screen, so the drag
    /// preview matches the sidebar UI instead of showing a synthetic chip.
    private func snapshotRow(_ rowFrame: NSRect) -> NSImage? {
        guard let contentView = window?.contentView else { return nil }
        let windowRect = convert(rowFrame, to: nil)
        let viewRect = contentView.convert(windowRect, from: nil)
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: viewRect) else {
            return nil
        }
        contentView.cacheDisplay(in: viewRect, to: rep)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
