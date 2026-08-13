import WarrenClientCore
import WarrenDomain

/// Device-local navigation owned by the application composition layer.
///
/// Host snapshots own durable projects, workspaces, sessions and tabs. This
/// value owns only which of those values the foreground window is presenting.
public struct WarrenDesktopNavigationState: Equatable, Sendable {
    public var selection: WarrenDesktopSidebarSelection?
    public var selectedTabID: String?

    public init(
        selection: WarrenDesktopSidebarSelection? = nil,
        selectedTabID: String? = nil
    ) {
        self.selection = selection
        self.selectedTabID = selectedTabID
    }
}

/// Pure navigation reducer. A click updates this state synchronously; Host and
/// tmux side effects may finish later without becoming another selection owner.
public enum WarrenDesktopNavigationReducer {
    public static func initial(
        for projection: WarrenDesktopProjection
    ) -> WarrenDesktopNavigationState {
        guard let tab = projection.tabs.first,
              let workspace = workspace(for: tab.id, in: projection) else {
            return WarrenDesktopNavigationState(
                selection: firstSelection(in: projection),
                selectedTabID: nil
            )
        }
        return WarrenDesktopNavigationState(
            selection: .workspace(workspace.id),
            selectedTabID: tab.id
        )
    }

    public static func reduce(
        _ state: WarrenDesktopNavigationState,
        action: WarrenDesktopAction,
        in projection: WarrenDesktopProjection
    ) -> WarrenDesktopNavigationState {
        switch action {
        case .selectProject(let projectID):
            guard let workspace = projection.firstWorkspace(in: projectID) else {
                return WarrenDesktopNavigationState(
                    selection: .project(projectID),
                    selectedTabID: nil
                )
            }
            return WarrenDesktopNavigationState(
                selection: .workspace(workspace.id),
                selectedTabID: firstTabID(inWorkspace: workspace.id, projection: projection)
            )
        case .selectWorkspace(let workspaceID):
            return WarrenDesktopNavigationState(
                selection: .workspace(workspaceID),
                selectedTabID: firstTabID(inWorkspace: workspaceID, projection: projection)
            )
        case .selectTab(let tabID):
            guard projection.tabs.contains(where: { $0.id == tabID }) else { return state }
            let selection = workspace(for: tabID, in: projection)
                .map { WarrenDesktopSidebarSelection.workspace($0.id) }
                ?? state.selection
            return WarrenDesktopNavigationState(selection: selection, selectedTabID: tabID)
        case .openSession(let sessionID):
            guard let session = projection.sessions.first(where: { $0.id == sessionID }) else {
                return state
            }
            return WarrenDesktopNavigationState(
                selection: .workspace(session.workspaceID),
                selectedTabID: session.tabID
            )
        case .closeTab(let tabID):
            guard state.selectedTabID == tabID else { return state }
            let tabs = tabs(for: state.selection, projection: projection)
            guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return state }
            let remaining = tabs.enumerated().filter { $0.element.id != tabID }
            let replacement = remaining.first(where: { $0.offset >= index })?.element
                ?? remaining.last?.element
            guard let replacement else {
                return WarrenDesktopNavigationState(
                    selection: state.selection,
                    selectedTabID: nil
                )
            }
            return reduce(state, action: .selectTab(replacement.id), in: projection)
        case .closeOtherTabs(let tabID):
            return reduce(state, action: .selectTab(tabID), in: projection)
        case .closeAllTabs:
            return WarrenDesktopNavigationState(
                selection: state.selection,
                selectedTabID: nil
            )
        case .addProject, .importSuperset, .requestNewWorkspace,
             .requestNewSession, .launchSession,
             .toggleInspector, .toggleSidebar:
            return state
        }
    }

    public static func reconcile(
        _ state: WarrenDesktopNavigationState,
        with projection: WarrenDesktopProjection
    ) -> WarrenDesktopNavigationState {
        let hadValidSelection = state.selection.map { isValid($0, in: projection) } ?? false
        let selection = hadValidSelection ? state.selection : firstSelection(in: projection)

        if let tabID = state.selectedTabID,
           projection.tabs.contains(where: { $0.id == tabID }),
           tab(tabID, belongsTo: selection, in: projection) {
            return WarrenDesktopNavigationState(selection: selection, selectedTabID: tabID)
        }

        // A valid explicit workspace with no selected tab is an intentional
        // empty workspace view. Background snapshot publications must not
        // steal focus by selecting an unrelated tab.
        if hadValidSelection, state.selectedTabID == nil {
            return WarrenDesktopNavigationState(selection: selection, selectedTabID: nil)
        }

        return WarrenDesktopNavigationState(
            selection: selection,
            selectedTabID: firstTabID(for: selection, projection: projection)
        )
    }

    private static func tab(
        _ tabID: String,
        belongsTo selection: WarrenDesktopSidebarSelection?,
        in projection: WarrenDesktopProjection
    ) -> Bool {
        guard let selection else { return true }
        guard let workspace = workspace(for: tabID, in: projection) else { return false }
        switch selection {
        case .workspace(let workspaceID):
            return workspace.id == workspaceID
        case .project(let projectID):
            return workspace.projectID == projectID
        }
    }

    private static func firstTabID(
        for selection: WarrenDesktopSidebarSelection?,
        projection: WarrenDesktopProjection
    ) -> String? {
        guard let selection else { return projection.tabs.first?.id }
        switch selection {
        case .project(let projectID):
            return firstTabID(inProject: projectID, projection: projection)
        case .workspace(let workspaceID):
            return firstTabID(inWorkspace: workspaceID, projection: projection)
        }
    }

    private static func tabs(
        for selection: WarrenDesktopSidebarSelection?,
        projection: WarrenDesktopProjection
    ) -> [ClientTab] {
        guard let selection else { return projection.tabs }
        switch selection {
        case .project(let projectID):
            return projection.tabs.filter { tab in
                workspace(for: tab.id, in: projection)?.projectID == projectID
            }
        case .workspace(let workspaceID):
            return projection.tabs(in: workspaceID)
        }
    }

    private static func firstTabID(
        inProject projectID: ProjectID,
        projection: WarrenDesktopProjection
    ) -> String? {
        projection.tabs.first { tab in
            workspace(for: tab.id, in: projection)?.projectID == projectID
        }?.id
    }

    private static func firstTabID(
        inWorkspace workspaceID: WorkspaceID,
        projection: WarrenDesktopProjection
    ) -> String? {
        projection.tabs.first { tab in
            workspace(for: tab.id, in: projection)?.id == workspaceID
        }?.id
    }

    private static func workspace(
        for tabID: String,
        in projection: WarrenDesktopProjection
    ) -> Workspace? {
        projection.workspaceID(forTabID: tabID).flatMap(projection.workspace(id:))
    }

    private static func isValid(
        _ selection: WarrenDesktopSidebarSelection,
        in projection: WarrenDesktopProjection
    ) -> Bool {
        switch selection {
        case .project(let projectID):
            projection.groups.contains { $0.project.id == projectID }
        case .workspace(let workspaceID):
            projection.workspace(id: workspaceID) != nil
        }
    }

    private static func firstSelection(
        in projection: WarrenDesktopProjection
    ) -> WarrenDesktopSidebarSelection? {
        if let tabID = projection.tabs.first?.id,
           let workspace = workspace(for: tabID, in: projection) {
            return .workspace(workspace.id)
        }
        for group in projection.groups {
            if let workspace = group.workspaces.first {
                return .workspace(workspace.id)
            }
        }
        return projection.groups.first.map { .project($0.project.id) }
    }
}

// Kept package-internal while probes and older tests migrate to the public API.
typealias WarrenDesktopReconciledState = WarrenDesktopNavigationState

enum WarrenDesktopSelectionReconciler {
    static func reconcile(
        selection: WarrenDesktopSidebarSelection?,
        selectedTabID: String?,
        with projection: WarrenDesktopProjection
    ) -> WarrenDesktopNavigationState {
        WarrenDesktopNavigationReducer.reconcile(
            WarrenDesktopNavigationState(
                selection: selection,
                selectedTabID: selectedTabID
            ),
            with: projection
        )
    }
}
