# Workspace 是 Client Tab 与 Renderer 的作用域

Burrow 的 Host 事实按 `Project → Workspace → Terminal Session` 组织，Client 展示按 `Workspace → Tab → Active Tab` 组织。我们选择让每个 Workspace 独立保存 Tab 顺序和 Active Tab，并让窗口只挂载 Active Workspace 的 Renderer Set；不采用全局 Tab 条，也不让 Host Session 记录承担 Tab 可见性。这样切换 Project 或 Workspace 不会混入其他分支的 Tab、焦点或终端尺寸事件，同时关闭 Tab 仍不影响长生命周期 Terminal Session。

## Consequences

- Project 只分组 Workspace。Project 行的新增动作表示新建 Workspace，不表示新建 Session。
- Workspace 行、顶部 Tab 条和 Preset 才能新建 Session，并且命令必须携带明确的 Workspace ID。
- Client Layout 与 Host State 分开持久化。旧 Host State 中的 Tab 可见性只用于一次迁移。
- UI 不接收全局 Tab 数组。Application 只向窗口提供 Active Workspace 的屏幕投影。
- Ghostty Surface 只在 Active Workspace 内挂载；后台 Session 继续由 Host 和 Runtime 持有。
