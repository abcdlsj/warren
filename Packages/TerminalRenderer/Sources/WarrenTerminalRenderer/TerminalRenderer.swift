import WarrenDomain
import WarrenProtocol
import WarrenClientCore

/// Actor-safe boundary for terminal rendering. Every operation is async so an
/// implementation can isolate SwiftTerm on its platform actor without making
/// that executor part of the cross-platform API.
public protocol TerminalRenderer: Sendable {
    func createSurface(
        for attachment: TerminalAttachment,
        viewport: TerminalViewport,
        anchor: RecoveryAnchor
    ) async throws -> TerminalSurface

    func render(_ output: BinaryOutputFrame, on surface: TerminalSurface) async throws
    func resize(_ viewport: TerminalViewport, on surface: TerminalSurface) async throws
    func focus(_ focused: Bool, on surface: TerminalSurface) async throws
    func send(_ input: TerminalInputEvent, to surface: TerminalSurface) async throws
    func reanchor(_ anchor: RecoveryAnchor, on surface: TerminalSurface) async throws

    /// Releases only this renderer surface. It must not send a session-kill or
    /// detach command; session ownership remains with Host and its attachment.
    func dispose(_ surface: TerminalSurface) async
}

public extension TerminalRenderer {
    func createSurface(
        for attachment: TerminalAttachment,
        viewport: TerminalViewport
    ) async throws -> TerminalSurface {
        try await createSurface(
            for: attachment,
            viewport: viewport,
            anchor: RecoveryAnchor(epoch: 0, sequence: 0)
        )
    }
}
