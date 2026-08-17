import AppKit
import SwiftUI
import WarrenDomain

public enum TerminalSurfaceResidency: String, Equatable, Sendable {
    case active
    case warm
    case cold
}

public struct TerminalSurfaceRetentionPolicy: Equatable, Sendable {
    public let warmLimit: Int
    public private(set) var activeSessionID: TerminalSessionID?
    public private(set) var warmSessionIDs: [TerminalSessionID] = []

    public init(warmLimit: Int = 2) {
        self.warmLimit = max(0, warmLimit)
    }

    @discardableResult
    public mutating func activate(_ sessionID: TerminalSessionID) -> [TerminalSessionID] {
        if let previous = activeSessionID, previous != sessionID {
            warmSessionIDs.removeAll { $0 == previous }
            warmSessionIDs.insert(previous, at: 0)
        }
        warmSessionIDs.removeAll { $0 == sessionID }
        activeSessionID = sessionID
        return trimWarmSessions()
    }

    @discardableResult
    public mutating func deactivate() -> [TerminalSessionID] {
        if let activeSessionID {
            warmSessionIDs.removeAll { $0 == activeSessionID }
            warmSessionIDs.insert(activeSessionID, at: 0)
        }
        activeSessionID = nil
        return trimWarmSessions()
    }

    public mutating func remove(_ sessionID: TerminalSessionID) {
        if activeSessionID == sessionID {
            activeSessionID = nil
        }
        warmSessionIDs.removeAll { $0 == sessionID }
    }

    public func residency(of sessionID: TerminalSessionID) -> TerminalSurfaceResidency {
        if activeSessionID == sessionID { return .active }
        if warmSessionIDs.contains(sessionID) { return .warm }
        return .cold
    }

    private mutating func trimWarmSessions() -> [TerminalSessionID] {
        guard warmSessionIDs.count > warmLimit else { return [] }
        let evicted = Array(warmSessionIDs.dropFirst(warmLimit))
        warmSessionIDs.removeLast(warmSessionIDs.count - warmLimit)
        return evicted
    }
}

public struct TerminalPresentationIntent: Equatable, Sendable {
    public let activeSessionID: TerminalSessionID?
    public let viewportSize: CGSize
    public let wantsTerminalFocus: Bool

    public init(
        activeSessionID: TerminalSessionID?,
        viewportSize: CGSize,
        wantsTerminalFocus: Bool
    ) {
        self.activeSessionID = activeSessionID
        self.viewportSize = viewportSize
        self.wantsTerminalFocus = wantsTerminalFocus
    }
}

public struct TerminalSurfaceManagerSnapshot: Equatable, Sendable {
    public let activeSessionID: TerminalSessionID?
    public let warmSessionIDs: [TerminalSessionID]
    public let retainedSurfaceCount: Int
    public let transitionGeneration: UInt64
    public let staleCommandCancellationCount: UInt64
    public let surfaceCreationCount: UInt64
    public let surfaceDisposalCount: UInt64
    public let hiddenRenderAttemptCount: UInt64
}

/// The only owner of AppKit terminal views and Ghostty presentation work.
///
/// SwiftUI submits immutable intent. Reconciliation runs on a later main-loop
/// turn, outside `body`, `layout`, and `updateNSView` call stacks.
@MainActor
public final class TerminalSurfaceManager {
    private final class Entry {
        let surface: GhosttySurface
        let view: AppTerminalView
        var transitionGeneration: UInt64 = 0

        init(surface: GhosttySurface, view: AppTerminalView) {
            self.surface = surface
            self.view = view
        }
    }

    private var entries: [TerminalSessionID: Entry] = [:]
    private var policy: TerminalSurfaceRetentionPolicy
    private weak var host: TerminalHostContainerView?
    private var latestIntent = TerminalPresentationIntent(
        activeSessionID: nil,
        viewportSize: .zero,
        wantsTerminalFocus: false
    )
    private var reconcileScheduled = false
    private var transitionGeneration: UInt64 = 0
    private var staleCommandCancellationCount: UInt64 = 0
    private var surfaceCreationCount: UInt64 = 0
    private var surfaceDisposalCount: UInt64 = 0
    private var hiddenRenderAttemptCount: UInt64 = 0
    private var windowObservers: [NSObjectProtocol] = []
    private var onFocused: (TerminalSessionID, TerminalSize?) -> Void = { _, _ in }
    private var onBlurred: (TerminalSessionID) -> Void = { _ in }

