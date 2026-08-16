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
  assert.deepEqual(blocks.map(block => block.kind), ["user", "tool_group", "assistant"]);
  assert.equal(blocks[1].items[0].call.toolName, "Bash");
  assert.equal(blocks[1].items[0].outputs.length, 1);
  assert.equal(blocks[1].items[0].outputs[0].output, "file.txt\n");
});

test("groupAgentEvents collapses adjacent reasoning into one group", () => {
  const blocks = groupAgentEvents([
    { seq: 1, type: "user", content: "hello" },
    { seq: 2, type: "reasoning", content: "think one" },
    { seq: 3, type: "reasoning", content: "think two" },
    { seq: 4, type: "assistant", content: "done" },
  ]);
  assert.deepEqual(blocks.map(block => block.kind), ["user", "reasoning_group", "assistant"]);
  assert.equal(blocks[1].events.length, 2);
  assert.deepEqual(blocks[1].events.map(event => event.content), ["think one", "think two"]);
});

test("groupAgentEvents collapses adjacent tool calls into one group", () => {
  const blocks = groupAgentEvents([
    { seq: 1, type: "tool_call", callId: "call-1", toolName: "Bash", toolInput: { command: "ls" } },
    { seq: 2, type: "tool_output", callId: "call-1", toolStatus: "success", output: "a\n" },
    { seq: 3, type: "tool_call", callId: "call-2", toolName: "Edit", toolInput: { file_path: "x.ts" } },
    { seq: 4, type: "tool_output", callId: "call-2", toolStatus: "success", output: "ok" },
  ]);
  assert.deepEqual(blocks.map(block => block.kind), ["tool_group"]);
  assert.equal(blocks[0].items.length, 2);
  assert.deepEqual(blocks[0].items.map(item => item.call.toolName), ["Bash", "Edit"]);
});

test("groupAgentEvents keeps separated tool groups separate", () => {
  const blocks = groupAgentEvents([
    { seq: 1, type: "tool_call", callId: "call-1", toolName: "Bash", toolInput: { command: "ls" } },
    { seq: 2, type: "assistant", content: "checking" },
    { seq: 3, type: "tool_call", callId: "call-2", toolName: "Edit", toolInput: { file_path: "x.ts" } },
  ]);
  assert.deepEqual(blocks.map(block => block.kind), ["tool_group", "assistant", "tool_group"]);
  assert.equal(blocks[0].items.length, 1);
  assert.equal(blocks[2].items.length, 1);
});

test("groupAgentEvents keeps unmatched tool outputs standalone", () => {
  const blocks = groupAgentEvents([
    { seq: 1, type: "tool_output", callId: "unknown", output: "orphan" },
  ]);
  assert.equal(blocks.length, 1);
  assert.equal(blocks[0].kind, "tool_output");
});
