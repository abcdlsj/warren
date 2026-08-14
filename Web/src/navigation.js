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
