# Superset Desktop 高保真复刻规范

## 结论

Burrow Desktop 必须复刻 Superset 的“单一 Sidebar 表面 + TopBar/TabBar + 递归 Pane”结构。
视觉结果必须由语义令牌驱动。不得把颜色、尺寸或交互状态散落为个人审美值。
源码没有确认的尺寸，本文明确标为“待测量”。

本规范只约束 Burrow Desktop 的复刻基准。它不要求复制 Electron、React、Tailwind 或 Superset 的组件边界。

## 规范等级

| 等级 | 含义 |
| --- | --- |
| 必须一致 | macOS Desktop 的布局、尺寸、间距、令牌、信息层级和状态反馈。验收时逐项对照源码与截图。 |
| 平台原生适配 | 由 macOS/iOS 窗口、系统控件、SwiftUI 可访问性或终端渲染约束造成的差异。差异必须有平台原因。 |
| 暂缓 | 源码未给出可靠数值，或本轮 Burrow 明确不做的内容。实现时不得猜测成“设计值”。 |

## 1. 组件层级与窗口布局（必须一致）

### 1.1 Dashboard 根布局

Dashboard 根节点是全窗口的横向 Flex，`h-full w-full overflow-hidden`。展开的 v2 Sidebar 位于主列之外；其余内容是纵向主列。右侧预留 `workspace-right-sidebar-slot`，用于把工作区 Inspector/文件侧栏挂到同一窗口高度。依据：

- [DashboardLayout 根节点与右侧 slot](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/layout.tsx:213)
- [展开 Sidebar 的列外布局](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/layout.tsx:189)
- [右侧 Sidebar slot](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/layout.tsx:238)

Dashboard 的主列顺序如下：

```text
DashboardLayout
├── CommandPaletteHost
├── [v2 expanded] ResizablePanel(DashboardSidebar)
└── main column
    ├── TopBar                 （某些 v2 路由隐藏）
    └── content row
        ├── [closed/collapsed or v1] ResizablePanel(WorkspaceSidebar)
        └── Outlet
└── workspace-right-sidebar-slot
```

在 v2 Workspace 路由中，TopBar 被隐藏，TabBar 承接顶部拖拽区、左侧导航和右侧操作；展开 Sidebar 自己承接交通灯留白。折叠 Sidebar 时，折叠 rail 的顶部 `h-10` strip 与 TabBar 具有相同高度、背景和底边界。依据：

- [TopBar 隐藏条件与 v2 合并说明](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/layout.tsx:196)
- [折叠 rail 继续 TabBar 的条件](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/layout.tsx:151)
- [折叠 rail 的 `h-10` strip](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/components/DashboardSidebarHeader/DashboardSidebarHeader.tsx:182)
- [v2 路由把导航注入 TabBar leading/trailing](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/v2-workspace/$workspaceId/page.tsx:344)

### 1.2 TopBar

TopBar 的可执行规范：

| 项目 | Superset 事实 | Burrow 要求 |
| --- | --- | --- |
| 高度 | Mac 为 `48 / zoomFactor` CSS px；非 Mac 使用 Tailwind `h-12` | macOS 保持固定物理高度；其他平台由系统窗口行为决定。精确截图仍需待测量。 |
| 表面 | `bg-muted/45`；dark 为 `bg-muted/35` | 使用 `surface.chrome` 语义令牌，不直接复制类名。 |
| 左侧 | 交通灯留白、SidebarToggle、NavigationControls、v1 ResourceConsumption | 控件均可点击；拖拽区只能是空白叶子。 |
| 中间 | 空白拖拽 filler；v2 可显示工作区标题 | filler 可拖拽，标题不吞掉交互。 |
| 右侧 | Offline、Open In、组织、右侧 Sidebar、非 Mac WindowControls | 按路由和平台披露；保持 `gap-3`、`pr-4` 的密度。 |

来源：

- [TopBar 高度、表面、三段布局](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/TopBar/TopBar.tsx:46)
- [TopBar 左侧与中间拖拽 filler](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/TopBar/TopBar.tsx:61)
- [TopBar 右侧状态与操作](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/TopBar/TopBar.tsx:81)
- [v2 工作区标题字号与层级](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/TopBar/components/V2WorkspaceTitle/V2WorkspaceTitle.tsx:23)

Mac 交通灯左侧 inset 是 `80 / zoomFactor`；当展开 Sidebar 承接 chrome 时，TopBar 改用 `16px` inset。TopBar 的 Mac 控件使用 `ZoomStable`，让缩放不改变交通灯对齐。依据：[TopBar 交通灯 inset 与 zoom 规则](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/TopBar/TopBar.tsx:37)。

