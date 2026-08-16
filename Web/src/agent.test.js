import test from "node:test";
import assert from "node:assert/strict";

import { agentEventLimit, groupAgentEvents, mergeAgentEvents } from "./agent.js";

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

test("groupAgentEvents pairs tool calls with their outputs", () => {
  const blocks = groupAgentEvents([
    { seq: 1, type: "user", content: "hello" },
    { seq: 2, type: "tool_call", callId: "call-1", toolName: "Bash", toolInput: { command: "ls" } },
    { seq: 3, type: "tool_output", callId: "call-1", toolStatus: "success", output: "file.txt\n" },
    { seq: 4, type: "assistant", content: "done" },
  ]);
  assert.deepEqual(blocks.map(block => block.kind), ["user", "tool", "assistant"]);
  assert.equal(blocks[1].call.toolName, "Bash");
  assert.equal(blocks[1].outputs.length, 1);
  assert.equal(blocks[1].outputs[0].output, "file.txt\n");
});

test("groupAgentEvents keeps unmatched tool outputs standalone", () => {
  const blocks = groupAgentEvents([
    { seq: 1, type: "tool_output", callId: "unknown", output: "orphan" },
  ]);
  assert.equal(blocks.length, 1);
  assert.equal(blocks[0].kind, "tool_output");
});
