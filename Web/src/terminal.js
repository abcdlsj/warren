export function terminalSize(terminal) {
  const cols = Number(terminal?.cols);
  const rows = Number(terminal?.rows);
  if (!Number.isInteger(cols) || !Number.isInteger(rows) || cols <= 0 || rows <= 0) {
    return null;
  }
  return { cols, rows };
}

export function attachTerminalMessage(session, terminal, anchor = null) {
  // Attaching subscribes to output only. The focused terminal claims the
  // shared PTY geometry through session.focus after it actually receives UI
  // focus, so a background browser cannot resize a desktop session.
  const size = terminalSize(terminal);
  const params = { id: session, focused: false };
  if (size) {
    // A passive attach still carries the viewer's viewport size. The server
    // resizes the shared runtime with it when nobody owns focus, which lets
    // a mobile viewer reflow the shell before the first tap.
    params.cols = size.cols;
    params.rows = size.rows;
  }
  if (anchor) {
    params.epoch = anchor.epoch;
    params.sequence = anchor.sequence;
  }
  return { method: "session.attach", params };
}

export function fitTerminalToHost(fitAddon, host) {
  if (!host?.clientWidth || !host.clientHeight || !fitAddon?.fit) return false;
  fitAddon.fit();
  return true;
}

const FONT_SETTLE_TIMEOUT_MS = 2000;

/**
 * Wait until the configured terminal font is available so xterm measures
 * cell dimensions against the glyphs it will actually render (including
 * CJK fallback fonts) instead of a half-loaded font stack.
 */
export function waitForTerminalFont({ fontFamily, fontSize, timeoutMs = FONT_SETTLE_TIMEOUT_MS } = {}) {
  if (typeof document === "undefined" || !document.fonts?.load) return Promise.resolve();
  const spec = `${fontSize}px ${fontFamily}`;
  let timeoutId = null;
  const timeout = new Promise(resolve => {
    timeoutId = setTimeout(resolve, timeoutMs);
  });
  const loaded = Promise.resolve(document.fonts.load(spec)).catch(() => {});
  return Promise.race([loaded, timeout]).finally(() => clearTimeout(timeoutId));
}

export function terminalSearchSummary(resultIndex, resultCount, hasQuery) {
  if (!hasQuery) return "";
  if (resultCount <= 0) return "No results";
  if (resultIndex >= 0) return `${resultIndex + 1}/${resultCount}`;
  return `${resultCount} found`;
}
