import test from "node:test";
import assert from "node:assert/strict";

import { agentEventLimit, mergeAgentEvents } from "./agent.js";

test("mergeAgentEvents keeps sequence order and deduplicates overlap", () => {
  const existing = [
    { seq: 1, type: "system", content: "started" },
    { seq: 2, type: "user", content: "hello" },
  ];
  const incoming = [
    { seq: 2, type: "user", content: "hello" },
    { seq: 3, type: "assistant", content: "hi" },
  ];
  const merged = mergeAgentEvents(existing, incoming);
  assert.deepEqual(merged.map(event => event.seq), [1, 2, 3]);
  assert.deepEqual(merged.map(event => event.content), ["started", "hello", "hi"]);
});

test("mergeAgentEvents caps history at the agent event limit", () => {
  const existing = Array.from({ length: agentEventLimit }, (_, index) => ({ seq: index, type: "system" }));
  const incoming = [{ seq: agentEventLimit, type: "user", content: "new" }];
  const merged = mergeAgentEvents(existing, incoming);
  assert.equal(merged.length, agentEventLimit);
  assert.equal(merged[0].seq, 1);
  assert.equal(merged.at(-1).seq, agentEventLimit);
});