Offline 状态是右上角紧凑 badge：图标 `size-3.5`、字号 `text-xs`、`bg-muted px-2 py-1 rounded`。依据：[Offline badge](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/TopBar/TopBar.tsx:81)。

### 1.3 窗口拖拽区（必须一致；窗口实现可平台适配）

Superset 明确禁止把整个 TopBar/TabBar 标成拖拽区，再用 `no-drag` 反向切割。原因是 zoom、mask 或 scroll wrapper 会让 carve-out 失效，导致按钮失去点击能力。Burrow 必须只把空白叶子标为拖拽区：

- TopBar：交通灯 spacer 和中间空白 filler。
- 展开 Sidebar header：交通灯 spacer 和右侧空白 filler。
- 折叠 v2 rail：顶部 `h-10` 空白 strip。
- TabBar：tabs 右侧的空白 filler。
- 所有按钮、输入框、标签项和操作区：显式 no-drag。

依据：

- [TopBar 只在空白叶子使用 drag](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/TopBar/TopBar.tsx:52)
- [展开 Sidebar header 只在 spacer/filler 使用 drag](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/components/DashboardSidebarHeader/DashboardSidebarHeader.tsx:385)
- [TabBar 只把 tabs 右侧空白作为 drag](/Users/lisongjian/Workspace/gh/superset/packages/panes/src/react/components/Workspace/components/TabBar/TabBar.tsx:170)
- [全局 drag/no-drag 令牌](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/globals.css:271)

### 1.4 TopBar 直接控件

- SidebarToggle 和 NavigationControls 的命中框均为 `size-7` 或 `size-8`，圆角 `rounded-md`。hover 使用 `fill-hover`；禁用导航使用 `opacity-30` 且禁止指针事件。依据：[导航按钮状态](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/NavigationControls/NavigationControls.tsx:33)、[SidebarToggle](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/SidebarToggle/SidebarToggle.tsx:25)。
- 右侧 SidebarToggle 使用 `size-8`、`hover:bg-accent/50`，图标在 hover 时切换为 open/close 语义图标。依据：[RightSidebarToggle](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/TopBar/components/RightSidebarToggle/RightSidebarToggle.tsx:31)。
- 非 Mac 才显示 WindowControls；三个命中框都是 `h-8 w-8`。关闭 hover 使用 destructive。依据：[WindowControls](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/TopBar/components/WindowControls/WindowControls.tsx:21)。

## 2. Sidebar 尺寸、表面与折叠（必须一致）

### 2.1 宽度与 resize

Sidebar 状态必须保持以下数值：

| 状态 | 数值 | 证据 |
| --- | ---: | --- |
| 默认展开宽度 | `280px` | [Sidebar store](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/stores/workspace-sidebar-state.ts:4) |
| 折叠 rail 宽度 | `52px` | [Sidebar store](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/stores/workspace-sidebar-state.ts:4) |
| 展开最小宽度 | `220px` | [Sidebar store](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/stores/workspace-sidebar-state.ts:6) |
| 展开最大宽度 | `400px` | [Sidebar store](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/stores/workspace-sidebar-state.ts:7) |
| 拖拽折叠阈值 | 小于 `120px` 即吸附到 `52px` | [setWidth 吸附逻辑](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/stores/workspace-sidebar-state.ts:60) |
| 双击 resize handle | 恢复 `280px` | [DashboardLayout 双击恢复](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/layout.tsx:162) |

拖拽 handle 不是 1px 命中区。外层命中宽度是 `20px`，可见分隔线是 `4px`。hover、focus 和 dragging 都显示 border；拖拽中 body 暂时禁止选择文本并使用 `col-resize` 光标。依据：[ResizablePanel handle](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/screens/main/components/ResizablePanel/ResizablePanel.tsx:124)。

宽度拖拽每帧通过 `requestAnimationFrame` 合并，方向由 handle side 决定；不能在 SwiftUI 中用连续 view 重建模拟出抖动的拖拽反馈。依据：[ResizablePanel 鼠标拖拽与 RAF flush](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/screens/main/components/ResizablePanel/ResizablePanel.tsx:59)。

### 2.2 Sidebar 表面与内容顺序

Sidebar 是一个连续表面：`border-r border-border bg-muted/45`，dark 使用 `bg-muted/35`。内部是 Header、可滚动内容、Ports、setup card、HiringBanner 和底部组织/更新/设置区。依据：[DashboardSidebar 表面与子树](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/DashboardSidebar.tsx:222)。

