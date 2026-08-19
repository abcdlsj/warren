import WarrenDomain

/// Pure guard for the optional empty-workspace entry conveniences.
///
/// A normal selection can start the first AI only when explicitly enabled.
/// A double-click/open action can start either the configured AI or Shell;
/// the composition root gives AI precedence when both options are enabled.
public enum WarrenDesktopAutomaticSessionPolicy {
    public static func workspaceID(
        for action: WarrenDesktopAction,
        in projection: WarrenDesktopProjection,
        creatingWorkspaceIDs: Set<WorkspaceID>,
        autoOpenShell: Bool,
        autoStartAI: Bool = false
    ) -> WorkspaceID? {
        let workspaceID: WorkspaceID?
        switch action {
        case .openWorkspace(let id):
            guard autoOpenShell || autoStartAI else { return nil }
            workspaceID = id
        case .selectWorkspace(let id):
            guard autoStartAI else { return nil }
            workspaceID = id
        case .selectProject(let id):
            guard autoStartAI else { return nil }
            workspaceID = projection.firstWorkspace(in: id)?.id
        default:
            return nil
        }
        guard let workspaceID,
              projection.workspace(id: workspaceID) != nil,
              projection.tabs(in: workspaceID).isEmpty,
              !creatingWorkspaceIDs.contains(workspaceID) else {
            return nil
        }
        return workspaceID
    }
}
