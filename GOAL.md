# Burrow 第一期交付目标

状态：执行中  
设计依据：`DESIGN.md`  
完成定义：本文件所有 P0 条目通过自动验收，且无未解释的已知阻断问题

## 1. 交付结果

第一期交付一个可日常使用的 macOS 本地应用：

- 用户可一次性从 Superset 导入现有 Project 和 Workspace，或手动添加本地 Git Project。
- 用户可按 Project 和 Workspace 导航。
- 每个 Workspace 拥有独立 Tabs 和 Terminal Sessions。
- shell、Codex 和 Claude 在 Ghostty 中可以可靠输入、显示颜色、调整尺寸、切换和恢复。
- App 关闭或崩溃后 tmux Session 继续存在；重新打开后恢复。
- App 不会在初始化、切换或重试时生成重复 shell。
- 自动测试可在不截图、不移动鼠标、不抢焦点的条件下验收以上能力。

## 2. 发布门槛

以下条件全部满足才可标记第一期完成：

1. 所有 P0 功能用例通过。
2. 所有架构不变量有自动测试。
3. 全量 Swift 测试、集成测试和无干扰 UI 验收连续通过三次。
4. 测试前后前台应用 PID 和鼠标位置一致。
5. 测试不读取或修改用户 Burrow、Superset、Git 和 tmux 状态。
6. 冷启动、恢复、切换和退出没有遗留未受管 Task 或重复前台进程。
7. `git diff --check` 通过，工作树只包含本目标相关变更。

## 3. 工作分解

### G1：清除双重状态所有权（P0）

交付：

- 使用 workspace-scoped、window-scoped Client Layout。
- 从 Host Session 删除 Tab 可见性、Tab 顺序和选中状态。
- Application 为每个 Window 生成 `WorkspaceScreenProjection`。
- Desktop 不消费全局 Tab 数组。
- Project、Workspace、Tab 选择全部使用稳定 ID。

验收：

- 两个 Project、三个 Workspace 各自拥有独立 Tabs。
- 连续切换 100 次后，Tab、Active Session 和 Renderer 始终属于 Active Workspace。
- 创建 Session 期间切换 Workspace，新 Session 仍落入原目标 Workspace。
- Close Other Tabs 和 Close All Tabs 只影响当前 Workspace View。
- 新窗口不复用其他窗口的 Active Workspace 或 Active Tab。

### G2：Renderer Coordinator（P0）

交付：

- 从 Composition Root/Application Model 提取独立 Renderer Coordinator。
- Surface Key 使用 `(windowID, workspaceID, sessionID)`。
- 只挂载 Active Workspace 的可见 Surface。
- 只有 Active Tab Surface 可输入、聚焦和 resize。
- Resize 每 Session 串行、去重、latest wins。
- Workspace/Tab 切换后进行一次实际 viewport 校准。

验收：

- 后台 Workspace 的布局变化不会触发 tmux resize。
- 隐藏 Tab 不会收到输入。
- 快速 resize 100 次后 tmux 最终尺寸等于最后一次可见尺寸。
- 删除 Tab 后新增按钮位置立即回流。
- Surface 重建后可以从 Recovery Anchor 恢复，且无重复字节。

### G3：Session 和 tmux 生命周期（P0）

交付：

- 一个 Burrow Session 严格映射一个独立 tmux session。
- 创建、adopt、attach、detach、input、special key、resize、terminate、inspect 全部是 typed operation。
- 普通输入使用唯一 buffer 的 load/paste，每 Session 保序。
- 输出保留原始 ANSI/OSC/Unicode 字节，并同时进入内存恢复环和持久日志。
- Runtime 退出产生明确事件和生命周期状态。
- App 退出只关闭观察与连接，不 kill tmux。
- 恢复时 adopt 存活 tmux；缺失 tmux 标记 ended。

验收：

- shell 可输入 ASCII、中文、多行文本、控制键和粘贴内容。
- Codex/Claude 的 ANSI 颜色在终端 cell attributes 中存在。
- 交错并发输入保持调用顺序，不丢字节。
- App 退出后 tmux 存活；重启后输出和交互继续。
- 显式 terminate 后 tmux 消失，Session 保留可检查的 ended 记录。
- 手动 kill tmux 后重启 App 不停留在 connecting。
- 一个 Runtime 故障不会冻结其他 Session。

### G4：启动、退出和单实例（P0）

交付：

- 冷启动只恢复资源，不自动创建 Session。
- 同时只运行一个前台 Client Instance。
- 二次启动向首实例发送 activate/open intent，随后退出。
- Quit 完整结束 App 进程和客户端 Task。
- 测试数据目录、tmux socket、观察 socket 均可显式覆盖。

验收：

- 空数据首次启动的 Session 数为 0。
- 连续启动五次只有一个前台实例。
- Quit 后在限定时间内无 Burrow App 进程。
- Quit 后已有 tmux Session 仍存在。
- 连续冷启动和退出 20 次无僵尸进程、重复监听器和额外 shell。

