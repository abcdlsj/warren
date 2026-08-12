# Burrow 产品与系统设计

状态：第一期唯一设计事实源  
适用范围：产品、领域模型、架构、数据、终端运行时、界面和验收  
更新规则：实现与本文冲突时，以本文为准；变更设计时必须在同一提交中更新本文

## 1. 产品目标

Burrow 是以 Workspace 为边界、以持久终端为核心的本地开发工作台。

第一期只交付 macOS 本地产品。用户可以管理 Project 和 Workspace，在每个 Workspace 内创建、切换、关闭和恢复 Terminal Session，并通过 Ghostty 获得接近原生终端的输入、颜色、尺寸和交互体验。

系统必须为后续 iOS、Web、远程 Host、Session 分享、Automation 和中心控制面保留稳定边界，但第一期不得为尚未交付的网络功能增加用户可见复杂度。

## 2. 第一原则

1. Session 属于 Host，Tab 属于 Window，Runtime 属于 Session。三者生命周期互不替代。
2. Workspace 是终端、Tab 和异步命令的隔离边界。
3. tmux 是可替换的 Runtime Adapter，不是产品领域模型。
4. 关闭 Tab、切换 Workspace、关闭窗口或退出 Client 不结束 Session。
5. 只有显式终止 Session 才能结束其 Runtime。
6. UI 只展示投影并发送 typed intent，不直接操作 tmux、数据库或 Ghostty 生命周期。
7. 每类状态只有一个写入权威；缓存和投影不得成为第二权威。
8. 所有异步操作携带不可变目标 ID 和 Request ID，不读取完成时的当前选择来推断目标。
9. 本地连接与未来网络连接共用同一应用协议。
10. 可观测性是产品能力，不是测试补丁。

## 3. 统一术语

### 3.1 资源

**Host**：持有 Project、Workspace、Terminal Session 和 Runtime 真实状态的执行节点。第一期是当前 Mac 上的本地 Host Service。

**Project**：一个 Git 仓库身份。Project 用于组织 Workspace，不是终端运行目录。

**Workspace**：Project 下一个具体、可访问的本地工作目录及其 Git 上下文。主检出目录和 worktree 都是 Workspace。Workspace ID 是稳定身份，branch 和 path 是可变化属性。

**Terminal Session**：Host 上持续存在的交互式终端上下文。它只属于一个 Workspace，并独立于窗口、Tab、Renderer 和 Attachment 存活。

**Runtime Binding**：Terminal Session 到具体运行实现的持久映射。第一期实现为一个 Burrow Session 对应一个独立 tmux session 和一个 pane。

### 3.2 客户端

**Device**：稳定设备身份。第一期只有当前 Mac，但模型不得假定永远只有一个设备。

**Client Instance**：一次 App 运行实例。退出 App 后失效。

**Client Window**：独立的导航和布局作用域。每个 Window 独立保存 Active Workspace 和各 Workspace View。

**Workspace View**：一个 Window 为一个 Workspace 保存的本地展示状态，包含有序 Tabs 和 Active Tab。

**Tab**：Workspace View 中指向 Terminal Session 的本地入口。关闭 Tab 不终止 Session；同一个 Session 在一个 Workspace View 中最多有一个 Tab。

**Renderer Surface**：客户端为一个 Tab 挂载的 Ghostty 表面。Surface 不拥有 Session。

**Attachment**：Client Instance 与 Terminal Session 的临时连接。后续分享能力通过同一 Session 上的多个 Attachment 实现。

**Input Lease**：允许一个 Attachment 向 Session 输入的排他租约。

**Canonical Viewport Owner**：允许一个 Attachment 改变 PTY 行列数的唯一参与者。第一版由 Input Lease 持有者同时承担；观察者不得 resize PTY。

### 3.3 导入与自动化

**Superset Import**：从 Superset 本地数据库读取 Project 和 Workspace 元数据，并一次性复制为 Burrow 自有数据的 onboarding 操作。它不是同步。

**Import Receipt**：成功导入的持久记录，包含来源、版本、时间和摘要。成功后不再自动提示或重复导入。

**Automation Run**：后续版本中一次有明确开始、退出状态和保留策略的非人工任务。它可以使用 Terminal Session 展示过程，但不能用 Tab 或提示符推断完成状态。

## 4. 权威模型

