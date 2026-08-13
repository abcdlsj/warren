# Warren 产品与系统设计

状态：第一期唯一设计事实源  
适用范围：产品、领域模型、架构、数据、终端运行时、界面和验收  
更新规则：实现与本文冲突时，以本文为准；变更设计时必须在同一提交中更新本文

## 1. 产品目标

Warren 是以 Workspace 为边界、以持久终端为核心的本地与远程开发工作台。

macOS Desktop 默认连接进程内 Local Host，也可连接运行于 VPS 的 `warren-headless`。用户可以在右上角切换 Local 与 Server，管理目标 Host 上的 Project、Workspace、Git worktree 和 Terminal Session，并通过 Ghostty 获得持续的终端交互。CLI 使用同一远端 API，并提供 SSH 启动和端口转发入口。

系统必须为后续 iOS 原生端、Session 分享、Automation 和中心控制面保留稳定边界。Web 网络可达性由用户显式启用；Desktop 和 headless daemon 默认均不得开放公网入口。

## 2. 第一原则

1. Session 属于 Host，Tab 属于 Window，Runtime 属于 Session。一个打开的 Tab
   持有一个 Session；关闭 Tab 会连带结束该 Session 和 Runtime。
2. Workspace 是终端、Tab 和异步命令的隔离边界。
3. tmux 是可替换的 Runtime Adapter，不是产品领域模型。
4. Warren v1 中，一个打开的 Tab 对应一个 Warren Terminal Session；关闭 Tab
   就是显式终止该 Session 的 Runtime。切换 Workspace 或退出 Client 不会
   额外终止仍被保留在客户端布局中的 Tab/Session。
5. 只有 Close Tab 或显式 Terminate Session 才能结束其 Runtime；切换 Workspace、Detach
   和退出 Client 都不会额外终止仍在运行的 Session。
6. UI 只展示投影并发送 typed intent，不直接操作 tmux、数据库或 Ghostty 生命周期。
7. 每类状态只有一个写入权威；缓存和投影不得成为第二权威。
8. 所有异步操作携带不可变目标 ID 和 Request ID，不读取完成时的当前选择来推断目标。
9. 本地连接与未来网络连接共用同一应用协议。
10. 可观测性是产品能力，不是测试补丁。

## 3. 统一术语

### 3.1 资源

**Host**：持有 Project、Workspace、Terminal Session 和 Runtime 真实状态的执行节点。Host 可以是当前 Mac 上的本地 Host Service，也可以是远端 VPS 上的 `warren-headless`。

**Project**：一个 Git 仓库身份。Project 用于组织 Workspace，不是终端运行目录。

**Workspace**：Project 下一个具体、可访问的本地工作目录及其 Git 上下文。主检出目录和 worktree 都是 Workspace。Workspace ID 是稳定身份，branch 和 path 是可变化属性。

**Terminal Session**：Host 上的交互式终端上下文。它只属于一个 Workspace，并在
  一个打开的 Tab 中被访问；Tab 关闭时 Session 结束。Client 退出时仍运行的
  Session 可由 Host 保持并在重启后恢复。

**Runtime Binding**：Terminal Session 到具体运行实现的持久映射。第一期实现为一个 Warren Session 对应一个独立 tmux session 和一个 pane。

### 3.2 客户端

**Device**：稳定设备身份。第一期只有当前 Mac，但模型不得假定永远只有一个设备。

**Client Instance**：一次 App 运行实例。退出 App 后失效。

**Client Window**：独立的导航和布局作用域。每个 Window 独立保存 Active Workspace 和各 Workspace View。

**Workspace View**：一个 Window 为一个 Workspace 保存的本地展示状态，包含有序 Tabs 和 Active Tab。

**Tab**：Workspace View 中指向 Terminal Session 的本地入口。Warren v1 中
一个打开的 Tab 对应一个 Session；关闭 Tab 会终止该 Session 的 Runtime。
同一个活动 Session 不在一个 Workspace View 中重复打开。

**Renderer Surface**：客户端为一个 Tab 挂载的 Ghostty 表面。Surface 不拥有 Session。

