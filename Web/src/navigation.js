import { workspaceTabs } from "./catalog.js";

export function createNavigationMemory(raw = {}) {
  const normalize = value => Object.fromEntries(
    Object.entries(value && typeof value === "object" ? value : {}).filter(
      ([key, item]) => typeof key === "string" && typeof item === "string" && item,
    ),
  );
  return {
    workspaceByProjectID: normalize(raw.workspaceByProjectID),
    sessionByWorkspaceID: normalize(raw.sessionByWorkspaceID),
  };
}

export function rememberNavigation(memory, catalog, workspaceID, sessionID = null) {
  const next = createNavigationMemory(memory);
  const workspace = catalog?.workspaces?.find(value => value.id === workspaceID);
  if (!workspace) return next;

  next.workspaceByProjectID[workspace.project] = workspaceID;
  const tabs = workspaceTabs(catalog, workspaceID);
  if (sessionID && tabs.some(tab => tab.id === sessionID)) {
    next.sessionByWorkspaceID[workspaceID] = sessionID;
  }
  return next;
}

export function resolveProjectWorkspace(catalog, projectID, memory = {}) {
  const workspaces = catalog?.workspacesByProject?.get(projectID) || [];
  const normalized = createNavigationMemory(memory);
  const rememberedID = normalized.workspaceByProjectID[projectID];
  return workspaces.find(workspace => workspace.id === rememberedID)?.id
    || workspaces[0]?.id
    || null;
}

export function resolveWorkspaceSession(
  catalog,
  workspaceID,
  memory = {},
  preferredSessionID = null,
) {
  if (!catalog || !workspaceID) return null;
  const tabs = workspaceTabs(catalog, workspaceID);
  if (preferredSessionID && tabs.some(tab => tab.id === preferredSessionID)) {
    return preferredSessionID;
  }
  const normalized = createNavigationMemory(memory);
  const rememberedID = normalized.sessionByWorkspaceID[workspaceID];
  return tabs.find(tab => tab.id === rememberedID)?.id
    || tabs[0]?.id
    || null;
}

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