    public init(warmLimit: Int = 2) {
        policy = TerminalSurfaceRetentionPolicy(warmLimit: warmLimit)
    }

    public var retainedSurfaceCount: Int { entries.count }

    public func surface(for sessionID: TerminalSessionID) -> GhosttySurface? {
        entries[sessionID]?.surface
    }

    public func insert(_ surface: GhosttySurface) {
        guard entries[surface.id] == nil else { return }
        let view = AppTerminalView(frame: .zero)
        view.delegate = surface.state
        view.controller = surface.state.controller
        view.configuration = surface.state.configuration
        view.setSurfaceVisible(false)
        view.isHidden = true
        surface.mountedTerminalView = view
        entries[surface.id] = Entry(surface: surface, view: view)
        surfaceCreationCount &+= 1
        scheduleReconciliation()
    }

    public func remove(_ sessionID: TerminalSessionID) {
        policy.remove(sessionID)
        dispose(sessionID)
    }

    public func removeAll(except liveSessionIDs: Set<TerminalSessionID>) {
        for sessionID in Array(entries.keys) where !liveSessionIDs.contains(sessionID) {
            policy.remove(sessionID)
            dispose(sessionID)
        }
    }

    public func shutdown() {
        transitionGeneration &+= 1
        removeWindowObservers()
        for sessionID in Array(entries.keys) {
            policy.remove(sessionID)
            dispose(sessionID)
        }
        host = nil
        latestIntent = TerminalPresentationIntent(
            activeSessionID: nil,
            viewportSize: .zero,
            wantsTerminalFocus: false
        )
    }

    public func apply(font: TerminalFontPreference) {
        entries.values.forEach { $0.surface.apply(font: font) }
    }

    public func submit(
        host: TerminalHostContainerView,
        intent: TerminalPresentationIntent,
        onFocused: @escaping (TerminalSessionID, TerminalSize?) -> Void,
        onBlurred: @escaping (TerminalSessionID) -> Void
    ) {
        let needsReconciliation = self.host !== host || latestIntent != intent
        self.host = host
        host.manager = self
        latestIntent = intent
        self.onFocused = onFocused
        self.onBlurred = onBlurred
        if needsReconciliation {
            scheduleReconciliation()
        }
    }

    public func disconnect(host: TerminalHostContainerView) {
        guard self.host === host else { return }
        transitionGeneration &+= 1
        if let activeSessionID = policy.activeSessionID {
            demote(activeSessionID)
        }
        let evicted = policy.deactivate()
        evicted.forEach(dispose)
        removeWindowObservers()
        self.host = nil
    }

    public func hostDidLayout(_ host: TerminalHostContainerView, size: CGSize) {
        guard self.host === host, latestIntent.viewportSize != size else { return }
        latestIntent = TerminalPresentationIntent(
            activeSessionID: latestIntent.activeSessionID,
            viewportSize: size,
            wantsTerminalFocus: latestIntent.wantsTerminalFocus
        )
        scheduleReconciliation()
    }

    public func requestFocusForActiveSurface() {
        guard let sessionID = policy.activeSessionID else { return }
        focus(sessionID, generation: transitionGeneration)
    }

    public func requestPresent(_ sessionID: TerminalSessionID) {
        guard policy.activeSessionID == sessionID,
              let entry = entries[sessionID] else {
            hiddenRenderAttemptCount &+= 1
            return
        }
        schedulePresent(entry, generation: entry.transitionGeneration)
    }

    public func enqueueRawOutput(_ data: Data, for sessionID: TerminalSessionID) {
        guard let entry = entries[sessionID] else { return }
        entry.surface.outputWriter.enqueueRaw(data)
    }

    public func endSearch(in sessionID: TerminalSessionID) {
        entries[sessionID]?.surface.endSearch()
    }

    public func endAllSearches() {
        entries.values.forEach { $0.surface.endSearch() }
    }

