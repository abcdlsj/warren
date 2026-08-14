import Foundation
import Observation
import WarrenApplication
import WarrenDomain
import GhosttyAdapter

protocol WarrenRendererService: Sendable {
    func sendInput(
        sessionID: TerminalSessionID,
        attachmentID: TerminalAttachmentID,
        data: Data
    ) async throws

    func resize(
        sessionID: TerminalSessionID,
        attachmentID: TerminalAttachmentID,
        size: TerminalSize
    ) async throws
}

extension WarrenApplicationService: WarrenRendererService {}

struct WarrenRendererSurfaceKey: Hashable, Sendable {
    let windowID: ClientWindowID
    let workspaceID: WorkspaceID
    let sessionID: TerminalSessionID
}

/// The sole owner of Ghostty surfaces and viewport side effects.
///
/// Host Session state and Client Layout remain value inputs. A Surface can
/// only send input or resize while its key matches the active Window,
/// Workspace and Tab.
@MainActor
@Observable
final class WarrenRendererCoordinator {
    private(set) var mountedSurfaces: [GhosttySurface] = []

    @ObservationIgnored private let service: any WarrenRendererService
    @ObservationIgnored private let windowID: ClientWindowID
    @ObservationIgnored private var surfaces: [WarrenRendererSurfaceKey: GhosttySurface] = [:]
    @ObservationIgnored private var pendingResizeSizes: [TerminalSessionID: TerminalSize] = [:]
    @ObservationIgnored private var appliedResizeSizes: [TerminalSessionID: TerminalSize] = [:]
    @ObservationIgnored private var resizeTasks: [TerminalSessionID: Task<Void, Never>] = [:]
    @ObservationIgnored private var outputBuffers: [TerminalSessionID: WarrenTerminalOutputBuffer] = [:]
    @ObservationIgnored private var outputTasks: [TerminalSessionID: Task<Void, Never>] = [:]
    @ObservationIgnored private var outputGenerations: [TerminalSessionID: UInt64] = [:]
    @ObservationIgnored private var nextOutputGeneration: UInt64 = 0
    @ObservationIgnored private var snapshot = WarrenApplicationSnapshot.empty()
    @ObservationIgnored private var activeWorkspaceID: WorkspaceID?
    @ObservationIgnored private var activeSessionID: TerminalSessionID?
    @ObservationIgnored private var terminalFont = TerminalFontPreference()
    @ObservationIgnored private var reportError: (Error) -> Void = { _ in }
    @ObservationIgnored private let outputRenderBudgetBytes: Int
    @ObservationIgnored private let outputRenderYield: Duration

    init(
        service: any WarrenRendererService,
        windowID: ClientWindowID = WarrenApplicationDefaults.mainWindowID,
        outputRenderBudgetBytes: Int = 128 * 1024,
        outputRenderYield: Duration = .milliseconds(8)
    ) {
        precondition(outputRenderBudgetBytes > 0)
        self.service = service
        self.windowID = windowID
        self.outputRenderBudgetBytes = outputRenderBudgetBytes
        self.outputRenderYield = outputRenderYield
    }