可滚动内容使用 `OverflowFadeContainer`，上下边缘 fade，隐藏滚动条。fade 默认长度为 `1.5rem`；该长度来自 UI 组件，不得凭印象改为 8/12/16px。依据：[Sidebar scroll container](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/DashboardSidebar.tsx:233)、[OverflowFade 默认尺寸](/Users/lisongjian/Workspace/gh/superset/packages/ui/src/components/overflow-fade/fade-edge.css:9)。

内容顺序如下：

```text
DashboardSidebar
├── DashboardSidebarHeader
├── scroll surface
│   ├── Pinned
│   ├── Sessions
│   ├── Projects header
│   └── draggable project groups
├── Ports（展开且未启用 inline ports 时）
├── V2SetupScriptCard（存在 active project/host 时）
├── HiringBanner
└── OrganizationDropdown + UpdatesPill + Settings
```

依据：[DashboardSidebar 内容顺序与折叠条件](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/DashboardSidebar.tsx:237)。

### 2.3 Header 的展开/折叠尺寸

展开 Header 的外层是 `px-2 pt-2 pb-2`；Mac 顶部 padding 为 `8 / zoomFactor`。交通灯 spacer 为 Mac `80 / zoomFactor`、非 Mac `8px`；匹配行高为 `32 / zoomFactor`。依据：[展开 Header 尺寸](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/components/DashboardSidebarHeader/DashboardSidebarHeader.tsx:370)。

展开 Header 的导航项：

- New Workspace：`w-full`、`gap-2`、`rounded-md`、`px-1 py-1`、字号 `13px`、`font-medium`。
- Search/Workspaces/Automations/Tasks/Pull requests：`w-full`、`gap-2`、`px-2 py-1`、字号 `13px`、`font-medium`。
- 各项 hover 为 `fill-hover`；当前路由为 `fill-selected` 加 foreground。

依据：[展开导航项样式](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/components/DashboardSidebarHeader/DashboardSidebarHeader.tsx:403)。

折叠 Header 的导航容器为 `items-center gap-1 px-2 pt-3 pb-2`。每个命中框是 `size-7`，图标为 `size-3.5`；New Workspace 外层有 `size-5` 的 plus 背景。依据：[折叠 Header 导航](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/components/DashboardSidebarHeader/DashboardSidebarHeader.tsx:198)。

### 2.4 Project、Section 与 workspace rows

Project row：

- `mx-2`，`min-h-8`，`pl-2 pr-1 py-1`，字号 `13px`、`font-medium`。
- hover 显示 `fill-hover`。
- Project icon 与 hover 时的 chevron 共用 `size-4` 槽位；右侧 New workspace 按钮仅 hover/focus 显示。

依据：[Project row](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/components/DashboardSidebarProjectSection/components/DashboardSidebarProjectRow/DashboardSidebarProjectRow.tsx:65)。

Projects/Pinned 标签：`min-h-8 py-1.5 pl-4 pr-2 text-[10px] font-semibold uppercase tracking-[0.075em]`。依据：[Projects header](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/components/DashboardSidebarWorkspacesHeader/DashboardSidebarWorkspacesHeader.tsx:55)、[Pinned label](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/components/DashboardSidebarPinnedSection/DashboardSidebarPinnedSection.tsx:39)。

Section row：`mx-2 min-h-7 pl-2 pr-2 py-1 text-[13px] font-medium`；左侧是 `h-5 w-5` 的拖拽/折叠槽位。Section action 仅在 hover、focus 或菜单打开时披露。依据：[Section header](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/components/DashboardSidebarSection/components/DashboardSidebarSectionHeader/DashboardSidebarSectionHeader.tsx:59)。

展开 workspace row：

- 外层 `mx-2 rounded-md text-sm`；在 active 或 selected 时使用 `bg-fill-selected`。
- 行内容 `py-1.5 pr-2`；顶层 `pl-3`，Section 内 `pl-8`。
- 标题字号 `13px`、`leading-tight`；active/selected 为 foreground，普通态为 `foreground/80`。
- 图标槽位为 `size-5`，右侧差异统计所在行高为 `h-5`。
- 行 hover 使用 `bg-fill-hover`；active/selected hover 保持 `bg-fill-selected`。

依据：[workspace row 外层与 hover/selected](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/components/DashboardSidebarWorkspaceItem/components/DashboardSidebarExpandedWorkspaceRow/DashboardSidebarExpandedWorkspaceRow.tsx:128)、[workspace row 内边距与标题](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/components/DashboardSidebarWorkspaceItem/components/DashboardSidebarExpandedWorkspaceRow/DashboardSidebarExpandedWorkspaceRow.tsx:165)。

