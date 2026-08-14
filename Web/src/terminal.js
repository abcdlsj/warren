export function terminalSize(terminal) {
  const cols = Number(terminal?.cols);
  const rows = Number(terminal?.rows);
  if (!Number.isInteger(cols) || !Number.isInteger(rows) || cols <= 0 || rows <= 0) {
    return null;
  }
  return { cols, rows };
}

export function attachTerminalMessage(session, terminal, anchor = null) {
  const size = terminalSize(terminal);
  const params = size
    ? { id: session, ...size }
    : { id: session };
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
