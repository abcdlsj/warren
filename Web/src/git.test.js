import test from "node:test";
import assert from "node:assert/strict";
import { normalizeGitPanel, statusLabel, relativeTime } from "./git.js";

test("normalizeGitPanel groups staged and unstaged changes", () => {
  const panel = normalizeGitPanel({
    workspace: "w1",
    branch: "main",
    ahead: 2,
    behind: 1,
    changes: [
      { path: "a.txt", status: "M", staged: true },
      { path: "b.txt", status: "M", staged: false },
      { path: "c.txt", status: "?", staged: false },
    ],
    commits: [{ hash: "abc", files: [{ path: "x", status: "A" }] }],
    branches: [
      { name: "main", remote: false },
      { name: "origin/main", remote: true },
    ],
  });

  assert.equal(panel.branch, "main");
  assert.equal(panel.ahead, 2);
  assert.equal(panel.behind, 1);
  assert.deepEqual(panel.staged.map(c => c.path), ["a.txt"]);
  assert.deepEqual(panel.unstaged.map(c => c.path), ["b.txt", "c.txt"]);
  assert.deepEqual(panel.branches.local, ["main"]);
  assert.deepEqual(panel.branches.remote, ["origin/main"]);
  assert.deepEqual(panel.commits[0].files, [{ path: "x", status: "A" }]);
});

test("normalizeGitPanel tolerates missing payload", () => {
  const panel = normalizeGitPanel(null);
  assert.equal(panel.branch, "");
  assert.deepEqual(panel.staged, []);
  assert.deepEqual(panel.commits, []);
  assert.deepEqual(panel.branches.local, []);
});

test("statusLabel maps letters and falls back to raw", () => {
  assert.equal(statusLabel("M"), "Modified");
  assert.equal(statusLabel("?"), "Untracked");
  assert.equal(statusLabel("Q"), "Q");
});

test("relativeTime formats past timestamps", () => {
  const minute = 60 * 1000;
  const hour = 60 * minute;
  assert.equal(relativeTime(new Date(Date.now() - 30 * 1000).toISOString()), "just now");
  assert.equal(relativeTime(new Date(Date.now() - 5 * minute).toISOString()), "5 minutes ago");
  assert.equal(relativeTime(new Date(Date.now() - 2 * hour).toISOString()), "2 hours ago");
  assert.equal(relativeTime(new Date(Date.now() + 5 * minute).toISOString()), "just now");
  assert.equal(relativeTime(""), "");
  assert.equal(relativeTime("not-a-date"), "");
});