```text
Resource Authority
Local Host
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
9. 关闭 Tab 不 detach 其他 Client，也不 kill tmux。
10. Project 的新增动作创建 Workspace；Workspace 或 Tab 条的新增动作创建 Session。
11. 创建 Session 必须携带固定 Workspace ID 和 Request ID；相同 Request ID 最多创建一个 Session。
12. App 初始化不得自动创建 shell、Codex 或 Claude Session。
13. App 同时只允许一个前台 Client Instance；重复启动应激活已有实例后退出。
14. App 退出必须结束 Client 进程，但不得 kill 已创建的 tmux Session。
15. 导入不得修改 Superset 数据、Git 仓库、worktree 或 tmux。

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

第一期使用进程内或本地 IPC 组合。后续将 Host 移入 daemon 时，不改变 Project、Workspace、Session、Client Layout 或 Host Protocol。

Tailscale、局域网、Cloudflare Tunnel 只提供网络可达性，不进入业务模型。未来中心 Server 只提供账号、Host 发现、配对、撤销、信令和 Relay；Session 与进程仍由 Host 持有。

Session 分享通过 Principal、Share Grant、Capability 和多个 Attachment 增量实现，不改变资源树。

## 7. 本地数据设计

Burrow 使用自己的版本化 SQLite 数据库，开启 WAL、foreign keys 和 busy timeout。JSON 文件不得承担并发资源状态。

默认目录：

```text
~/Library/Application Support/Burrow/
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
→ 单一 SQLite 事务写入 Burrow 新 ID
→ 写入 Import Receipt
→ 选择首个有效 Workspace
```

失败时整个事务回滚，不留下半导入数据或 Receipt。成功后不再自动检查 Superset，也不建立文件监听。重新导入只作为显式诊断能力，不属于第一期主流程。

## 9. Session 与 tmux 设计

### 9.1 映射

一个 Terminal Session 对应一个唯一命名的 tmux session。第一期只使用其首个 pane，不把 tmux window/pane 暴露为 UI 领域对象。

tmux session 名由 Burrow Session ID 确定，不使用用户标题、branch 或路径，避免重命名和字符转义影响身份。

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

- Close Tab：移除本地 Tab 和 Surface，不终止 Session。
- Detach：断开一个 Attachment，不终止 Session。
- Terminate Session：请求 Runtime 结束 tmux，并记录 ended 状态。
- Quit Client：停止 UI、连接和观察任务；tmux 保持运行。
- Relaunch：Host Store 恢复资源，Runtime Adapter 检测并 adopt 存活 tmux；缺失 Runtime 被标记 ended，不得卡在 connecting。

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
- 点击 Project 选中其最近 Workspace；没有 Workspace 时展示创建入口。
- 点击 Workspace 必须立即切换，不等待 tmux、Git 或磁盘操作。
- 点击 Tab 必须立即切换 Active Session，并把焦点交给 Ghostty。
- Preset 在当前捕获的 Workspace 创建 Session；切换 Workspace 不得改变在途请求目标。
- Tab 新增按钮紧随最后一个 Tab；没有 Tab 时位于起始位置。
- 无意义、无动作或重复表达的图标不展示。
- 字体、密度、间距、层级和 hover/selected 状态以 Superset macOS Desktop 为第一期视觉基准；终端本体使用等宽字体和 Ghostty 主题能力。
- 所有可交互元素必须有稳定 Accessibility Identifier、Role、Label、Value 和可执行 Action。

性能目标：

- 本地导航和 Tab 切换在同一主线程事务内完成，不等待 I/O。
- 输入到 Runtime 写入不得被持久化或全局 Snapshot 阻塞。
- PTY 输出不得因数据库写入产生背压。
- 单个 Workspace 的失败不得冻结其他 Workspace 或整个窗口。

## 11. 无干扰可观测与验收设计

验收不得依赖截图，不得移动鼠标，不得抢占用户当前 App 的键盘焦点。

### 11.1 三层观测

**领域事件日志**：每条命令和状态迁移输出结构化事件，包含 monotonic timestamp、trace ID、request ID、window ID、workspace ID、session ID、旧状态、目标状态、结果和错误。严禁记录凭证及完整用户输入。

**语义 UI 快照**：实际 View 对外提供只读语义树，包含 Accessibility Identifier、role、label、value、enabled、selected、focused、frame 和 children。它描述用户能操作什么，不包含像素。

**终端探针**：记录 Runtime 状态、tmux 实际尺寸、Attachment/Lease、输入序列、Recovery Anchor、原始输出摘要和终端解析后的 cell/style 摘要。颜色验收读取 ANSI 后的 cell attributes，不读取截图。

### 11.2 测试运行方式

测试使用独立临时目录和独立 tmux server：

```text
Burrow Test Process
├── data-dir = mktemp
├── tmux socket = burrow-test-<uuid>
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

### 11.3 验收证据

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

## 12. 第一期开外范围

- 中心 Server、账号系统、Relay 和公网发现。
- Tailscale 或 Cloudflare 的产品内集成。
- iOS/Web 正式客户端。
- 多人分享和权限 UI。
- Automation 调度器。
- tmux 多 window/pane 到 UI Pane 的映射。
- 跨设备实时同步 Client Layout。
- CRDT。

这些能力只能通过已定义的 Host Protocol、Transport、Principal/Capability、Attachment 和 Runtime 边界增量加入，不得反向污染一期模型。
