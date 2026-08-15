import test from "node:test";
import assert from "node:assert/strict";
import {
  attachTerminalMessage,
  fitTerminalToHost,
  terminalSearchSummary,
  terminalSize,
} from "./terminal.js";

test("terminalSize accepts only a positive integer grid", () => {
  assert.deepEqual(terminalSize({ cols: 120, rows: 36 }), { cols: 120, rows: 36 });
  assert.equal(terminalSize({ cols: 0, rows: 24 }), null);
  assert.equal(terminalSize({ cols: 80, rows: -1 }), null);
  assert.equal(terminalSize({ cols: 80.5, rows: 24 }), null);
  assert.equal(terminalSize(null), null);
});

test("attach subscribes without claiming shared terminal focus", () => {
  assert.deepEqual(
    attachTerminalMessage("session-1", { cols: 96, rows: 31 }),
    { method: "session.attach", params: { id: "session-1", focused: false } },
  );
  assert.deepEqual(
    attachTerminalMessage("session-1", { cols: 0, rows: 31 }),
    { method: "session.attach", params: { id: "session-1", focused: false } },
  );
});

test("fitTerminalToHost waits for a measurable host and invokes fit once", () => {
  let calls = 0;
  const addon = { fit: () => { calls += 1; } };
  assert.equal(fitTerminalToHost(addon, { clientWidth: 0, clientHeight: 400 }), false);
  assert.equal(fitTerminalToHost(addon, { clientWidth: 800, clientHeight: 400 }), true);
  assert.equal(calls, 1);
});

test("terminalSearchSummary formats empty, total-only and active-index states", () => {
  assert.equal(terminalSearchSummary(0, 0, false), "");
  assert.equal(terminalSearchSummary(-1, 0, true), "No results");
  assert.equal(terminalSearchSummary(-1, 12, true), "12 found");
  assert.equal(terminalSearchSummary(2, 12, true), "3/12");
});
