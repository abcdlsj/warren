# Burrow 架构

本文定义 Burrow 当前 macOS 产品的状态所有权和模块边界。实现与测试必须满足本文的不变量。

## 1. 核心模型

Burrow 有两棵不同的树。它们不能合并。

```text
Host Resource Tree
Host
└── Project
    └── Workspace
        └── Terminal Session
            └── Runtime Binding

Client Presentation Tree
Client Window
└── Active Workspace
    └── Workspace View
        ├── ordered Tabs
        └── Active Tab
            └── Active Renderer
```

Project 是仓库身份。Workspace 是该仓库的一个具体本地目录及分支上下文。Terminal Session 必须且只能属于一个 Workspace。

Tab 不是 Terminal Session。Tab 是 Client 在某个 Workspace View 中展示 Terminal Session 的入口。关闭 Tab 只改变 Client Layout。

## 2. 唯一权威

| 状态 | 唯一权威 | 持久化位置 |
| --- | --- | --- |
| Project、Workspace、Terminal Session | Host | Host State |
| Runtime descriptor、输出恢复锚点 | Host | Host State |
| Workspace 的 Tab 顺序和 Active Tab | Client Layout | Client Layout State |
| 窗口的 Active Workspace、Sidebar、窗口几何 | Client Window | Client Layout State |
| Attachment、Control Lease | Host 连接状态 | 不长期持久化 |
| Ghostty Surface、焦点、测量尺寸 | Renderer Coordinator | 不持久化 |

任何字段只能有一个写入权威。投影可以复制值，但不能反向成为第二个权威。

## 3. 必须满足的不变量

1. 一个 Workspace 属于一个 Project。
2. 一个 Terminal Session 属于一个 Workspace。
3. 一个 Tab 属于一个 Workspace View，并引用该 Workspace 下的一个 Terminal Session。
4. 顶部 Tab 条只显示 Active Workspace 的 Tabs。
5. 切换 Workspace 后，旧 Workspace 的 Tabs、Active Tab 和 Renderer 不得出现在当前内容区。
6. 一个窗口同时只有一个 Active Workspace 和一个 Active Tab。
7. 只有 Active Tab 的 Renderer 可以发送输入和 resize。
8. 关闭 Tab、切换 Workspace、关闭窗口或退出 App，不得终止 Terminal Session。
9. Project 行的 `+` 创建 Workspace；Workspace 行和 Tab 条的 `+` 创建 Session。
10. Session 创建命令必须携带不可变的 Workspace ID。命令执行期间的导航变化不得改变目标 Workspace。
11. 同一个用户动作最多创建一个 Session。重复点击由请求身份或进行中状态合并。
12. 后台 Workspace 不挂载 Ghostty Surface，也不参与 AppKit 布局。

## 4. 屏幕投影

Desktop 不消费全局 Application Snapshot。窗口只消费一个 `WorkspaceScreenProjection`：

```text
WorkspaceScreenProjection
├── sidebar: Project 与 Workspace 摘要
├── activeWorkspace: Workspace?
├── tabs: Active Workspace 的有序 Tabs
├── activeTabID: String?
├── sessions: Active Workspace 的 Session 摘要
└── issue: 当前窗口需要展示的问题
```

Desktop 只能发出 typed intent。它不能直接创建 Runtime、修改 Host State、持久化布局或管理 Ghostty Surface。

## 5. 命令流

### 切换 Workspace

```text
Click Workspace
→ Window Navigation 立即更新 Active Workspace
→ Client Layout 恢复该 Workspace 的 Active Tab
→ Application 生成新的 WorkspaceScreenProjection
→ Renderer Coordinator 卸载旧 Renderer Set
→ Renderer Coordinator 挂载新 Workspace 的 Renderer Set
→ Active Renderer 获取焦点并校准尺寸
```

切换是本地同步操作，不等待 tmux、磁盘或网络。

### 创建 Session