    public func snapshot() -> TerminalSurfaceManagerSnapshot {
        TerminalSurfaceManagerSnapshot(
            activeSessionID: policy.activeSessionID,
            warmSessionIDs: policy.warmSessionIDs,
            retainedSurfaceCount: entries.count,
            transitionGeneration: transitionGeneration,
            staleCommandCancellationCount: staleCommandCancellationCount,
            surfaceCreationCount: surfaceCreationCount,
            surfaceDisposalCount: surfaceDisposalCount,
            hiddenRenderAttemptCount: hiddenRenderAttemptCount
        )
    }

    private func scheduleReconciliation() {
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            reconcileScheduled = false
            reconcile()
        }
    }

    private func reconcile() {
        transitionGeneration &+= 1
        let generation = transitionGeneration
        let nextSessionID = latestIntent.activeSessionID
        let previousSessionID = policy.activeSessionID

        if previousSessionID != nextSessionID, let previousSessionID {
            demote(previousSessionID)
        }

        let evicted: [TerminalSessionID]
        if let nextSessionID, entries[nextSessionID] != nil {
            evicted = policy.activate(nextSessionID)
        } else {
            evicted = policy.deactivate()
        }
        evicted.forEach(dispose)

        guard let nextSessionID,
              let entry = entries[nextSessionID],
              let host else { return }
        entry.transitionGeneration = generation
        attach(entry, sessionID: nextSessionID, to: host, generation: generation)
    }

    private func attach(
        _ entry: Entry,
        sessionID: TerminalSessionID,
        to host: TerminalHostContainerView,
        generation: UInt64
    ) {
        let viewport = sanitizedViewport(latestIntent.viewportSize, fallback: host.bounds.size)
        entry.view.setSurfaceVisible(false)
        entry.view.isHidden = true
        if entry.view.superview !== host {
            entry.view.removeFromSuperview()
            entry.view.frame = CGRect(origin: .zero, size: viewport)
            host.addSubview(entry.view)
        } else if entry.view.frame.size != viewport {
            entry.view.setFrameSize(viewport)
        }

        installWindowObservers(for: host.window)
        DispatchQueue.main.async { [weak self, weak host, weak entry] in
            guard let self, let host, let entry,
                  isCurrent(
                      sessionID,
                      entry: entry,
                      host: host,
                      generation: generation,
                      requiresVisibleView: false
                  )
            else {
                self?.staleCommandCancellationCount &+= 1
                return
            }
            entry.view.isHidden = false
            entry.view.setSurfaceVisible(true)
            entry.view.fitToSize()
            schedulePresent(entry, generation: generation)
            if latestIntent.wantsTerminalFocus {
                focus(sessionID, generation: generation)
            }
        }
    }

    private func demote(_ sessionID: TerminalSessionID) {
        guard let entry = entries[sessionID] else { return }
        entry.transitionGeneration &+= 1
        if entry.view.window?.firstResponder === entry.view {
            entry.view.window?.makeFirstResponder(nil)
        }
        entry.view.setSurfaceVisible(false)
        entry.view.isHidden = true
        entry.view.removeFromSuperview()
        onBlurred(sessionID)
    }

    private func dispose(_ sessionID: TerminalSessionID) {
        guard let entry = entries.removeValue(forKey: sessionID) else { return }
        entry.transitionGeneration &+= 1
        if entry.view.window?.firstResponder === entry.view {
            entry.view.window?.makeFirstResponder(nil)
        }
        entry.view.setSurfaceVisible(false)
        entry.view.isHidden = true
        entry.view.removeFromSuperview()
        entry.surface.mountedTerminalView = nil
        entry.surface.outputWriter.shutdown()
        surfaceDisposalCount &+= 1
    }

    private func focus(_ sessionID: TerminalSessionID, generation: UInt64) {
        guard let host,
              let window = host.window,
              let entry = entries[sessionID],
              isCurrent(sessionID, entry: entry, host: host, generation: generation),
              window.isKeyWindow else { return }
        guard window.firstResponder === entry.view || window.makeFirstResponder(entry.view) else {
            return
        }
        let size = entry.surface.state.surfaceSize.flatMap {
            TerminalSize(columns: Int($0.columns), rows: Int($0.rows))
        }
        onFocused(sessionID, size)
    }

    private func schedulePresent(_ entry: Entry, generation: UInt64) {
        let sessionID = entry.surface.id
        Task { @MainActor [weak self, weak entry] in
            guard let self, let entry else { return }
            let targetSequence = entry.surface.outputWriter.enqueuedSequence
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while entry.surface.outputWriter.renderedSequence < targetSequence,
                  ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(16))
                guard isCurrent(
                    sessionID,
                    entry: entry,
                    host: host,
                    generation: generation
                ) else {
                    staleCommandCancellationCount &+= 1
                    return
                }
            }
            guard isCurrent(
                sessionID,
                entry: entry,
                host: host,
                generation: generation
            ) else {
                staleCommandCancellationCount &+= 1
                return
            }
            entry.surface.requestDisplayRefresh()
            _ = entry.surface.presentNow()
        }
    }

    private func installWindowObservers(for window: NSWindow?) {
        removeWindowObservers()
        guard let window else { return }
        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, latestIntent.wantsTerminalFocus else { return }
                requestFocusForActiveSurface()
            }
        })
        windowObservers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let sessionID = policy.activeSessionID else { return }
                onBlurred(sessionID)
            }
        })
    }

    private func removeWindowObservers() {
        let center = NotificationCenter.default
        windowObservers.forEach(center.removeObserver)
        windowObservers.removeAll()
    }

    private func isCurrent(
        _ sessionID: TerminalSessionID,
        entry: Entry,
        host: TerminalHostContainerView?,
        generation: UInt64,
        requiresVisibleView: Bool = true
    ) -> Bool {
        let transitionIsCurrent = policy.activeSessionID == sessionID
            && entries[sessionID] === entry
            && entry.transitionGeneration == generation
            && transitionGeneration == generation
            && self.host === host
            && entry.view.superview === host
            && entry.view.window != nil
        return transitionIsCurrent && (!requiresVisibleView || !entry.view.isHidden)
    }

    private func sanitizedViewport(_ requested: CGSize, fallback: CGSize) -> CGSize {
        let candidate = requested.width > 0 && requested.height > 0 ? requested : fallback
        return CGSize(width: max(candidate.width, 1), height: max(candidate.height, 1))
    }
}

