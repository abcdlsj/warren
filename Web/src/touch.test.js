import test from "node:test";
import assert from "node:assert/strict";
import { PixelScrollAccumulator } from "./touch.js";

test("PixelScrollAccumulator emits whole lines as pixels accumulate", () => {
  const lines = [];
  const accumulator = new PixelScrollAccumulator({
    getStep: () => 16,
    onLine: amount => lines.push(amount),
  });
  accumulator.add(15);
  assert.deepEqual(lines, []);
  accumulator.add(1);
  assert.deepEqual(lines, [1]);
});

test("PixelScrollAccumulator handles negative (finger-down) deltas", () => {
  const lines = [];
  const accumulator = new PixelScrollAccumulator({
    getStep: () => 16,
    onLine: amount => lines.push(amount),
  });
  accumulator.add(-16);
  assert.deepEqual(lines, [-1]);
});

test("PixelScrollAccumulator keeps leftover pixels between deltas", () => {
  const lines = [];
  const accumulator = new PixelScrollAccumulator({
    getStep: () => 16,
    onLine: amount => lines.push(amount),
  });
  accumulator.add(20);
  accumulator.add(-25);
  assert.deepEqual(lines, [1, -1]);
  accumulator.add(-10);
  accumulator.add(-5);
  assert.deepEqual(lines, [1, -1, -1]);
});

test("PixelScrollAccumulator resets leftover pixels", () => {
  const lines = [];
  const accumulator = new PixelScrollAccumulator({
    getStep: () => 16,
    onLine: amount => lines.push(amount),
  });
  accumulator.add(15);
  accumulator.reset();
  accumulator.add(15);
  assert.deepEqual(lines, []);
});

test("PixelScrollAccumulator skips emission without a measurable step", () => {
  const lines = [];
  const accumulator = new PixelScrollAccumulator({
    getStep: () => 0,
    onLine: amount => lines.push(amount),
  });
  accumulator.add(100);
  assert.deepEqual(lines, []);
});