```text
Click Workspace/Tab + or Preset
→ 捕获 Workspace ID 和 Launch Request
→ 标记该 Workspace 的创建请求为 in-flight
→ Host 创建 Terminal Session 与 Runtime Binding
→ Client Layout 在该 Workspace 插入 Tab 并设为 Active Tab
→ 投影更新
→ Renderer Coordinator 挂载并激活新 Surface
→ 清除 in-flight
```

不同 Workspace 的创建可以并发。同一 Workspace 内的布局写入按顺序提交。失败只回滚对应请求，不阻塞导航。

### 关闭 Tab

```text
Close Tab
→ Client Layout 移除该 Workspace 的 Tab
→ 在同一 Workspace 内选择相邻 Tab
→ Renderer Coordinator 卸载对应 Surface
→ Attachment 可释放
→ Terminal Session 与 Runtime 继续运行
```

`Close Other Tabs` 和 `Close All Tabs` 的作用域永远是当前 Workspace。

## 6. Renderer 生命周期

Renderer Coordinator 使用 `(WorkspaceID, TerminalSessionID)` 识别 Surface。

- Active Workspace 的可见 Tabs 可以保留 Surface，以保存本地滚动和渲染状态。
- 非 Active Workspace 不保留 Surface；再次进入时从 Host 输出环和 Recovery Anchor 重建。
- Hidden Surface 不发送输入或 resize。
- Active Surface 是唯一 viewport owner。resize 按 Session 串行合并，只提交最新尺寸。

## 7. 并发规则

- 导航状态只在 MainActor 修改，并立即完成。
- Host 资源操作在 Application Service actor 中执行。
- 不使用一条全局任务队列串行化所有 UI 操作。
- Session 创建按 Workspace 隔离；输入和 resize 按 Terminal Session 隔离。
- 异步完成事件必须携带原始 Workspace ID 和请求 ID，禁止读取“当前选择”来推断目标。
- Snapshot 是只读事实。Reducer 不在 Snapshot 发布时发起副作用。

## 8. 模块边界

```text
Domain
  ↑
Host ← StateStore / Runtime Adapter
  ↑
Transport
  ↑
Application ← Client Layout Store
  ↑                 ↑
Desktop        Renderer Coordinator ← Ghostty Adapter
  ↑
BurrowNext Composition Root
```

- `Domain`：Project、Workspace、Terminal Session 等稳定概念。
- `Host`：资源生命周期、Attachment、Control Lease 和输出恢复。
- `StateStore`：Host State 与 Client Layout State 的独立存储边界。
- `Application`：执行 use case，组合 Host 事实和 Client Layout，生成屏幕投影。
- `Desktop`：纯 SwiftUI 展示和 typed intent。
- `GhosttyAdapter`：渲染、焦点和网格测量，不拥有 Session。
- `BurrowNext`：依赖注入和 macOS 窗口生命周期。

## 9. 禁止模式

- 禁止把全局 `snapshot.tabs` 直接传给 Workspace 页面。
- 禁止在 Host Session 上新增 Tab、选中态或窗口字段。
- 禁止通过当前 UI selection 推断异步命令的 Workspace。
- 禁止挂载所有 Workspace 的 Ghostty Surface 后用 opacity 隐藏。
- 禁止 Project 行的 `+` 直接创建 Session。
- 禁止关闭 Tab 时 kill tmux Session。
- 禁止使用全局 action tail 阻塞无关 Workspace 的操作。

## 10. 迁移顺序

1. 引入 workspace-scoped Client Layout，并从旧 `isTabVisible` 一次迁移。
2. 让 Application 输出 `WorkspaceScreenProjection`，删除 Desktop 对全局 Tabs 的依赖。
3. 用 Renderer Coordinator 只管理 Active Workspace 的 Surface。
4. 将创建、关闭和恢复操作改为 workspace-scoped command。
5. 把 Project `+` 改为 Workspace 创建入口；在 Workspace 创建能力完成前不展示虚假动作。
6. 删除兼容字段和旧全局 Tab API。
