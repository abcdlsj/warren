import Foundation
import XCTest
import WarrenApplication
import WarrenClientCore
import WarrenDomain
import WarrenHost
@testable import WarrenNext

final class WarrenRendererCoordinatorTests: XCTestCase {
    func testRemoteAttachParametersCarryViewportWithoutClaimingFocus() throws {
        let sessionID = TerminalSessionID()
        let size = try XCTUnwrap(TerminalSize(columns: 117, rows: 38))

        XCTAssertEqual(
            WarrenRemoteTerminalProtocol.attachParameters(sessionID: sessionID, size: size),
            [
                "id": sessionID.description,
                "focused": "false",
                "cols": "117",
                "rows": "38",
            ]
        )
    }

    func testRemoteAttachParametersRemainExplicitlyPassiveWithoutGrid() {
        let sessionID = TerminalSessionID()

        XCTAssertEqual(
            WarrenRemoteTerminalProtocol.attachParameters(sessionID: sessionID, size: nil),
            ["id": sessionID.description, "focused": "false"]
        )
    }

    func testRemoteRosterAttachesInitialTabAndDoesNotDuplicateMountedSurface() {
        XCTAssertTrue(WarrenRemoteTerminalProtocol.shouldAttach(
            previousTabID: nil,
            nextTabID: "tab-1",
            mountedSurfaceCount: 0
        ))
        XCTAssertFalse(WarrenRemoteTerminalProtocol.shouldAttach(
            previousTabID: "tab-1",
            nextTabID: "tab-1",
            mountedSurfaceCount: 1
        ))
        XCTAssertTrue(WarrenRemoteTerminalProtocol.shouldAttach(
            previousTabID: "tab-1",
            nextTabID: "tab-2",
            mountedSurfaceCount: 1
        ))
        XCTAssertFalse(WarrenRemoteTerminalProtocol.shouldAttach(
            previousTabID: nil,
            nextTabID: nil,
            mountedSurfaceCount: 0
        ))
    }

    func testRemoteRosterReattachesSameTabAfterTransportReset() {
        XCTAssertTrue(WarrenRemoteTerminalProtocol.shouldAttach(
            previousTabID: "tab-1",
            nextTabID: "tab-1",
            mountedSurfaceCount: 0
        ))
    }

    func testReconnectDelayBacksOffExponentiallyAndCapsAtThirtySeconds() {
        XCTAssertEqual(WarrenRemoteApplicationModel.reconnectDelay(attempt: 0), 500)
        XCTAssertEqual(WarrenRemoteApplicationModel.reconnectDelay(attempt: 1), 1_000)
        XCTAssertEqual(WarrenRemoteApplicationModel.reconnectDelay(attempt: 2), 2_000)
        XCTAssertEqual(WarrenRemoteApplicationModel.reconnectDelay(attempt: 6), 30_000)
        XCTAssertEqual(WarrenRemoteApplicationModel.reconnectDelay(attempt: 99), 30_000)
    }

    @MainActor
    func testPendingShellTabIDIsStablePerWorkspace() {
        let workspaceID = WorkspaceID(
            rawValue: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        )

        XCTAssertEqual(
            WarrenNextApplicationModel.pendingShellTabID(for: workspaceID),
            "pending-shell-cccccccc-cccc-cccc-cccc-cccccccccccc"
        )
    }

    @MainActor
    func testDesktopProjectionInputsIgnoreRendererOnlyOutputButObserveVisibleState() {
        let fixture = Fixture()
        let outputOnlySession = copySession(
            fixture.firstSession,
            output: WarrenApplicationOutputSnapshot(
                sessionID: fixture.firstSession.id,
                epoch: 1,
                lowerSequence: 1,
                upperSequence: 42
            )
        )
        let outputOnly = copySnapshot(fixture.snapshot, sessions: [
            outputOnlySession,
            fixture.secondSession,
        ])

        XCTAssertTrue(WarrenNextApplicationModel.desktopProjectionInputsEqual(
            fixture.snapshot,
            outputOnly
        ))

        let renamed = copySnapshot(fixture.snapshot, sessions: [
            copySession(fixture.firstSession, title: "Renamed"),
            fixture.secondSession,
        ])
        XCTAssertFalse(WarrenNextApplicationModel.desktopProjectionInputsEqual(
            fixture.snapshot,
            renamed
        ))
    }

