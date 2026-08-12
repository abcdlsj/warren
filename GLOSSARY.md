# Burrow 终端工作空间领域

本领域描述由 Host 持有、由多个 Client 观察或控制的跨端终端工作空间，以及连接和恢复这些工作空间所需的关系。

## 资源与归属

**Host**：
持有 Project、Workspace 和 Terminal Session 真实状态的设备；它是这些资源的唯一权威。
_Avoid_: Server、Client、Relay

**Project**：
Host 管理的一个代码仓库身份，包含一个或多个 Workspace。Project 本身不是可运行终端的目录。
_Avoid_: Repository、App、Workspace

**Workspace**：
Project 下一个具体的本地工作目录及其分支上下文，是 Terminal Session 的唯一工作归属。主检出目录和 worktree 都是 Workspace；分支名是上下文属性，不是稳定身份。
_Avoid_: Worktree、Window、Pane

**Terminal Session**：
Host 上持续存在的交互式终端运行上下文；它的生命周期独立于任何 Client 或 Terminal Attachment。
_Avoid_: Terminal、Tab、tmux Session

## 连接与设备

**Terminal Attachment**：
Client 与一个 Terminal Session 之间的临时连接关系，记录观察或控制该 Session 的参与者。
_Avoid_: Session、Client、Socket

**Client**：
访问 Host 资源的设备端参与者，可以观察或在获得 Control Lease 后控制 Terminal Session。
_Avoid_: Host、User、Peer

**Client Layout**：
单个 Client 保存的 Sidebar、Workspace View、窗口和导航状态集合，不属于 Host，也不在 Client 之间共享。
_Avoid_: Session Layout、Shared Layout、Workspace Layout

**Workspace View**：
Client 为一个 Workspace 保存的展示状态，包含有序 Tab 集合和当前 Active Tab。一个 Client 可以同时保存多个 Workspace View，但一个窗口同时只展示其中一个。
_Avoid_: Workspace、Project View、Global Tabs

**Tab**：
Workspace View 中对一个 Terminal Session 的本地入口。Tab 只属于一个 Workspace View；关闭 Tab 不会结束 Terminal Session。
_Avoid_: Terminal Session、Pane、Global Tab

**Active Workspace**：
一个 Client 窗口当前展示的 Workspace。切换 Active Workspace 会整体切换 Tab 条、Active Tab 和 Renderer Set。
_Avoid_: Selected Project、Current Session

**Active Tab**：
Workspace View 当前展示的 Tab。同一 Workspace View 同时最多有一个 Active Tab。
_Avoid_: Focused Session、Selected Project

**Renderer Set**：
Client 为 Active Workspace 挂载的终端渲染表面集合。Renderer Set 不拥有 Terminal Session；只有 Active Tab 的表面拥有键盘焦点和终端尺寸控制权。
_Avoid_: Session Set、Runtime、Workspace

**Control Lease**：
授予一个 Terminal Attachment 在限定时间内输入和调整终端尺寸的排他性权利；同一 Session 同时最多存在一个有效租约持有者。
_Avoid_: Lock、Ownership、Attachment

## 终端恢复

**Recovery Anchor**：
标识 Client 已经接收的 Terminal Session 输出位置，由该 Session 的 epoch 与输出 sequence 组成。
_Avoid_: Cursor、Offset、Checkpoint
