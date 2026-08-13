import XCTest
import SwiftUI
import AppKit
@testable import WarrenDesktop
import WarrenDesignSystem
import WarrenDomain
import WarrenClientCore

private struct TestTerminalSurface: View {
    let context: WarrenDesktopTerminalContext

    var body: some View {
        Text("surface:\(context.tab.id):\(context.workspace.id.rawValue.uuidString)")
    }
}

@MainActor
final class WarrenDesktopTests: XCTestCase {
    func testWorkspaceChromeIsDefaultAndDoesNotShowIndependentTopBar() {
        XCTAssertFalse(WarrenDesktopChromeMode.workspace.showsIndependentTopBar)
        XCTAssertTrue(WarrenDesktopChromeMode.dashboard.showsIndependentTopBar)

        let defaultMode = WarrenDesktopChromeMode.workspace
        XCTAssertEqual(defaultMode, .workspace)
    }

    func testRootLayoutMountsAtSupersetDesktopSizeWithoutPixelCapture() {
        let root = WarrenDesktopRoot(
            projection: WarrenDesktopFixture.preview.projection,
            actions: WarrenDesktopActions()
        ) { context in
            TestTerminalSurface(context: context)
        }
        .environment(\.colorScheme, .dark)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertEqual(hostingView.bounds.width, 1280)
        XCTAssertEqual(hostingView.bounds.height, 800)
        XCTAssertLessThanOrEqual(hostingView.fittingSize.width, hostingView.bounds.width)
        XCTAssertLessThanOrEqual(hostingView.fittingSize.height, hostingView.bounds.height)
        XCTAssertGreaterThanOrEqual(
            hostingView.fittingSize.width,
            WarrenLayoutMetrics.sidebarExpandedWidth + WarrenLayoutMetrics.paneMinimumWidth
        )
        XCTAssertGreaterThanOrEqual(
            hostingView.fittingSize.height,
            WarrenLayoutMetrics.tabBarHeight
                + WarrenLayoutMetrics.presetBarHeight
                + WarrenLayoutMetrics.paneHeaderHeight
                + WarrenLayoutMetrics.paneMinimumHeight
        )
    }

    func testWindowDragRegionUsesDedicatedAppKitView() {
        let view = WarrenDesktopWindowDragView()

        XCTAssertFalse(view.acceptsFirstResponder)
    }

    func testSidebarStateUsesSupersetSnapAndRestoreValues() {
        var state = WarrenDesktopSidebarState()
        XCTAssertEqual(state.width, WarrenLayoutMetrics.sidebarExpandedWidth)
        XCTAssertFalse(state.isCollapsed)

        state.setWidth(119)
        XCTAssertTrue(state.isCollapsed)
        XCTAssertEqual(state.renderedWidth, WarrenLayoutMetrics.sidebarCollapsedWidth)

        state.restoreExpanded()
        XCTAssertFalse(state.isCollapsed)
        XCTAssertEqual(state.width, WarrenLayoutMetrics.sidebarExpandedWidth)

        state.setWidth(399)
        XCTAssertEqual(state.width, 399)
        state.setWidth(401)
        XCTAssertEqual(state.width, WarrenLayoutMetrics.sidebarMaximumWidth)
    }

    func testPreviewFixtureKeepsStableRowsAndRelationships() {
        let fixture = WarrenDesktopFixture.preview
        XCTAssertEqual(fixture.groups.count, 2)
        XCTAssertEqual(fixture.groups.first?.workspaces.count, 2)
        XCTAssertEqual(
            fixture.groups.first?.workspaces.first?.projectID,
            fixture.groups.first?.project.id
        )
        XCTAssertEqual(fixture.tabs.map(\.id), ["tab-main", "tab-review"])
        XCTAssertNotNil(fixture.workspace(id: fixture.groups[0].workspaces[0].id))
    }

    func testProjectionKeepsEmptyStateWithoutInventingRows() {
        let fixture = WarrenDesktopFixture.preview
        let projection = WarrenDesktopProjection.empty(host: fixture.host)

        XCTAssertTrue(projection.groups.isEmpty)
        XCTAssertTrue(projection.tabs.isEmpty)
        XCTAssertNil(projection.inspector)
        XCTAssertTrue(projection.isConnected)
        XCTAssertNil(projection.workspace(id: fixture.groups[0].workspaces[0].id))
    }