@MainActor
public final class TerminalHostContainerView: NSView {
    weak var manager: TerminalSurfaceManager?

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        manager?.hostDidLayout(self, size: bounds.size)
    }
}

public struct TerminalHostRepresentable: NSViewRepresentable {
    public let manager: TerminalSurfaceManager
    public let activeSessionID: TerminalSessionID?
    public let wantsTerminalFocus: Bool
    public let onFocused: (TerminalSessionID, TerminalSize?) -> Void
    public let onBlurred: (TerminalSessionID) -> Void

    public init(
        manager: TerminalSurfaceManager,
        activeSessionID: TerminalSessionID?,
        wantsTerminalFocus: Bool = true,
        onFocused: @escaping (TerminalSessionID, TerminalSize?) -> Void = { _, _ in },
        onBlurred: @escaping (TerminalSessionID) -> Void = { _ in }
    ) {
        self.manager = manager
        self.activeSessionID = activeSessionID
        self.wantsTerminalFocus = wantsTerminalFocus
        self.onFocused = onFocused
        self.onBlurred = onBlurred
    }

    public func makeNSView(context: Context) -> TerminalHostContainerView {
        TerminalHostContainerView(frame: .zero)
    }

    public func updateNSView(_ nsView: TerminalHostContainerView, context: Context) {
        manager.submit(
            host: nsView,
            intent: TerminalPresentationIntent(
                activeSessionID: activeSessionID,
                viewportSize: nsView.bounds.size,
                wantsTerminalFocus: wantsTerminalFocus
            ),
            onFocused: onFocused,
            onBlurred: onBlurred
        )
    }

    public static func dismantleNSView(
        _ nsView: TerminalHostContainerView,
        coordinator: Void
    ) {
        nsView.manager?.disconnect(host: nsView)
    }
}
