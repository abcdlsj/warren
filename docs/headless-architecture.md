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

## 输出与恢复

- tmux `pipe-pane -o -O` 把每个 Session 的原始 PTY 字节写入独立 append-only
  spool（`~/.warren/output/<runtime>.out`）。Host 为每个 Session 持有一个
  SpoolWatcher，按持久化 offset 持续读取字节，不再轮询 capture-pane。
- `capture-pane` 只用于首次恢复和 reanchor：新客户端、Host 重启 adopt、
  anchor 被 Ring 淘汰或 spool 压缩时，Host 发送 tmux 屏幕快照并重定锚。
- 二进制输出帧使用与 Swift 端相同的 DENB envelope：
  `DENB | version | direction | kind | headerLen | payloadLen | JSON header | payload`，
  header 携带 `sessionID/epoch/sequence/payloadLength`。输出先写入有界
  OutputRing，再广播给客户端；客户端用最后确认的 Recovery Anchor 重连，
  Host 按 Ring 内区间精确补发或发送快照 reanchor。
- 每个 WebSocket 客户端有独立 outbound writer 与发送队列；队列溢出或写超时
  只断开该客户端，由其重连并从 anchor 补数据。
- Host 启动后由单一 lifecycle watcher 探测并 adopt 存活 tmux（幂等重装
  pipe），缺失的 Runtime 被标记 ended。只有显式删除 Session 才执行
  `kill-session`；detach 和客户端退出都不终止 tmux。

## 当前限制

- spool 达到上限时执行 in-place 压缩（archive + truncate）并 bump epoch；
  所有客户端以 tmux 屏幕快照 reanchor，不做静默字节裁剪。
- Headless Go 的 `/v1/ws` 与 `/ws` 已统一为同一套 request/response 控制协议
  （`session.attach` 携带 `cols/rows/epoch/sequence` 恢复锚），控制消息和
  DENB 输出帧语义与 Swift Host 一致。
- Desktop 从 CLI 配置文件发现 server；配置改变后需重新选择或重启 Desktop。
- 远端 Project 的路径必须通过 CLI 添加，Desktop 文件选择器只适用于 Local。
- SSH 自动启动要求远端已安装 `warren-headless` 和 `openssl`。
