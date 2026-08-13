#if os(iOS)
import Foundation
import UIKit
import WarrenClientCore
import WarrenDomain
import WarrenProtocol
import WarrenTerminalRenderer
@preconcurrency import SwiftTerm

/// UIKit renderer for a remote terminal session. It never starts or owns a
/// process; PTY bytes arrive through `render` and input leaves via the sink.
@MainActor
public final class SwiftTermMobileRenderer: TerminalRenderer {
    fileprivate struct Record {
        let surface: TerminalSurface
        let view: TerminalView
        let delegate: SwiftTermMobileRendererDelegate
        var viewport: TerminalViewport
        var outputSequence: TerminalOutputSequence
        var focused = false
    }

    public struct SurfaceState: Hashable, Sendable {
        public let surface: TerminalSurface
        public let viewport: TerminalViewport
        public let expectedAnchor: RecoveryAnchor
        public let needsReanchor: Bool
        public let focused: Bool

        fileprivate init(record: Record) {
            surface = record.surface
            viewport = record.viewport
            expectedAnchor = record.outputSequence.expectedAnchor
            needsReanchor = record.outputSequence.needsReanchor
            focused = record.focused
        }
    }

    private let theme: SwiftTermMobileTheme
    private let font: SwiftTermMobileFont
    private let dispatcher: TerminalSurfaceEventDispatcher
    private var records: [TerminalSurfaceID: Record] = [:]
    private var attachmentToSurface: [TerminalAttachmentID: TerminalSurfaceID] = [:]
    private var disposedIDs: Set<TerminalSurfaceID> = []

    public init(
        eventSink: @escaping @Sendable (TerminalSurfaceEvent) async -> Void = { _ in },
        theme: SwiftTermMobileTheme = .slate,
        font: SwiftTermMobileFont = .systemMono
    ) {
        self.theme = theme
        self.font = font
        dispatcher = TerminalSurfaceEventDispatcher(sink: eventSink)
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
        let view = TerminalView(frame: .zero, font: font.uiFont)
        apply(theme, to: view)
        view.resize(cols: viewport.columns, rows: viewport.rows)
        let delegate = SwiftTermMobileRendererDelegate(
            surfaceID: surface.id,
            dispatcher: dispatcher
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

    public func attach(
        surface: TerminalSurface,
        to container: SwiftTermMobileSurfaceContainer,
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
            await settleEvents()
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
        await settleEvents()
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
        record.view.send(data: Array(data)[...])
        await settleEvents()
    }

    public func reanchor(_ anchor: RecoveryAnchor, on surface: TerminalSurface) async throws {
        var record = try requireRecord(for: surface)
        record.outputSequence.reanchor(anchor)
        records[surface.id] = record
    }

    public func dispose(_ surface: TerminalSurface) async {
        guard let record = records.removeValue(forKey: surface.id) else { return }
        attachmentToSurface.removeValue(forKey: record.surface.attachmentID)
        _ = record.view.resignFirstResponder()
        record.view.terminalDelegate = nil
        record.view.removeFromSuperview()
        disposedIDs.insert(surface.id)
    }

    public func state(for surface: TerminalSurface) -> SurfaceState? {
        guard let record = records[surface.id], record.surface == surface else { return nil }
        return SurfaceState(record: record)
    }

    /// Stops event delivery and releases renderer views without touching Host.
    public func shutdown() {
        dispatcher.cancel()
        records.values.forEach {
            _ = $0.view.resignFirstResponder()
            $0.view.terminalDelegate = nil
            $0.view.removeFromSuperview()
        }
        records.removeAll()
        attachmentToSurface.removeAll()
    }

    func updateSurface(_ surface: TerminalSurface, view: TerminalView, focused: Bool) {
        guard var record = records[surface.id], record.surface == surface, record.view === view else { return }
        record.focused = focused
        records[surface.id] = record
        applyFocus(to: view, focused: focused)
    }

    private func settleEvents() async {
        await Task.yield()
        await dispatcher.drain()
        await Task.yield()
        await dispatcher.drain()
    }

    private func recordResize(surfaceID: TerminalSurfaceID, viewport: TerminalViewport) {
        guard var record = records[surfaceID] else { return }
        record.viewport = viewport
        records[surfaceID] = record
    }

    private func apply(_ theme: SwiftTermMobileTheme, to view: TerminalView) {
        view.nativeBackgroundColor = theme.background
        view.nativeForegroundColor = theme.foreground
        view.caretColor = theme.cursor
        view.selectedTextBackgroundColor = theme.selection
        view.installColors(theme.ansiPalette)
    }

    private func applyFocus(to view: TerminalView, focused: Bool) {
        guard view.window != nil else { return }
        if focused {
            if !view.isFirstResponder { _ = view.becomeFirstResponder() }
        } else if view.isFirstResponder {
            _ = view.resignFirstResponder()
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
#endif
