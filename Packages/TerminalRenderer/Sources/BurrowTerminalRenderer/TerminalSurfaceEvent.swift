import Foundation

/// Events emitted by a platform terminal surface toward ClientCore.
///
/// The surface only reports user input and emulator metadata. Session
/// ownership, transport, and control leases remain outside the renderer.
public enum TerminalSurfaceEvent: Hashable, Sendable {
    case input(surface: TerminalSurfaceID, data: Data)
    case title(surface: TerminalSurfaceID, title: String)
    case resize(surface: TerminalSurfaceID, viewport: TerminalViewport)
}

