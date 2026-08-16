# Headless and Remote Connection Architecture

Status: implemented baseline architecture
Protocol version: 1.0

## Decisions

Warren is split into three layers: Host, Transport, and Client:

```text
Desktop / CLI
      ↓ versioned WebSocket API
Endpoint (Local, SSH tunnel, Tailscale, Relay)
      ↓
warren-headless
├── Project / Workspace / Session authority
├── atomic JSON state store
├── Git worktree adapter
└── tmux runtime adapter
```

SSH is not a Warren business protocol. `warren ssh` only starts the remote daemon, reads the token, and establishes loopback port forwarding. Once connected, Desktop and CLI use the same WebSocket API.

## State Ownership

| State | Authority | Behavior after disconnect |
| --- | --- | --- |
| Projects, Workspaces, Sessions, sidebar order | Remote daemon | Retained |
| tmux runtime | Remote daemon | Keeps running |
| Current endpoint | Local Desktop/CLI config | Retained |
| Desktop selection and renderer | Local Desktop | Rebuildable |
| SSH tunnel | `warren ssh` process | Closed when the process exits |

Local and Server are two independent Host resource trees. Switching endpoints only switches the projection and renderer; it does not migrate, copy, or terminate Sessions on the other end.

## Security

- The daemon binds to loopback by default.
- Tokens use 256 random bits; config files use `0600` permissions.
- WebSocket auth uses constant-time comparison.
- HTTP state endpoints require a Bearer token.
- Public connections should go through SSH, Tailscale, or a TLS-terminating Relay.

## Extension Points

- The store can move from atomic JSON to SQLite without changing the API.
- Runtime is isolated behind an interface, so systemd, container, or PTY adapters can be added.
- Endpoints can add Relay, mTLS, and organization-level discovery.
- The protocol can add request receipts, incremental output sequences, Input Lease, and capability negotiation.
- The Desktop remote model is the only client model; local Host state is owned by the daemon.

## Output and Recovery

- `tmux pipe-pane -o -O` writes each Session's raw PTY bytes to a dedicated append-only spool (`~/.warren/output/<runtime>.out`). The Host holds one SpoolWatcher per Session that keeps reading bytes from a persisted offset instead of polling `capture-pane`.
- `capture-pane` is only used for first recovery and reanchoring: when a new client connects, the Host restarts and adopts, the Anchor is evicted from the Ring, or the spool is compacted, the Host sends a tmux screen snapshot and reanchors.
- Binary output frames use the same DENB envelope as the Swift side:
  `DENB | version | direction | kind | headerLen | payloadLen | JSON header | payload`,
  with the header carrying `sessionID/epoch/sequence/payloadLength`. Output first goes into a bounded OutputRing and is then broadcast to clients; on reconnect a client sends its last confirmed Recovery Anchor, and the Host either replays the exact interval from the Ring or sends a snapshot to reanchor.
- Each WebSocket client has its own outbound writer and send queue; queue overflow or a write timeout disconnects only that client, which can reconnect and catch up from its anchor.
- After startup, a single lifecycle watcher probes and adopts live tmux sessions (reinstalling pipes idempotently); missing Runtimes are marked ended. Only an explicit Session delete runs `kill-session`; detaching and client exits never terminate tmux.

## Current Limitations

- When a spool reaches its cap, it is compacted in place (archive + truncate) and the epoch is bumped; all clients reanchor from a tmux screen snapshot, with no silent byte trimming.
- Headless Go's `/v1/ws` exposes one request/response control protocol. `session.attach` creates an output subscription only (and carries the `epoch/sequence` recovery anchor); a client sends `session.focus` with an optional `cols/rows` viewport after it gains UI focus. The Host only lets the focused peer resize the shared tmux/PTY; background `session.resize` requests are safe no-ops, and detach releases focus. Control messages and DENB output frames match the Swift Host semantics.
- Desktop discovers servers from the CLI config file; after a config change, reselect or restart Desktop.
- Remote Project paths must be added through the CLI; the Desktop file picker only applies to Local.
- SSH auto-start requires `warren-headless` and `openssl` to be installed on the remote host.
