# Warren Headless

Warren Headless 在远端主机持有 Project、Workspace、Git worktree、Terminal Session 和 tmux runtime。Desktop 与 CLI 都是客户端；客户端断开不会结束 Session。

## 安装

远端主机需要 Go 1.25、Git 和 tmux。

```sh
go install github.com/abcdlsj/warren/Headless/cmd/warren-headless@latest
go install github.com/abcdlsj/warren/Headless/cmd/warren@latest
```

也可以在仓库中构建当前版本：

```sh
mise run build:headless
```

`warren-headless` listens on `0.0.0.0:8789` by default so phones and tablets on the same LAN can open the Web UI directly. It also serves the same UI over HTTPS on `0.0.0.0:8788` (see "LAN HTTPS" below). The HTTP port has no TLS, so do not expose it to the public internet.

## 启动与连接

远端直接启动：

```sh
warren-headless
```

默认文件：

- 状态：`~/.warren/state.json`
- token：`~/.warren/token`
- tmux socket：`warren-headless`
- worktree：`~/.warren/worktrees/`

本地可用 SSH 完成远端启动、token 获取、endpoint 保存和端口转发：

```sh
warren ssh user@vps
```

保持该进程运行。Desktop 会从 `~/.warren/config.json` 读取 endpoint，并在右上角显示 `Local` 和服务器选项。

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

命令支持 `--json`。`worktree` 是 `workspace` 的别名。

## API 边界

The control interface is `/v1/ws`: authenticate with the token first, then use request/response messages with request IDs. Roster is the Host resource projection; terminal output uses WebSocket binary frames. `session.attach` subscribes to output only. The client that owns UI focus sends `session.focus` with optional `cols/rows` to control the shared terminal size, while background `session.resize` requests are safe no-ops. SSH, Tailscale, and future Relay provide reachability only and do not enter the resource domain model.

The Web UI and `/v1/ws` share port 8789; the local browser uses `http://127.0.0.1:8789/#t=<token>` and LAN devices use `https://<host-LAN-IP>:8788/#t=<token>` after trusting the local CA (see "LAN HTTPS"). Tunnel management is handled by the daemon itself: `GET /v1/tunnels` queries status, while `POST /v1/tunnels/start` and `POST /v1/tunnels/stop` control cloudflared / tailscale / funnel; all require Bearer token authentication.

## 输出链路

每个 Session 的原始 PTY 字节通过 `tmux pipe-pane -o -O` 写入独立 append-only
spool（默认 `~/.warren/output/<runtime>.out`）。Host 的 SpoolWatcher 按持久化
offset 持续读取，先写入有界 OutputRing，再以 DENB binary frame
（`sessionID/epoch/sequence/payloadLength`）广播给客户端。断线重连时客户端携带
最后确认的 Recovery Anchor；Anchor 在 Ring 内精确补发，被淘汰时发送 tmux
屏幕快照并 reanchor。每个客户端拥有独立 outbound 队列，慢客户端只会断开自己。
