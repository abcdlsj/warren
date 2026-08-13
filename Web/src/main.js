import { Terminal } from "@xterm/xterm";
import "@xterm/xterm/css/xterm.css";
import "./style.css";

import { buildCatalog, rosterFromMessage, workspaceTabs } from "./catalog.js";
import { RelayConnection } from "./connection.js";
import { runtime, serviceWorkerURL, webSocketURL } from "./runtime.js";
import { defaultTitleTemplate, renderTerminalTitle, titlePlaceholders } from "./title.js";
import {
  emptyTerminal,
  escapeHTML,
  loading,
  renderProjects,
  renderSearchResults,
  renderTabs,
} from "./view.js";

const storageKeys = {
  activeWorkspace: "warren.activeWorkspace",
  expandedProjects: "warren.expandedProjects",
  fontFamily: "warren.terminalFontFamily",
  fontSize: "warren.terminalFontSize",
  titleTemplate: "warren.terminalTitleTemplate",
};

const defaultFontFamily = 'ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace';
const defaultFontSize = matchMedia("(max-width: 760px)").matches ? 12 : 13;
const previewSession = {
  title: "Claude",
  process: "claude",
  directory: "/Users/me/Workspace/warren",
  kind: "claude",
};
const previewWorkspace = {
  name: "warren",
  branch: "main",
  path: "/Users/me/Workspace/warren",
};
const sessionPresets = {
  shell: { title: "Shell" },
  claude: { title: "Claude Code", command: "claude" },
  codex: { title: "Codex", command: "codex --dangerously-bypass-hook-trust" },
};

const element = id => document.getElementById(id);
const dom = {
  app: element("app"),
  connection: element("connection"),
  empty: element("empty"),
  fontFamily: element("font-family"),
  fontPreview: element("font-preview"),
  fontSize: element("font-size"),
  paneTitle: element("pane-title"),
  projects: element("projects"),
  searchInput: element("search-input"),
  searchPanel: element("search-panel"),
  searchResults: element("search-results"),
  settingsPage: element("settings-page"),
  status: element("status"),
  tabs: element("tabs"),
  terminal: element("terminal"),
  titlePreview: element("title-preview"),
  titleTemplate: element("title-template"),
};

let catalog = buildCatalog();
const state = {
  activeSession: null,
  activeWorkspace: localStorage.getItem(storageKeys.activeWorkspace),
  attachedSession: null,
  expandedProjects: loadSet(storageKeys.expandedProjects),
  fontFamily: localStorage.getItem(storageKeys.fontFamily) || defaultFontFamily,
  fontSize: Number(localStorage.getItem(storageKeys.fontSize)) || defaultFontSize,
  titleTemplate: localStorage.getItem(storageKeys.titleTemplate) || defaultTitleTemplate,
};

const terminal = new Terminal({
  theme: {
    background: "#151110",
    foreground: "#eae8e6",
    cursor: "#eae8e6",
    selectionBackground: "#3a3837",
  },
  fontFamily: state.fontFamily,
  fontSize: state.fontSize,
  lineHeight: 1.12,
  cursorBlink: true,
  scrollback: 5000,
  allowTransparency: false,
});
terminal.open(dom.terminal);

const connection = new RelayConnection({
  url: webSocketURL(),
  token: runtime.token,
  onMessage: acceptMessage,
  onState: acceptConnectionState,
});

function send(message) {
  return connection.sendJSON(message);
}

function sendInput(data) {
  if (data && state.activeSession && state.attachedSession === state.activeSession) {
    connection.sendBinary(data);
  }
}

function tabsForWorkspace(workspaceID) {
  return workspaceTabs(catalog, workspaceID);
}

function normalizeSelection() {
  if (state.activeWorkspace && !catalog.workspaces.some(workspace => workspace.id === state.activeWorkspace)) {
    state.activeWorkspace = null;
  }
  if (!state.activeWorkspace) state.activeWorkspace = catalog.workspaces[0]?.id || null;

  const workspace = catalog.workspaces.find(value => value.id === state.activeWorkspace);
  if (workspace) state.expandedProjects.add(workspace.project);
}

