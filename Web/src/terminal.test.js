import test from "node:test";
import assert from "node:assert/strict";
import { attachTerminalMessage, fitTerminalToHost, terminalSize } from "./terminal.js";

test("terminalSize accepts only a positive integer grid", () => {
  assert.deepEqual(terminalSize({ cols: 120, rows: 36 }), { cols: 120, rows: 36 });
  assert.equal(terminalSize({ cols: 0, rows: 24 }), null);
  assert.equal(terminalSize({ cols: 80, rows: -1 }), null);
  assert.equal(terminalSize({ cols: 80.5, rows: 24 }), null);
  assert.equal(terminalSize(null), null);
});

test("initial attach carries the fitted terminal grid", () => {
  assert.deepEqual(
    attachTerminalMessage("session-1", { cols: 96, rows: 31 }),
    { t: "attach", session: "session-1", cols: 96, rows: 31 },
  );
  assert.deepEqual(
    attachTerminalMessage("session-1", { cols: 0, rows: 31 }),
    { t: "attach", session: "session-1" },
  );
});

test("fitTerminalToHost waits for a measurable host and invokes fit once", () => {
  let calls = 0;
  const addon = { fit: () => { calls += 1; } };
  assert.equal(fitTerminalToHost(addon, { clientWidth: 0, clientHeight: 400 }), false);
  assert.equal(fitTerminalToHost(addon, { clientWidth: 800, clientHeight: 400 }), true);
  assert.equal(calls, 1);
});
