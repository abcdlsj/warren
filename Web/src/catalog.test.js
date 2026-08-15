import test from "node:test";
import assert from "node:assert/strict";
import { buildCatalog, rosterFromMessage, workspaceTabs } from "./catalog.js";
import {
  captureNavigationPosition,
  resolveRestoredWorkspace,
  restoreNavigationPosition,
} from "./navigation.js";
import { renderTerminalTitle, terminalTabTitle } from "./title.js";
import { escapeHTML } from "./view.js";

test("catalog indexes workspaces and open tabs", () => {
  const catalog = buildCatalog(rosterFromMessage({
    workspaces: [{ id: "workspace", project: "project" }],
    tabs: [{ id: "tab", session: "session", workspace: "workspace", title: "Shell" }],
  }));

  assert.equal(catalog.workspacesByProject.get("project")[0].id, "workspace");
  assert.deepEqual(workspaceTabs(catalog, "workspace"), [{
    id: "session",
    session: "session",
    workspace: "workspace",
    tabID: "tab",
    title: "Shell",
    kind: undefined,
  }]);
});

test("custom session titles win over derived tab titles", () => {
  assert.equal(
    terminalTabTitle(
      { title: "Codex", customTitle: "My Agent", process: "codex", directory: "/work/warren" },
      {},
    ),
    "My Agent",
  );
});

test("catalog keeps pinned workspaces and sessions first", () => {
  const catalog = buildCatalog(rosterFromMessage({
    projects: [
      { id: "project-b", name: "B", pinned: false },
      { id: "project-a", name: "A", pinned: true },
    ],
    workspaces: [
      { id: "workspace-b", project: "project-a", name: "B" },
      { id: "workspace-a", project: "project-a", name: "A", pinned: true },
    ],
    tabs: [
      { id: "tab-b", session: "session-b", workspace: "workspace-a", title: "B" },
      { id: "tab-a", session: "session-a", workspace: "workspace-a", title: "A", pinned: true },
    ],
  }));

  assert.equal(catalog.projects[0].id, "project-a");
  assert.equal(catalog.workspaces[0].id, "workspace-a");
  assert.equal(workspaceTabs(catalog, "workspace-a")[0].id, "session-a");
});

test("terminal title removes empty separators", () => {
  assert.equal(
    renderTerminalTitle("{command} — {directoryName}", { title: "Session" }),
    "shell",
  );
  assert.equal(
    renderTerminalTitle("{command} — {directoryName}", { process: "codex", directory: "/work/warren" }),
    "codex — warren",
  );
});

test("terminal tab title uses directory name for interactive shells", () => {
  assert.equal(
    terminalTabTitle(
      { title: "Shell", process: "zsh", directory: "/Users/me/Workspace/warren" },
      {},
    ),
    "warren",
  );
});

test("terminal tab title shows running process alongside directory", () => {
  assert.equal(
    terminalTabTitle(
      { title: "Codex", process: "codex", directory: "/Users/me/Workspace/superset" },
      {},
    ),
    "codex — superset",
  );
});

test("terminal tab title falls back without a directory", () => {
  assert.equal(terminalTabTitle({ title: "Shell" }, {}), "Shell");
});

test("HTML escaping is safe for text and attributes", () => {
  assert.equal(escapeHTML(`<a title="x">&</a>`), "&lt;a title=&quot;x&quot;&gt;&amp;&lt;/a&gt;");
});

test("settings return restores the last workspace and session", () => {
  const catalog = buildCatalog(rosterFromMessage({
    workspaces: [
      { id: "workspace-main", project: "project" },
      { id: "workspace-review", project: "project" },
    ],
    tabs: [
      { id: "tab-main", session: "session-main", workspace: "workspace-main", title: "Main" },
      { id: "tab-review", session: "session-review", workspace: "workspace-review", title: "Review" },
    ],
  }));

  const position = captureNavigationPosition({
    activeWorkspace: "workspace-review",
    activeSession: "session-review",
  });
  assert.deepEqual(restoreNavigationPosition(position, catalog), {
    workspaceID: "workspace-review",
    sessionID: "session-review",
  });
});

test("settings return keeps the workspace when its previous session disappeared", () => {
  const catalog = buildCatalog(rosterFromMessage({
    workspaces: [{ id: "workspace-main", project: "project" }],
    tabs: [],
  }));

  assert.deepEqual(
    restoreNavigationPosition({ workspaceID: "workspace-main", sessionID: "deleted" }, catalog),
    { workspaceID: "workspace-main", sessionID: null },
  );
  assert.equal(
    restoreNavigationPosition({ workspaceID: "deleted", sessionID: "deleted" }, catalog),
    null,
  );
});

test("refresh restore prefers the saved session's workspace", () => {
  const catalog = buildCatalog(rosterFromMessage({
    workspaces: [
      { id: "workspace-main", project: "project" },
      { id: "workspace-review", project: "project" },
    ],
    tabs: [
      { id: "tab-main", session: "session-main", workspace: "workspace-main", title: "Main" },
      { id: "tab-review", session: "session-review", workspace: "workspace-review", title: "Review" },
    ],
  }));

  assert.equal(
    resolveRestoredWorkspace(catalog, "workspace-main", "session-review"),
    "workspace-review",
  );
  assert.equal(
    resolveRestoredWorkspace(catalog, "workspace-main", "deleted"),
    "workspace-main",
  );
  assert.equal(
    resolveRestoredWorkspace(catalog, "deleted", "deleted"),
    "workspace-main",
  );
});