function render() {
  normalizeSelection();
  const tabs = state.activeWorkspace ? tabsForWorkspace(state.activeWorkspace) : [];
  dom.projects.innerHTML = renderProjects(
    catalog,
    state.activeWorkspace,
    state.expandedProjects,
    tabsForWorkspace,
  );
  dom.tabs.innerHTML = renderTabs(tabs, state.activeSession);

  const empty = emptyTerminal({
    activeWorkspace: state.activeWorkspace,
    activeSession: state.activeSession,
    attachedSession: state.attachedSession,
    tabCount: tabs.length,
    projectCount: catalog.projects.length,
  });
  dom.empty.hidden = empty.hidden;
  dom.empty.innerHTML = empty.html;
  updatePaneTitle();
  if (dom.searchPanel.classList.contains("open")) renderSearch();

  localStorage.setItem(storageKeys.activeWorkspace, state.activeWorkspace || "");
  localStorage.setItem(storageKeys.expandedProjects, JSON.stringify([...state.expandedProjects]));
}

function renderSearch() {
  dom.searchResults.innerHTML = renderSearchResults(catalog, dom.searchInput.value);
}

function updatePaneTitle() {
  const session = state.activeSession ? catalog.sessions.get(state.activeSession) : null;
  const workspace = catalog.workspaces.find(value => value.id === state.activeWorkspace);
  dom.paneTitle.textContent = session
    ? renderTerminalTitle(state.titleTemplate, session, workspace, catalog.host)
    : "";
  dom.titlePreview.textContent = "Preview: " + renderTerminalTitle(
    state.titleTemplate,
    session || previewSession,
    workspace || previewWorkspace,
    catalog.host,
  );
}

function attachSession(sessionID) {
  if (!sessionID || sessionID === state.attachedSession) return;
  const changed = sessionID !== state.activeSession;
  state.activeSession = sessionID;
  state.attachedSession = null;
  if (changed) terminal.clear();
  send({ t: "attach", session: sessionID });
  render();
}

function chooseWorkspace(workspaceID, preferredSessionID = null) {
  const wasAttached = Boolean(state.activeSession || state.attachedSession);
  const tabs = tabsForWorkspace(workspaceID);
  state.activeWorkspace = workspaceID;
  state.activeSession = null;
  state.attachedSession = null;
  terminal.clear();
  dom.app.classList.remove("drawer-open");
  render();

  if (preferredSessionID) attachSession(preferredSessionID);
  else if (tabs.length) attachSession(tabs[0].id);
  else if (wasAttached) send({ t: "detach" });
}

function createSession(kind) {
  if (!state.activeWorkspace) return;
  const preset = sessionPresets[kind] || sessionPresets.shell;
  const sent = send({
    t: "create",
    workspace: state.activeWorkspace,
    kind,
    command: preset.command || null,
    title: preset.title,
  });
  dom.empty.hidden = false;
  dom.empty.innerHTML = sent
    ? loading(`Starting ${preset.title}…`)
    : loading("Waiting for connection…");
  if (!sent) connection.reconnectNow();
}

function acceptRoster(message) {
  connection.markStable();
  catalog = buildCatalog(rosterFromMessage(message));
  normalizeSelection();
  const tabs = state.activeWorkspace ? tabsForWorkspace(state.activeWorkspace) : [];
  const activeTabWasRemoved = state.activeSession && !tabs.some(tab => tab.id === state.activeSession);
  if (activeTabWasRemoved) {
    state.activeSession = null;
    state.attachedSession = null;
    terminal.clear();
  }
  render();
  setConnection("Connected", true);
  if (state.activeSession) attachSession(state.activeSession);
  else if (tabs.length) attachSession(tabs[0].id);
  else if (activeTabWasRemoved) send({ t: "detach" });
}

