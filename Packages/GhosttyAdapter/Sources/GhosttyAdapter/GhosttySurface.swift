import Foundation
import GhosttyKit
import GhosttyTerminal
import WarrenDomain
import WarrenTerminalRenderer

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
    /// Background output feed shared by the local and remote render paths.
    /// Immutable and thread-safe; scroll events stay on the main thread while
    /// Ghostty's ANSI parsing happens off it.
    public let outputWriter: WarrenGhosttyOutputWriter
    private let onViewportResize: @Sendable (Int, Int) -> Void
    private let ansiObserver = TerminalANSIObserver()
    private let reflowGate: ReflowGate
    private var settleWorkItem: DispatchWorkItem?

    public init(
        id: TerminalSessionID,
        attachmentID: TerminalAttachmentID,
        workingDirectory: String,
        font: TerminalFontPreference = .init(),
        outputRenderBudgetBytes: Int = 128 * 1024,
        outputRenderYield: Duration = .milliseconds(8),
        onInput: @escaping @Sendable (Data) -> Void,
        onResize: @escaping @Sendable (Int, Int) -> Void
    ) {
        self.id = id
        self.attachmentID = attachmentID
        self.onViewportResize = onResize
        let reflowGate = ReflowGate()
        self.reflowGate = reflowGate

        let inMemory = InMemoryTerminalSession(
            write: onInput,
            resize: { viewport in
                guard !reflowGate.isReflowing else { return }
                onResize(Int(viewport.columns), Int(viewport.rows))
            }
        )
        let outputWriter = WarrenGhosttyOutputWriter(
            inMemory: inMemory,
            ansiObserver: ansiObserver,
            budgetBytes: outputRenderBudgetBytes,
            yield: outputRenderYield
        )
        self.inMemory = inMemory
        self.outputWriter = outputWriter

        let theme = TerminalTheme(
            dark: TerminalConfiguration { builder in
                builder.withBackground("#151110")
                builder.withForeground("#eae8e6")
                builder.withCursorColor("#e07850")
                builder.withCursorText("#151110")
                // Ghostty colors carry no alpha; blend Superset's 25% orange
                // selection over #151110 instead of using its rgba() value.
                builder.withSelectionBackground("#482b20")
                builder.withCursorStyle(.block)
                builder.withCursorStyleBlink(true)
                for (index, color) in TerminalPalette.ember.enumerated() {
                    builder.withPalette(index, color: Self.hex(color))
                }
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

        // A reanchor snapshot is fed in bounded background chunks. Ghostty
        // requests a frame after each write, but a frame can land while the
        // grid is only partially replayed and stay on screen until the next
        // real resize. Once the queue has fully drained, request one final
        // renderer-thread frame so the settled snapshot is presented.
        outputWriter.setOnDrained { [weak self] in
            Task { @MainActor [weak self] in
                self?.presentSettledOutput()
            }
        }
    }

    public func markRendered(epoch: UInt64, sequence: UInt64) {
        outputWriter.markRendered(epoch: epoch, sequence: sequence)
    }

    public var renderedEpoch: UInt64 {
        outputWriter.renderedEpoch
    }

    public var renderedSequence: UInt64 {
        outputWriter.renderedSequence
    }

    public func receive(_ payload: Data) {
        outputWriter.receive(payload)
    }

    /// Requests an immediate Ghostty app tick so pending state (including a
    /// freshly attached snapshot) is processed without waiting for the next
    /// resize or keystroke.
    ///
    /// This deliberately does not call `ghostty_surface_refresh`: host output
    /// is written in bounded background chunks, and an arbitrary main-thread
    /// refresh can ask the renderer to draw while the grid is only partially
    /// updated. Ghostty's own render request (fired after each write and
    /// coalesced through the display link) paints a consistent grid instead.
    public func requestDisplayRefresh() {
        state.controller.tick()
    }

    /// Re-entry repaint for a surface whose AppKit view is being recreated or
    /// reattached (tab switch, settings dismissal). App tick only; rendering
    /// stays on Ghostty's write-completion path so the grid is never sampled
    /// mid-update.
    public func refreshAfterReentry() {
        requestDisplayRefresh()
    }

    /// Forces the settled grid to reflow after the output queue drains.
    ///
    /// Ghostty's BCE handling corrupts soft-wrapped colored history when a
    /// reanchor snapshot is replayed into a fresh surface: the background
    /// color active at a wrap point bleeds past later SGR resets, and neither
    /// `ghostty_surface_refresh` nor an inline draw clears it. A transient
    /// pixel resize forces Ghostty to reflow the grid, which does clear the
    /// corrupted rows. Debounce one wider-then-restore resize after the queue
    /// settles; resize callbacks are gated so tmux never sees the transient
    /// geometry.
    public func presentSettledOutput() {
        settleWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  let raw = self.state.surface?.rawValue,
                  let size = self.state.surfaceSize else { return }
            self.reflowGate.begin()
            let wider = size.widthPixels + max(32, size.cellWidthPixels * 2)
            ghostty_surface_set_size(raw, wider, size.heightPixels)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self,
                      let raw = self.state.surface?.rawValue else {
                    self?.reflowGate.end()
                    return
                }
                ghostty_surface_set_size(raw, size.widthPixels, size.heightPixels)
                self.reflowGate.end()
                self.state.controller.tick()
                ghostty_surface_refresh(raw)
            }
        }
        settleWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.15,
            execute: workItem
        )
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
            builder.withCustom("copy-on-select", "true")
            builder.withCustom("search-foreground", "#eae8e6")
            builder.withCustom("search-background", "#3a3837")
            builder.withCustom("search-selected-foreground", "#151110")
            builder.withCustom("search-selected-background", "#e07850")
            builder.withWindowPaddingX(0)
            builder.withWindowPaddingY(0)
            // Ghostty's macOS app doubles precise trackpad deltas before they
            // reach the C API; libghostty-swift forwards raw pixels instead.
            // Compensate in the core so scroll pacing matches standalone
            // Ghostty instead of feeling half-speed and slightly choppy.
            builder.withCustom("mouse-scroll-multiplier", "precision:2")
            builder.withCustom("keybind", "super+t=unbind")
            builder.withCustom("keybind", "super+w=unbind")
            builder.withCustom("keybind", "super+x=unbind")
            builder.withCustom("keybind", "super+k=unbind")
            builder.withCustom("keybind", "super+b=unbind")
            builder.withCustom("keybind", "super+q=unbind")
            // ⌘1…⌘9 are Warren's tab shortcuts, but Ghostty defaults them to
            // goto_tab/last_tab. Unbind both the character and physical-key
            // forms; recent Ghostty versions keep consuming the physical form
            // unless both are removed.
            for index in 1...9 {
                builder.withCustom("keybind", "super+\(index)=unbind")
                builder.withCustom("keybind", "super+digit_\(index)=unbind")
            }
        }
    }

    private static func hex(_ color: TerminalPaletteColor) -> String {
        String(
            format: "#%02x%02x%02x",
            color.red,
            color.green,
            color.blue
        )
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

public enum TerminalSearchDirection: Sendable {
    case next
    case previous
}

/// Gates Ghostty's resize callbacks while a settled-output reflow is in
/// flight. The transient wider/restore resize must never reach tmux: only the
/// original viewport is real.
private final class ReflowGate: @unchecked Sendable {
    private let lock = NSLock()
    private var reflowing = false

    var isReflowing: Bool {
        lock.withLock { reflowing }
    }

    func begin() {
        lock.withLock { reflowing = true }
    }

    func end() {
        lock.withLock { reflowing = false }
    }
}

public extension GhosttySurface {
    /// Starts (or replaces) a scrollback search inside Ghostty. An empty
    /// query stops the current search, matching Ghostty's `search:` action.
    func search(for query: String) {
        guard !query.isEmpty else {
            endSearch()
            return
        }
        _ = performBindingAction("search:\(query)")
    }

    func navigateSearch(_ direction: TerminalSearchDirection) {
        switch direction {
        case .next: _ = performBindingAction("navigate_search:next")
        case .previous: _ = performBindingAction("navigate_search:previous")
        }
    }

    func endSearch() {
        _ = performBindingAction("end_search")
    }

    /// Current selection text, used to prefill the find box (⌘F with a
    /// selection behaves like Ghostty's "search selection").
    func readSelection() -> String? {
        guard let raw = state.surface?.rawValue else { return nil }
        var out = ghostty_text_s()
        guard ghostty_surface_read_selection(raw, &out) else { return nil }
        defer { ghostty_surface_free_text(raw, &out) }
        guard let text = out.text, out.text_len > 0 else { return nil }
        let bytes = UnsafeBufferPointer(start: text, count: Int(out.text_len))
            .map { UInt8(bitPattern: $0) }
        let value = String(decoding: bytes, as: UTF8.self)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    private func performBindingAction(_ action: String) -> Bool {
        guard let raw = state.surface?.rawValue else { return false }
        return action.withCString { pointer in
            ghostty_surface_binding_action(raw, pointer, UInt(action.utf8.count))
        }
    }
}
