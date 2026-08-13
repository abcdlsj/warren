# Headless 与远程连接架构

状态：已实现的基础架构  
协议版本：1.0

## 决策

Warren 分为 Host、Transport 和 Client 三层：

```text
Desktop / CLI
      ↓ versioned WebSocket API
Endpoint（Local、SSH tunnel、Tailscale、Relay）
      ↓
warren-headless
├── Project / Workspace / Session authority
├── atomic JSON state store
├── Git worktree adapter
└── tmux runtime adapter
```

SSH 不是 Warren 业务协议。`warren ssh` 只启动远端 daemon、读取 token 并建立 loopback 端口转发。连接建立后，Desktop 和 CLI 均使用相同的 WebSocket API。

## 状态所有权

| 状态 | 权威 | 断开后的行为 |
| --- | --- | --- |
| Project、Workspace、Session | 远端 daemon | 保留 |
| tmux runtime | 远端 daemon | 继续运行 |
| 当前 endpoint | 本地 Desktop/CLI 配置 | 保留 |
| Desktop 选择与 renderer | 本地 Desktop | 可重建 |
| SSH tunnel | `warren ssh` 进程 | 进程结束时关闭 |

Local 与 Server 是两套独立 Host 资源树。切换 endpoint 只切换投影和 renderer，不迁移、不复制，也不终止另一端的 Session。

## 安全

- daemon 默认绑定 loopback。
- token 使用 256 位随机值，配置文件权限为 `0600`。
- WebSocket 鉴权使用常量时间比较。
- HTTP state 端点要求 Bearer token。
- 公网连接应通过 SSH、Tailscale 或带 TLS 的 Relay。

## 扩展点

- Store 可从原子 JSON 换为 SQLite，而不改变 API。
- Runtime 通过接口隔离，可增加 systemd、container 或 PTY adapter。
- Endpoint 可增加 Relay、mTLS 和组织级发现。
- 协议可增加 request receipt、增量输出 sequence、Input Lease 和 capability negotiation。
- Desktop 远端模型独立于本地 `WarrenApplicationService`，后续可收敛到统一 Host Client repository。

## 当前限制

- Headless 输出以 100 ms 周期抓取 tmux 当前屏幕，协议会发送完整终端快照。下一版应使用增量 pipe-pane spool、epoch 和 sequence。
- Desktop 从 CLI 配置文件发现 server；配置改变后需重新选择或重启 Desktop。
- 远端 Project 的路径必须通过 CLI 添加，Desktop 文件选择器只适用于 Local。
- SSH 自动启动要求远端已安装 `warren-headless` 和 `openssl`。

