import test from "node:test";
import assert from "node:assert/strict";

import { buildCatalog, rosterFromMessage } from "./catalog.js";
import {
  rememberNavigation,
  resolveProjectWorkspace,
  resolveWorkspaceSession,
} from "./navigation.js";

function fixtureCatalog() {
  return buildCatalog(rosterFromMessage({
    projects: [
      { id: "project" },
      { id: "other-project" },
    ],
    workspaces: [
      { id: "workspace-main", project: "project" },
      { id: "workspace-feature", project: "project" },
      { id: "workspace-other", project: "other-project" },
    ],
    tabs: [
      { id: "session-main", session: "session-main", workspace: "workspace-main" },
      { id: "session-feature", session: "session-feature", workspace: "workspace-feature" },
      { id: "session-other", session: "session-other", workspace: "workspace-other" },
    ],
  }));
}

test("navigation memory restores the last tab for each workspace", () => {
  const catalog = fixtureCatalog();
  const memory = rememberNavigation({}, catalog, "workspace-main", "session-main");

  assert.equal(
    resolveWorkspaceSession(catalog, "workspace-main", memory),
    "session-main",
  );
  assert.equal(
    resolveWorkspaceSession(catalog, "workspace-feature", memory),
    "session-feature",
  );
});

test("navigation memory restores the last workspace for a project", () => {
  const catalog = fixtureCatalog();
  const memory = rememberNavigation({}, catalog, "workspace-feature", "session-feature");

  assert.equal(
    resolveProjectWorkspace(catalog, "project", memory),
    "workspace-feature",
  );
});

test("navigation memory falls back when remembered resources disappear", () => {
  const catalog = fixtureCatalog();
  const memory = {
    workspaceByProjectID: { project: "deleted-workspace" },
    sessionByWorkspaceID: { "workspace-main": "deleted-session" },
  };

  assert.equal(resolveProjectWorkspace(catalog, "project", memory), "workspace-main");
  assert.equal(resolveWorkspaceSession(catalog, "workspace-main", memory), "session-main");
});
