export function rosterFromMessage(message = {}) {
  return {
    host: message.host || {},
    projects: message.projects || [],
    workspaces: message.workspaces || [],
    tabs: message.tabs || [],
  };
}

export function buildCatalog(roster = rosterFromMessage()) {
  const sessions = new Map();
  const tabsByWorkspace = new Map();
  const workspacesByProject = new Map();

  for (const tab of roster.tabs) {
    sessions.set(tab.session, { ...tab, id: tab.session });
    append(tabsByWorkspace, tab.workspace, tab);
  }
  for (const workspace of roster.workspaces) {
    append(workspacesByProject, workspace.project, workspace);
  }

  return { ...roster, sessions, tabsByWorkspace, workspacesByProject };
}

export function workspaceTabs(catalog, workspaceID) {
  return (catalog.tabsByWorkspace.get(workspaceID) || []).flatMap(tab => {
    const session = catalog.sessions.get(tab.session);
    if (!session) return [];
    return [{
      ...session,
      tabID: tab.id,
      title: tab.title || session.title,
      kind: tab.kind || session.kind,
    }];
  });
}

function append(map, key, value) {
  const values = map.get(key) || [];
  values.push(value);
  map.set(key, values);
}