折叠 workspace 命中框是 `size-8`、`rounded-md`；active 使用 `bg-fill-selected`，普通态 hover 使用 `bg-fill-hover`。依据：[折叠 workspace button](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/components/DashboardSidebarWorkspaceItem/components/DashboardSidebarCollapsedWorkspaceButton/DashboardSidebarCollapsedWorkspaceButton.tsx:40)。

workspace 行下方 activity chips：`h-7`；顶层左 inset `42px`，Section 内 `50px`，右 padding `8px`。单个 agent/port chip 为 `h-[18px] px-1.5 py-0 text-[9px]`，hover 提升到 foreground。依据：[activity strip](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/components/DashboardSidebarWorkspaceItem/components/DashboardSidebarExpandedWorkspaceRow/components/DashboardSidebarWorkspaceChips/DashboardSidebarWorkspaceChips.tsx:44)、[agent chip](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/components/DashboardSidebarWorkspaceItem/components/DashboardSidebarExpandedWorkspaceRow/components/DashboardSidebarWorkspaceChips/components/DashboardSidebarAgentsChip/DashboardSidebarAgentsChip.tsx:68)。

### 2.5 Sidebar 状态与反馈

| 状态 | 视觉/行为要求 | 证据 |
| --- | --- | --- |
| hover | row/按钮显示低对比度 `fill-hover`；row 的关闭、移除、快捷键只在 `group-hover` 或 `group-focus-within` 显示 | [workspace hover action](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/components/DashboardSidebarWorkspaceItem/components/DashboardSidebarExpandedWorkspaceRow/DashboardSidebarExpandedWorkspaceRow.tsx:318) |
| focus | 键盘可激活 project/section/row；嵌套 action 使用 `focus-visible` ring；不要让父 row 吞掉子按钮事件 | [Project action focus ring](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/components/DashboardSidebarProjectSection/components/DashboardSidebarProjectRow/DashboardSidebarProjectRow.tsx:100) |
| selected | 多选 workspace 显示 check icon，row 使用 `fill-selected`，并提供屏幕阅读器 selected 文本 | [Selected row](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/components/DashboardSidebarWorkspaceItem/components/DashboardSidebarExpandedWorkspaceRow/DashboardSidebarExpandedWorkspaceRow.tsx:150) |
| dragging | sortable item opacity `0.5`；drag overlay 透明，不得铺不透明卡片；workspace 的 accent 用左边界表达 | [Sortable workspace](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/components/SortableWorkspaceItem/SortableWorkspaceItem.tsx:39)、[透明 overlay](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/components/SidebarDragOverlay/SidebarDragOverlay.tsx:20) |
| disabled/pending | 创建中显示 Ascii spinner 与 `Creating…`；行 `aria-disabled`；不可拖拽的 main workspace 不进入 sortable | [pending row](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/components/DashboardSidebarWorkspaceItem/components/DashboardSidebarExpandedWorkspaceRow/DashboardSidebarExpandedWorkspaceRow.tsx:102)、[disabled sortable](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/components/SortableWorkspaceItem/SortableWorkspaceItem.tsx:30) |
| disconnected | TopBar 显示 Offline badge；远端设备离线时主图标换为 cloud-off 且降低 opacity | [Offline badge](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/TopBar/TopBar.tsx:82)、[远端离线图标](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/components/DashboardSidebarWorkspaceItem/components/DashboardSidebarWorkspaceIcon/DashboardSidebarWorkspaceIcon.tsx:68) |
| hover card | row hover 延迟 `400ms` 打开、`100ms` 关闭；卡片宽度 `w-72`；鼠标沿安全三角移动到卡片时不闪退 | [hover timing](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/providers/DashboardSidebarHoverProvider/DashboardSidebarHoverProvider.tsx:12)、[hover card width](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/components/DashboardSidebarHoverCardOverlay/DashboardSidebarHoverCardOverlay.tsx:79) |

Sidebar DnD 必须支持鼠标、触摸和键盘：鼠标 activation distance `8px`；触摸 delay `200ms`、tolerance `5px`；键盘使用 sortable coordinates。依据：[Sidebar sensors](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/DashboardSidebar.tsx:130)。

状态指示器必须保留语义：permission 为黄色脉冲、failed 为红色脉冲、working 为琥珀色脉冲、review 为绿色静态点；点大小为 `size-2`。依据：[StatusIndicator 语义配置](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/screens/main/components/StatusIndicator/StatusIndicator.tsx:7)。

## 3. Pane 数据模型与组件层级（必须一致）

### 3.1 数据模型

Pane 系统的层级是 `WorkspaceState → Tab[] → LayoutNode → Pane`。

