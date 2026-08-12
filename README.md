# Burrow

Burrow 是一个面向个人使用的 macOS 终端工作空间。当前版本在 App 进程内运行本机 Host，通过 tmux 保持终端会话，并使用 libghostty（Termio 同款终端内核）渲染终端。它不监听局域网端口，也不包含账号或多人系统。

界面布局完整参照 Superset：左侧 Sidebar + 中间信息区，顶部只有一条 40pt TabBar，不做右侧栏。Sidebar 负责 Session / Workspace 管理，中间 TabBar 承载会话标签、Command Palette 与新会话入口；新增会话可以直接选择 Shell、Claude Code、Codex 或自定义 CLI。

## 运行要求

- macOS 14 或更高版本
- Xcode 和 Swift 6 工具链
- tmux

如果尚未安装 tmux，请运行：

```bash
brew install tmux
```

## 启动

在仓库根目录运行：

```bash
mise run dev
```

未安装 mise 时，可运行：

```bash
bash scripts/run-app.sh debug
```

不要用 `swift run BurrowNext` 启动 UI。裸 SwiftPM 可执行文件没有 macOS App bundle，系统无法可靠地把键盘焦点从启动终端交给 Burrow。

首次打开后：

1. 点击 Sidebar 底部的“Add project”。
2. 选择一个本机文件夹。
3. 点击顶部“+”或按 `⌘T`，选择 Shell / Claude Code / Codex / 自定义命令创建会话。
4. 直接在终端中输入命令。

常用快捷键：

- `⌘K` Command Palette
- `⌘T` 新建会话
- `⌘B` 折叠/展开侧栏

## Web 访问

App 启动后会自动在 `ws://127.0.0.1:8788` 开启 WebSocket Relay。菜单 `Session ▸ Open Web Access…` 会在浏览器打开本地网页客户端；网页会列出 sessions 并自动 attach 第一个，实时看到终端输出并发送输入。xterm 已内联进网页，`data:` URL 完全自包含、离线可用。菜单还提供 cloudflared quick tunnel、tailscale serve、tailscale funnel 的启停与 `Copy Web URL`：隧道启动后复制的是一份自包含网页 URL，公网或 tailnet 浏览器粘贴即可通过 `wss://` 连接。`mise run verify:web` 会启动真实 App 并验证 HTTP 健康检查、WebSocket 鉴权、roster、attach、输入回显。

## burrow CLI

`burrow` 是给脚本/多 agent bridge 用的无头 CLI，通过 App 的 WebSocket Relay 工作：

```bash
swift build --product burrow
BIN=$(swift build --show-bin-path)/burrow

$BIN session list
$BIN agent create session "Codex Worker" --command "codex" --kind codex
$BIN session send <session-id> "Reply with exactly: ok"
$BIN session read <session-id> --timeout 60 --contains "ok"
```

自动化 codex 多轮验收：

```bash
mise run accept:agent
```

该命令会启动 App，用 `burrow agent create session` 创建 `codex exec` 会话，等待第一轮回复，再用 `codex exec resume --last` 发第二轮并等待回复。

关闭标签页或 App 不会终止对应的 tmux Session。再次启动 App 时，Burrow 会读取持久化 descriptor，并从本机 spool 重放终端内容。

## 本机数据

- Host 状态：`~/Library/Application Support/Burrow/host-state.json`
- 终端输出：`~/Library/Application Support/Burrow/RuntimeOutput/`

不要在仍需恢复会话时删除这些文件。Burrow 当前只面向本机单用户，不启动 WebSocket Server，也不需要局域网配置。

## 验证

```bash
bash scripts/build-app.sh debug
swift test --filter ApplicationIntegrationTests
bash scripts/observe-ui.sh
mise run verify
mise run accept
mise run package
```

第二条命令会创建隔离的临时状态和 tmux Session，验证输入、输出、resize 和重启恢复，并清理该测试自己创建的 Session。第三条命令会把真实 Desktop 壳离屏渲染成 PNG，并用 OCR + 像素扫描输出 `/tmp/burrow-ui-report/report.json`。`mise run verify` 会完整跑一遍所有 package 测试、tmux 集成测试、App 构建和 web.html bundle 检查；`mise run accept` 会再叠加真实 App 的 Web Relay 双向验证与 UI 观测；`mise run package` 会构建 release 并打包 `Burrow-0.1.0.zip`。
