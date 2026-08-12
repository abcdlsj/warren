import Foundation
import BurrowTerminalRenderer
@preconcurrency import SwiftTerm

@MainActor
final class SwiftTermRendererDelegate: NSObject, @preconcurrency TerminalViewDelegate {
    let surfaceID: TerminalSurfaceID
    private let dispatcher: TerminalSurfaceEventDispatcher
    private let didResize: (TerminalViewport) -> Void
    private var lastViewport: TerminalViewport?

    init(
        surfaceID: TerminalSurfaceID,
        dispatcher: TerminalSurfaceEventDispatcher,
        initialViewport: TerminalViewport? = nil,
        didResize: @escaping (TerminalViewport) -> Void
    ) {
        self.surfaceID = surfaceID
        self.dispatcher = dispatcher
        self.lastViewport = initialViewport
        self.didResize = didResize
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let viewport = TerminalViewport(columns: newCols, rows: newRows) else { return }
        // AppKit can report the same terminal size several times while a
        // window settles its constraints.  A resize is a user intent, not a
        // frame tick; suppress duplicate callbacks before they cross the
        // async event boundary.
        guard lastViewport != viewport else { return }
        lastViewport = viewport
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
}
