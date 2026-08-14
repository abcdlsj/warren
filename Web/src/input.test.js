import test from "node:test";
import assert from "node:assert/strict";
import { InputQueue } from "./input.js";

function encoded(value) {
  return new TextEncoder().encode(value);
}

test("enqueues input while attaching and replays it in order", () => {
  const sent = [];
  const queue = new InputQueue({
    send: data => {
      sent.push(new TextDecoder().decode(data));
      return true;
    },
  });
  queue.enqueue("session-a", encoded("he"));
  queue.enqueue("session-a", encoded("llo"));
  assert.equal(sent.length, 0, "nothing sends before the session is ready");

  assert.equal(queue.flush("session-a"), true);
  assert.deepEqual(sent, ["he", "llo"]);
  assert.equal(queue.size, 0);
});

test("flushing one session preserves another session's pending input", () => {
  const sent = [];
  const queue = new InputQueue({
    send: data => {
      sent.push(new TextDecoder().decode(data));
      return true;
    },
  });
  queue.enqueue("session-b", encoded("b"));
  queue.enqueue("session-a", encoded("a"));

  assert.equal(queue.flush("session-a"), true);
  assert.deepEqual(sent, ["a"]);
  assert.equal(queue.size, 1);

  assert.equal(queue.flush("session-b"), true);
  assert.deepEqual(sent, ["a", "b"]);
});

test("send failure keeps the failed frame and everything after it", () => {
  const sent = [];
  let failures = 0;
  let failAttempts = 0;
  const queue = new InputQueue({
    send: data => {
      const value = new TextDecoder().decode(data);
      if (value === "fail" && failAttempts === 0) {
        failAttempts += 1;
        return false;
      }
      sent.push(value);
      return true;
    },
    onSendFailure: () => {
      failures += 1;
    },
  });
  queue.enqueue("session-a", encoded("ok"));
  queue.enqueue("session-a", encoded("fail"));
  queue.enqueue("session-a", encoded("after"));
  queue.enqueue("session-b", encoded("other"));

  assert.equal(queue.flush("session-a"), false);
  assert.equal(failures, 1);
  assert.deepEqual(sent, ["ok"]);
  assert.equal(queue.size, 3);

  // The retry starts at the failed frame; bytes already delivered are gone.
  assert.equal(queue.flush("session-a"), true);
  assert.deepEqual(sent, ["ok", "fail", "after"]);
  assert.equal(queue.size, 1);
  assert.equal(queue.flush("session-b"), true);
});

test("clear drops queued input on an explicit session switch", () => {
  const queue = new InputQueue({ send: () => true });
  queue.enqueue("session-a", encoded("x"));
  queue.clear();
  assert.equal(queue.size, 0);
});

test("overflow evicts the oldest queued bytes", () => {
  const queue = new InputQueue({ limit: 10, send: () => true });
  queue.enqueue("session-a", encoded("12345"));
  queue.enqueue("session-a", encoded("67890"));
  queue.enqueue("session-a", encoded("abc"));
  assert.equal(queue.size, 2);
  assert.equal(queue.flush("session-a"), true);
  assert.equal(queue.size, 0);
});

test("send exceptions are treated as failures and keep the frame", () => {
  let failures = 0;
  const queue = new InputQueue({
    send: () => {
      throw new Error("socket closing");
    },
    onSendFailure: () => {
      failures += 1;
    },
  });
  queue.enqueue("session-a", encoded("x"));
  assert.equal(queue.flush("session-a"), false);
  assert.equal(failures, 1);
  assert.equal(queue.size, 1);
});
