import test from "node:test";
import assert from "node:assert/strict";

import { agentEventLimit, groupAgentEvents, mergeAgentEvents, questionData } from "./agent.js";

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

test("mergeAgentEvents keeps older pages intact when paginating", () => {
  const existing = Array.from({ length: agentEventLimit }, (_, index) => ({
    seq: index,
    type: "system",
  }));
  const olderPage = Array.from({ length: 200 }, (_, index) => ({
    seq: index - 200,
    type: "user",
    content: `old-${index}`,
  }));
  const merged = mergeAgentEvents(existing, olderPage, { cap: false });
  assert.equal(merged.length, agentEventLimit + 200);
  assert.equal(merged[0].seq, -200);
  assert.equal(merged.at(-1).seq, agentEventLimit - 1);
  // No middle gap: every sequence from the oldest loaded event to the newest
  // live event is still present.
  assert.deepEqual(
    merged.map(event => event.seq),
    Array.from({ length: agentEventLimit + 200 }, (_, index) => index - 200),
  );
});

test("groupAgentEvents pairs tool calls with their outputs", () => {
  const blocks = groupAgentEvents([
    { seq: 1, type: "user", content: "hello" },
    { seq: 2, type: "tool_call", callId: "call-1", toolName: "Bash", toolInput: { command: "ls" } },
    { seq: 3, type: "tool_output", callId: "call-1", toolStatus: "success", output: "file.txt\n" },
    { seq: 4, type: "assistant", content: "done" },
  ]);
  assert.deepEqual(blocks.map(block => block.kind), ["user", "activity_group", "assistant"]);
  assert.equal(blocks[1].tools[0].call.toolName, "Bash");
  assert.equal(blocks[1].tools[0].outputs.length, 1);
  assert.equal(blocks[1].tools[0].outputs[0].output, "file.txt\n");
});

test("groupAgentEvents folds a turn at its last activity position", () => {
  const blocks = groupAgentEvents([
    { seq: 1, type: "user", content: "hello" },
    { seq: 2, type: "reasoning", content: "think one" },
    { seq: 3, type: "assistant", content: "checking" },
    { seq: 4, type: "tool_call", callId: "call-1", toolName: "Bash", toolInput: { command: "ls" } },
    { seq: 5, type: "tool_output", callId: "call-1", toolStatus: "success", output: "a\n" },
    { seq: 6, type: "reasoning", content: "think two" },
    { seq: 7, type: "assistant", content: "done" },
  ]);
  assert.deepEqual(blocks.map(block => block.kind), ["user", "assistant", "activity_group", "assistant"]);
  assert.equal(blocks[2].reasoning.length, 2);
  assert.deepEqual(blocks[2].reasoning.map(event => event.content), ["think one", "think two"]);
  assert.equal(blocks[2].tools.length, 1);
  assert.equal(blocks[2].tools[0].call.toolName, "Bash");
  assert.deepEqual(blocks[2].order.map(item => item.kind), ["reasoning", "tool", "reasoning"]);
});

test("groupAgentEvents folds standalone tool runs without a user message", () => {
  const blocks = groupAgentEvents([
    { seq: 1, type: "tool_call", callId: "call-1", toolName: "Bash", toolInput: { command: "ls" } },
    { seq: 2, type: "tool_output", callId: "call-1", toolStatus: "success", output: "a\n" },
    { seq: 3, type: "tool_call", callId: "call-2", toolName: "Edit", toolInput: { file_path: "x.ts" } },
    { seq: 4, type: "tool_output", callId: "call-2", toolStatus: "success", output: "ok" },
  ]);
  assert.deepEqual(blocks.map(block => block.kind), ["activity_group"]);
  assert.equal(blocks[0].tools.length, 2);
  assert.deepEqual(blocks[0].tools.map(item => item.call.toolName), ["Bash", "Edit"]);
});

test("groupAgentEvents resets folding at each user message", () => {
  const blocks = groupAgentEvents([
    { seq: 1, type: "tool_call", callId: "call-1", toolName: "Bash", toolInput: { command: "ls" } },
    { seq: 2, type: "user", content: "again" },
    { seq: 3, type: "tool_call", callId: "call-2", toolName: "Edit", toolInput: { file_path: "x.ts" } },
  ]);
  assert.deepEqual(blocks.map(block => block.kind), ["activity_group", "user", "activity_group"]);
  assert.equal(blocks[0].tools.length, 1);
  assert.equal(blocks[2].tools.length, 1);
});

test("groupAgentEvents keeps unmatched tool outputs standalone", () => {
  const blocks = groupAgentEvents([
    { seq: 1, type: "tool_output", callId: "unknown", output: "orphan" },
  ]);
  assert.equal(blocks.length, 1);
  assert.equal(blocks[0].kind, "tool_output");
});

test("questionData extracts ask_user_questions prompts and options", () => {
  const call = {
    toolName: "ask_user_questions",
    toolInput: {
      questions: [
        { id: "q1", header: "Env", question: "Which environment?", options: [{ label: "UAT", description: "test" }, { label: "PROD" }] },
        { id: "q2", question: "Second?" },
      ],
    },
  };
  const data = questionData(call, []);
  assert.notEqual(data, null);
  assert.equal(data.questions.length, 2);
  assert.equal(data.questions[0].header, "Env");
  assert.equal(data.questions[0].question, "Which environment?");
  assert.equal(data.questions[0].options.length, 2);
  assert.equal(data.answer, "");
});

test("questionData extracts the chosen answer from tool output", () => {
  const call = { toolName: "ask_user_questions", toolInput: { questions: [{ question: "Go?" }] } };
  const data = questionData(call, [
    { output: '{"answers":[{"question_id":"q1","answer":"UAT"}]}' },
  ]);
  assert.equal(data.answer, "UAT");
});

test("questionData falls back to plain-text answers", () => {
  const call = { toolName: "request_user_input", toolInput: { question: "Ready?" } };
  const data = questionData(call, [{ output: "Not yet" }]);
  assert.equal(data.questions[0].question, "Ready?");
  assert.equal(data.answer, "Not yet");
});

test("questionData returns null for non-question tools", () => {
  assert.equal(questionData({ toolName: "exec_command", toolInput: { cmd: "ls" } }), null);
  assert.equal(questionData(null), null);
});
