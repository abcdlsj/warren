import test from "node:test";
import assert from "node:assert/strict";
import { OutputBatcher } from "./output.js";

function manualFrameLoop() {
  const callbacks = new Map();
  let nextID = 1;
  let scheduled = 0;
  return {
    requestFrame: callback => {
      scheduled += 1;
      const id = nextID++;
      callbacks.set(id, callback);
      return id;
    },
    cancelFrame: id => callbacks.delete(id),
    scheduledCount: () => scheduled,
    tick: () => {
      const queued = [...callbacks.values()];
      callbacks.clear();
      for (const callback of queued) callback();
    },
  };
}

test("coalesces chunks into one ordered write per frame", () => {
  const frames = manualFrameLoop();
  const writes = [];
  const batcher = new OutputBatcher({
    write: bytes => writes.push(bytes),
    requestFrame: frames.requestFrame,
    cancelFrame: frames.cancelFrame,
    isHidden: () => false,
  });
  batcher.enqueue(new TextEncoder().encode("hello"));
  batcher.enqueue(new TextEncoder().encode(" "));
  batcher.enqueue(new TextEncoder().encode("world"));
  assert.equal(writes.length, 0, "nothing writes before the animation frame");
  frames.tick();
  assert.equal(writes.length, 1);
  assert.equal(new TextDecoder().decode(writes[0]), "hello world");
});

test("flush writes pending bytes synchronously and in order", () => {
  const frames = manualFrameLoop();
  const writes = [];
  const batcher = new OutputBatcher({
    write: bytes => writes.push(bytes),
    requestFrame: frames.requestFrame,
    cancelFrame: frames.cancelFrame,
    isHidden: () => false,
  });
  batcher.enqueue(new TextEncoder().encode("first"));
  batcher.enqueue(new TextEncoder().encode("second"));
  batcher.flush();
  assert.equal(writes.length, 1);
  assert.equal(new TextDecoder().decode(writes[0]), "firstsecond");
  frames.tick();
  assert.equal(writes.length, 1, "the canceled frame must not write again");
});

test("hidden pages stop scheduling and overflow triggers reanchor", () => {
  const frames = manualFrameLoop();
  const writes = [];
  let hidden = true;
  let overflows = 0;
  const batcher = new OutputBatcher({
    write: bytes => writes.push(bytes),
    requestFrame: frames.requestFrame,
    cancelFrame: frames.cancelFrame,
    maxPending: 10,
    isHidden: () => hidden,
    onOverflow: () => { overflows += 1; },
  });
  batcher.enqueue(new Uint8Array(5));
  assert.equal(frames.scheduledCount(), 0, "hidden page must not schedule rAF");
  batcher.enqueue(new Uint8Array(10));
  assert.equal(overflows, 1);
  assert.equal(batcher.pendingBytes, 0, "overflow clears the pending buffer");

  hidden = false;
  batcher.enqueue(new Uint8Array(3));
  assert.equal(frames.scheduledCount(), 1);
  frames.tick();
  assert.equal(writes.length, 1);
  assert.equal(writes[0].length, 3);
});

test("wake flushes output accumulated while the page was hidden", () => {
  const frames = manualFrameLoop();
  const writes = [];
  let hidden = true;
  const batcher = new OutputBatcher({
    write: bytes => writes.push(bytes),
    requestFrame: frames.requestFrame,
    cancelFrame: frames.cancelFrame,
    isHidden: () => hidden,
  });
  batcher.enqueue(new Uint8Array(5));
  assert.equal(frames.scheduledCount(), 0, "hidden page must not schedule rAF");

  hidden = false;
  batcher.wake();
  assert.equal(frames.scheduledCount(), 1, "wake must schedule a frame");
  frames.tick();
  assert.equal(writes.length, 1);
  assert.equal(writes[0].length, 5);
});
