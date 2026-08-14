import { workspaceTabs } from "./catalog.js";

export function captureNavigationPosition(state = {}) {
  return {
    workspaceID: state.activeWorkspace || null,
    sessionID: state.activeSession || null,
  };
}

export function restoreNavigationPosition(position, catalog) {
  if (!position || !catalog) return null;

  const workspaceID = position.workspaceID && catalog.workspaces.some(
    workspace => workspace.id === position.workspaceID,
  )
    ? position.workspaceID
    : null;
  if (!workspaceID) return null;

  const sessionID = position.sessionID && workspaceTabs(catalog, workspaceID).some(
    session => session.id === position.sessionID,
  )
    ? position.sessionID
    : null;

  return { workspaceID, sessionID };
}

// Resolves the workspace to restore after a full page reload. The session the
// user was viewing is the anchor: if it still exists, its workspace wins even
// when the saved workspace no longer matches (for example after the user
// switched sessions just before refresh).
export function resolveRestoredWorkspace(catalog, preferredWorkspaceID, sessionID) {
  const session = sessionID ? catalog.sessions.get(sessionID) : null;
  const sessionWorkspaceID = session?.workspace || null;
  if (sessionWorkspaceID && catalog.workspaces.some(workspace => workspace.id === sessionWorkspaceID)) {
    return sessionWorkspaceID;
  }
  if (preferredWorkspaceID && catalog.workspaces.some(workspace => workspace.id === preferredWorkspaceID)) {
    return preferredWorkspaceID;
  }
  return catalog.workspaces[0]?.id || null;
}