**Attachment**：Client Instance 与 Terminal Session 的临时连接。后续分享能力通过同一 Session 上的多个 Attachment 实现。

**Input Lease**：允许一个 Attachment 向 Session 输入的排他租约。

**Canonical Viewport Owner**：允许一个 Attachment 改变 PTY 行列数的唯一参与者。第一版由 Input Lease 持有者同时承担；观察者不得 resize PTY。

### 3.3 导入与自动化

**Superset Import**：从 Superset 本地数据库读取 Project 和 Workspace 元数据，并一次性复制为 Warren 自有数据的 onboarding 操作。它不是同步。

**Import Receipt**：成功导入的持久记录，包含来源、版本、时间和摘要。成功后不再自动提示或重复导入。

**Automation Run**：后续版本中一次有明确开始、退出状态和保留策略的非人工任务。它可以使用 Terminal Session 展示过程，但不能用 Tab 或提示符推断完成状态。

## 4. 权威模型

```text
Resource Authority
Selected Host
└── Project
    └── Workspace
        └── Terminal Session
            └── Runtime Binding

Presentation Authority
Device
└── Client Instance
    └── Client Window
        ├── Active Workspace
        └── Workspace Views
            └── Tabs / Active Tab

Connection Authority
Terminal Session
└── Attachments
    ├── Input Lease
    └── Canonical Viewport Owner
```

| 状态 | 唯一权威 | 持久化 |
| --- | --- | --- |
| Project、Workspace、Session | Host Store | 是 |
| Runtime Binding、Session 状态 | Host Store | 是 |
| PTY 输出恢复位置 | Host Output Store | 是 |
| Window、Workspace View、Tabs | Client Layout Store | 是，设备本地 |
| Attachment、Lease、Viewport Owner | Host 内存状态 | 否 |
| Agent activity（working、waiting、ready、failed） | Host 内存状态 | 否 |
| Surface、焦点、测量尺寸 | Renderer Coordinator | 否 |
| 导入完成状态 | Import Receipt Store | 是 |

## 5. 必须成立的不变量

1. 一个 Workspace 属于且只属于一个 Project。
2. 一个 Terminal Session 属于且只属于一个 Workspace。
3. 一个 Tab 属于且只属于一个 Window 的 Workspace View，并只引用该 Workspace 下的 Session。
4. 顶部 Tab 条只展示 Active Workspace 的 Tabs。
5. 切换 Workspace 必须原子切换 Tabs、Active Tab 和 Renderer Set。
6. 一个 Window 同时只有一个 Active Workspace；一个 Workspace View 同时最多只有一个 Active Tab。
7. 后台 Workspace 不挂载 Surface，不发送输入，不发送 resize。
8. 一个 Session 同时最多有一个 Input Lease 和一个 Canonical Viewport Owner。
9. Warren v1 关闭 Tab 会终止其对应 Runtime；它不是仅 detach。没有 Tab
   的 ended Session 记录仍可保留供历史查看和后续清理。
10. Project 的新增动作创建 Workspace；Workspace 或 Tab 条的新增动作创建 Session。
11. 创建 Session 必须携带固定 Workspace ID 和 Request ID；相同 Request ID 最多创建一个 Session。
12. App 初始化不得自动创建 shell、Codex 或 Claude Session。
13. 用户选择没有 Tab 的 Workspace 时，必须幂等创建一个默认 Shell Tab；重复选择不得重复创建。
14. App 同时只允许一个前台 Client Instance；重复启动应激活已有实例后退出。
15. App 退出必须结束 Client 进程，但不得 kill 已创建的 tmux Session。
16. 导入不得修改 Superset 数据、Git 仓库、worktree 或 tmux。

## 6. 模块边界

```text
macOS UI
  ↓ typed intents / screen projections
Client Application
  ├── Client Layout Store
  └── Renderer Coordinator → Ghostty Adapter
  ↓ Host Protocol
Local Transport
  ↓
Host Service
  ├── Resource Service
  ├── Session Service
  ├── Import Service
  ├── Host Store
  └── Terminal Runtime → tmux Adapter
```

