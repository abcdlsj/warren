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
  const message = size
    ? { t: "attach", session, ...size }
    : { t: "attach", session };
  if (anchor) {
    message.epoch = anchor.epoch;
    message.sequence = anchor.sequence;
  }
  return message;
}

export function fitTerminalToHost(fitAddon, host) {
  if (!host?.clientWidth || !host.clientHeight || !fitAddon?.fit) return false;
  fitAddon.fit();
  return true;
}
