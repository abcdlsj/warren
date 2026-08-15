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

`warren-headless` 默认只监听 `127.0.0.1:8789`。同一个端口同时提供 Web UI（`/`、静态资源）和控制协议（`/v1/ws`）。不要为了省一条 SSH 命令，把未启用 TLS 的端口直接暴露到公网。

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

Web UI 与 `/v1/ws` 共用 8789 端口；浏览器访问 `http://127.0.0.1:8789/#t=<token>`。隧道管理由 daemon 自身负责：`GET /v1/tunnels` 查询状态，`POST /v1/tunnels/start` 和 `POST /v1/tunnels/stop` 控制 cloudflared / tailscale / funnel，均需 Bearer token 鉴权。

## 输出链路

每个 Session 的原始 PTY 字节通过 `tmux pipe-pane -o -O` 写入独立 append-only
spool（默认 `~/.warren/output/<runtime>.out`）。Host 的 SpoolWatcher 按持久化
offset 持续读取，先写入有界 OutputRing，再以 DENB binary frame
（`sessionID/epoch/sequence/payloadLength`）广播给客户端。断线重连时客户端携带
最后确认的 Recovery Anchor；Anchor 在 Ring 内精确补发，被淘汰时发送 tmux
屏幕快照并 reanchor。每个客户端拥有独立 outbound 队列，慢客户端只会断开自己。