依赖只能向内指向协议和领域值。SwiftUI、Ghostty、tmux、SQLite、Superset Schema 和 WebSocket 都是边缘适配器。

### 6.1 后续扩展边界

```text
macOS / iOS / Web Client
        ↓
Endpoint Resolver
        ↓
Local IPC / Direct WebSocket / Relay Transport
        ↓
Host Service or Host Daemon
```

macOS Client 对 Local 使用进程内组合，对 Server 使用版本化 WebSocket API。`warren-headless` 是远端 Host 的部署形态，持有独立资源树和 tmux runtime。Endpoint 切换只替换客户端投影与 renderer，不迁移或终止另一 Host 上的资源。

SSH 只承担远端 daemon 引导和 loopback 端口转发。`warren ssh` 建立可达性后，Desktop 和 CLI 继续使用同一 WebSocket API；Git、tmux 和资源语义不得编码进 SSH transport。

Tailscale、局域网、Cloudflare Tunnel 只提供网络可达性，不进入业务模型。中心 Relay Service 只提供 Host 注册、发现、配对、撤销、信令和 WebSocket Relay；Session 与进程仍由 Host 持有。

WebRelay 默认只绑定 `127.0.0.1`。移动端访问和 PWA 安装使用用户显式启动的 Cloudflare Tunnel 或 Tailscale Serve HTTPS 地址；访问 URL 携带随机配对 token，WebSocket 握手后仍须认证。慢 Web Client 使用有界非阻塞发送队列，不能阻塞 macOS 主线程或 Host 输出。

Web/PWA 客户端源码使用 Vite 组织，位于 `Web/`。`Packages/WebRelay/Sources/WebRelay/Resources` 只保存构建产物，由 Swift WebRelay 和 Go Relay Service 共同嵌入；不得直接维护单文件内嵌脚本副本。

远端控制面是独立可部署进程。每台 Host 由管理员签发独立 credential，只向 Relay 建立出站 WSS；Relay 以 connection ID 多路复用 Web Client，不连接 macOS 入站端口。短期一次性 pairing code 换取绑定 Host 与 credential generation 的 HMAC access token；撤销或轮换 Host credential 必须立即断开 Host 并使旧 token 失效。Relay 持久化 credential hash、generation 和在线元数据，不保存 Project/Workspace/Session、Terminal 输出或用户输入。公网部署必须在 TLS 后、配置严格 Origin、强随机 Secret 和持久数据卷。

Session 分享通过 Principal、Share Grant、Capability 和多个 Attachment 增量实现，不改变资源树。

## 7. 本地数据设计

Warren 使用自己的版本化 SQLite 数据库，开启 WAL、foreign keys 和 busy timeout。JSON 文件不得承担并发资源状态。

默认目录：

```text
~/Library/Application Support/Warren/
├── state.sqlite3
├── state.sqlite3-wal
├── state.sqlite3-shm
├── runtime/
│   └── <session-id>/output.log
├── diagnostics/
└── lock/
```

测试必须允许通过显式启动参数覆盖数据目录和 tmux socket，不接触用户数据。

最低数据集合：

```text
schema_migrations(version, applied_at)
hosts(id, kind, display_name, created_at)
projects(id, host_id, name, repository_path, repository_identity, created_at, updated_at)
workspaces(id, project_id, name, path, branch, kind, created_at, updated_at)
terminal_sessions(id, workspace_id, title, kind, lifecycle, created_at, ended_at)
runtime_bindings(session_id, adapter, runtime_identifier, metadata, output_epoch, output_sequence)
client_windows(id, device_id, active_workspace_id, geometry, updated_at)
workspace_views(window_id, workspace_id, active_tab_id, updated_at)
tabs(id, window_id, workspace_id, session_id, position, created_at)
import_receipts(id, source_kind, source_identity, source_version, summary, completed_at)
request_receipts(request_id, command_kind, resource_id, completed_at)
```

约束：

