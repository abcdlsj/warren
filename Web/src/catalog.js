export function rosterFromMessage(message = {}) {
  if (message.state) {
    const state = message.state;
    return {
      host: state.host || {},
      projects: state.projects || [],
      workspaces: state.workspaces || [],
      tabs: (state.sessions || [])
        .filter(session => session.lifecycle === "running")
        .map(session => ({
          id: session.id,
          session: session.id,
          workspace: session.workspace,
          title: session.title,
          customTitle: session.customTitle,
          kind: session.kind,
          lifecycle: session.lifecycle,
          process: session.command || "",
          pinned: session.pinned || false,
        })),
    };
  }
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
  const projects = [...roster.projects].sort(pinnedFirst);
  const workspaces = [...roster.workspaces].sort(pinnedFirst);
  const tabs = [...roster.tabs].sort(pinnedFirst);

  for (const tab of tabs) {
    sessions.set(tab.session, { ...tab, id: tab.session });
    append(tabsByWorkspace, tab.workspace, tab);
  }
  for (const workspace of workspaces) {
    append(workspacesByProject, workspace.project, workspace);
  }

  return { ...roster, projects, workspaces, sessions, tabsByWorkspace, workspacesByProject };
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
  }).sort(pinnedFirst);
}

function append(map, key, value) {
  const values = map.get(key) || [];
  values.push(value);
  map.set(key, values);
}

function pinnedFirst(left, right) {
  return Number(Boolean(right.pinned)) - Number(Boolean(left.pinned));
}
