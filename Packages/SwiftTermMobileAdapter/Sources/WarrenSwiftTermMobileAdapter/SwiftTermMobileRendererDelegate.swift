#if os(iOS)
import Foundation
import WarrenTerminalRenderer
@preconcurrency import SwiftTerm

@MainActor
final class SwiftTermMobileRendererDelegate: NSObject, @preconcurrency TerminalViewDelegate {
    private let surfaceID: TerminalSurfaceID
    private let dispatcher: TerminalSurfaceEventDispatcher
    private let didResize: (TerminalViewport) -> Void

    init(
        surfaceID: TerminalSurfaceID,
        dispatcher: TerminalSurfaceEventDispatcher,
        didResize: @escaping (TerminalViewport) -> Void
    ) {
        self.surfaceID = surfaceID
        self.dispatcher = dispatcher
        self.didResize = didResize
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let viewport = TerminalViewport(columns: newCols, rows: newRows) else { return }
        didResize(viewport)
        dispatcher.enqueue(.resize(surface: surfaceID, viewport: viewport))
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        dispatcher.enqueue(.title(surface: surfaceID, title: title))
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        dispatcher.enqueue(.input(surface: surfaceID, data: Data(data)))
    }

    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
#endif

