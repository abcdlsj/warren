const activityLabels = {
  working: "Working",
  waitingForInput: "Needs input",
  failed: "Failed",
  ready: "Ready",
  exited: "Exited",
  connecting: "Connecting",
};

const activityPriority = {
  failed: 5,
  waitingForInput: 4,
  connecting: 3,
  working: 2,
  ready: 1,
  exited: 0,
};

const terminalIcon = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="3" y="4" width="18" height="16" rx="2"/><path d="m7 9 3 3-3 3m5 0h5"/></svg>';
const folderIcon = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M3 7h7l2 2h9v10H3z"/><path d="M3 7V5h7l2 2"/></svg>';

export function renderProjects(catalog, activeWorkspace, expandedProjects, tabsForWorkspace) {
  const html = catalog.projects.map(project => {
    const workspaces = catalog.workspacesByProject.get(project.id) || [];
    const open = expandedProjects.has(project.id);
    const rows = workspaces.map(workspace => {
      const activity = highestActivity(tabsForWorkspace(workspace.id));
      const active = workspace.id === activeWorkspace ? " active" : "";
      return `<button class="workspace-row${active}" data-workspace="${escapeHTML(workspace.id)}">${activityDot(activity)}<span class="branch">${escapeHTML(workspace.branch || workspace.name || "Workspace")}</span></button>`;
    }).join("");
    return `<section class="project${open ? " open" : ""}" data-project="${escapeHTML(project.id)}"><button class="project-toggle" data-project-toggle="${escapeHTML(project.id)}" aria-expanded="${open}"><span class="chevron">›</span><span class="branch">${escapeHTML(project.name)}</span></button><div class="workspace-list">${rows}</div></section>`;
  }).join("");

  return html || '<div class="workspace-row">No projects</div>';
}

export function renderTabs(tabs, activeSession) {
  return tabs.map(session => {
    const active = session.id === activeSession;
    return `<button role="tab" aria-selected="${active}" class="tab${active ? " active" : ""}" data-tab="${escapeHTML(session.tabID)}" data-session="${escapeHTML(session.id)}">${activityDot(session.activity)}<span class="tab-title">${escapeHTML(session.title)}</span></button>`;
  }).join("");
}

export function emptyTerminal({ activeWorkspace, activeSession, attachedSession, tabCount, projectCount }) {
  if (activeSession && attachedSession === activeSession) return { hidden: true, html: "" };
  if (activeSession) return { hidden: false, html: loading("Connecting…") };
  if (activeWorkspace && tabCount) return { hidden: false, html: "<span>Select a session</span>" };
  if (activeWorkspace) {
    return {
      hidden: false,
      html: `<div class="empty-state">${terminalIcon}<div class="empty-title">Start a session</div><button class="empty-action" data-empty-new>New Session</button></div>`,
    };
  }
  const title = projectCount ? "Select a workspace" : "No projects on this host";
  return {
    hidden: false,
    html: `<div class="empty-state">${folderIcon}<div class="empty-title">${title}</div></div>`,
  };
}

export function renderSearchResults(catalog, query) {
  const needle = query.trim().toLowerCase();
  const matches = value => !needle || String(value || "").toLowerCase().includes(needle);
  const cards = catalog.projects.flatMap(project => {
    const workspaces = catalog.workspacesByProject.get(project.id) || [];
    const projectMatches = matches(project.name) || matches(project.path);
    const visibleWorkspaces = workspaces.filter(workspace =>
      projectMatches || matches(workspace.name) || matches(workspace.branch),
    );
    if (!projectMatches && !visibleWorkspaces.length) return [];
    const rows = visibleWorkspaces.map(workspace =>
      `<button class="search-workspace" data-search-workspace="${escapeHTML(workspace.id)}"><span>•</span><span class="search-name">${escapeHTML(workspace.branch || workspace.name || "Workspace")}</span><span class="search-kind">Workspace</span></button>`,
    ).join("");
    return [`<section class="search-project"><button class="search-project-button" data-search-project="${escapeHTML(project.id)}"><span>□</span><span class="search-copy"><span class="search-name">${escapeHTML(project.name)}</span><span class="search-path">${escapeHTML(project.path || "")}</span></span></button>${rows}</section>`];
  }).join("");

  return cards || '<div class="search-empty">No projects found</div>';
}

export function loading(message) {
  return `<span class="terminal-loading"><span class="spinner"></span>${escapeHTML(message)}</span>`;
}

export function escapeHTML(value) {
  return String(value ?? "").replace(/[&<>'"]/g, character => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "'": "&#39;",
    '"': "&quot;",
  })[character]);
}

function highestActivity(sessions) {
  return sessions.reduce((highest, session) => {
    const activity = session.activity;
    return (activityPriority[activity] || 0) > (activityPriority[highest] || 0) ? activity : highest;
  }, null);
}

function activityDot(activity) {
  const label = activityLabels[activity];
  if (!label) return "";
  const pulse = activity === "ready" || activity === "exited" ? "" : " pulse";
  return `<span class="activity ${activity}${pulse}" title="${label}" aria-label="${label}"></span>`;
}