function acceptMessage(event) {
  if (event.data instanceof ArrayBuffer) {
    terminal.write(new Uint8Array(event.data));
    return;
  }
  let message;
  try {
    message = JSON.parse(event.data);
  } catch {
    setConnection("Protocol error", false);
    connection.reset();
    return;
  }
  switch (message.t) {
  case "roster":
    acceptRoster(message);
    break;
  case "attached":
    state.activeSession = message.session;
    state.attachedSession = message.session;
    render();
    requestAnimationFrame(() => {
      fitTerminal();
      terminal.focus();
    });
    break;
  case "created":
    state.activeSession = null;
    state.attachedSession = null;
    attachSession(message.session);
    break;
  case "runtimeMetadata": {
    const session = catalog.sessions.get(message.session);
    if (!session) break;
    session.process = message.process || "";
    session.directory = message.directory || "";
    updatePaneTitle();
    break;
  }
  case "sessionDeleted":
    if (state.activeSession === message.session) {
      state.activeSession = null;
      state.attachedSession = null;
      terminal.clear();
    }
    break;
  case "error":
    setConnection(message.message || "Error", false);
    dom.empty.hidden = false;
    dom.empty.textContent = message.message || "Session error";
    if (message.message === "unauthorized") connection.stop();
    break;
  }
}

function acceptConnectionState(connectionState) {
  if (connectionState === "connecting") {
    setConnection("Connecting…", false);
    return;
  }
  if (connectionState === "open") {
    setConnection("Authenticating…", false);
    return;
  }
  state.attachedSession = null;
  setConnection("Reconnecting…", false);
  render();
}

function setConnection(message, online) {
  dom.status.textContent = message;
  dom.connection.classList.toggle("online", online);
}

function applyTerminalFont() {
  state.fontFamily = dom.fontFamily.value.trim() || defaultFontFamily;
  state.fontSize = clamp(Number(dom.fontSize.value) || defaultFontSize, 8, 32);
  localStorage.setItem(storageKeys.fontFamily, state.fontFamily);
  localStorage.setItem(storageKeys.fontSize, String(state.fontSize));
  terminal.options.fontFamily = state.fontFamily;
  terminal.options.fontSize = state.fontSize;
  dom.fontPreview.style.fontFamily = state.fontFamily;
  dom.fontPreview.style.fontSize = `${state.fontSize}px`;
  requestAnimationFrame(fitTerminal);
}

function fitTerminal() {
  const mobile = matchMedia("(max-width:760px)").matches;
  const cellWidth = mobile ? 7.3 : 8;
  const cellHeight = mobile ? 15.2 : 16.3;
  terminal.resize(
    Math.max(20, Math.floor(dom.terminal.clientWidth / cellWidth)),
    Math.max(6, Math.floor(dom.terminal.clientHeight / cellHeight)),
  );
}

function openSearch() {
  renderSearch();
  dom.searchPanel.classList.add("open");
  dom.searchInput.focus();
}

function closeSearch() {
  dom.searchPanel.classList.remove("open");
}

function bindEvents() {
  dom.projects.onclick = event => {
    const toggle = event.target.closest("[data-project-toggle]");
    if (toggle) {
      const projectID = toggle.dataset.projectToggle;
      if (state.expandedProjects.has(projectID)) state.expandedProjects.delete(projectID);
      else state.expandedProjects.add(projectID);
      render();
      return;
    }
    const workspace = event.target.closest("[data-workspace]");
    if (workspace) chooseWorkspace(workspace.dataset.workspace);
  };
  dom.tabs.onclick = event => {
    const tab = event.target.closest("[data-session]");
    if (tab) attachSession(tab.dataset.session);
  };
  dom.empty.onclick = event => {
    if (event.target.closest("[data-empty-new]")) createSession("shell");
  };

  document.querySelectorAll("[data-kind]").forEach(button => {
    button.onclick = () => createSession(button.dataset.kind);
  });
  element("new-session").onclick = () => createSession("shell");
  element("menu").onclick = () => dom.app.classList.add("drawer-open");
  element("backdrop").onclick = () => dom.app.classList.remove("drawer-open");
  window.addEventListener("online", () => connection.reconnectNow());

  bindSettings();
  bindSearch();
  bindTerminal();
}