- Project 以规范化 repository identity 去重。
- Workspace 以 Host 内规范化真实路径去重。
- Session 的 Workspace 外键不可为空。
- Tab 的 Workspace 必须与 Session 的 Workspace 相同。
- Window 内 Tab position 唯一且连续归一化。
- 所有迁移具有事务性，并提供从上一已发布 schema 的前向迁移。

## 8. Superset 单次导入

### 8.1 来源

第一期默认读取 `~/.superset/local.db`。用户可以显式选择其他文件。读取连接必须为 read-only，并在导入前检测必要表与列；不得假定 Superset 未来 schema 永远不变。

导入对象：

- `projects`：名称、主仓库路径和可用 Git 元数据。
- `worktrees`：工作目录、branch 和主仓库归属。
- `workspaces`：显示名称、顺序以及到 worktree 或主检出目录的关系。

明确不导入：

- tmux session、terminal tab、pane、终端输出。
- Superset 账号、组织、任务、Automation 和云端标识。
- UI 窗口状态和凭证。

### 8.2 流程

```text
选择 Import from Superset
→ 只读打开并识别 schema
→ 构建候选 Project/Workspace
→ realpath、Git common-dir 和 branch 校验
→ 展示可导入、重复、缺失和无效摘要
→ 单一 SQLite 事务写入 Warren 新 ID
→ 写入 Import Receipt
→ 选择首个有效 Workspace
```

失败时整个事务回滚，不留下半导入数据或 Receipt。成功后不再自动检查 Superset，也不建立文件监听。重新导入只作为显式诊断能力，不属于第一期主流程。

## 9. Session 与 tmux 设计

### 9.1 映射

一个 Terminal Session 对应一个唯一命名的 tmux session。第一期只使用其首个 pane，不把 tmux window/pane 暴露为 UI 领域对象。

tmux session 名由 Warren Session ID 确定，不使用用户标题、branch 或路径，避免重命名和字符转义影响身份。

### 9.2 创建

```text
CreateSession(workspaceID, launchSpec, requestID)
→ 校验 Workspace 和请求幂等性
→ 订阅 Runtime 输出
→ detached 创建 tmux
→ 设置工作目录、TERM、尺寸和 shell 环境
→ 安装输出管道
→ 持久化 Session 与 Runtime Binding
→ 返回资源事件
→ Client Layout 创建并激活 Tab
```

交互 Shell 直接作为 tmux pane 前台进程启动。Preset 命令不得依赖固定 sleep 后模拟键入；Runtime 必须提供可靠的启动命令方式，并保留完整交互式 TTY。

### 9.3 输入

普通字节输入使用唯一 tmux buffer 的 `load-buffer` 与 `paste-buffer -d`，每个 Session 串行保序。特殊键和信号使用显式操作，不把 `Ctrl-C` 等控制动作编码为普通业务字符串。

任何输入必须验证 Attachment、Input Lease 和 Session lifecycle。输入失败不得导致连接或 App 全局失效。

### 9.4 输出与颜色

tmux `pipe-pane` 产生原始 PTY 字节。Host 不剥离 ANSI、OSC、Unicode 或控制序列。Ghostty 在 Client 侧解析和渲染，因此 Codex、Claude、shell 和 TUI 的颜色必须保留。

输出同时进入：

- 有界内存环：低延迟广播与短期恢复。
- Session 持久日志：Host/App 重启和长时间任务恢复。

每个字节位置由 `epoch + sequence` 标识。Client 重连时请求其最后 Recovery Anchor；Host 返回 catch-up 或 reanchor，不允许静默跳过缺口。

### 9.5 尺寸与焦点

只有 Active Workspace 的 Active Tab Surface 可以获取本机键盘焦点。只有 Canonical Viewport Owner 可以 resize PTY。

Resize 按 Session 使用单一 worker，latest wins；激活 Surface 后强制以实际可见区域重新计算一次行列数。隐藏 Surface 的布局回调必须被丢弃。

### 9.6 关闭、退出与恢复

- Close Tab：终止对应 Runtime，记录 Session 为 ended，再移除本地 Tab 和 Surface；
  已 ended 的 Session 不可重新打开，只能新建 Tab/Session。