### G5：Burrow 本地数据存储（P0）

交付：

- 建立版本化 SQLite Host Store、Client Layout Store 和 Import Receipt Store。
- 开启 WAL、foreign keys 和 busy timeout。
- 数据目录符合 `DESIGN.md`。
- 写操作具备事务边界和错误回滚。
- 现有开发期 JSON 状态只做一次内部迁移或明确丢弃；发布后不得形成双写。

验收：

- 外键和唯一约束可以阻止跨 Workspace Tab、重复路径和孤立 Session。
- 写入中断后数据库仍可打开，不出现半条资源链。
- 两个 Window 的布局独立恢复。
- Host 资源和 Client Layout 可分别清理，互不破坏。
- schema migration 从每个已发布版本可重复执行且结果一致。

### G6：Superset 单次导入（P0）

交付：

- Onboarding 提供 `Import from Superset`。
- 默认定位 `~/.superset/local.db`，允许用户选择替代文件。
- Source Adapter 只读并探测 Superset schema。
- 导入 Project、主检出 Workspace 和有效 worktree Workspace。
- 使用 realpath、Git common-dir 和路径做归属与去重。
- 使用 Burrow 新 ID，写入来源摘要和 Import Receipt。
- 不导入任何 tmux、Terminal Session、Tab 或云端数据。
- 成功后不再自动提示、扫描或同步 Superset。

验收：

- 使用包含主检出、两个 worktree、重复 Workspace 和失效路径的 fixture。
- 预览准确区分新增、重复、缺失、无效四类结果。
- 导入成功后 Project/Workspace 关系、名称、branch 和路径正确。
- Superset 数据库文件 hash、mtime 和内容不变。
- Git worktree 列表和 tmux session 列表不变。
- 任一步失败时 Burrow 数据和 Import Receipt 均不变化。
- 再次启动不执行扫描；显式重复导入不产生重复资源。

### G7：macOS 基础界面与交互（P0）

交付：

- 保持 Superset 风格的信息密度、字体层级、Sidebar、Top Bar、Preset Bar 和 Tab Bar。
- Project 展开 Workspace；Project 新增创建 Workspace。
- Workspace、Preset 和 Tab 新增创建 Session。
- 删除无动作、含义重复或无法解释的图标。
- 所有控件拥有稳定 Accessibility 语义。
- 空态、loading、失败、离线和 ended 状态有明确反馈。
- Terminal 填满内容区域，不出现半宽、错误 padding 或透明遮挡点击。

验收：

- 每个可交互元素可通过 Accessibility Identifier 唯一定位。
- 控件 frame 无重叠，hit target 与可见区域一致。
- Project、Workspace、Tab、Preset 连续快速点击不会冻结 UI。
- Tab 删除后新增按钮 frame 紧随最后 Tab。
- Terminal Surface frame 与内容容器一致，允许的误差不超过 1 point。
- 字体 token、字号、行高、颜色和间距符合设计 token 合约。

### G8：无干扰观测与测试套件（P0）

交付：

- 结构化 Domain/Application/Runtime event trace。
- 只读语义 UI Snapshot。
- Renderer、tmux、Recovery Anchor 和 terminal cell/style Snapshot。
- 仅测试模式启用的随机 Unix Observation Socket。
- offscreen、never-key 的真实 SwiftUI/AppKit Harness。
- 独立临时数据目录和独立 tmux socket。
- JSON artifact 和失败诊断器。
- 前台 App 与鼠标位置守卫。

验收：

- 测试全程不调用全局鼠标事件和 App activation API。
- 测试开始和结束的鼠标坐标完全一致。
- 测试开始和结束的 frontmostApplication PID 完全一致。
- 不截图即可断言布局 frame、selected/focused/enabled、终端文字和 ANSI 样式。
- 任意失败均输出首个违规不变量和完整 trace ID。
- Probe 与生产 UI 使用同一 typed intent，不直接修改内部 Store。

### G9：协议与未来扩展口（P1，不阻断本地 UI，阻断架构验收）

交付：

- Host Protocol 分离 command、resource event、terminal stream 和 presence/control event。
- 所有写命令携带 Request ID；有冲突风险的操作携带 revision。
- Endpoint Resolver 与 Host Transport 独立。
- Attachment 模型可绑定 Principal 和 Capability，但第一期只使用 local owner。
- Input Lease 与 Canonical Viewport Owner 在协议中是独立概念。

验收：

- 同一 CreateSession Request 重试只创建一个 tmux。
- In-process Transport 可由 scripted Transport 替换且 Application 行为一致。
- 两个模拟 Client Attachment 可同时观察；只有控制者可输入和 resize。
- 控制权转移后旧 Attachment 的输入和 resize 被拒绝。

## 4. 测试矩阵