- `LayoutNode` 只有 `pane` 和 `split` 两种节点。
- `split` 有 `horizontal/vertical` direction、first/second 子树和可选 `splitPercentage`。
- Pane 有 `id`、`kind`、可选 `titleOverride`/`pinned` 和业务 `data`。
- Tab 有 `activePaneId`、layout 和 flat `panes` map。
- WorkspaceState 只有 `tabs` 和 `activeTabId`，版本为 `1`。

依据：[Pane/Tab/LayoutNode 类型](/Users/lisongjian/Workspace/gh/superset/packages/panes/src/types.ts:1)。

Burrow 的领域模型可以不同，但 Desktop UI 的可见关系必须等价：Tab 是一级导航；Split 只负责几何；Pane 是内容叶子。不要把 tmux window/pane 直接暴露为跨端 UI 模型。

### 3.2 Workspace 与空状态

Workspace 组件的层级是：

```text
Workspace
├── TabBar
├── renderBelowTabBar（可选 Presets bar）
└── active Tab
    └── recursive LayoutNodeView
        ├── SplitView → ResizablePanelGroup → Panel / Handle / Panel
        └── Pane → PaneHeader + PaneContent + DropZoneOverlay
```

Workspace 全面使用 `bg-background text-foreground`，没有 active tab 时显示 `No tabs open`，字号 `text-sm text-muted-foreground`。有 Tab 但 layout 为空时显示 `No panes open`，同样是 `text-sm`。依据：[Workspace 组装与空状态](/Users/lisongjian/Workspace/gh/superset/packages/panes/src/react/components/Workspace/Workspace.tsx:91)、[Tab 无 pane 空状态](/Users/lisongjian/Workspace/gh/superset/packages/panes/src/react/components/Workspace/components/Tab/Tab.tsx:194)。

工作区自定义空状态使用居中内容：外层 `px-6 py-10`，最大宽度 `max-w-xl`；wordmark 高度 `h-8`；操作列表 `max-w-md`，每项 `h-9`、`rounded-[6px]`、`text-sm`，hover 为 tertiary wash。依据：[WorkspaceEmptyState 布局](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/v2-workspace/$workspaceId/components/WorkspaceEmptyState/WorkspaceEmptyState.tsx:95)、[空状态 action button](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/screens/main/components/WorkspaceView/ContentView/TabsContent/components/EmptyTabActionButton/EmptyTabActionButton.tsx:19)。

### 3.3 TabBar 尺寸、overflow 与拖放

TabBar 的事实尺寸：

- 整行 `h-10`，背景 `bg-muted/45`，dark `bg-muted/35`。
- 每个 tab 固定 `160px` 宽；`TAB_WIDTH` 是源码常量。
- tabs 容器横向滚动、隐藏滚动条，并观察 children 尺寸变化。
- 没有横向溢出时，AddTab 按钮在 tabs 后方；发生溢出时，AddTab 移到滚动容器外的固定 `w-10` 区域。
- tabs 右侧有 `flex-1` 空白 drag filler；leading/trailing 均是 no-drag。

依据：[TabBar 高度、overflow、AddTab 与 drag filler](/Users/lisongjian/Workspace/gh/superset/packages/panes/src/react/components/Workspace/components/TabBar/TabBar.tsx:170)、[固定 tab 宽度](/Users/lisongjian/Workspace/gh/superset/packages/panes/src/react/components/Workspace/components/TabBar/utils/utils.ts:1)。

Tab 插入线是 `w-0.5`、`bg-primary`、opacity `0.85`，左坐标按 `index * 160px` 计算。插入点在 tab 中线左侧/右侧切换；拖到所有 tabs 后插入末尾。依据：[TabBar 插入线与 drop](/Users/lisongjian/Workspace/gh/superset/packages/panes/src/react/components/Workspace/components/TabBar/TabBar.tsx:97)。

Tab 可以拖拽排序；Pane 拖到 TabBar 会生成新 Tab；Pane 拖到其他 Tab 时，hover 先选中目标 Tab。拖拽自身 Tab 不应中途切换 active，click 而非 mousedown 才选中。依据：[TabItem 的 drag/drop 与 click 规则](/Users/lisongjian/Workspace/gh/superset/packages/panes/src/react/components/Workspace/components/TabBar/components/TabItem/TabItem.tsx:75)。

TabItem 的可执行样式：