    func testLosslessAsyncBufferBackpressuresAndPreservesOrder() async throws {
        let buffer = WarrenLosslessAsyncBuffer<Int>(capacity: 2)
        let progress = SendProgress()
        let producer = Task {
            for value in 0..<100 {
                guard await buffer.send(value) else { return false }
                await progress.recordSend()
            }
            return true
        }

        await progress.waitForSends(2)
        try await Task.sleep(for: .milliseconds(2))
        let sentBeforeConsumption = await progress.sentCount
        XCTAssertEqual(sentBeforeConsumption, 2)

        var iterator = buffer.stream.makeAsyncIterator()
        var received: [Int] = []
        for _ in 0..<100 {
            let next = await iterator.next()
            received.append(try XCTUnwrap(next))
        }
        let completed = await producer.value
        XCTAssertTrue(completed)
        buffer.finish()
        XCTAssertEqual(received, Array(0..<100))
    }

    func testTerminalOutputBufferDeduplicatesOverlapAndKeepsSequenceGaps() {
        var buffer = WarrenTerminalOutputBuffer()
        buffer.reset(epoch: 7, sequence: 0)
        buffer.append(epoch: 7, sequence: 0, payload: Data("abcdef".utf8))
        buffer.append(epoch: 7, sequence: 0, payload: Data("abcdef".utf8))
        buffer.append(epoch: 7, sequence: 3, payload: Data("defghi".utf8))

        var slices: [WarrenTerminalOutputSlice] = []
        while let slice = buffer.take(maxBytes: 4) { slices.append(slice) }
        XCTAssertEqual(slices.map(\.sequence), [0, 4, 6])
        XCTAssertEqual(
            Data(slices.flatMap { $0.payload }),
            Data("abcdefghi".utf8)
        )
        XCTAssertEqual(buffer.enqueuedSequence, 9)

        buffer.append(epoch: 8, sequence: 100, payload: Data("xyz".utf8))
        XCTAssertEqual(buffer.take(maxBytes: 8), WarrenTerminalOutputSlice(
            epoch: 8,
            sequence: 100,
            payload: Data("xyz".utf8)
        ))
    }

    @MainActor
    func testLargeOutputIsFedAcrossMainActorTurnsWithoutDuplication() async throws {
        let fixture = Fixture()
        var ring = OutputRing(epoch: 9, capacity: 4, nextSequence: 100)
        try ring.append(
            sessionID: fixture.firstSession.id,
            payload: Data("abcdefghijkl".utf8)
        )
        let session = copySession(
            fixture.firstSession,
            output: WarrenApplicationOutputSnapshot(
                sessionID: fixture.firstSession.id,
                ring: ring.recovery(for: nil).snapshot
            )
        )
        let snapshot = copySnapshot(fixture.snapshot, sessions: [session, fixture.secondSession])
        let coordinator = WarrenRendererCoordinator(
            service: RendererServiceSpy(),
            windowID: fixture.windowID,
            outputRenderBudgetBytes: 4,
            outputRenderYield: .milliseconds(20)
        )

        coordinator.reconcile(
            snapshot: snapshot,
            activeWorkspaceID: fixture.firstWorkspace.id,
            activeSessionID: fixture.firstSession.id,
            reportError: { _ in }
        )
        try await Task.sleep(for: .milliseconds(3))
        let surface = try XCTUnwrap(coordinator.mountedSurfaces.first)
        XCTAssertEqual(surface.renderedSequence, 104)

        // Replaying the same immutable snapshot while bytes are pending must
        // not enqueue another copy.
        coordinator.reconcile(
            snapshot: snapshot,
            activeWorkspaceID: fixture.firstWorkspace.id,
            activeSessionID: fixture.firstSession.id,
            reportError: { _ in }
        )
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(surface.renderedSequence, 112)
        XCTAssertEqual(surface.semanticSnapshot().plainText, "abcdefghijkl")
        coordinator.shutdown()
    }

    @MainActor
    func testOnlyActiveWorkspaceAndTabCanSendInputOrResize() async throws {
        let fixture = Fixture()
        let service = RendererServiceSpy()
        let coordinator = WarrenRendererCoordinator(service: service, windowID: fixture.windowID)
        coordinator.reconcile(
            snapshot: fixture.snapshot,
            activeWorkspaceID: fixture.firstWorkspace.id,
            activeSessionID: fixture.firstSession.id,
            reportError: { _ in }
        )

        await coordinator.receiveInput(Data("active".utf8), from: fixture.firstKey)
        await coordinator.receiveResize(columns: 120, rows: 40, from: fixture.firstKey)
        await coordinator.receiveInput(Data("background".utf8), from: fixture.secondKey)
        await coordinator.receiveResize(columns: 90, rows: 30, from: fixture.secondKey)
        try? await Task.sleep(for: .milliseconds(50))

        let values = await service.snapshot()
        XCTAssertEqual(values.inputs.map(\.sessionID), [fixture.firstSession.id])
        XCTAssertEqual(values.inputs.map(\.data), [Data("active".utf8)])
        XCTAssertEqual(values.resizes.map(\.sessionID), [fixture.firstSession.id])
        XCTAssertEqual(values.resizes.map(\.size), [TerminalSize(columns: 120, rows: 40)!])
    }

