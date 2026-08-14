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

`warren-headless` 默认只监听 `127.0.0.1:8789`。不要为了省一条 SSH 命令，把未启用 TLS 的端口直接暴露到公网。

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

控制接口是 `/v1/ws`，先发送 token 鉴权，再使用带 request ID 的 request/response。Roster 是 Host 资源投影；终端输出使用 WebSocket binary frame。SSH、Tailscale 和未来的 Relay 只负责可达性，不进入资源领域模型。
