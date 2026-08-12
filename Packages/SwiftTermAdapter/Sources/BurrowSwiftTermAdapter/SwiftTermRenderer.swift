import AppKit
import Foundation
import BurrowClientCore
import BurrowDomain
import BurrowProtocol
import BurrowTerminalRenderer
@preconcurrency import SwiftTerm

@MainActor
public final class SwiftTermRenderer: TerminalRenderer {
    private struct Record {
        let surface: TerminalSurface
        let view: TerminalView
        let delegate: SwiftTermRendererDelegate
        var viewport: TerminalViewport
        var outputSequence: TerminalOutputSequence
        var focused = false
    }

    private let theme: SwiftTermTheme
    private let font: SwiftTermFont
    private let dispatcher: TerminalSurfaceEventDispatcher
    private var records: [TerminalSurfaceID: Record] = [:]
    private var attachmentToSurface: [TerminalAttachmentID: TerminalSurfaceID] = [:]
    private var disposedIDs: Set<TerminalSurfaceID> = []

    public init(
        eventSink: @escaping @Sendable (TerminalSurfaceEvent) async -> Void = { _ in },
        theme: SwiftTermTheme = .ember,
        font: SwiftTermFont = .systemMono
    ) {
        self.theme = theme
        self.font = font
        self.dispatcher = TerminalSurfaceEventDispatcher(sink: eventSink)
    }

    public func createSurface(
        for attachment: TerminalAttachment,
        viewport: TerminalViewport,
        anchor: RecoveryAnchor
    ) async throws -> TerminalSurface {
        guard attachmentToSurface[attachment.id] == nil else {
            throw TerminalRendererError.surfaceAlreadyExists(attachment.id)
        }
        let surface = TerminalSurface(attachment: attachment)
        let view = TerminalView(frame: .zero, font: font.nsFont)
        apply(theme, to: view)
        view.resize(cols: viewport.columns, rows: viewport.rows)
        let delegate = SwiftTermRendererDelegate(
            surfaceID: surface.id,
            dispatcher: dispatcher,
            initialViewport: viewport
        ) { [weak self] newViewport in
            self?.recordResize(surfaceID: surface.id, viewport: newViewport)
        }
        view.terminalDelegate = delegate
        records[surface.id] = Record(
            surface: surface,
            view: view,
            delegate: delegate,
            viewport: viewport,
            outputSequence: TerminalOutputSequence(anchor: anchor)
        )
        attachmentToSurface[attachment.id] = surface.id
        return surface
    }

    public func view(for surface: TerminalSurface) -> TerminalView? {
        guard let record = records[surface.id], record.surface == surface else { return nil }
        return record.view
    }
    /// Attaches a live surface to a stable SwiftUI container. A disposed
    /// surface leaves the container empty.
    public func attach(
        surface: TerminalSurface,
        to container: SwiftTermSurfaceContainer,
        focused: Bool = false
    ) {
        container.apply(renderer: self, surface: surface, focused: focused)
    }

    public func render(_ output: BinaryOutputFrame, on surface: TerminalSurface) async throws {
        var record = try requireRecord(for: surface)
        do {
            let payload = try record.outputSequence.accept(
                output,
                sessionID: surface.sessionID,
                surfaceID: surface.id
            )
            records[surface.id] = record
            record.view.feed(byteArray: Array(payload)[...])
            await dispatcher.drain()
        } catch {
            records[surface.id] = record
            throw error
        }
    }
    public func resize(_ viewport: TerminalViewport, on surface: TerminalSurface) async throws {
        var record = try requireRecord(for: surface)
        guard record.viewport != viewport else { return }
        record.viewport = viewport
        records[surface.id] = record
        record.view.resize(cols: viewport.columns, rows: viewport.rows)
        await dispatcher.drain()
    }
    public func focus(_ focused: Bool, on surface: TerminalSurface) async throws {
        var record = try requireRecord(for: surface)
        record.focused = focused
        records[surface.id] = record
        applyFocus(to: record.view, focused: focused)
    }
    public func send(_ input: TerminalInputEvent, to surface: TerminalSurface) async throws {
        let record = try requireRecord(for: surface)
        let data: Data
        do {
            data = try input.encodedData()
        } catch let error as TerminalInputEncodingError {
            throw TerminalRendererError.inputEncoding(error)
        }
        let bytes = Array(data)
        record.view.send(data: bytes[...])
        await dispatcher.drain()
    }
    public func reanchor(_ anchor: RecoveryAnchor, on surface: TerminalSurface) async throws {
        var record = try requireRecord(for: surface)
        record.outputSequence.reanchor(anchor)
        records[surface.id] = record
    }
    public func dispose(_ surface: TerminalSurface) async {
        guard let record = records.removeValue(forKey: surface.id) else { return }
        attachmentToSurface.removeValue(forKey: record.surface.attachmentID)
        record.view.terminalDelegate = nil
        record.view.removeFromSuperview()
        disposedIDs.insert(surface.id)
    }
    public func state(for surface: TerminalSurface) -> SurfaceState? {
        guard let record = records[surface.id], record.surface == surface else { return nil }
        return SurfaceState(
            surface: record.surface,
            viewport: record.viewport,
            expectedAnchor: record.outputSequence.expectedAnchor,
            needsReanchor: record.outputSequence.needsReanchor,
            focused: record.focused
        )
    }

    /// Cancels pending event delivery and removes all renderer surfaces. This
    /// does not send detach or kill commands to the Host session.
    public func shutdown() {
        dispatcher.cancel()
        for record in records.values {
            record.view.terminalDelegate = nil
            record.view.removeFromSuperview()
        }
        records.removeAll()
        attachmentToSurface.removeAll()
    }

    func updateSurface(
        _ surface: TerminalSurface,
        view: TerminalView,
        focused: Bool,
        requestFocus: Bool = false
    ) {
        guard var record = records[surface.id], record.surface == surface, record.view === view else { return }
        let focusChanged = record.focused != focused
        if focusChanged {
            record.focused = focused
            records[surface.id] = record
        }
        // `updateNSView` can run for unrelated projection changes. Reasserting
        // first responder on every update steals focus from other controls.
        // Focus only when the active state changes or the view enters a window.
        if focusChanged || (requestFocus && focused) {
            applyFocus(to: view, focused: focused)
        }
    }

    private func recordResize(surfaceID: TerminalSurfaceID, viewport: TerminalViewport) {
        guard var record = records[surfaceID] else { return }
        record.viewport = viewport
        records[surfaceID] = record
    }

    private func apply(_ theme: SwiftTermTheme, to view: TerminalView) {
        view.nativeBackgroundColor = theme.background
        view.nativeForegroundColor = theme.foreground
        view.caretColor = theme.cursor
        view.selectedTextBackgroundColor = theme.selection
        view.installColors(theme.ansiPalette)
    }

    private func applyFocus(to view: TerminalView, focused: Bool) {
        if focused {
            view.window?.makeFirstResponder(view)
        } else if view.window?.firstResponder === view {
            view.window?.makeFirstResponder(nil)
        }
    }

    private func requireRecord(for surface: TerminalSurface) throws -> Record {
        guard let record = records[surface.id] else {
            if disposedIDs.contains(surface.id) {
                throw TerminalRendererError.surfaceDisposed(surface.id)
            }
            throw TerminalRendererError.unknownSurface(surface.id)
        }
        guard record.surface == surface else {
            throw TerminalRendererError.surfaceBindingMismatch(surface.id)
        }
        return record
    }
}