    @MainActor
    func testSwitchingWorkspaceDisposesOldSurfacesAndRejectsStaleCallbacks() async {
        let fixture = Fixture()
        let service = RendererServiceSpy()
        let coordinator = WarrenRendererCoordinator(service: service, windowID: fixture.windowID)
        coordinator.reconcile(
            snapshot: fixture.snapshot,
            activeWorkspaceID: fixture.firstWorkspace.id,
            activeSessionID: fixture.firstSession.id,
            reportError: { _ in }
        )
        let oldSurface = coordinator.mountedSurfaces.first

        coordinator.reconcile(
            snapshot: fixture.snapshot,
            activeWorkspaceID: fixture.secondWorkspace.id,
            activeSessionID: fixture.secondSession.id,
            reportError: { _ in }
        )
        await coordinator.receiveInput(Data("stale".utf8), from: fixture.firstKey)
        await coordinator.receiveInput(Data("current".utf8), from: fixture.secondKey)

        XCTAssertEqual(coordinator.mountedSurfaces.map(\.id), [fixture.secondSession.id])
        XCTAssertFalse(coordinator.mountedSurfaces.contains { $0 === oldSurface })
        let values = await service.snapshot()
        XCTAssertEqual(values.inputs.map(\.data), [Data("current".utf8)])
    }

    @MainActor
    func testChangingTerminalFontReconfiguresTheExistingSurfaceInPlace() {
        let fixture = Fixture()
        let coordinator = WarrenRendererCoordinator(
            service: RendererServiceSpy(),
            windowID: fixture.windowID
        )
        coordinator.reconcile(
            snapshot: fixture.snapshot,
            activeWorkspaceID: fixture.firstWorkspace.id,
            activeSessionID: fixture.firstSession.id,
            reportError: { _ in }
        )
        let originalSurface = coordinator.mountedSurfaces.first

        coordinator.reconcile(
            snapshot: fixture.snapshot,
            activeWorkspaceID: fixture.firstWorkspace.id,
            activeSessionID: fixture.firstSession.id,
            terminalFont: TerminalFontPreference(family: "Menlo", size: 16),
            reportError: { _ in }
        )

        XCTAssertEqual(coordinator.mountedSurfaces.count, 1)
        XCTAssertTrue(coordinator.mountedSurfaces.first === originalSurface)
        XCTAssertEqual(coordinator.mountedSurfaces.first?.id, fixture.firstSession.id)
        XCTAssertEqual(
            coordinator.mountedSurfaces.first?.attachmentID,
            fixture.firstSession.attachmentID
        )
    }

    @MainActor
    func testResizeBurstIsSerializedAndLatestValueWins() async {
        let fixture = Fixture()
        let service = RendererServiceSpy(resizeDelay: .milliseconds(10))
        let coordinator = WarrenRendererCoordinator(service: service, windowID: fixture.windowID)
        coordinator.reconcile(
            snapshot: fixture.snapshot,
            activeWorkspaceID: fixture.firstWorkspace.id,
            activeSessionID: fixture.firstSession.id,
            reportError: { _ in }
        )

        for columns in 81...180 {
            await coordinator.receiveResize(columns: columns, rows: 40, from: fixture.firstKey)
        }
        try? await Task.sleep(for: .milliseconds(100))

        let values = await service.snapshot()
        XCTAssertEqual(values.resizes.last?.size, TerminalSize(columns: 180, rows: 40))
        XCTAssertEqual(values.maximumConcurrentResizes, 1)
        XCTAssertLessThan(values.resizes.count, 100)
    }
}