- Detach：断开一个 Attachment，不终止 Session。
- Terminate Session：请求 Runtime 结束 tmux，并记录 ended 状态。
- Quit Client：停止 UI、连接和观察任务；tmux 保持运行。
- Relaunch：Host Store 恢复资源，Runtime Adapter 检测并 adopt 存活 tmux；缺失 Runtime 被标记 ended，不得卡在 connecting。

Runtime 使用单一生命周期 watcher。每轮以一次 `list-sessions` 获取 tmux 存活集合，再与全部受管 Session 比对；不得为每个 Session 启动独立轮询进程。瞬时命令失败不产生 ended 事件。没有受管 Session 时 watcher 必须停止。

## 10. macOS 交互设计

界面信息架构沿用 Superset 已验证的基础关系，但不复制其领域实现：

```text
Window
├── Sidebar
│   └── Project
│       └── Workspaces
└── Workspace Screen
    ├── Top Bar
    ├── Preset Bar
    ├── Workspace-scoped Tab Bar
    └── Active Terminal
```

行为要求：

- 初始空状态只展示导入或添加 Project，不创建任何 Session。
- Project 默认收缩；用户明确展开后才显示其 Workspace，新增 Project 同样默认收缩。
- Project 行除独立新增按钮外，整行是展开和收缩热区；展开动作不隐式创建 Session。
- Workspace 行整行是选择和进入 Session 的热区，不再放置容易误点的小型新增按钮。
- 点击 Workspace 必须立即切换，不等待 tmux、Git 或磁盘操作。
- 点击没有 Tab 的 Workspace 后，立即显示不可交互的 `Starting Shell…` Loading Tab 和内容进度态，再在该 Workspace 的串行命令队列中创建默认 Shell。快速重复点击共享同一在途操作；完成后原位替换为真实 Tab，失败时移除 Loading 并显示可恢复错误。若用户已切换到别处，创建结果不得抢回选择。
- 点击 Tab 必须立即切换 Active Session，并把焦点交给 Ghostty。
- Preset 在当前捕获的 Workspace 创建 Session；切换 Workspace 不得改变在途请求目标。
- Tab 新增按钮紧随最后一个 Tab；没有 Tab 时位于起始位置。
- 无意义、无动作或重复表达的图标不展示。
- 字体、密度、间距、层级和 hover/selected 状态以 Superset macOS Desktop 为第一期视觉基准；终端本体使用等宽字体和 Ghostty 主题能力。
- 所有可交互元素必须有稳定 Accessibility Identifier、Role、Label、Value 和可执行 Action。
- 自绘无标题窗口只允许顶部明确的空白 chrome 叶节点调用 AppKit `performDrag`；Tab、按钮和 Terminal 不继承窗口拖动行为。
- Workspace 汇总所有 Host Session 的明确 activity，优先级为 `failed > waitingForInput > connecting > working > ready > exited`；不能只查看当前 Tab。
- Superset 风格状态点：failed 红色呼吸、waitingForInput 黄色呼吸、working 琥珀色呼吸、ready 绿色静态、exited 灰色静态。
- Agent activity 由 Warren 管理的 Claude/Codex Hook 上报。Hook 只读取事件类型和 `WARREN_SESSION_ID`，不读取或上传对话内容；配置合并必须保留用户条目并可幂等更新。
- Warren 启动 Codex 时只使用 `--dangerously-bypass-hook-trust` 信任由 Warren 生成和校验的 Hook；不得因此绕过 Codex command approval 或 sandbox。

## 11. Web/PWA 交互设计

Web Client 使用与桌面一致的 Project → Workspace → Session 信息架构，并遵循以下规则：

