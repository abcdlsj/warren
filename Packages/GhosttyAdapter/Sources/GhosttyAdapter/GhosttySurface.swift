import Foundation
import GhosttyTerminal
import BurrowDomain

@_exported import GhosttyTerminal

/// One Ghostty terminal surface backed by Burrow's Host output stream.
///
/// The terminal process itself remains owned by tmux/Host; Ghostty only
/// renders the PTY byte stream and forwards input/resize back to Burrow. This is
/// the same in-memory shape Termio uses for its companion/status architecture.
@MainActor
public final class GhosttySurface: Identifiable, ObservableObject {
    public let id: TerminalSessionID
    public let attachmentID: TerminalAttachmentID
    public let state: TerminalViewState
    public let inMemory: InMemoryTerminalSession
    private let onViewportResize: @Sendable (Int, Int) -> Void
    public private(set) var renderedSequence: UInt64
    public private(set) var renderedEpoch: UInt64

    public init(
        id: TerminalSessionID,
        attachmentID: TerminalAttachmentID,
        workingDirectory: String,
        onInput: @escaping @Sendable (Data) -> Void,
        onResize: @escaping @Sendable (Int, Int) -> Void
    ) {
        self.id = id
        self.attachmentID = attachmentID
        self.onViewportResize = onResize
        renderedSequence = 0
        renderedEpoch = 0

        let inMemory = InMemoryTerminalSession(
            write: onInput,
            resize: { viewport in
                onResize(Int(viewport.columns), Int(viewport.rows))
            }
        )
        self.inMemory = inMemory

        let theme = TerminalTheme(
            dark: TerminalConfiguration { builder in
                builder.withBackground("#151110")
                builder.withForeground("#eae8e6")
                builder.withSelectionBackground("#3a3837")
                builder.withCursorColor("#e07850")
                builder.withCursorStyle(.block)
                builder.withCursorStyleBlink(true)
            }
        )
        let controller = TerminalController(theme: theme) { builder in
            builder.withBackgroundOpacity(1)
            builder.withFontFamily("monospace")
            builder.withFontSize(13)
            builder.withWindowPaddingX(0)
            builder.withWindowPaddingY(0)
        }
        let state = TerminalViewState(controller: controller)
        state.configuration = TerminalSurfaceOptions(
            backend: .inMemory(inMemory),
            workingDirectory: workingDirectory
        )
        self.state = state
    }

    public func markRendered(epoch: UInt64, sequence: UInt64) {
        renderedEpoch = epoch
        renderedSequence = sequence
    }

    public func receive(_ payload: Data) {
        inMemory.receive(payload)
    }

    /// Re-submit Ghostty's current grid even when the renderer's pixel size
    /// has not changed. libghostty intentionally suppresses duplicate metric
    /// callbacks, while Burrow must calibrate a newly adopted or re-selected
    /// tmux runtime that may not match the persisted last-requested size.
    public func synchronizeViewport() {
        guard let size = state.surfaceSize else { return }
        onViewportResize(Int(size.columns), Int(size.rows))
    }

    public var view: TerminalSurfaceView {
        TerminalSurfaceView(context: state)
    }
}