- active：四周 `border`，底边透明，`bg-background text-foreground`，从 TabBar 无缝接入 Pane 内容。
- inactive：透明边界但保留底线，`text-muted-foreground/70`；hover 为 `bg-border/20`。
- drag：opacity `0.3`。
- 标题区 `text-xs`，左 padding `pl-3`，右 padding `pr-1`，图标与标题 gap `1.5`。
- 关闭按钮命中框 `size-5`，默认不可见；只在 hover/focus-within 出现。accessory 在 hover 时隐藏。
- 双击标题进入重命名；输入最大长度 `64`，focus ring 为 `ring-1`。

依据：[TabItem active/inactive 样式](/Users/lisongjian/Workspace/gh/superset/packages/panes/src/react/components/Workspace/components/TabBar/components/TabItem/TabItem.tsx:116)、[TabItem 标题与关闭按钮](/Users/lisongjian/Workspace/gh/superset/packages/panes/src/react/components/Workspace/components/TabBar/components/TabItem/TabItem.tsx:150)。

### 3.4 Split、resize 与最小尺寸

SplitView 递归渲染 `ResizablePanelGroup`。初始第一子树大小是 `splitPercentage`，缺省 `50`；第二子树为 `100 - first`。每个 Pane 最小尺寸类为 `min-h-[160px] min-w-[260px]`。依据：[SplitView 默认权重与最小尺寸](/Users/lisongjian/Workspace/gh/superset/packages/panes/src/react/components/Workspace/components/Tab/Tab.tsx:36)、[Pane 最小尺寸常量](/Users/lisongjian/Workspace/gh/superset/packages/panes/src/react/components/Workspace/components/Tab/constants.ts:1)。

Split handle：

- 默认可见线 `1px`，命中扩展为 `4px`。
- horizontal split 用 vertical handle；vertical split 用 horizontal handle。
- keyboard focus 显示 `ring-1`；handle hover/drag 使用 border 色。
- 双击 handle 将本组布局重置为 `50/50`。
- resize 过程中必须向上报告 `resizeActive`；window blur 或卸载必须清理 active，避免卡在 dragging 状态。

依据：[ResizableHandle 样式与 focus](/Users/lisongjian/Workspace/gh/superset/packages/ui/src/components/ui/resizable.tsx:31)、[Split handle 双击与 resize callback](/Users/lisongjian/Workspace/gh/superset/packages/panes/src/react/components/Workspace/components/Tab/Tab.tsx:97)、[resizeActive 清理](/Users/lisongjian/Workspace/gh/superset/packages/panes/src/react/components/Workspace/hooks/useWorkspaceInteractionState/useWorkspaceInteractionState.ts:16)。

### 3.5 Pane、PaneHeader 与命中区

Pane 外层是 `flex h-full w-full flex-col overflow-hidden border-2 transition-colors duration-150`。单 Pane 根节点不画 focus outline；split 中 active Pane 用 `border-primary/15`，其他状态透明。依据：[Pane 外层与 active border](/Users/lisongjian/Workspace/gh/superset/packages/panes/src/react/components/Workspace/components/Tab/components/Pane/Pane.tsx:243)。

PaneHeader：

- 固定高度 `h-7`，不 shrink。
- 默认 `cursor-grab`；非 active opacity `0.6`；拖拽中 opacity `0.3`。
- 标题内容 `h-full w-full gap-2 px-3`；active 标题 wrapper `font-semibold`。
- 默认标题 `text-xs`；active foreground，inactive muted-foreground。
- 右侧 header extras/actions gap `0.5`；mousedown 不冒泡，避免按钮触发 pane drag。
- 点击 header 默认 pin；middle-click close；Pane drag 由 header 承担。

依据：[PaneHeader 高度、active/dragging opacity](/Users/lisongjian/Workspace/gh/superset/packages/panes/src/react/components/Workspace/components/Tab/components/Pane/components/PaneHeader/PaneHeader.tsx:54)、[默认标题布局与字号](/Users/lisongjian/Workspace/gh/superset/packages/panes/src/react/components/Workspace/components/Tab/components/Pane/components/PaneHeader/components/DefaultHeaderContent/DefaultHeaderContent.tsx:21)。

Pane drop 命中按目标 Pane 的中心点分为四个 50% 区域：top、bottom、left、right。drop overlay 为 `border-2 border-primary/70 bg-primary/10 rounded-sm`，150ms ease 过渡；自身 Pane 或所属 Tab 不可 drop。依据：[Pane drop position 与 canDrop](/Users/lisongjian/Workspace/gh/superset/packages/panes/src/react/components/Workspace/components/Tab/components/Pane/Pane.tsx:54)、[DropZoneOverlay 视觉](/Users/lisongjian/Workspace/gh/superset/packages/panes/src/react/components/Workspace/components/Tab/components/Pane/components/DropZoneOverlay/DropZoneOverlay.tsx:7)。

