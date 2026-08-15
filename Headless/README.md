# Warren Headless

Warren Headless holds Projects, Workspaces, Git worktrees, Terminal Sessions, and tmux runtimes on a remote host. Both the Desktop and the CLI are clients; a client disconnecting never ends a Session.

## Installation

A remote host needs Go 1.25, Git, and tmux.

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
warren --endpoint my-vps workspace create PROJECT_ID --branch release/my-feature
warren --endpoint my-vps session create WORKSPACE_ID --kind codex --command codex
warren --endpoint my-vps session list
warren --endpoint my-vps session attach SESSION_ID
```

All commands support `--json`. `worktree` is an alias for `workspace`.

## API Boundaries

The control interface is `/v1/ws`: authenticate with the token first, then use request/response messages with request IDs. Roster is the Host resource projection; terminal output uses WebSocket binary frames. `session.attach` subscribes to output only. The client that owns UI focus sends `session.focus` with optional `cols/rows` to control the shared terminal size, while background `session.resize` requests are safe no-ops. SSH, Tailscale, and future Relay provide reachability only and do not enter the resource domain model.

The Web UI and `/v1/ws` share port 8789; the local browser uses `http://127.0.0.1:8789/#t=<token>` and LAN devices use `https://<host-LAN-IP>:8788/#t=<token>` after trusting the local CA (see "LAN HTTPS"). Tunnel management is handled by the daemon itself: `GET /v1/tunnels` queries status, while `POST /v1/tunnels/start` and `POST /v1/tunnels/stop` control cloudflared / tailscale / funnel; all require Bearer token authentication.

## Output Pipeline

Each Session's raw PTY bytes are written to a dedicated append-only spool (`~/.warren/output/<runtime>.out` by default) via `tmux pipe-pane -o -O`. The Host's SpoolWatcher reads continuously from a persisted offset, writes into a bounded OutputRing, and broadcasts to clients as DENB binary frames (`sessionID/epoch/sequence/payloadLength`). On reconnect, a client sends its last confirmed Recovery Anchor; the Host replays the exact bytes while the Anchor is still in the Ring, or sends a tmux screen snapshot and reanchors once it has been evicted. Every client has its own outbound queue; a slow client only disconnects itself.
