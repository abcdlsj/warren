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
  const params = { id: session, focused: false };
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

export function terminalSearchSummary(resultIndex, resultCount, hasQuery) {
  if (!hasQuery) return "";
  if (resultCount <= 0) return "No results";
  if (resultIndex >= 0) return `${resultIndex + 1}/${resultCount}`;
  return `${resultCount} found`;
}