    func testActionsExposeProjectWorkspaceAndTabIntentWithoutSideEffects() {
        var received: [WarrenDesktopAction] = []
        let actions = WarrenDesktopActions(
            send: { received.append($0) }
        )

        let fixture = WarrenDesktopFixture.preview
        let projectID = fixture.groups[0].project.id
        let workspaceID = fixture.groups[0].workspaces[0].id
        let sessionID = fixture.sessions[0].id

        actions(.addProject)
        actions(.importSuperset)
        actions(.requestNewWorkspace(projectID))
        actions(.selectWorkspace(workspaceID))
        actions(.openSession(sessionID))
        actions(.deleteSession(sessionID))
        actions(.requestNewSession(workspaceID))
        actions(.launchSession(workspaceID, .claude))
        actions(.selectTab("tab-main"))
        actions(.closeTab("tab-main"))
        actions(.toggleInspector)
        actions(.toggleSidebar)

        XCTAssertEqual(
            received,
            [
                .addProject,
                .importSuperset,
                .requestNewWorkspace(projectID),
                .selectWorkspace(workspaceID),
                .openSession(sessionID),
                .deleteSession(sessionID),
                .requestNewSession(workspaceID),
                .launchSession(workspaceID, .claude),
                .selectTab("tab-main"),
                .closeTab("tab-main"),
                .toggleInspector,
                .toggleSidebar,
            ]
        )
    }

    func testProductionRootAcceptsTypedTerminalSurfaceSlot() {
        let fixture = WarrenDesktopFixture.preview
        let root = WarrenDesktopRoot(
            projection: fixture.projection,
            actions: WarrenDesktopActions()
        ) { context in
            TestTerminalSurface(context: context)
        }

        XCTAssertNotNil(root)
    }

    func testBuiltInPresetsMapToExplicitLaunchRequests() {
        XCTAssertEqual(WarrenDesktopSessionPreset.pinned.map(\.id), ["shell", "claude", "codex"])
        XCTAssertEqual(
            WarrenDesktopSessionPreset.pinned.map(\.presetBarTitle),
            ["Shell", "Claude", "Codex"]
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.pinned.compactMap(\.presetBarIconName),
            ["preset-shell", "preset-claude", "preset-codex"]
        )
        XCTAssertEqual(WarrenDesktopSessionPreset.pinned.map(\.request), [.shell, .claude, .codex])
        XCTAssertNil(TerminalSessionLaunchRequest.shell.command)
        XCTAssertEqual(TerminalSessionLaunchRequest.claude.command, "claude")
        XCTAssertEqual(TerminalSessionLaunchRequest.claude.title, "Claude Code")
        XCTAssertEqual(
            TerminalSessionLaunchRequest.codex.command,
            "codex --dangerously-bypass-hook-trust"
        )
    }

    func testSelectionReconcilesEmptyToLoadedProjection() {
        let fixture = WarrenDesktopFixture.preview
        let empty = WarrenDesktopProjection.empty(host: fixture.host)

        let emptyState = WarrenDesktopSelectionReconciler.reconcile(
            selection: nil,
            selectedTabID: nil,
            with: empty
        )
        XCTAssertNil(emptyState.selection)
        XCTAssertNil(emptyState.selectedTabID)

        let loadedState = WarrenDesktopSelectionReconciler.reconcile(
            selection: emptyState.selection,
            selectedTabID: emptyState.selectedTabID,
            with: fixture.projection
        )
        XCTAssertEqual(
            loadedState.selection,
            .workspace(fixture.groups[0].workspaces[0].id)
        )
        XCTAssertEqual(loadedState.selectedTabID, "tab-main")
    }

    func testSelectionReconcilesRemovedProjectWorkspaceAndTab() {
        let fixture = WarrenDesktopFixture.preview
        let firstProjectID = fixture.groups[0].project.id
        let firstWorkspaceID = fixture.groups[0].workspaces[0].id
        let secondWorkspaceID = fixture.groups[1].workspaces[0].id

        let current = WarrenDesktopSelectionReconciler.reconcile(
            selection: .workspace(firstWorkspaceID),
            selectedTabID: "tab-main",
            with: fixture.projection
        )
        XCTAssertEqual(current.selection, .workspace(firstWorkspaceID))
        XCTAssertEqual(current.selectedTabID, "tab-main")

        let reducedGroups = fixture.projection.groups.filter { $0.project.id != firstProjectID }
        let reducedProjection = WarrenDesktopProjection(
            host: fixture.host,
            groups: reducedGroups,
            sessions: fixture.projection.sessions.filter { $0.tabID != "tab-main" },
            tabs: fixture.projection.tabs.filter { $0.id != "tab-main" },
            sessionWorkspaceIDs: fixture.projection.sessionWorkspaceIDs
        )
        let reduced = WarrenDesktopSelectionReconciler.reconcile(
            selection: current.selection,
            selectedTabID: current.selectedTabID,
            with: reducedProjection
        )
        XCTAssertEqual(reduced.selection, .workspace(secondWorkspaceID))
        XCTAssertEqual(reduced.selectedTabID, "tab-review")

        let emptied = WarrenDesktopSelectionReconciler.reconcile(
            selection: reduced.selection,
            selectedTabID: reduced.selectedTabID,
            with: WarrenDesktopProjection.empty(host: fixture.host)
        )
        XCTAssertNil(emptied.selection)
        XCTAssertNil(emptied.selectedTabID)
    }

