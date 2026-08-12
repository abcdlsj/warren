# 需求澄清

## 原始需求

接力完成当前分支上的需求，并实现 relay service 用于远端控制面；审查、验证并提交现有实现

## 需求来源

```yaml
sources: []
```

本需求来自用户自然语言指令，无外部 TAPD、轻流或其他需求链接。仓库中的
`DESIGN.md` 和 `GOAL.md` 已将中心 Relay 定义为只承担 Host 注册、发现、配对、
撤销、信令与 WebSocket 转发的远端控制面，并明确资源和 Terminal 状态仍由 Host
持有。

## 澄清后的目标

在不改变 Burrow 本地优先行为的前提下，交付一个可独立部署的 Relay Service，
让远端 Web/PWA 能安全连接指定 macOS Host，并经 Relay 使用现有 Host Protocol
控制该 Host。未配置 Relay 时，桌面端与 WebRelay 仍保持仅本地可用。

## 用户可见行为

- 管理员可以为一台 Host 签发、轮换和撤销独立凭证，并查询其在线状态。
- macOS Host 配置一次控制面地址、Host ID 和凭证后，会主动建立并自动恢复出站
  WSS 连接，不要求公网暴露 Mac 的入站端口。
- 用户可以使用短期、一次性配对码取得只针对该 Host 的 Web/PWA 地址；同一 Web
  bundle 在本地直连和 Relay 两种模式下均可运行。
- 远端客户端能够观察与操作 Host 上现有 Project、Workspace、Session 和 Terminal，
  文本帧与二进制帧均可双向传递。
- Host 被撤销或轮换凭证后，现有远端连接断开，之前签发的客户端 token 立即失效。

## 业务与协议规则

| 规则 / 字段 / 概念 | 澄清结论 | 来源 |
| --- | --- | --- |
| 数据归属 | Project、Workspace、Session、tmux、Terminal 输入与输出只属于 macOS Host | `DESIGN.md` §6.1 |
| 网络方向 | Host 仅向 Relay 发起出站 WSS；Relay 不连接 Mac 入站端口 | `DESIGN.md` §6.1 |
| Host 身份 | 每台 Host 使用独立 UUID 与 credential，不能跨 Host 使用 | `GOAL.md` G11 |
| 配对 | pairing code 短期且一次性；换取的 access token 绑定 Host 与 credential generation | `DESIGN.md` §6.1 |
| 撤销 | 撤销或轮换 credential 必须断开 Host，并使旧 access token 失效 | `DESIGN.md` §6.1 |
| 内容隐私 | Relay 不持久化或解析 Terminal 业务帧 | `DESIGN.md` §6.1 |
| 本地默认 | 未配置控制面时 WebRelay 仍只监听 loopback | `GOAL.md` G11 |

## 范围

### 范围内

- 独立 Relay 服务、持久化 Host registry、管理与配对 HTTP API。
- Host 和远端客户端的 WebSocket 鉴权、在线状态及多路复用帧转发。
- macOS Host connector 的凭证导入、安全存储、自动重连和本地 WebRelay 桥接。
- Web/PWA 的 Relay endpoint、Host 上下文、token 恢复和安装上下文。
- 容器构建、运行任务、部署与安全运维文档，以及自动化测试。

### 范围外

- 将 Host 资源、Terminal 历史或输入输出迁移到中心服务。
- Relay 代替 tmux、Host Store、Input Lease 或现有 Host Protocol。
- Relay 单实例之外的共享 presence、registry 和跨实例连接路由。
- iOS 原生客户端、Session 分享授权模型和多租户账号系统。

## 验收标准

- [x] 为 Host 签发的 credential 只显示一次、只对该 Host 有效，服务重启后仍能认证，
  registry 文件权限为 `0600`。
- [x] Host 只通过出站 WebSocket 上线；断线会清除在线状态，网络恢复后可自动重连。
- [x] pairing code 在过期或成功使用一次后不可重放；得到的 access token 只可连接绑定
  Host，且不出现在 HTTP query 中。
- [x] 文本和二进制 WebSocket 帧均能按虚拟 connection ID 双向转发；一个客户端断开
  不影响其他客户端或本地桌面 attachment。
- [x] 慢客户端的发送队列有界，超过限制时只清理对应连接；Relay 不记录 Terminal 帧。
- [x] 撤销或轮换 Host credential 会断开 Host，并立即拒绝此前 generation 的客户端 token。
- [x] 同一 Web/PWA bundle 可本地直连或通过 Relay 连接，PWA 安装启动后保留 Host 上下文。
- [x] 未提供控制面配置时不连接 Relay；控制面 credential 不泄露到 tmux、shell 或浏览器。
- [x] Relay 单元/竞态测试、Swift 测试、集成测试和无干扰 UI 验收均通过。

## 边界情况与兼容性

- Relay 暂按单实例运行；生产横向扩容前必须增加共享 registry、presence 和 routing。
- 公网部署要求外部 TLS/WSS、严格 Origin、强随机签名密钥和持久数据卷。
- Headless 验收环境不得访问真实 Keychain 或建立真实 Relay 连接。
- Relay Host ID 必须显式配置为全局 UUID，不复用可能在多台机器重复的本地域 Host ID。

## 假设与决策

- 假设当前需求的控制面客户端是已有响应式 Web/PWA；原生远端客户端后续复用相同协议。
- 决定 Relay 使用内容不可知的帧转发边界，不成为业务数据或 Terminal 状态权威。
- 决定 access token 通过 URL fragment 交付并在 WebSocket 首帧鉴权，避免进入 query/access log。
- 决定 macOS Keychain 保存 Host credential，URL 与 Host ID 保存于应用偏好。

## 决策访谈

仅当查阅需求来源和仓库后仍存在重要产品决策时使用本节。每次只记录一个已解决的决策。
不要粘贴问卷，也不要向用户询问可以直接查证的事实。

| 决策 | 推荐答案 | 用户答案 / 证据 | 状态 |
| --- | --- | --- | --- |
| 是否将 Relay 作为远端控制面且保留 Host 数据权威 | 是；可保持本地优先和最小中心信任面 | 用户明确要求 relay service 用于远端控制面；`DESIGN.md` 已固定边界 | 已解决 |

## ADR 候选

仅当一项决策难以逆转、缺少上下文时令人意外，并且确实经过取舍时，才记录候选。
普通实现选择不属于此处；只有 Knowledge Step 可以将候选提升为正式 ADR。

| 标题 | 背景与决策 | 入选理由 | 后果 / 替代方案 | 状态 |
| --- | --- | --- | --- | --- |
| Relay 为内容不可知的单实例控制面 | Relay 只保存身份/presence 并转发帧，不持有业务资源 | 这是安全、数据归属和未来扩容都会依赖的长期边界 | 简化隐私与本地优先；当前不能直接横向扩容 | 候选 |

## 待确认问题

没有问题时填写“无”。否则记录为什么需要答案，以及谁可以提供答案。

| 问题 | 重要性 | 负责人 / 所需证据 | 状态 |
| --- | --- | --- | --- |
| 无 | 无阻断性产品或协议决策遗留 | — | 已解决 |
