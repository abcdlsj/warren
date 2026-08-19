import WarrenDomain

/// Pure guard for the optional workspace-entry Shell convenience.
///
/// Selecting a workspace is always safe and passive. The composition root
/// calls this policy only for an explicit workspace-open gesture, and only
/// when the host setting enables the convenience.
public enum WarrenDesktopAutomaticSessionPolicy {
    public static func workspaceID(
        for action: WarrenDesktopAction,
        in projection: WarrenDesktopProjection,
        creatingWorkspaceIDs: Set<WorkspaceID>,
        autoOpenShell: Bool
    ) -> WorkspaceID? {
        guard autoOpenShell else { return nil }
        guard case .openWorkspace(let workspaceID) = action,
              projection.workspace(id: workspaceID) != nil,
              projection.tabs(in: workspaceID).isEmpty,
              !creatingWorkspaceIDs.contains(workspaceID) else {
            return nil
        }
        return workspaceID
    }
}