    func testSelectingWorkspaceNeverLeavesAnotherWorkspaceTabActive() {
        let fixture = WarrenDesktopFixture.preview
        let firstWorkspaceID = fixture.groups[0].workspaces[0].id
        let workspaceWithoutTabID = fixture.groups[0].workspaces[1].id
        let initial = WarrenDesktopNavigationState(
            selection: .workspace(firstWorkspaceID),
            selectedTabID: "tab-main"
        )

        let selected = WarrenDesktopNavigationReducer.reduce(
            initial,
            action: .selectWorkspace(workspaceWithoutTabID),
            in: fixture.projection
        )

        XCTAssertEqual(selected.selection, .workspace(workspaceWithoutTabID))
        XCTAssertNil(selected.selectedTabID)
        XCTAssertEqual(
            WarrenDesktopNavigationReducer.reconcile(selected, with: fixture.projection),
            selected
        )
    }

    func testPendingShellTabBelongsToWorkspaceBeforeSessionExists() {
        let fixture = WarrenDesktopFixture.preview
        let workspaceID = fixture.groups[0].workspaces[1].id
        let pendingTab = ClientTab(
            id: "pending-shell-\(workspaceID.description)",
            title: "Starting Shell…",
            kind: .shell
        )
        let projection = WarrenDesktopProjection(
            host: fixture.host,
            groups: fixture.groups,
            sessions: fixture.sessions,
            tabs: fixture.tabs + [pendingTab],
            sessionWorkspaceIDs: fixture.projection.sessionWorkspaceIDs,
            tabWorkspaceIDs: [pendingTab.id: workspaceID]
        )

        XCTAssertEqual(projection.tabs(in: workspaceID), [pendingTab])
        let selected = WarrenDesktopNavigationReducer.reduce(
            .init(selection: nil, selectedTabID: nil),
            action: .selectWorkspace(workspaceID),
            in: projection
        )
        XCTAssertEqual(selected.selectedTabID, pendingTab.id)
    }

    func testWorkspaceActivityUsesMostActionableSessionState() {
        let fixture = WarrenDesktopFixture.preview
        let workspaceID = fixture.groups[0].workspaces[0].id
        let working = fixture.sessions[0]
        let failed = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            tabID: "failed",
            title: "Failed",
            kind: .codex,
            state: .failed,
            activity: .failed
        )
        let waiting = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            tabID: "waiting",
            title: "Waiting",
            kind: .claude,
            activity: .waitingForInput
        )
        let projection = WarrenDesktopProjection(
            host: fixture.host,
            groups: fixture.groups,
            sessions: [working, waiting, failed]
        )

        XCTAssertEqual(projection.activity(in: workspaceID), .failed)
    }

    func testSelectingTabSynchronizesSidebarWorkspace() {
        let fixture = WarrenDesktopFixture.preview
        let reviewWorkspaceID = fixture.groups[1].workspaces[0].id
        let selected = WarrenDesktopNavigationReducer.reduce(
            .init(selection: nil, selectedTabID: nil),
            action: .selectTab("tab-review"),
            in: fixture.projection
        )

        XCTAssertEqual(selected.selection, .workspace(reviewWorkspaceID))
        XCTAssertEqual(selected.selectedTabID, "tab-review")
    }

    func testClosingSelectedTabStaysInsideWorkspace() {
        let fixture = WarrenDesktopFixture.preview
        let selected = WarrenDesktopNavigationReducer.reduce(
            .init(selection: .workspace(fixture.groups[0].workspaces[0].id), selectedTabID: "tab-main"),
            action: .closeTab("tab-main"),
            in: fixture.projection
        )

        XCTAssertEqual(selected.selection, .workspace(fixture.groups[0].workspaces[0].id))
        XCTAssertNil(selected.selectedTabID)
    }

    func testSelectingProjectResolvesItsDefaultWorkspaceAndLocalTab() {
        let fixture = WarrenDesktopFixture.preview
        let project = fixture.groups[1].project
        let workspace = fixture.groups[1].workspaces[0]

        let selected = WarrenDesktopNavigationReducer.reduce(
            .init(selection: nil, selectedTabID: nil),
            action: .selectProject(project.id),
            in: fixture.projection
        )

        XCTAssertEqual(selected.selection, .workspace(workspace.id))
        XCTAssertEqual(selected.selectedTabID, "tab-review")
        XCTAssertEqual(fixture.projection.tabs(in: workspace.id).map(\.id), ["tab-review"])
    }

    func testBackgroundTabPublicationDoesNotStealExplicitEmptyWorkspace() {
        let fixture = WarrenDesktopFixture.preview
        let workspaceWithoutTabID = fixture.groups[0].workspaces[1].id
        let state = WarrenDesktopNavigationState(
            selection: .workspace(workspaceWithoutTabID),
            selectedTabID: nil
        )

        XCTAssertEqual(
            WarrenDesktopNavigationReducer.reconcile(state, with: fixture.projection),
            state
        )
    }
}
