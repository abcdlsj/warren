import test from "node:test";
import assert from "node:assert/strict";
import { decodeOutputFrame, encodeInput, isBinaryEnvelope } from "./wire.js";

test("decodes a host output envelope", () => {
  const payload = new TextEncoder().encode("prompt\r\n");
  const header = {
    sessionID: "session-1",
    epoch: 3,
    sequence: 42,
    payloadLength: payload.length,
  };
  const headerBytes = new TextEncoder().encode(JSON.stringify(header));
  const frame = new Uint8Array(15 + headerBytes.length + payload.length);
  frame.set([0x44, 0x45, 0x4e, 0x42, 1, 2, 2], 0);
  const view = new DataView(frame.buffer);
  view.setUint32(7, headerBytes.length);
  view.setUint32(11, payload.length);
  frame.set(headerBytes, 15);
  frame.set(payload, 15 + headerBytes.length);

  assert.equal(isBinaryEnvelope(frame), true);
  const decoded = decodeOutputFrame(frame);
  assert.deepEqual(decoded.header, {
    sessionID: "session-1",
    epoch: 3,
    sequence: 42,
    payloadLength: payload.length,
  });
  assert.deepEqual([...decoded.payload], [...payload]);
});

test("rejects malformed and wrong-direction envelopes", () => {
  assert.equal(decodeOutputFrame(new Uint8Array(3)), null);
  const payload = new TextEncoder().encode("x");
  const headerBytes = new TextEncoder().encode(JSON.stringify({ sessionID: "s", epoch: 0, sequence: 0, payloadLength: 1 }));
  const frame = new Uint8Array(15 + headerBytes.length + 1);
  frame.set([0x44, 0x45, 0x4e, 0x42, 1, 1, 1], 0); // client-to-host input
  const view = new DataView(frame.buffer);
  view.setUint32(7, headerBytes.length);
  view.setUint32(11, payload.length);
  frame.set(headerBytes, 15);
  frame.set(payload, 15 + headerBytes.length);
  assert.equal(decodeOutputFrame(frame), null);
});

test("encodes client input envelopes", () => {
  const payload = new TextEncoder().encode("ls\r");
  const encoded = encodeInput(payload, { sessionID: "s-1", attachmentID: "a-1", sequence: 9 });
  assert.equal(isBinaryEnvelope(encoded), true);
  assert.equal(encoded[5], 1, "direction is client-to-host");
  assert.equal(encoded[6], 1, "kind is input");
});