## 4. 颜色、透明度、字号与全局基础（必须一致）

### 4.1 语义令牌

下表是 globals.css 的 fallback。主题 store hydration 后可以覆盖变量；Burrow 应保留同名语义层，而不是把 fallback 固定成唯一主题。

| 令牌 | Dark fallback | Light fallback | 用途 |
| --- | --- | --- | --- |
| background | `#151110` | `oklch(1 0 0)` | 主内容背景 |
| foreground | `#eae8e6` | `oklch(0.145 0 0)` | 主文字 |
| muted | `#2a2827` | `oklch(0.97 0 0)` | chrome/sidebar wash、次级表面 |
| muted-foreground | `#a8a5a3` | `oklch(0.556 0 0)` | 次级文字、图标 |
| border | `#2a2827` | `oklch(0.922 0 0)` | 分隔线、边界 |
| ring | `#3a3837` | `oklch(0.708 0 0)` | focus ring |
| primary | `#eae8e6` | `oklch(0.205 0 0)` | 主操作、drop/insert cue |
| destructive | `#cc4444` | `oklch(0.577 0.245 27.325)` | 关闭/失败/破坏性操作 |
| radius | `0.625rem` | 同令牌 | 基础圆角；sm/md/lg/xl 由此派生 |

依据：[Dark fallback 令牌](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/globals.css:17)、[Light fallback 令牌](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/globals.css:63)。

Sidebar row 的 hover/selected 不是固定灰色：

- Dark：`fill-hover = foreground 7%`，`fill-selected = foreground 10%`。
- Light：`fill-hover = foreground 4%`，`fill-selected = foreground 6%`。
- 实现使用 `color-mix(in oklab, var(--foreground) N%, transparent)`。

依据：[fill-hover/fill-selected 语义定义](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/globals.css:58)。

TabBar、TopBar、Sidebar 表面使用 muted 的低对比度混合，而不是新增卡片层：TopBar/TabBar 为 dark `muted/35`、其余 `muted/45`。依据：[TopBar 表面](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/TopBar/TopBar.tsx:58)、[TabBar 表面](/Users/lisongjian/Workspace/gh/superset/packages/panes/src/react/components/Workspace/components/TabBar/TabBar.tsx:178)、[Sidebar 表面](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/DashboardSidebar.tsx:230)。

### 4.2 文字与图标密度

已由源码确认的字号只能按用途复刻：

- 主 Sidebar nav、Project、Workspace row：`13px`。
- Pane/Tab 标题：`text-xs`；具体 CSS pixel 值由 Tailwind 配置/浏览器计算，当前源码未在组件中展开，标为待测量。
- Section/Pinned/Projects 标签：`10px`、semibold、uppercase、tracking `0.075em`。
- workspace diff/shortcut：`10px`；创建中：`11px`。
- activity chip：`9px`；状态 badge：`10px`。

依据：[Sidebar nav 13px](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/components/DashboardSidebarHeader/DashboardSidebarHeader.tsx:405)、[workspace title 13px](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/components/DashboardSidebarWorkspaceItem/components/DashboardSidebarExpandedWorkspaceRow/DashboardSidebarExpandedWorkspaceRow.tsx:289)、[section label 10px](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/routes/_authenticated/_dashboard/components/DashboardSidebar/components/DashboardSidebarWorkspacesHeader/DashboardSidebarWorkspacesHeader.tsx:67)。

图标默认 stroke width 为 `1.5`；强调 plus 使用 `2`；极细图标使用 `1`。依据：[Sidebar 图标 stroke 常量](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/screens/main/components/WorkspaceSidebar/constants.ts:1)。

### 4.3 全局基础

- `html/body` 固定 `100vw/100vh`，`overflow:hidden`，避免滚动锁导致布局塌缩。
- `body` 默认 `user-select:none`；可复制错误文本必须在局部显式恢复 selection。
- `app` 根节点占满 viewport。
- 所有元素默认 antialiased；body 使用 `-webkit-font-smoothing: antialiased`。
- 默认滚动条宽高 `12px`，thumb `rgb(63 63 70 / 0.5)`；thumb hover `0.7`，active `0.8`。compact 区域可使用 `8px` scrollbar。
- tabs/carousel 使用 `hide-scrollbar`：Firefox scrollbar-width none，WebKit display none。

依据：[全局 viewport、selection、overflow](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/globals.css:153)、[滚动条与 hide-scrollbar](/Users/lisongjian/Workspace/gh/superset/apps/desktop/src/renderer/globals.css:216)。

## 5. 验收状态清单