- 桌面宽度显示固定 Sidebar、横向 Session Tabs、Preset Bar 和 Terminal。
- 移动宽度使用可关闭的 Sidebar 抽屉、可横向滚动的 Tabs、底部安全区快捷键栏。
- PWA 提供 manifest、maskable 图标、standalone 模式和 shell 缓存；配对 token 首次认证后保存在当前浏览器本地，以便安装后从 `start_url` 启动。
- PWA 离线只展示缓存 UI 壳和断开状态，不伪造 Host 或 Session 可用性。
- Web Attachment 与桌面 Attachment 身份独立；两端可同时观察。只有实际输入或 resize 的 Attachment 才按 last-writer-wins 获取 Control Lease。
- Web 创建 Session 立即展示 loading；Host 返回新 Session ID 后直接 attach，不等待下一次 roster 猜测。
- 触屏方向键发送真实 ANSI cursor sequence，Esc、Tab、Ctrl-C、Ctrl-D 发送真实控制字节。

性能目标：

- 本地导航和 Tab 切换在同一主线程事务内完成，不等待 I/O。
- tmux 生命周期观察每轮最多启动一个查询进程，查询频率不随 Session 数增长。
- 输入到 Runtime 写入不得被持久化或全局 Snapshot 阻塞。
- PTY 输出不得因数据库写入产生背压。
- 单个 Workspace 的失败不得冻结其他 Workspace 或整个窗口。

## 12. 无干扰可观测与验收设计

验收不得依赖截图，不得移动鼠标，不得抢占用户当前 App 的键盘焦点。

### 12.1 三层观测

**领域事件日志**：每条命令和状态迁移输出结构化事件，包含 monotonic timestamp、trace ID、request ID、window ID、workspace ID、session ID、旧状态、目标状态、结果和错误。严禁记录凭证及完整用户输入。

**语义 UI 快照**：实际 View 对外提供只读语义树，包含 Accessibility Identifier、role、label、value、enabled、selected、focused、frame 和 children。它描述用户能操作什么，不包含像素。

**终端探针**：记录 Runtime 状态、tmux 实际尺寸、Attachment/Lease、输入序列、Recovery Anchor、原始输出摘要和终端解析后的 cell/style 摘要。颜色验收读取 ANSI 后的 cell attributes，不读取截图。

### 12.2 测试运行方式

测试使用独立临时目录和独立 tmux server：

```text
Warren Test Process
├── data-dir = mktemp
├── tmux socket = warren-test-<uuid>
├── deterministic clock / request IDs
├── offscreen, never-key NSWindow
└── test observation socket
```

实际 SwiftUI Root View 挂载到 `orderOut` 的 NSWindow。测试通过 Accessibility Action 或直接事件分发执行点击、选择、键盘和 resize；禁止使用 CGEvent 移动全局鼠标，禁止调用 `NSApp.activate`，禁止 `makeKeyAndOrderFront`。

Observation Socket 只在显式测试启动参数下开启，使用随机临时 Unix socket，并提供：

- `snapshot.resources`
- `snapshot.window`
- `snapshot.accessibility`
- `snapshot.renderer`
- `snapshot.runtime`
- `events.since(sequence)`
- `intent.perform(identifier, action)`
- `wait.until(predicate, timeout)`

生产构建默认关闭该入口。测试动作仍必须走与真实 UI 相同的 typed intent，禁止直接篡改 Store 制造通过结果。

### 12.3 验收证据

每个端到端用例输出一个机器可读 artifact：

```text
artifacts/<run-id>/
├── result.json
├── event-trace.jsonl
├── semantic-ui.json
├── runtime.json
└── terminal-cells.json
```

失败报告必须指出最后成功不变量、首次违规事件、相关资源 ID 和可重现命令。测试结束必须验证用户鼠标坐标与前台应用 PID 未变化。

## 13. 第一期开外范围

- 多用户账号、组织、计费与跨组织 Host 目录。
- 自动注册 Host 或自动打开公网入口。
- iOS 原生客户端。
- 多人分享和权限 UI。
- Automation 调度器。
- tmux 多 window/pane 到 UI Pane 的映射。
- 跨设备实时同步 Client Layout。
- CRDT。

这些能力只能通过已定义的 Host Protocol、Transport、Principal/Capability、Attachment 和 Runtime 边界增量加入，不得反向污染一期模型。