private actor SendProgress {
    private(set) var sentCount = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func recordSend() {
        sentCount += 1
        let ready = waiters.filter { sentCount >= $0.count }
        waiters.removeAll { sentCount >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }

    func waitForSends(_ count: Int) async {
        guard sentCount < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }
}

private func copySession(
    _ session: WarrenApplicationSession,
    title: String? = nil,
    output: WarrenApplicationOutputSnapshot? = nil
) -> WarrenApplicationSession {
    WarrenApplicationSession(
        id: session.id,
        workspaceID: session.workspaceID,
        tabID: session.tabID,
        title: title ?? session.title,
        kind: session.kind,
        lifecycle: session.lifecycle,
        connectionState: session.connectionState,
        agentActivity: session.agentActivity,
        runtimeProcess: session.runtimeProcess,
        workingDirectory: session.workingDirectory,
        attachmentID: session.attachmentID,
        controllerAttachmentID: session.controllerAttachmentID,
        controlLeaseID: session.controlLeaseID,
        recoveryAnchor: session.recoveryAnchor,
        terminalSize: session.terminalSize,
        runtimeAdoptionDescriptor: session.runtimeAdoptionDescriptor,
        output: output
    )
}

private func copySnapshot(
    _ snapshot: WarrenApplicationSnapshot,
    sessions: [WarrenApplicationSession]
) -> WarrenApplicationSnapshot {
    WarrenApplicationSnapshot(
        host: snapshot.host,
        projects: snapshot.projects,
        workspaces: snapshot.workspaces,
        sessions: sessions,
        windowLayout: snapshot.windowLayout,
        issues: snapshot.issues,
        lifecycle: snapshot.lifecycle
    )
}

private actor RendererServiceSpy: WarrenRendererService {
    struct Input: Sendable {
        let sessionID: TerminalSessionID
        let data: Data
    }

    struct Resize: Sendable {
        let sessionID: TerminalSessionID
        let size: TerminalSize
    }

    struct Values: Sendable {
        let inputs: [Input]
        let resizes: [Resize]
        let maximumConcurrentResizes: Int
    }

    private let resizeDelay: Duration
    private var inputs: [Input] = []
    private var resizes: [Resize] = []
    private var concurrentResizes = 0
    private var maximumConcurrentResizes = 0

    init(resizeDelay: Duration = .zero) {
        self.resizeDelay = resizeDelay
    }

    func sendInput(
        sessionID: TerminalSessionID,
        attachmentID: TerminalAttachmentID,
        data: Data
    ) async throws {
        _ = attachmentID
        inputs.append(Input(sessionID: sessionID, data: data))
    }

    func resize(
        sessionID: TerminalSessionID,
        attachmentID: TerminalAttachmentID,
        size: TerminalSize
    ) async throws {
        _ = attachmentID
        concurrentResizes += 1
        maximumConcurrentResizes = max(maximumConcurrentResizes, concurrentResizes)
        if resizeDelay != .zero { try? await Task.sleep(for: resizeDelay) }
        resizes.append(Resize(sessionID: sessionID, size: size))
        concurrentResizes -= 1
    }

    func snapshot() -> Values {
        Values(
            inputs: inputs,
            resizes: resizes,
            maximumConcurrentResizes: maximumConcurrentResizes
        )
    }
}

private struct Fixture {
    let windowID = ClientWindowID()
    let host = Host(name: "Test Host")
    let project: Project
    let firstWorkspace: Workspace
    let secondWorkspace: Workspace
    let firstSession: WarrenApplicationSession
    let secondSession: WarrenApplicationSession
    let snapshot: WarrenApplicationSnapshot

    init() {
        project = Project(hostID: host.id, name: "Project", rootPath: "/tmp/project")
        firstWorkspace = Workspace(
            projectID: project.id,
            name: "main",
            path: "/tmp/project",
            branch: "main"
        )
        secondWorkspace = Workspace(
            projectID: project.id,
            name: "feature",
            path: "/tmp/project-feature",
            branch: "feature"
        )
        firstSession = Self.session(workspace: firstWorkspace, title: "First")
        secondSession = Self.session(workspace: secondWorkspace, title: "Second")
        let layout = ClientWindowLayout(
            id: windowID,
            activeWorkspaceID: firstWorkspace.id,
            workspaceViews: [
                Self.view(workspace: firstWorkspace, session: firstSession),
                Self.view(workspace: secondWorkspace, session: secondSession),
            ]
        )!
        snapshot = WarrenApplicationSnapshot(
            host: host,
            projects: [project],
            workspaces: [firstWorkspace, secondWorkspace],
            sessions: [firstSession, secondSession],
            windowLayout: layout,
            lifecycle: .ready
        )
    }

    var firstKey: WarrenRendererSurfaceKey {
        WarrenRendererSurfaceKey(
            windowID: windowID,
            workspaceID: firstWorkspace.id,
            sessionID: firstSession.id
        )
    }

    var secondKey: WarrenRendererSurfaceKey {
        WarrenRendererSurfaceKey(
            windowID: windowID,
            workspaceID: secondWorkspace.id,
            sessionID: secondSession.id
        )
    }

    private static func session(
        workspace: Workspace,
        title: String
    ) -> WarrenApplicationSession {
        let id = TerminalSessionID()
        return WarrenApplicationSession(
            id: id,
            workspaceID: workspace.id,
            tabID: "tab-\(id.description)",
            title: title,
            connectionState: .attached,
            attachmentID: TerminalAttachmentID(),
            terminalSize: TerminalSize(columns: 80, rows: 24)!
        )
    }

    private static func view(
        workspace: Workspace,
        session: WarrenApplicationSession
    ) -> ClientWorkspaceView {
        let tab = ClientTab(
            id: session.tabID!,
            title: session.title,
            sessionID: session.id
        )
        return ClientWorkspaceView(
            workspaceID: workspace.id,
            tabs: [tab],
            activeTabID: tab.id
        )
    }
}
