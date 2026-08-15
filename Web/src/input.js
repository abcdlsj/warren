// Queues terminal input while a session is attaching or the transport is
// down, then replays it in order once the attachment is ready. Input typed
// during a reconnect must not be lost, but it must also never cross sessions:
// flushing one session keeps every other session's queued bytes intact.
export class InputQueue {
  constructor({
    limit = 64 * 1024,
    send,
    onSendFailure = () => {},
  } = {}) {
    this.limit = limit;
    this.send = send;
    this.onSendFailure = onSendFailure;
    this.pending = [];
  }

  enqueue(sessionID, data) {
    this.pending.push({ sessionID, data });
    let size = this.pending.reduce((total, item) => total + item.data.length, 0);
    while (size > this.limit && this.pending.length) {
      size -= this.pending.shift().data.length;
    }
  }

  // Sends every queued byte for the given session in order. Bytes for other
  // sessions stay queued. When the transport rejects a frame, the failed item
  // and everything after it are kept so a reconnect can replay them exactly
  // once; the caller is notified through onSendFailure.
  flush(sessionID) {
    const remaining = [];
    for (let index = 0; index < this.pending.length; index += 1) {
      const item = this.pending[index];
      if (item.sessionID !== sessionID) {
        remaining.push(item);
        continue;
      }
      let delivered = false;
      try {
        delivered = this.send(item.data);
      } catch {
        delivered = false;
      }
      if (!delivered) {
        remaining.push(item, ...this.pending.slice(index + 1));
        this.pending = remaining;
        this.onSendFailure();
        return false;
      }
    }
    this.pending = remaining;
    return true;
  }

  clear() {
    this.pending = [];
  }

  get size() {
    return this.pending.length;
  }
}

// Mobile soft keyboards and CJK IMEs can make xterm fire onData twice for the
// same keystroke (compositionend plus the following input event). This tracks
// composition state and drops exact duplicates inside a short window.
export class MobileInputDeduper {
  constructor({
    isTouch = false,
    windowMs = 150,
    now = Date.now,
  } = {}) {
    this.isTouch = isTouch;
    this.windowMs = windowMs;
    this.now = now;
    this.isComposing = false;
    this.compositionEndTime = Number.NEGATIVE_INFINITY;
    this.lastData = "";
    this.lastTime = 0;
  }

  onCompositionStart() {
    this.isComposing = true;
  }

  onCompositionEnd() {
    this.isComposing = false;
    this.compositionEndTime = this.now();
  }

  shouldSend(data) {
    const time = this.now();
    const inCompositionWindow = this.isComposing
      || time - this.compositionEndTime < this.windowMs;
    if ((inCompositionWindow || this.isTouch)
      && data === this.lastData
      && time - this.lastTime < this.windowMs) {
      return false;
    }
    this.lastData = data;
    this.lastTime = time;
    return true;
  }
}
