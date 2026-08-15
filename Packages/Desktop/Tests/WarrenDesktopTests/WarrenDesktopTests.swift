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

    func testTabBarDragFillerSpansEmptyTrackWhenTabsFit() {
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let dragViews = descendantViews(
            of: hostingView,
            as: WarrenDesktopWindowDragView.self
        )
        guard let filler = dragViews.first(where: {
            $0.identifier?.rawValue == "warren.tab-bar-drag-region"
        }) else {
            XCTFail("Tab bar drag filler is missing")
            return
        }

        XCTAssertGreaterThanOrEqual(filler.frame.width, 100)
    }

    private func descendantViews<T: NSView>(
        of view: NSView,
        as type: T.Type
    ) -> [T] {
        var matches: [T] = []
        for subview in view.subviews {
            if let typed = subview as? T {
                matches.append(typed)
            }
            matches.append(contentsOf: descendantViews(of: subview, as: type))
        }
        return matches
    }

    func testWindowDragRegionUsesDedicatedAppKitView() {
        let view = WarrenDesktopWindowDragView()

        XCTAssertFalse(view.acceptsFirstResponder)
    }

    func testWindowDragRegionPerformsDragOnSingleClick() {
        let view = WarrenDesktopWindowDragView()
        let window = WarrenDragProbeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view

        view.mouseDown(with: Self.mouseDownEvent(clickCount: 1))

        XCTAssertTrue(window.didRequestDrag)
        XCTAssertFalse(window.didToggleFullScreen)
    }

    func testWindowDragRegionTogglesFullScreenOnDoubleClick() {
        let view = WarrenDesktopWindowDragView()
        let window = WarrenDragProbeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view

        view.mouseDown(with: Self.mouseDownEvent(clickCount: 2))

        XCTAssertTrue(window.didToggleFullScreen)
        XCTAssertFalse(window.didRequestDrag)
    }

    private static func mouseDownEvent(clickCount: Int) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: clickCount,
            pressure: 1
        )!
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

    func testProjectionFindsFirstWorkspaceAfterAnEmptyProject() {
        let host = WarrenDomain.Host(name: "Indexed Host")
        let emptyProject = Project(hostID: host.id, name: "Empty", rootPath: "/tmp/empty")
        let populatedProject = Project(hostID: host.id, name: "Populated", rootPath: "/tmp/full")
        let workspace = Workspace(
            projectID: populatedProject.id,
            name: "main",
            path: "/tmp/full"
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [emptyProject, populatedProject],
            workspaces: [workspace]
        )

        XCTAssertEqual(projection.firstWorkspace, workspace)
        XCTAssertEqual(projection.firstWorkspace(in: populatedProject.id), workspace)
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
        actions(.restoreNavigation(WarrenDesktopNavigationState(
            selection: .workspace(workspaceID),
            selectedTabID: "tab-main"
        )))
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
                .restoreNavigation(WarrenDesktopNavigationState(
                    selection: .workspace(workspaceID),
                    selectedTabID: "tab-main"
                )),
                .closeTab("tab-main"),
                .toggleInspector,
                .toggleSidebar,
            ]
        )
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

    func testTabCyclerRequiresMultipleTabsAndWrapsInBothDirections() {
        let tabs = WarrenDesktopFixture.preview.projection.tabs
        XCTAssertEqual(tabs.count, 2)

        XCTAssertNil(WarrenDesktopTabCycler.tabID(
            forward: true,
            in: [tabs[0]],
            selectedTabID: tabs[0].id
        ))
        XCTAssertEqual(WarrenDesktopTabCycler.tabID(
            forward: true,
            in: tabs,
            selectedTabID: nil
        ), tabs[0].id)
        XCTAssertEqual(WarrenDesktopTabCycler.tabID(
            forward: true,
            in: tabs,
            selectedTabID: tabs[0].id
        ), tabs[1].id)
        XCTAssertEqual(WarrenDesktopTabCycler.tabID(
            forward: true,
            in: tabs,
            selectedTabID: tabs[1].id
        ), tabs[0].id)
        XCTAssertEqual(WarrenDesktopTabCycler.tabID(
            forward: false,
            in: tabs,
            selectedTabID: tabs[0].id
        ), tabs[1].id)
    }

    func testTabNumberSelectorIsOneBasedAndBoundsChecked() {
        let tabs = WarrenDesktopFixture.preview.projection.tabs
        XCTAssertEqual(WarrenDesktopTabSelector.tabID(in: tabs, number: 1), tabs[0].id)
        XCTAssertEqual(WarrenDesktopTabSelector.tabID(in: tabs, number: 2), tabs[1].id)
        XCTAssertNil(WarrenDesktopTabSelector.tabID(in: tabs, number: 0))
        XCTAssertNil(WarrenDesktopTabSelector.tabID(in: tabs, number: 3))
        XCTAssertNil(WarrenDesktopTabSelector.tabID(in: [], number: 1))
    }

    func testTabTitleUsesDirectoryNameForInteractiveShell() {
        let workspaceID = WorkspaceID()
        let sessionID = TerminalSessionID()
        let tab = ClientTab(
            id: "tab-1",
            title: "Shell",
            sessionID: sessionID,
            kind: .shell
        )
        let session = WarrenDesktopSession(
            id: sessionID,
            workspaceID: workspaceID,
            title: "Shell",
            kind: .shell,
            runtimeProcess: "zsh",
            workingDirectory: "/Users/me/Workspace/warren"
        )
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "warren",
            path: "/Users/me/Workspace/warren"
        )

        XCTAssertEqual(
            WarrenDesktopTabTitle.displayTitle(
                tab: tab,
                session: session,
                workspace: workspace
            ),
            "warren"
        )
    }

    func testTabTitleShowsRunningProcessAlongsideDirectory() {
        let workspaceID = WorkspaceID()
        let sessionID = TerminalSessionID()
        let tab = ClientTab(
            id: "tab-2",
            title: "Codex",
            sessionID: sessionID,
            kind: .codex
        )
        let session = WarrenDesktopSession(
            id: sessionID,
            workspaceID: workspaceID,
            title: "Codex",
            kind: .codex,
            runtimeProcess: "codex",
            workingDirectory: "/Users/me/Workspace/superset"
        )

        XCTAssertEqual(
            WarrenDesktopTabTitle.displayTitle(
                tab: tab,
                session: session,
                workspace: nil
            ),
            "codex — superset"
        )
    }

    func testTabTitleFallsBackWhenNoDirectoryIsKnown() {
        let tab = ClientTab(id: "tab-3", title: "Shell", kind: .shell)

        XCTAssertEqual(
            WarrenDesktopTabTitle.displayTitle(
                tab: tab,
                session: nil,
                workspace: nil
            ),
            "Shell"
        )
    }

    func testTabTitlePrefersCustomSessionTitle() {
        let workspaceID = WorkspaceID()
        let sessionID = TerminalSessionID()
        let tab = ClientTab(
            id: "tab-4",
            title: "Shell",
            sessionID: sessionID,
            kind: .shell
        )
        let session = WarrenDesktopSession(
            id: sessionID,
            workspaceID: workspaceID,
            title: "Shell",
            customTitle: "My Agent",
            kind: .shell,
            runtimeProcess: "zsh",
            workingDirectory: "/Users/me/Workspace/warren"
        )
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "warren",
            path: "/Users/me/Workspace/warren"
        )

        XCTAssertEqual(
            WarrenDesktopTabTitle.displayTitle(
                tab: tab,
                session: session,
                workspace: workspace
            ),
            "My Agent"
        )
    }

    func testProjectionKeepsPinnedProjectsWorkspacesAndSessionsFirst() {
        let host = WarrenDomain.Host(name: "Pinned Host")
        let pinnedProject = Project(
            hostID: host.id,
            name: "Pinned",
            rootPath: "/tmp/pinned",
            pinned: true
        )
        let regularProject = Project(hostID: host.id, name: "Regular", rootPath: "/tmp/regular")
        let pinnedWorkspace = Workspace(
            projectID: pinnedProject.id,
            name: "Pinned Worktree",
            path: "/tmp/pinned-worktree",
            pinned: true
        )
        let regularWorkspace = Workspace(
            projectID: pinnedProject.id,
            name: "Regular Worktree",
            path: "/tmp/regular-worktree"
        )
        let pinnedSessionID = TerminalSessionID()
        let regularSessionID = TerminalSessionID()
        let pinnedSession = WarrenDesktopSession(
            id: pinnedSessionID,
            workspaceID: pinnedWorkspace.id,
            title: "Pinned",
            pinned: true
        )
        let regularSession = WarrenDesktopSession(
            id: regularSessionID,
            workspaceID: pinnedWorkspace.id,
            title: "Regular"
        )
        let pinnedTab = ClientTab(
            id: "pinned-tab",
            title: "Pinned",
            sessionID: pinnedSessionID
        )
        let regularTab = ClientTab(
            id: "regular-tab",
            title: "Regular",
            sessionID: regularSessionID
        )

        let projection = WarrenDesktopProjection(
            host: host,
            projects: [regularProject, pinnedProject],
            workspaces: [regularWorkspace, pinnedWorkspace],
            sessions: [regularSession, pinnedSession],
            tabs: [regularTab, pinnedTab],
            sessionWorkspaceIDs: [
                pinnedSessionID: pinnedWorkspace.id,
                regularSessionID: pinnedWorkspace.id,
            ]
        )

        XCTAssertEqual(projection.groups.first?.project.id, pinnedProject.id)
        XCTAssertEqual(projection.groups.first?.workspaces.first?.id, pinnedWorkspace.id)
        XCTAssertEqual(projection.tabs.first?.id, pinnedTab.id)
    }

    func testPresetIconCacheLoadsHitsAndMissesOnlyOnce() {
        var loads: [String] = []
        let expected = NSImage(size: NSSize(width: 12, height: 12))
        let cache = WarrenPresetIconCache { name in
            loads.append(name)
            return name == "known" ? expected : nil
        }

        XCTAssertTrue(cache.image(named: "known") === expected)
        XCTAssertTrue(cache.image(named: "known") === expected)
        XCTAssertNil(cache.image(named: "missing"))
        XCTAssertNil(cache.image(named: "missing"))
        XCTAssertEqual(loads, ["known", "missing"])
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

    func testRestoringSettingsPositionReturnsToThePreviousWorkspaceAndTab() {
        let fixture = WarrenDesktopFixture.preview
        let previous = WarrenDesktopNavigationState(
            selection: .workspace(fixture.groups[1].workspaces[0].id),
            selectedTabID: "tab-review"
        )
        let current = WarrenDesktopNavigationState(
            selection: .workspace(fixture.groups[0].workspaces[0].id),
            selectedTabID: "tab-main"
        )

        let restored = WarrenDesktopNavigationReducer.reduce(
            current,
            action: .restoreNavigation(previous),
            in: fixture.projection
        )

        XCTAssertEqual(restored, previous)
    }

    func testRestoringSettingsPositionReconcilesADeletedTabWithoutLeavingItsWorkspace() {
        let fixture = WarrenDesktopFixture.preview
        let workspaceID = fixture.groups[0].workspaces[0].id
        let previous = WarrenDesktopNavigationState(
            selection: .workspace(workspaceID),
            selectedTabID: "deleted-tab"
        )

        let restored = WarrenDesktopNavigationReducer.reduce(
            WarrenDesktopNavigationState(selection: nil, selectedTabID: nil),
            action: .restoreNavigation(previous),
            in: fixture.projection
        )

        XCTAssertEqual(restored.selection, .workspace(workspaceID))
        XCTAssertEqual(restored.selectedTabID, "tab-main")
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
        XCTAssertEqual(projection.workspaceActivities[workspaceID], .failed)
        XCTAssertEqual(projection.session(id: failed.id), failed)
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

    func testNavigationPersistenceRoundTripsWorkspaceAndTab() throws {
        let suiteName = "WarrenDesktopTests.navigation.workspace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = WarrenDesktopFixture.preview
        let state = WarrenDesktopNavigationState(
            selection: .workspace(fixture.groups[0].workspaces[0].id),
            selectedTabID: "tab-main"
        )

        WarrenDesktopNavigationPersistence.save(state, to: defaults)
        XCTAssertEqual(WarrenDesktopNavigationPersistence.restore(from: defaults), state)
    }

    func testNavigationPersistenceRoundTripsProject() throws {
        let suiteName = "WarrenDesktopTests.navigation.project.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = WarrenDesktopFixture.preview
        let state = WarrenDesktopNavigationState(
            selection: .project(fixture.groups[0].project.id),
            selectedTabID: nil
        )

        WarrenDesktopNavigationPersistence.save(state, to: defaults)
        XCTAssertEqual(WarrenDesktopNavigationPersistence.restore(from: defaults), state)
    }

    func testNavigationPersistenceClearsWhenEmpty() throws {
        let suiteName = "WarrenDesktopTests.navigation.empty.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        WarrenDesktopNavigationPersistence.save(
            WarrenDesktopNavigationState(selection: nil, selectedTabID: nil),
            to: defaults
        )

        XCTAssertNil(WarrenDesktopNavigationPersistence.restore(from: defaults))
    }

    func testSidebarTreePersistenceIsPerScopeAndRoundTrips() throws {
        let suiteName = "WarrenDesktopTests.sidebarTree.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = WarrenDesktopSidebarTreeState(
            expandedProjectIDs: [ProjectID(), ProjectID()],
            projectsCollapsed: true
        )

        WarrenDesktopSidebarTreePersistence.save(state, scope: "local", defaults: defaults)

        XCTAssertEqual(
            WarrenDesktopSidebarTreePersistence.restore(scope: "local", defaults: defaults),
            state
        )
        XCTAssertEqual(
            WarrenDesktopSidebarTreePersistence.restore(scope: "server", defaults: defaults),
            WarrenDesktopSidebarTreeState()
        )
    }

    func testNavigationReducerIgnoresSidebarMoves() {
        let projection = WarrenDesktopFixture.preview.projection
        let initial = WarrenDesktopNavigationReducer.initial(for: projection)
        let projectID = projection.groups[0].project.id

        XCTAssertEqual(
            WarrenDesktopNavigationReducer.reduce(
                initial,
                action: .moveProject(projectID, before: nil),
                in: projection
            ),
            initial
        )
        if let workspace = projection.groups[0].workspaces.first {
            XCTAssertEqual(
                WarrenDesktopNavigationReducer.reduce(
                    initial,
                    action: .moveWorkspace(workspace.id, before: nil),
                    in: projection
                ),
                initial
            )
        }
    }
}

@MainActor
private final class WarrenDragProbeWindow: NSWindow {
    var didRequestDrag = false
    var didToggleFullScreen = false

    override func performDrag(with event: NSEvent) {
        didRequestDrag = true
    }

    override func toggleFullScreen(_ sender: Any?) {
        didToggleFullScreen = true
    }
}
