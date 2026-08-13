import Foundation
import XCTest
import WarrenApplication
import WarrenClientCore
import WarrenDomain
@testable import WarrenNext

final class WarrenRendererCoordinatorTests: XCTestCase {
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
