export function terminalSize(terminal) {
  const cols = Number(terminal?.cols);
  const rows = Number(terminal?.rows);
  if (!Number.isInteger(cols) || !Number.isInteger(rows) || cols <= 0 || rows <= 0) {
    return null;
  }
  return { cols, rows };
}

export function attachTerminalMessage(session, terminal) {
  const size = terminalSize(terminal);
  return size
    ? { t: "attach", session, ...size }
    : { t: "attach", session };
}

export function fitTerminalToHost(fitAddon, host) {
  if (!host?.clientWidth || !host.clientHeight || !fitAddon?.fit) return false;
  fitAddon.fit();
  return true;
}
