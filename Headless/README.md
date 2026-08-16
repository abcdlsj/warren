# Warren Headless

Warren Headless holds Projects, Workspaces, Git worktrees, Terminal Sessions, and ghostline/tmux runtimes on a Host (local Mac or remote VPS). Both the Desktop and the CLI are clients; a client disconnecting never ends a Session.

## Installation

A remote host needs Go 1.25 and Git. The default runtime is
[ghostline](https://github.com/abcdlsj/ghostline): server-side PTY sessions
with libghostty-vt snapshots, needing neither tmux nor any other terminal
multiplexer. `--runtime tmux` is a fully supported alternative runtime for
environments that prefer or require tmux.

```sh
go install github.com/abcdlsj/warren/Headless/cmd/warren-headless@latest
go install github.com/abcdlsj/warren/Headless/cmd/warren@latest
```

Or build the current revision from the repository:

```sh
mise run build:headless
```

`warren-headless` listens on `0.0.0.0:8789` by default so phones and tablets on the same LAN can open the Web UI directly. It also serves the same UI over HTTPS on `0.0.0.0:8788` (see "LAN HTTPS" below). The HTTP port has no TLS, so do not expose it to the public internet.

## Start and Connect

Start it directly on the remote host:

```sh
warren-headless
```

Default files:

- State: `~/.warren/state.json`
- Token: `~/.warren/token`
- ghostline socket: `~/.warren/ghostline.sock` (default runtime)
- tmux socket: `warren-headless` (alternative runtime)
- Worktrees: `~/.warren/worktrees/`

From your Mac, `warren ssh` starts the remote daemon, fetches the token, saves the endpoint, and sets up port forwarding:

```sh
warren ssh user@vps
```

Keep that process running. The Desktop reads the endpoint from `~/.warren/config.json` and shows `Local` plus server options in the top-right corner. Endpoint changes made with `warren endpoint add|use|remove` are picked up within about a second, so restarting Warren is not required.

## LAN HTTPS

To remove the browser's "Not secure" badge when opening the Web UI from a phone on the same LAN, use the HTTPS listener on `0.0.0.0:8788` (disable it with `--lan-https=` or an empty `WARREN_LAN_HTTPS`). On first start the daemon generates a local CA and a server certificate in `~/.warren/tls/`; the certificate includes `localhost` and the machine's current LAN IPs.

1. Open `http://<host-LAN-IP>:8789/tls/ca.pem` on the phone, install the CA certificate, and enable full trust for it (iOS: Settings → General → VPN & Device Management, then Certificate Trust Settings; Android: Settings → Security → Install certificates).
2. Open `https://<host-LAN-IP>:8788/#t=<token>`.

The loopback HTTP endpoint `127.0.0.1:8789` keeps serving Desktop and CLI clients unchanged. If the machine's LAN IP changes, restart the daemon so the server certificate is regenerated with the new IP.

## CLI

```sh
warren endpoint list
warren --endpoint my-vps project add /srv/git/my-project
warren --endpoint my-vps project list
warren --endpoint my-vps project move PROJECT_ID --before OTHER_PROJECT_ID
warren --endpoint my-vps workspace create PROJECT_ID --branch release/my-feature
warren --endpoint my-vps workspace move WORKSPACE_ID --before OTHER_WORKSPACE_ID
warren --endpoint my-vps session create WORKSPACE_ID --kind codex --command codex
warren --endpoint my-vps session list
warren --endpoint my-vps session attach SESSION_ID
```

All commands support `--json`. `worktree` is an alias for `workspace`; help
and error messages keep the command name you typed instead of rewriting it to
the canonical name. `warren help`, `warren --help`, and
`warren <command> --help` print help and exit 0. Missing or invalid arguments
print the relevant usage and exit 2; server errors use exit code 1.

Commands default to aligned, human-readable tables. Pass `--json` for stable,
machine-readable JSON output. `workspace create` reports `created` and
`gitWorktree` in its result, so scripts know whether a Git worktree was really
created and where it landed. `session list` shows running sessions by default;
pass `--all` to include ended sessions, or `--ended` to list only ended ones.

For `workspace create`, `--branch` is required and `--path` is optional: omit
`--path` and the daemon places the new worktree under
`~/.warren/worktrees/<project>/<workspace>-<branch>`; pass `--path /custom/path`
only when the worktree must live somewhere specific. `session create` starts a
durable terminal in an existing workspace; the Desktop and Web clients see it
as soon as the daemon broadcasts the updated roster.

On macOS, `mise run install` also initializes a `local` endpoint pointing at
`http://127.0.0.1:8789` with the daemon token from `~/.warren/token`, so the
CLI works against the local daemon without extra setup. On a remote host, use
`warren ssh user@vps` to create and select the endpoint instead.

## API Boundaries

The control interface is `/v1/ws`: authenticate with the token first, then use request/response messages with request IDs. Roster is the Host resource projection; terminal output uses WebSocket binary frames. `project.move` and `workspace.move` persist the sidebar order on the Host (both accept `id` and an optional `before`; omitting `before` moves the entry to the end). `session.attach` subscribes to output only. The client that owns UI focus sends `session.focus` with optional `cols/rows` to control the shared terminal size, while background `session.resize` requests are safe no-ops. SSH, Tailscale, and future Relay provide reachability only and do not enter the resource domain model.

Tunnel lifetimes are bound to the daemon: every running adapter is stopped on shutdown, and a gnar process left behind by a crashed daemon is reaped before the next start, so a public URL never outlives its owner and a restart cannot leave two clients fighting over one reserved name. The user's intent is persisted in `tunnelEnabled` in `~/.warren/settings.json`; after a restart the daemon restores the tunnels that were left running, so a shared URL survives Warren restarts until the user explicitly stops sharing.

Daemon events (start/stop with build version, tunnel start, restore, and errors) are appended to `~/.warren/headless.log` with `0600` permissions and rotate at 5 MiB; point `--log-file` or `WARREN_LOG_FILE` elsewhere or set it empty to disable file logging.

The Web UI and `/v1/ws` share port 8789; the local browser uses `http://127.0.0.1:8789/#t=<token>` and LAN devices use `https://<host-LAN-IP>:8788/#t=<token>` after trusting the local CA (see "LAN HTTPS"). Tunnel management is handled by the daemon itself: `GET /v1/tunnels` queries status, while `POST /v1/tunnels/start` and `POST /v1/tunnels/stop` control cloudflared / tailscale / gnar; all require Bearer token authentication. The gnar edge is configured through `gnarEdge` in `~/.warren/settings.json` (or `WARREN_GNAR_EDGE`) and can be read or updated with `GET/PUT /v1/settings` or the `settings.get` / `settings.put` WebSocket methods.

Operators can announce a planned restart with `POST /v1/maintenance` (Bearer
token required). The daemon broadcasts a `{"t":"maintenance","state":"starting","message":...}`
control message to every connected client, which then shows an "Updating"
state instead of treating the disconnect as a connection failure. The install
script calls this endpoint before replacing the daemon binary.

## Output Pipeline

Each Session's raw PTY bytes are written to a dedicated append-only spool (`~/.warren/output/<runtime>.out` by default); ghostline writes its own spool, while tmux uses `pipe-pane -o -O`. The Host's SpoolWatcher reads continuously from a persisted offset, writes into a bounded OutputRing, and broadcasts to clients as DENB binary frames (`sessionID/epoch/sequence/payloadLength`). On reconnect, a client sends its last confirmed Recovery Anchor; the Host replays the exact bytes while the Anchor is still in the Ring or the spool gap is small, otherwise it sends a screen snapshot and reanchors. Raw spool replay is bounded to the same order as the in-memory ring, so a long-detached session never replays tens of megabytes of terminal bytes. Every client has its own outbound queue; a slow client only disconnects itself.

## Runtime

`warren-headless` defaults to the
[ghostline](https://github.com/abcdlsj/ghostline) runtime: one
pseudo-terminal per session. Sessions are owned by a detached ghostline
server process (`ghostline serve`, spawned automatically on first start and
reconnected over `~/.warren/ghostline.sock`), so daemon upgrades and restarts
never end sessions. A server-side libghostty-vt emulator renders screen
snapshots (visible grid + scrollback, SGR preserved) at the client's size.
The output pipeline is unchanged: raw PTY bytes are appended to the same
spool files, so recovery anchors and reanchor behave identically, and clients
still render with their own terminal emulator. Input is written to the PTY
verbatim, so there is no tmux paste-vs-key translation and kitty-protocol keys
(for example Shift+Enter) reach the application unchanged.

The tmux adapter (`--runtime tmux`) is a fully supported alternative runtime;
ghostline remains the default and recommended choice.

See [docs/runtime.md](../docs/runtime.md) for the full comparison, how to
switch the default, and why sessions keep the engine they were created with.

Known limits:

- A forced ghostline server restart still ends its sessions (the server
  process owns the PTY masters). Protocol upgrades are rolled in place: the
  daemon starts a fresh server, adopts every session over the admin socket,
  and retires the old process without ending children. If adoption is not
  possible (for example a server predating the admin socket), the daemon
  keeps the old server running and retries on a later start.
- The ghostline module bundles a prebuilt libghostty-vt dylib for macOS
  arm64; other platforms must rebuild it (see the ghostline README).

## Agent Transcript Projection

For `codex` and `claude` sessions, `warren-headless` also watches the JSONL
transcript written by the CLI itself (Codex: `~/.codex/sessions/**/rollout-*.jsonl`,
Claude Code: `~/.claude/projects/**/<session>.jsonl`), normalizes messages,
reasoning, tool calls, and tool output into `agent` events, and sends them to
attached clients as `{"t":"agent","session":...,"events":[...]}` text messages.
Live batches are split so a single message stays around 256 KiB; the activity
status light is its own lightweight `{"t":"agent.activity","session":...,"activity":...}`
message. Attach only replays a bounded tail of the conversation, so clients
that need the full history fetch it page by page with the `agent.history`
request (`session`, optional `before` sequence cursor and `limit`, returning
`events`, `cursor` and `hasMore`). This keeps any single WebSocket message far
below client message-size limits even for transcripts with thousands of events.
The PTY byte stream remains the source of truth; the transcript is a
best-effort side channel.

Each Warren session is bound to one CLI conversation by its own session ID,
so several agents in the same workspace never mix transcripts:

- Claude starts with `--session-id <warren-session-id>`, which makes its
  transcript path deterministic (`~/.claude/projects/-Users-.../<id>.jsonl`).
- Codex and Claude get Warren-managed `SessionStart` and `SessionEnd` hooks
  merged into `$CODEX_HOME/hooks.json` / `$CLAUDE_CONFIG_DIR/settings.json`
  (user entries are preserved). `SessionStart` writes the CLI's
  `session_id`/`transcript_path` to
  `~/.warren/agent-bind/<warren-session-id>.json` and resets the state file;
  `SessionEnd` marks the state file exited so the status light returns to
  the surrounding shell. The daemon starts the watcher from the exact file.
- Every Warren session, including a plain Shell tab, inherits the same
  binding environment. A Codex/Claude CLI started manually inside that shell
  is bound by the same hooks: the tab shows agent activity while it runs and
  returns to a plain shell after `SessionEnd`. Sessions created before this
  feature need to be reopened so the shell picks up the new environment.

The bound CLI session ID and transcript path are stored on the Session and
shown in the Web Agent view. When a binding is not available yet (hook not
installed, CLI version with a different layout), discovery falls back to
cwd + mtime matching so the session still works.

The Web client renders an Agent view for these sessions and sends user input
through the same PTY as terminal bytes. If a transcript is missing or its
format changes, sessions keep working as plain terminals.
