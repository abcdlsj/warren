# ADR-0005：macOS 默认内嵌 Local Host 与进程内 Transport

## 状态

已接受（2026-08-11）。

## 背景

Burrow 当前定位为个人使用的 macOS 工具。把 Mac 局域网、设备发现、账号或多人隔离放进首个可用版本，会增加部署与安全边界，却不能改善单机终端工作流。与此同时，Host 必须独立于 Desktop UI，才能保留未来接入 iOS 或网络 Client 的替换空间。

## 决策

`BurrowNext` 默认在同一个 macOS App 进程内装配以下组件：

`BurrowNext → Embedded Local Host → In-process HostTransport → Local Runtime → BurrowClientCore → BurrowDesktop`。

Host 仍然拥有 Project、Workspace 与 Terminal Session 的生命周期；Transport 只负责请求与事件路由；Desktop 只消费 value projection、发出 typed actions，并通过注入的 terminal surface 显示远程字节。Session 不因 View、Transport 或 Attachment 销毁而结束。

网络 Transport、WebSocket Server、iOS Client、设备发现、账号、鉴权、TLS 和多人隔离均不属于本轮产品范围。未来适配器不得改变 Host/Transport/Client 的协议边界，也不得把网络假设泄漏到 Desktop View。

## 影响

- macOS 首次启动不需要端口、配对、证书或后台服务。
- 真实运行时仍可在 App 重启后由 StateStore 与 Local Runtime adoption 恢复 Session。
- Desktop 测试可以使用内存 Host/Transport 与确定性的 terminal surface，不启动进程。
- 未来增加网络或 iOS 时，需要新增 Transport/Client composition，而不是重写 Domain、Host 或 Desktop。

## 验收

- `BurrowNext` 不创建监听 Server，不执行设备发现或鉴权流程。
- macOS 端到端测试覆盖 create/attach/input/resize/detach/recover。
- Desktop 生产入口使用 `BurrowDesktopProjection`、`BurrowDesktopActions` 和注入的 terminal surface；preview fixture 只出现在 preview/test 兼容层。