| 层级 | 目的 | 必测内容 |
| --- | --- | --- |
| Domain | 保护不变量 | 归属、状态机、ID、Lease、Request 幂等 |
| Store | 保护事实 | schema、事务、迁移、约束、并发 |
| Runtime Contract | 替换 tmux 实现 | create/adopt/input/resize/terminate/events |
| Real tmux Integration | 验证真实 TTY | ANSI、Unicode、控制键、尺寸、退出、恢复 |
| Application | 验证命令流 | Projection、Workspace 隔离、失败回滚 |
| Renderer | 验证终端状态 | 输出序列、颜色 cell、focus、latest resize |
| Offscreen UI | 验证可操作效果 | AX tree、frame、hit target、动作、无焦点抢占 |
| Process E2E | 验证产品生命周期 | 单实例、启动、退出、恢复、隔离目录 |
| Import Contract | 防 Superset schema 漂移 | fixture versions、read-only、去重、回滚 |

## 5. 必须自动化的用户旅程

### J1：首次使用

1. 使用空数据启动。
2. 断言没有 Session 和 tmux。
3. 选择 Superset 导入。
4. 查看摘要并确认。
5. 断言 Project/Workspace 正确出现。
6. 断言没有导入或自动创建 Session。

### J2：本地终端日常使用

1. 选择 Workspace A。
2. 创建 Shell 并输入彩色 Unicode fixture。
3. 创建 Codex Tab。
4. 在 Tabs 间快速切换。
5. 切到 Workspace B 创建 Claude Tab。
6. 返回 Workspace A，断言其 Tabs、输出和尺寸保持。
7. 关闭 Tab，断言 tmux 仍存活。
8. 从 Session 列表重新打开，断言可继续输入。

### J3：退出和恢复

1. 在两个 Workspace 创建多个 Session。
2. 记录输出 Anchor 和 tmux ID。
3. Quit App。
4. 断言 App 进程退出、tmux 存活。
5. 重新启动。
6. 断言布局、Session 和输出恢复。
7. 输入新文本，断言没有重复旧输出。

### J4：竞态压力

1. 并发执行 Workspace 切换、Session 创建、Tab 关闭和 resize。
2. 重复 100 轮。
3. 断言 Request ID 唯一生效。
4. 断言没有跨 Workspace Tab/Surface。
5. 断言 UI event loop 始终可响应探针请求。

### J5：无干扰验收

1. 记录用户 frontmostApplication PID 和 mouseLocation。
2. 在 offscreen Window 执行 J1 至 J4 的 UI 子集。
3. 读取 Accessibility、Runtime 和 terminal cell snapshots。
4. 禁止生成图片文件。
5. 断言前台 PID 和鼠标坐标未变化。

## 6. 实施顺序

每一阶段必须先补失败测试，再修改生产代码，并在完成后提交独立 commit。

1. 建立 Observation Core、隔离测试运行环境和不变量测试。
2. 建立 SQLite Store 和迁移，移除 JSON 双写。
3. 完成 Superset Import Adapter、预览、事务提交和 onboarding。
4. 完成 workspace/window-scoped Client Layout 与 Screen Projection。
5. 提取 Renderer Coordinator，完成 Surface、focus 和 resize 生命周期。
6. 完善 tmux Runtime typed operations、持久输出、terminate 和恢复。
7. 收敛 macOS UI、Accessibility 语义和 Superset 视觉基准。
8. 完成单实例、退出、恢复和进程级压力测试。
9. 连续执行三轮全量验收，修复所有不稳定项。

## 7. 完成记录

每个 Goal 完成后在此追加：

```text
Goal:
Commit:
Tests:
Artifacts:
Known limitations:
```

不得用“测试大体通过”“肉眼正常”或“以后再看”作为完成证据。

Goal: tmux Runtime、Session lifecycle 与 Renderer Coordinator 基线
Commit: `5760922`, `d71d490`
Tests: Host 7；TmuxRuntime 12；Application 23；Renderer Coordinator 3；真实 tmux 恢复 1
Artifacts: `/tmp/burrow-observation/ui-probe/result.json`
Known limitations: Ghostty 上游尚未公开最终 cell attribute dump；当前颜色验收使用同一输出边界的 ANSI 状态。

Goal: Project 下创建 Git worktree Workspace
Commit: `49b9857`
Tests: Request Receipt 幂等、Git adapter contract、真实临时 Git worktree 创建与删除、Desktop typed action、UI semantic action
Artifacts: `/tmp/burrow-observation/ui-probe/semantic-ui.json`
Known limitations: 第一期只创建新 branch worktree；不接管或删除用户已有 worktree。

Goal: 无截图、无焦点终端颜色与单实例验收
Commit: 待本次提交
Tests: GhosttyAdapter ANSI/Unicode semantic test；TerminalProbe；单实例锁连续 5 次竞争；全量 `scripts/verify.sh`
Artifacts: `/tmp/burrow-observation/terminal-probe/terminal-semantics.json`, `/tmp/burrow-observation/ui-probe/result.json`
Known limitations: Process contract 覆盖锁与 tmux 保活；尚未用真实前台 App 自动发 Quit，因为该操作会违反不抢用户焦点约束。