固定一个 macOS Desktop 窗口尺寸，至少验收以下状态。窗口尺寸、字体渲染和主题实际 hydration 后的截图差异必须记录，不能用肉眼猜成通过。

| 场景 | 必须验证 |
| --- | --- |
| 初始 Dashboard | Sidebar 280px、TopBar 48px、右侧空 slot 不挤压主内容；根节点无滚动。 |
| Sidebar resize | 220–400px 可拖；低于 120px 吸附 52px；双击恢复 280px；handle 20px 命中区；拖拽中显示 col-resize。 |
| Sidebar collapsed | 52px rail；导航命中框 28px；workspace 命中框 32px；v2 Workspace 顶部 h-10 strip 与 TabBar 连续。 |
| Row hover/focus | hover wash；关闭/移除/shortcut 只在 hover/focus-within 显示；键盘 Enter/Space 可激活；嵌套按钮可独立点击。 |
| Row selected/active | selected check；active/selected wash 不被普通 hover 覆盖；active diff stats 可见。 |
| Row dragging | 8px 鼠标 activation；opacity 0.5；透明 overlay；accent left border 保留。 |
| Pending/disabled | spinner、Creating…、aria-disabled；不可排序的 main workspace 不被拖起；disabled button 的 opacity 与 pointer 行为明确。 |
| Offline/disconnected | TopBar Offline；remote workspace cloud-off；status tooltip 与颜色正确。 |
| Tab overflow | 单 tab 160px；溢出后 horizontal fade；AddTab 从滚动区内移到右侧固定 w-10；插入线位置正确。 |
| Tab drag | tabs 可排序；Pane 拖到 TabBar 新建 tab；拖过其他 tab 切换预览；自身 tab 不被误选中。 |
| Pane split/resize | Pane 最小 260×160；split 默认 50/50；双击 handle 复位；四象限 drop overlay；resizeActive 在 blur 后清理。 |
| Empty | 无 tabs 显示 No tabs open；空 layout 显示 No panes open；工作区空状态 wordmark + 4 个基础 action（Chat v3 feature flag 打开时第 5 个）的间距和 hover 正确。 |

## 6. Burrow 实现分级

### 必须一致

1. Dashboard 根层级、Sidebar 280/52/220–400、TabBar 40、Tab 160、Pane header 28、Pane 最小 260×160。
2. `background/foreground/muted/border/ring/destructive` 与 `fill-hover/fill-selected` 语义。
3. TopBar/TabBar/Sidebar 的连续低对比度表面。
4. hover、focus、active、selected、dragging、disabled、pending、offline、empty 的视觉和操作结果。
5. 只在空白叶子提供窗口拖拽区；所有交互控件可点击。
6. Tab → Split → Pane 数据和视觉层级，以及 Tab overflow/drag、Pane split/resize/drop。

### 平台原生适配

1. macOS traffic lights、窗口拖拽、窗口关闭/最小化/最大化使用 AppKit/SwiftUI 原生机制；保留 Superset 的空白 hit area、物理 inset 和控件密度。
2. SwiftUI 使用系统 Button、稳定 identity、Accessibility label/focus；不得因为系统控件而丢失源码要求的 hover/selected wash。
3. iOS 不复制 Desktop 的 Sidebar/TopBar/多 Pane 几何。iOS 只继承令牌、层级、状态语言和信息密度；这是 Burrow GOAL 已明确的平台边界。
4. 终端内容、PTY、窗口尺寸控制属于 BurrowTerminalRenderer/Host 协议。Pane UI 只消费投影，不把 tmux 结构变成 UI API。

### 暂缓

1. 未从源码确认的 Tailwind `text-xs/text-sm` 实际像素、字体家族、line-height、系统字体 fallback：待浏览器 computed style 与截图测量。
2. 实际主题 store hydration 后的最终颜色：globals.css 只提供 fallback；待在 dark/light 主题下取样并建立 BurrowDesignSystem 对照表。
3. 固定验收窗口的具体宽高、截图像素阈值和 macOS titlebar 的真实物理坐标：待 Burrow Desktop 原型可运行后测量。
4. Superset 具体 Pane 内容（terminal、chat、browser、file viewer）的业务空态和运行态：本规范只锁定通用 Pane chrome；按 Burrow 第一阶段范围暂不复制完整终端仿真。
5. 右侧 WorkspaceSidebar 的全部文件树、Changes、Review 内容：本轮只锁定其 slot、resize 约束和与 Pane 的边界。

以上“暂缓”不是允许自由设计。完成测量前，Burrow 应保留令牌和可配置尺寸，避免把未经证实的数字写死。