    func reconcile(
        snapshot: WarrenApplicationSnapshot,
        activeWorkspaceID: WorkspaceID?,
        activeSessionID: TerminalSessionID?,
        terminalFont: TerminalFontPreference = .init(),
        reportError: @escaping (Error) -> Void
    ) {
        let interval = WarrenPerformance.signposter.beginInterval("Renderer Reconcile")
        defer { WarrenPerformance.signposter.endInterval("Renderer Reconcile", interval) }
        self.snapshot = snapshot
        self.activeWorkspaceID = activeWorkspaceID
        self.activeSessionID = activeSessionID
        let fontChanged = terminalFont != self.terminalFont
        self.terminalFont = terminalFont
        self.reportError = reportError

        let visibleTabs = activeWorkspaceID.map { snapshot.tabs(in: $0) } ?? []
        let visibleSessionIDs = Set(visibleTabs.compactMap(\.sessionID))
        // Keep Host sessions alive, but only create a Ghostty/AppKit surface
        // for the selected tab. Creating one surface for every tab makes a
        // large restored workspace monopolize SwiftUI's main-thread graph and
        // leaves the whole desktop looking like an unclickable spinner.
        let mountedSessionIDs = activeSessionID.map { Set([$0]) } ?? []
        let validKeys = Set(snapshot.sessions.compactMap { session -> WarrenRendererSurfaceKey? in
            guard visibleSessionIDs.contains(session.id),
                  mountedSessionIDs.contains(session.id),
                  session.lifecycle == .running,
                  session.attachmentID != nil,
                  session.connectionState != .disconnected,
                  session.connectionState != .failed else { return nil }
            return WarrenRendererSurfaceKey(
                windowID: windowID,
                workspaceID: session.workspaceID,
                sessionID: session.id
            )
        })

        for key in surfaces.keys where !validKeys.contains(key) {
            disposeSurface(key)
        }
        for session in snapshot.sessions where mountedSessionIDs.contains(session.id) {
            guard let attachmentID = session.attachmentID,
                  session.lifecycle == .running,
                  session.connectionState != .disconnected,
                  session.connectionState != .failed else { continue }
            let key = WarrenRendererSurfaceKey(
                windowID: windowID,
                workspaceID: session.workspaceID,
                sessionID: session.id
            )
            if let existing = surfaces[key], existing.attachmentID != attachmentID {
                disposeSurface(key)
            }
            if surfaces[key] == nil {
                surfaces[key] = makeSurface(for: session, attachmentID: attachmentID, key: key)
            } else if fontChanged {
                surfaces[key]?.apply(font: terminalFont)
            }
            enqueueAvailableOutput(for: session, key: key)
        }

        let nextMountedSurfaces: [GhosttySurface] = visibleTabs.compactMap { tab in
            guard let sessionID = tab.sessionID,
                  let workspaceID = activeWorkspaceID else { return nil }
            return surfaces[WarrenRendererSurfaceKey(
                windowID: windowID,
                workspaceID: workspaceID,
                sessionID: sessionID
            )]
        }
        // `reconcile` also runs for coalesced PTY output snapshots. Do not
        // publish an observation change when the mounted surface identities
        // are unchanged; otherwise every background Session redraw rebuilds
        // the entire SwiftUI graph and can starve AppKit event handling.
        let unchanged = mountedSurfaces.count == nextMountedSurfaces.count
            && mountedSurfaces.indices.allSatisfy {
                mountedSurfaces[$0] === nextMountedSurfaces[$0]
            }
        if !unchanged {
            mountedSurfaces = nextMountedSurfaces
        }
    }

    func shutdown() {
        for task in resizeTasks.values { task.cancel() }
        for task in outputTasks.values { task.cancel() }
        resizeTasks.removeAll()
        outputTasks.removeAll()
        outputBuffers.removeAll()
        outputGenerations.removeAll()
        pendingResizeSizes.removeAll()
        appliedResizeSizes.removeAll()
        surfaces.removeAll()
        mountedSurfaces.removeAll()
        activeWorkspaceID = nil
        activeSessionID = nil
    }

    /// Semantic input seam used by Ghostty callbacks and headless tests.
    /// Authorization is decided here, never by the view that emitted input.
    func receiveInput(_ data: Data, from key: WarrenRendererSurfaceKey) async {
        await sendInput(data, key: key)
    }

    /// Semantic viewport seam used by Ghostty callbacks and headless tests.
    func receiveResize(
        columns: Int,
        rows: Int,
        from key: WarrenRendererSurfaceKey
    ) async {
        await requestResize(columns: columns, rows: rows, key: key)
    }

    private func makeSurface(
        for session: WarrenApplicationSession,
        attachmentID: TerminalAttachmentID,
        key: WarrenRendererSurfaceKey
    ) -> GhosttySurface {
        GhosttySurface(
            id: session.id,
            attachmentID: attachmentID,
            workingDirectory: snapshot.workspace(id: session.workspaceID)?.path ?? "",
            font: terminalFont,
            onInput: { [weak self] data in
                Task { @MainActor in await self?.receiveInput(data, from: key) }
            },
            onResize: { [weak self] columns, rows in
                Task { @MainActor in
                    await self?.receiveResize(columns: columns, rows: rows, from: key)
                }
            }
        )
    }

    private func sendInput(_ data: Data, key: WarrenRendererSurfaceKey) async {
        guard key.windowID == windowID,
              key.workspaceID == activeWorkspaceID,
              key.sessionID == activeSessionID,
              let attachmentID = snapshot.session(id: key.sessionID)?.attachmentID else { return }
        do {
            try await service.sendInput(
                sessionID: key.sessionID,
                attachmentID: attachmentID,
                data: data
            )
        } catch {
            NSLog(
                "Warren terminal input failed for %@: %@",
                key.sessionID.description,
                String(describing: error)
            )
        }
    }

