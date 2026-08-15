import Foundation
import GhosttyTerminal
import WarrenDomain

@_exported import GhosttyTerminal

/// One Ghostty terminal surface backed by Warren's Host output stream.
///
/// The terminal process itself remains owned by tmux/Host; Ghostty only
/// renders the PTY byte stream and forwards input/resize back to Warren. This is
/// the same in-memory shape Termio uses for its companion/status architecture.
@MainActor
public final class GhosttySurface: Identifiable, ObservableObject {
    /// Matches the 1.12 line-height used by the Web terminal while keeping
    /// Ghostty's cell grid authoritative for tmux resize calculations.
    private static let defaultCellHeightAdjustment = "12%"

    public let id: TerminalSessionID
    public let attachmentID: TerminalAttachmentID
    public let state: TerminalViewState
    public let inMemory: InMemoryTerminalSession
    private let onViewportResize: @Sendable (Int, Int) -> Void
    private let ansiObserver = TerminalANSIObserver()
    public private(set) var renderedSequence: UInt64
    public private(set) var renderedEpoch: UInt64

    public init(
        id: TerminalSessionID,
        attachmentID: TerminalAttachmentID,
        workingDirectory: String,
        font: TerminalFontPreference = .init(),
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
        let controller = TerminalController(theme: theme) { _ in }
        controller.setTerminalConfiguration(Self.makeConfiguration(font: font))
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
        ansiObserver.receive(payload)
        inMemory.receive(payload)
    }

    public func apply(font: TerminalFontPreference) {
        _ = state.controller.setTerminalConfiguration(Self.makeConfiguration(font: font))
    }

    /// Terminal chrome that Warren owns as app-level shortcuts. Ghostty's
    /// default bindings for these keys would consume them while the surface is
    /// the first responder, so each one is explicitly unbound.
    private static func makeConfiguration(
        font: TerminalFontPreference
    ) -> TerminalConfiguration {
        TerminalConfiguration { builder in
            builder.withBackgroundOpacity(1)
            builder.withFontFamily(font.family)
            builder.withFontSize(Float(font.size))
            builder.withFontThicken(false)
            builder.withCustom("adjust-cell-height", Self.defaultCellHeightAdjustment)
            builder.withWindowPaddingX(0)
            builder.withWindowPaddingY(0)
            builder.withCustom("keybind", "super+t=unbind")
            builder.withCustom("keybind", "super+w=unbind")
            builder.withCustom("keybind", "super+x=unbind")
            builder.withCustom("keybind", "super+k=unbind")
            builder.withCustom("keybind", "super+b=unbind")
            builder.withCustom("keybind", "super+q=unbind")
        }
    }

    public func semanticSnapshot() -> TerminalSemanticSnapshot {
        ansiObserver.snapshot()
    }

    /// Re-submit Ghostty's current grid even when the renderer's pixel size
    /// has not changed. libghostty intentionally suppresses duplicate metric
    /// callbacks, while Warren must calibrate a newly adopted or re-selected
    /// tmux runtime that may not match the persisted last-requested size.
    public func synchronizeViewport() {
        guard let size = state.surfaceSize else { return }
        onViewportResize(Int(size.columns), Int(size.rows))
    }

    public var view: TerminalSurfaceView {
        TerminalSurfaceView(context: state)
    }
}
