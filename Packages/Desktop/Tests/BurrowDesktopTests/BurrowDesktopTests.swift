import XCTest
import SwiftUI
import AppKit
@testable import BurrowDesktop
import BurrowDesignSystem
import BurrowDomain

private struct TestTerminalSurface: View {
    let context: BurrowDesktopTerminalContext

    var body: some View {
        Text("surface:\(context.tab.id):\(context.workspace.id.rawValue.uuidString)")
    }
}

@MainActor
final class BurrowDesktopTests: XCTestCase {
    func testWorkspaceChromeIsDefaultAndDoesNotShowIndependentTopBar() {
        XCTAssertFalse(BurrowDesktopChromeMode.workspace.showsIndependentTopBar)
        XCTAssertTrue(BurrowDesktopChromeMode.dashboard.showsIndependentTopBar)

        let defaultMode = BurrowDesktopChromeMode.workspace
        XCTAssertEqual(defaultMode, .workspace)
    }

    func testReferenceFrameRendersAtSupersetDesktopSize() throws {
        let root = BurrowDesktopRoot(
            projection: BurrowDesktopFixture.preview.projection,
            actions: BurrowDesktopActions()
        ) { context in
            TestTerminalSurface(context: context)
        }
        .environment(\.colorScheme, .dark)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        XCTAssertEqual(hostingView.bounds.width, 1280)
        XCTAssertEqual(hostingView.bounds.height, 800)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 1280)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, 800)

        if ProcessInfo.processInfo.environment["DEN_CAPTURE_UI"] == "1" {
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/tmp/burrow-reference-frame.png"))
        }
    }

    func testSidebarStateUsesSupersetSnapAndRestoreValues() {
        var state = BurrowDesktopSidebarState()
        XCTAssertEqual(state.width, BurrowLayoutMetrics.sidebarExpandedWidth)
        XCTAssertFalse(state.isCollapsed)

        state.setWidth(119)
        XCTAssertTrue(state.isCollapsed)
        XCTAssertEqual(state.renderedWidth, BurrowLayoutMetrics.sidebarCollapsedWidth)

        state.restoreExpanded()
        XCTAssertFalse(state.isCollapsed)
        XCTAssertEqual(state.width, BurrowLayoutMetrics.sidebarExpandedWidth)

        state.setWidth(399)
        XCTAssertEqual(state.width, 399)
        state.setWidth(401)
        XCTAssertEqual(state.width, BurrowLayoutMetrics.sidebarMaximumWidth)
    }

    func testPreviewFixtureKeepsStableRowsAndRelationships() {
        let fixture = BurrowDesktopFixture.preview
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
        let fixture = BurrowDesktopFixture.preview
        let projection = BurrowDesktopProjection.empty(host: fixture.host)

        XCTAssertTrue(projection.groups.isEmpty)
        XCTAssertTrue(projection.tabs.isEmpty)
        XCTAssertNil(projection.inspector)
        XCTAssertTrue(projection.isConnected)
        XCTAssertNil(projection.workspace(id: fixture.groups[0].workspaces[0].id))
    }

    func testActionsExposeProjectWorkspaceAndTabIntentWithoutSideEffects() {
        var received: [BurrowDesktopAction] = []
        let actions = BurrowDesktopActions(
            send: { received.append($0) }
        )

        let fixture = BurrowDesktopFixture.preview
        let workspaceID = fixture.groups[0].workspaces[0].id
        let sessionID = fixture.sessions[0].id

        actions(.addProject)
        actions(.importSuperset)
        actions(.selectWorkspace(workspaceID))
        actions(.openSession(sessionID))
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
                .selectWorkspace(workspaceID),
                .openSession(sessionID),
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
        let fixture = BurrowDesktopFixture.preview
        let root = BurrowDesktopRoot(
            projection: fixture.projection,
            actions: BurrowDesktopActions()
        ) { context in
            TestTerminalSurface(context: context)
        }

        XCTAssertNotNil(root)
    }

    func testBuiltInPresetsMapToExplicitLaunchRequests() {
        XCTAssertEqual(BurrowDesktopSessionPreset.pinned.map(\.id), ["shell", "claude", "codex"])
        XCTAssertEqual(BurrowDesktopSessionPreset.pinned.map(\.request), [.shell, .claude, .codex])
        XCTAssertNil(TerminalSessionLaunchRequest.shell.command)
        XCTAssertEqual(TerminalSessionLaunchRequest.claude.command, "claude")
        XCTAssertEqual(TerminalSessionLaunchRequest.claude.title, "Claude Code")
        XCTAssertEqual(TerminalSessionLaunchRequest.codex.command, "codex")
    }

    func testSelectionReconcilesEmptyToLoadedProjection() {
        let fixture = BurrowDesktopFixture.preview
        let empty = BurrowDesktopProjection.empty(host: fixture.host)

        let emptyState = BurrowDesktopSelectionReconciler.reconcile(
            selection: nil,
            selectedTabID: nil,
            with: empty
        )
        XCTAssertNil(emptyState.selection)
        XCTAssertNil(emptyState.selectedTabID)

        let loadedState = BurrowDesktopSelectionReconciler.reconcile(
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
        let fixture = BurrowDesktopFixture.preview
        let firstProjectID = fixture.groups[0].project.id
        let firstWorkspaceID = fixture.groups[0].workspaces[0].id
        let secondWorkspaceID = fixture.groups[1].workspaces[0].id

        let current = BurrowDesktopSelectionReconciler.reconcile(
            selection: .workspace(firstWorkspaceID),
            selectedTabID: "tab-main",
            with: fixture.projection
        )
        XCTAssertEqual(current.selection, .workspace(firstWorkspaceID))
        XCTAssertEqual(current.selectedTabID, "tab-main")

        let reducedGroups = fixture.projection.groups.filter { $0.project.id != firstProjectID }
        let reducedProjection = BurrowDesktopProjection(
            host: fixture.host,
            groups: reducedGroups,
            sessions: fixture.projection.sessions.filter { $0.tabID != "tab-main" },
            tabs: fixture.projection.tabs.filter { $0.id != "tab-main" },
            sessionWorkspaceIDs: fixture.projection.sessionWorkspaceIDs
        )
        let reduced = BurrowDesktopSelectionReconciler.reconcile(
            selection: current.selection,
            selectedTabID: current.selectedTabID,
            with: reducedProjection
        )
        XCTAssertEqual(reduced.selection, .workspace(secondWorkspaceID))
        XCTAssertEqual(reduced.selectedTabID, "tab-review")

        let emptied = BurrowDesktopSelectionReconciler.reconcile(
            selection: reduced.selection,
            selectedTabID: reduced.selectedTabID,
            with: BurrowDesktopProjection.empty(host: fixture.host)
        )
        XCTAssertNil(emptied.selection)
        XCTAssertNil(emptied.selectedTabID)
    }

    func testSelectingWorkspaceNeverLeavesAnotherWorkspaceTabActive() {
        let fixture = BurrowDesktopFixture.preview
        let firstWorkspaceID = fixture.groups[0].workspaces[0].id
        let workspaceWithoutTabID = fixture.groups[0].workspaces[1].id
        let initial = BurrowDesktopNavigationState(
            selection: .workspace(firstWorkspaceID),
            selectedTabID: "tab-main"
        )

        let selected = BurrowDesktopNavigationReducer.reduce(
            initial,
            action: .selectWorkspace(workspaceWithoutTabID),
            in: fixture.projection
        )

        XCTAssertEqual(selected.selection, .workspace(workspaceWithoutTabID))
        XCTAssertNil(selected.selectedTabID)
        XCTAssertEqual(
            BurrowDesktopNavigationReducer.reconcile(selected, with: fixture.projection),
            selected
        )
    }

    func testSelectingTabSynchronizesSidebarWorkspace() {
        let fixture = BurrowDesktopFixture.preview
        let reviewWorkspaceID = fixture.groups[1].workspaces[0].id
        let selected = BurrowDesktopNavigationReducer.reduce(
            .init(selection: nil, selectedTabID: nil),
            action: .selectTab("tab-review"),
            in: fixture.projection
        )

        XCTAssertEqual(selected.selection, .workspace(reviewWorkspaceID))
        XCTAssertEqual(selected.selectedTabID, "tab-review")
    }

    func testClosingSelectedTabStaysInsideWorkspace() {
        let fixture = BurrowDesktopFixture.preview
        let selected = BurrowDesktopNavigationReducer.reduce(
            .init(selection: .workspace(fixture.groups[0].workspaces[0].id), selectedTabID: "tab-main"),
            action: .closeTab("tab-main"),
            in: fixture.projection
        )

        XCTAssertEqual(selected.selection, .workspace(fixture.groups[0].workspaces[0].id))
        XCTAssertNil(selected.selectedTabID)
    }

    func testSelectingProjectResolvesItsDefaultWorkspaceAndLocalTab() {
        let fixture = BurrowDesktopFixture.preview
        let project = fixture.groups[1].project
        let workspace = fixture.groups[1].workspaces[0]

        let selected = BurrowDesktopNavigationReducer.reduce(
            .init(selection: nil, selectedTabID: nil),
            action: .selectProject(project.id),
            in: fixture.projection
        )

        XCTAssertEqual(selected.selection, .workspace(workspace.id))
        XCTAssertEqual(selected.selectedTabID, "tab-review")
        XCTAssertEqual(fixture.projection.tabs(in: workspace.id).map(\.id), ["tab-review"])
    }

    func testBackgroundTabPublicationDoesNotStealExplicitEmptyWorkspace() {
        let fixture = BurrowDesktopFixture.preview
        let workspaceWithoutTabID = fixture.groups[0].workspaces[1].id
        let state = BurrowDesktopNavigationState(
            selection: .workspace(workspaceWithoutTabID),
            selectedTabID: nil
        )

        XCTAssertEqual(
            BurrowDesktopNavigationReducer.reconcile(state, with: fixture.projection),
            state
        )
    }
}
