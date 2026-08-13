import test from "node:test";
import assert from "node:assert/strict";
import { buildCatalog, rosterFromMessage, workspaceTabs } from "./catalog.js";
import { renderTerminalTitle } from "./title.js";
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

test("HTML escaping is safe for text and attributes", () => {
  assert.equal(escapeHTML(`<a title="x">&</a>`), "&lt;a title=&quot;x&quot;&gt;&amp;&lt;/a&gt;");
});
