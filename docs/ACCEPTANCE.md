# Burrow 验收清单

## 0. 自动化预检

```bash
mise run accept
```

应输出 `Acceptance smoke passed.`。该命令覆盖：

- 所有 package 单元测试
- 真实 tmux 重启持久化集成测试
- App 构建与 web.html bundle
- 真实 App Web Relay：HTTP 健康检查、WS 握手、auth/roster、attach、输入回显
- 无头 UI 观测（`/tmp/burrow-ui-report/report.json`）
- 真实点击审计（`bash scripts/click-probe.sh`）：OCR 定位 + NSEvent 点击，验证
  Search / Sessions+ / Session 行 / Session 关闭 / Project / Workspace / Tab /
  Tab 关闭 / 新建 Tab / 顶栏搜索 / 侧栏折叠 / 分支详情 / 空态 Add Project
  全部到达 action 通道
- Ghostty 键盘输入审计（`bash scripts/input-probe.sh`）：真实 NSWindow 内挂载
  Ghostty surface，合成 keyDown，断言字节到达 Host 输入通道

## 1. 稳定性

- [ ] 在项目目录创建/拉取一个分支
- [ ] 打开 App，新建 Shell / Claude Code / Codex 会话
- [ ] 在终端里执行一个可观察命令（如 `echo stable-ok`）
- [ ] 完全退出 App（⌘Q）
- [ ] 重新打开 App
- [ ] 确认同一个 tmux session 仍然存在、终端内容仍在
- [ ] 如果 tmux server 被手动杀掉，重启 App 后应自动重建 session，而不是卡在 Connecting

自动化证据：`ApplicationIntegrationTests.testLocalTmuxSessionSurvivesAdapterRestartAndReplaysOutput`

## 2. 交互

- [ ] 侧栏：Project 行可选中/折叠
- [ ] 侧栏：Workspace(branch) 行整行可点击，hover 出现 `+` 可新建 session
- [ ] 侧栏：branch 下的 Session 行可点击打开、可关闭
- [ ] 顶部：Tab 可切换、可关闭，`+` 可新建会话
- [ ] 顶部：Command Palette（⌘K）可打开，搜索并执行动作
- [ ] 菜单：New Session（⌘T）、Toggle Sidebar（⌘B）生效
- [ ] 菜单：Open Web Access、Start/Stop Tunnel、Copy Web URL 有明确响应
- [ ] 没有“点了没反应”的控件
- [ ] Tab 内可以直接键入；切换 Tab / 从别处点回后焦点回到终端

自动化证据：`bash scripts/click-probe.sh` 输出三个场景全部 passed。
自动化证据：`bash scripts/input-probe.sh` 输出 `Ghostty surface received typed bytes`。

## 2.5 会话可见性

- [ ] CLI/Web 创建的 agent session 默认不占 UI Tab（`isTabVisible=false`）
- [ ] 关闭 Tab 后重启 App，该 Tab 不再自动打开；打开过的 Tab 保持打开
- [ ] 旧状态文件（schema 1）升级后只保留最近 8 个可见 Tab，其余进入分支详情区

## 3. UI

- [ ] 顶部是 40pt 一体化 TabBar，无系统 titlebar 色块
- [ ] 侧栏是 Project → Branch → Sessions 层级，无顶部多余导航堆
- [ ] 主区域在选中 branch 且无 tab 时显示 branch sessions 详情
- [ ] 切换 tab / workspace 有平滑过渡，不卡顿
- [ ] 运行 `mise run ui:observe`，检查报告中的 sidebar/topBar 颜色与 OCR 层级

## 4. Web Relay

```bash
mise run verify:web
```

应输出 `web relay OK: http page + ws auth + roster + attach/input/echo`。

- [ ] App 内菜单 `Session ▸ Open Web Access…` 打开本地网页
- [ ] 网页自动 attach 第一个 session
- [ ] 网页输入能出现在 Mac 终端
- [ ] Mac 终端输出能实时出现在网页
- [ ] `Copy Web URL` 在本地复制 file/data URL，在隧道下复制带公网 host 的 data URL

## 5. Agent 实际使用

- [ ] create project
- [ ] 拉一个分支
- [ ] 用 App 启动 Claude Code / Codex 跑一个需求
- [ ] 中途关闭再打开 App，agent 会话仍在
- [ ] 通过网页访问同一会话并发送信息，双端一致

## 6. 公网隧道（可选，受环境限制）

- cloudflared quick tunnel：已实现，受 Cloudflare 限流影响
- tailscale serve：tailnet 内网可用
- tailscale funnel：已实现，需关闭 Tailscale shields-up