    private func requestResize(
        columns: Int,
        rows: Int,
        key: WarrenRendererSurfaceKey
    ) async {
        guard key.windowID == windowID,
              key.workspaceID == activeWorkspaceID,
              key.sessionID == activeSessionID,
              let size = TerminalSize(columns: columns, rows: rows),
              snapshot.session(id: key.sessionID)?.attachmentID != nil,
              pendingResizeSizes[key.sessionID] != size,
              appliedResizeSizes[key.sessionID] != size else { return }
        pendingResizeSizes[key.sessionID] = size
        guard resizeTasks[key.sessionID] == nil else { return }
        resizeTasks[key.sessionID] = Task { @MainActor [weak self] in
            await self?.drainResizes(for: key)
        }
    }

    private func drainResizes(for key: WarrenRendererSurfaceKey) async {
        defer { resizeTasks.removeValue(forKey: key.sessionID) }
        while !Task.isCancelled {
            guard key.workspaceID == activeWorkspaceID,
                  key.sessionID == activeSessionID,
                  let size = pendingResizeSizes[key.sessionID],
                  let attachmentID = snapshot.session(id: key.sessionID)?.attachmentID else {
                pendingResizeSizes.removeValue(forKey: key.sessionID)
                return
            }
            do {
                try await service.resize(
                    sessionID: key.sessionID,
                    attachmentID: attachmentID,
                    size: size
                )
                appliedResizeSizes[key.sessionID] = size
            } catch {
                pendingResizeSizes.removeValue(forKey: key.sessionID)
                reportError(error)
                return
            }
            if pendingResizeSizes[key.sessionID] == size {
                pendingResizeSizes.removeValue(forKey: key.sessionID)
                return
            }
        }
    }

    private func enqueueAvailableOutput(
        for session: WarrenApplicationSession,
        key: WarrenRendererSurfaceKey
    ) {
        guard let surface = surfaces[key],
              let output = session.output,
              !output.frames.isEmpty else { return }
        var buffer = outputBuffers[session.id] ?? WarrenTerminalOutputBuffer()
        if buffer.epoch != output.epoch {
            cancelOutputTask(for: session.id)
            let sequence = surface.renderedEpoch == output.epoch
                ? surface.renderedSequence
                : 0
            buffer.reset(epoch: output.epoch, sequence: sequence)
        }
        guard output.upperSequence > buffer.enqueuedSequence else { return }
        for frame in output.frames where frame.header.epoch == output.epoch {
            buffer.append(
                epoch: frame.header.epoch,
                sequence: frame.header.sequence,
                payload: frame.payload
            )
        }
        outputBuffers[session.id] = buffer
        guard !buffer.isEmpty, outputTasks[session.id] == nil else { return }
        nextOutputGeneration &+= 1
        let generation = nextOutputGeneration
        outputGenerations[session.id] = generation
        outputTasks[session.id] = Task { @MainActor [weak self] in
            await self?.drainOutput(for: key, generation: generation)
        }
    }

    private func drainOutput(
        for key: WarrenRendererSurfaceKey,
        generation: UInt64
    ) async {
        defer {
            if outputGenerations[key.sessionID] == generation {
                outputTasks.removeValue(forKey: key.sessionID)
            }
        }
        while !Task.isCancelled,
              outputGenerations[key.sessionID] == generation,
              let surface = surfaces[key] {
            let interval = WarrenPerformance.signposter.beginInterval("Ghostty Feed")
            var remaining = outputRenderBudgetBytes
            while remaining > 0,
                  var buffer = outputBuffers[key.sessionID],
                  let slice = buffer.take(maxBytes: remaining) {
                outputBuffers[key.sessionID] = buffer
                surface.receive(slice.payload)
                surface.markRendered(epoch: slice.epoch, sequence: slice.endSequence)
                remaining -= slice.payload.count
            }
            WarrenPerformance.signposter.endInterval("Ghostty Feed", interval)
            guard outputBuffers[key.sessionID]?.isEmpty == false else { return }
            do {
                try await Task.sleep(for: outputRenderYield)
            } catch {
                return
            }
        }
    }

    private func cancelOutputTask(for sessionID: TerminalSessionID) {
        outputTasks.removeValue(forKey: sessionID)?.cancel()
        outputGenerations.removeValue(forKey: sessionID)
    }

    private func disposeSurface(_ key: WarrenRendererSurfaceKey) {
        surfaces.removeValue(forKey: key)
        resizeTasks.removeValue(forKey: key.sessionID)?.cancel()
        cancelOutputTask(for: key.sessionID)
        outputBuffers.removeValue(forKey: key.sessionID)
        outputGenerations.removeValue(forKey: key.sessionID)
        pendingResizeSizes.removeValue(forKey: key.sessionID)
        appliedResizeSizes.removeValue(forKey: key.sessionID)
    }
}
