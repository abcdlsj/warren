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
    @ObservationIgnored private var snapshot = WarrenApplicationSnapshot.empty()
    @ObservationIgnored private var activeWorkspaceID: WorkspaceID?
    @ObservationIgnored private var activeSessionID: TerminalSessionID?
    @ObservationIgnored private var terminalFont = TerminalFontPreference()
    @ObservationIgnored private var reportError: (Error) -> Void = { _ in }

    init(
        service: any WarrenRendererService,
        windowID: ClientWindowID = WarrenApplicationDefaults.mainWindowID
    ) {
        self.service = service
        self.windowID = windowID
    }

    func reconcile(
        snapshot: WarrenApplicationSnapshot,
        activeWorkspaceID: WorkspaceID?,
        activeSessionID: TerminalSessionID?,
        terminalFont: TerminalFontPreference = .init(),
        reportError: @escaping (Error) -> Void
    ) {
        self.snapshot = snapshot
        self.activeWorkspaceID = activeWorkspaceID
        self.activeSessionID = activeSessionID
        let fontChanged = terminalFont != self.terminalFont
        self.terminalFont = terminalFont
        self.reportError = reportError

        let visibleTabs = activeWorkspaceID.map { snapshot.tabs(in: $0) } ?? []
        let visibleSessionIDs = Set(visibleTabs.compactMap(\.sessionID))
        let validKeys = Set(snapshot.sessions.compactMap { session -> WarrenRendererSurfaceKey? in
            guard visibleSessionIDs.contains(session.id),
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
        for session in snapshot.sessions where visibleSessionIDs.contains(session.id) {
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
            renderAvailableOutput(for: session, key: key)
        }

        mountedSurfaces = visibleTabs.compactMap { tab in
            guard let sessionID = tab.sessionID,
                  let workspaceID = activeWorkspaceID else { return nil }
            return surfaces[WarrenRendererSurfaceKey(
                windowID: windowID,
                workspaceID: workspaceID,
                sessionID: sessionID
            )]
        }
    }

    func shutdown() {
        for task in resizeTasks.values { task.cancel() }
        resizeTasks.removeAll()
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

    private func renderAvailableOutput(
        for session: WarrenApplicationSession,
        key: WarrenRendererSurfaceKey
    ) {
        guard let surface = surfaces[key],
              let output = session.output,
              !output.frames.isEmpty else { return }
        var epoch = surface.renderedEpoch
        var sequence = surface.renderedSequence
        guard epoch != output.epoch || output.upperSequence > sequence else { return }
        let start = epoch == output.epoch
            ? output.frames.firstIndex { $0.header.sequence + UInt64($0.payload.count) > sequence }
                ?? output.frames.count
            : 0
        guard start < output.frames.count else { return }
        for frame in output.frames[start...] {
            let frameEnd = frame.header.sequence + UInt64(frame.payload.count)
            guard frame.header.epoch == output.epoch, frameEnd > sequence else { continue }
            let offset = frame.header.sequence < sequence ? Int(sequence - frame.header.sequence) : 0
            let payload = offset == 0 ? frame.payload : Data(frame.payload.dropFirst(offset))
            surface.receive(payload)
            sequence += UInt64(payload.count)
            epoch = frame.header.epoch
            surface.markRendered(epoch: epoch, sequence: sequence)
        }
    }

    private func disposeSurface(_ key: WarrenRendererSurfaceKey) {
        surfaces.removeValue(forKey: key)
        resizeTasks.removeValue(forKey: key.sessionID)?.cancel()
        pendingResizeSizes.removeValue(forKey: key.sessionID)
        appliedResizeSizes.removeValue(forKey: key.sessionID)
    }
}
