# Warren Headless

Warren Headless holds Projects, Workspaces, Git worktrees, Terminal Sessions, and tmux runtimes on a remote host. Both the Desktop and the CLI are clients; a client disconnecting never ends a Session.

## Installation

A remote host needs Go 1.25 and Git. The default runtime is
[ghostline](https://github.com/abcdlsj/ghostline): server-side PTY sessions
with libghostty-vt snapshots, needing neither tmux nor any other terminal
multiplexer. `--runtime tmux` remains as a deprecated fallback for
environments that cannot run ghostline and is not maintained.

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
- tmux socket: `warren-headless`
- Worktrees: `~/.warren/worktrees/`

From your Mac, `warren ssh` starts the remote daemon, fetches the token, saves the endpoint, and sets up port forwarding:

```sh
warren ssh user@vps
```

Keep that process running. The Desktop reads the endpoint from `~/.warren/config.json` and shows `Local` plus server options in the top-right corner.

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

All commands support `--json`. `worktree` is an alias for `workspace`. For
`workspace create`, `--path` is optional: omit it and the daemon places the new
worktree under `~/.warren/worktrees/<project>/<workspace>-<branch>`; pass
`--path /custom/path` only when the worktree must live somewhere specific.
`session create` starts a durable terminal in an existing workspace; the
Desktop and Web clients see it as soon as the daemon broadcasts the updated
roster.

On macOS, `mise run install` also initializes a `local` endpoint pointing at
`http://127.0.0.1:8789` with the daemon token from `~/.warren/token`, so the
CLI works against the local daemon without extra setup. On a remote host, use
`warren ssh user@vps` to create and select the endpoint instead.

## API Boundaries

The control interface is `/v1/ws`: authenticate with the token first, then use request/response messages with request IDs. Roster is the Host resource projection; terminal output uses WebSocket binary frames. `project.move` and `workspace.move` persist the sidebar order on the Host (both accept `id` and an optional `before`; omitting `before` moves the entry to the end). `session.attach` subscribes to output only. The client that owns UI focus sends `session.focus` with optional `cols/rows` to control the shared terminal size, while background `session.resize` requests are safe no-ops. SSH, Tailscale, and future Relay provide reachability only and do not enter the resource domain model.

The Web UI and `/v1/ws` share port 8789; the local browser uses `http://127.0.0.1:8789/#t=<token>` and LAN devices use `https://<host-LAN-IP>:8788/#t=<token>` after trusting the local CA (see "LAN HTTPS"). Tunnel management is handled by the daemon itself: `GET /v1/tunnels` queries status, while `POST /v1/tunnels/start` and `POST /v1/tunnels/stop` control cloudflared / tailscale / funnel; all require Bearer token authentication.

Operators can announce a planned restart with `POST /v1/maintenance` (Bearer
token required). The daemon broadcasts a `{"t":"maintenance","state":"starting","message":...}`
control message to every connected client, which then shows an "Updating"
state instead of treating the disconnect as a connection failure. The install
script calls this endpoint before replacing the daemon binary.

## Output Pipeline

Each Session's raw PTY bytes are written to a dedicated append-only spool (`~/.warren/output/<runtime>.out` by default) via `tmux pipe-pane -o -O`. The Host's SpoolWatcher reads continuously from a persisted offset, writes into a bounded OutputRing, and broadcasts to clients as DENB binary frames (`sessionID/epoch/sequence/payloadLength`). On reconnect, a client sends its last confirmed Recovery Anchor; the Host replays the exact bytes while the Anchor is still in the Ring, or sends a tmux screen snapshot and reanchors once it has been evicted. Every client has its own outbound queue; a slow client only disconnects itself.

## Runtime

`warren-headless` defaults to the
[ghostline](https://github.com/abcdlsj/ghostline) runtime: one
pseudo-terminal per session owned by the daemon, with a server-side
libghostty-vt emulator rendering screen snapshots (visible grid + scrollback,
SGR preserved) at the client's size. The output pipeline is unchanged: raw
PTY bytes are appended to the same spool files, so recovery anchors and
reanchor behave identically, and clients still render with their own terminal
emulator. Input is written to the PTY verbatim, so there is no tmux
paste-vs-key translation and kitty-protocol keys (for example Shift+Enter)
reach the application unchanged.

The tmux adapter (`--runtime tmux`) is kept only as a minimal fallback for
environments that cannot run ghostline and is no longer maintained.

Known limits:

- A daemon restart closes the PTY master and ends its sessions. tmux sessions
  survive a daemon restart because tmux owns them; adopting existing PTY
  children is not implemented yet.
- Building `warren-headless` with the PTY runtime requires the local
  `ghostline` checkout (see its README for the libghostty-vt build steps).