function bindSettings() {
  dom.titleTemplate.value = state.titleTemplate;
  dom.fontFamily.value = state.fontFamily;
  dom.fontSize.value = String(state.fontSize);
  dom.fontFamily.oninput = applyTerminalFont;
  dom.fontSize.oninput = applyTerminalFont;
  applyTerminalFont();

  const placeholders = element("placeholders");
  placeholders.innerHTML = Object.entries(titlePlaceholders).map(([key, description]) =>
    `<button type="button" class="placeholder" data-placeholder="{${key}}" title="${escapeHTML(description)}">{${key}}</button>`,
  ).join("");
  placeholders.onclick = event => {
    const button = event.target.closest("[data-placeholder]");
    if (!button) return;
    const space = dom.titleTemplate.value && !dom.titleTemplate.value.endsWith(" ") ? " " : "";
    dom.titleTemplate.value += space + button.dataset.placeholder;
    dom.titleTemplate.dispatchEvent(new Event("input"));
  };
  dom.titleTemplate.oninput = () => {
    state.titleTemplate = dom.titleTemplate.value.trim() || defaultTitleTemplate;
    localStorage.setItem(storageKeys.titleTemplate, state.titleTemplate);
    updatePaneTitle();
  };
  element("restore-title-default").onclick = () => {
    dom.titleTemplate.value = defaultTitleTemplate;
    dom.titleTemplate.dispatchEvent(new Event("input"));
    dom.fontFamily.value = defaultFontFamily;
    dom.fontSize.value = String(defaultFontSize);
    applyTerminalFont();
  };
  element("settings").onclick = () => {
    closeSearch();
    updatePaneTitle();
    dom.app.hidden = true;
    dom.settingsPage.classList.add("open");
  };
  element("settings-back").onclick = () => {
    dom.settingsPage.classList.remove("open");
    dom.app.hidden = false;
    requestAnimationFrame(fitTerminal);
  };
}

function bindSearch() {
  element("search").onclick = openSearch;
  element("search-close").onclick = closeSearch;
  dom.searchInput.oninput = renderSearch;
  dom.searchResults.onclick = event => {
    const workspace = event.target.closest("[data-search-workspace]");
    if (workspace) {
      closeSearch();
      chooseWorkspace(workspace.dataset.searchWorkspace);
      return;
    }
    const project = event.target.closest("[data-search-project]");
    const firstWorkspace = project && catalog.workspacesByProject.get(project.dataset.searchProject)?.[0];
    if (firstWorkspace) {
      closeSearch();
      chooseWorkspace(firstWorkspace.id);
    }
  };
  document.addEventListener("keydown", event => {
    if (event.key === "Escape" && dom.searchPanel.classList.contains("open")) closeSearch();
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
      event.preventDefault();
      openSearch();
    }
  });
}

function bindTerminal() {
  const mobileKeys = {
    escape: "\u001b",
    tab: "\t",
    ctrlC: "\u0003",
    ctrlD: "\u0004",
    up: "\u001b[A",
    down: "\u001b[B",
    right: "\u001b[C",
    left: "\u001b[D",
  };
  document.querySelectorAll("[data-key]").forEach(button => {
    button.onclick = () => sendInput(mobileKeys[button.dataset.key]);
  });
  terminal.onData(sendInput);
  terminal.onResize(size => {
    if (state.activeSession && state.attachedSession === state.activeSession) {
      send({ t: "resize", cols: size.cols, rows: size.rows });
    }
  });
  new ResizeObserver(() => {
    if (state.activeSession) fitTerminal();
  }).observe(dom.terminal);
}

function loadSet(key) {
  try {
    return new Set(JSON.parse(localStorage.getItem(key) || "[]"));
  } catch {
    return new Set();
  }
}

function clamp(value, minimum, maximum) {
  return Math.min(maximum, Math.max(minimum, value));
}

bindEvents();
connection.start();
if ("serviceWorker" in navigator && location.protocol !== "file:") {
  navigator.serviceWorker.register(serviceWorkerURL()).catch(() => {});
}
render();
