# 技术方案

## 需求合同

`clarification.md` 是行为与范围的事实真源。下文只记录技术影响，不重复需求。

## 上下文与源码证据

| 路径 / 符号 / 文档 | 证明内容 |
| --- | --- |
| `Packages/WebRelay/Sources/WebRelay/WebRelayServer.swift` | 本地 WebRelay 已在 loopback 上承载现有 Host Protocol，并持有本地 pairing token |
| `Packages/WebRelay/Sources/WebRelay/Resources/web.html` | 响应式 Web/PWA 已有认证首帧、终端帧和本地 token 恢复逻辑，可按 Host 上下文切换 endpoint |
| `Sources/BurrowNext/BurrowNextApplicationModel.swift` | Composition Root 负责启动/停止本地 WebRelay，适合托管一个可选的出站 connector |
| `Packages/TmuxRuntime/Sources/BurrowTmuxRuntime/TmuxCommandExecutor.swift` | tmux 子进程环境由集中白名单/剔除规则构建，可在这里阻止控制面 Secret 继承 |
| `RelayService/internal/controlplane/registry.go` | Host credential hash、generation、presence 和 tunnel 的单实例权威已集中在 registry |
| `RelayService/internal/controlplane/tunnel.go` | `BRLY` envelope、connection ID、有界 route queue 和 WebSocket 生命周期形成内容不可知的转发层 |
| `RelayService/internal/controlplane/server_test.go` | 现有测试可真实建立 Host/Client WebSocket，覆盖配对、持久化、撤销和双向帧转发 |
| `scripts/verify.sh` | 仓库全量验收包含 Swift、真实 tmux、进程、UIProbe、TerminalProbe 和 App 打包 |

## 选定方案

新增一个独立 Go HTTP/WebSocket 服务作为控制面边缘：管理 API 持有 bootstrap
权限；Host credential 只认证单台 Host 的出站隧道；一次性 pairing code 换取
HMAC access token。Relay 将每个远端 WebSocket 映射为随机 connection ID，并用
固定二进制 envelope 在一个 Host WSS 上多路复用，业务 payload 原样转发。

macOS 端在现有 WebRelay 前增加 `RelayHostConnector`。每个远端 connection ID
对应一个独立 loopback WebSocket attachment；connector 仅将远端客户端的第一个
auth payload 改写为本地 pairing token。控制面 credential 从启动环境一次性导入
Keychain 后清除，且所有子进程环境继续显式剔除。

Web/PWA 通过服务端注入 Host ID 判定 Relay 模式，token 按 Host 分区存储并只从
URL fragment 读取；WebSocket query 只携带非秘密的 Host ID，token 在首帧发送。

## 关键决策与替代方案

| 决策 | 理由 | 未采用的替代方案 |
| --- | --- | --- |
| Relay 不理解 Host Protocol payload | 保持数据本地权威，降低中心服务隐私面和协议耦合 | 在 Relay 复制资源模型或保存 Terminal 历史 |
| 单 Host WSS 多路复用 connection ID | Mac 无需入站端口，远端 attachment 可独立清理 | 每个浏览器连接都让 Host 新建一条公网连接 |
| generation 绑定 access token | credential 轮换/撤销可即时失效，而无需持久化每个客户端 token | 只依赖长周期 token 过期或服务端 token 黑名单 |
| Host 边缘改写本地 auth | 浏览器和 Relay 永远接触不到 loopback pairing token | 将本地 token 注册到中心或复用 Host credential 访问本地协议 |
| registry/presence 暂为单实例 | 满足独立部署且避免虚假的多副本一致性保证 | 未引入共享存储就开放多实例负载均衡 |

## 受影响的组件与契约

| 组件 / 接口 | 计划改动 | 兼容性影响 |
| --- | --- | --- |
| Relay HTTP API | `/v1/hosts`、pairing、revoke、discovery 与 PWA 静态资源 | 新增独立进程，不影响本地 API |
| Relay WebSocket API | Host/Client endpoint，首帧 client auth，`BRLY` envelope | access token 不进入 query；Host credential 仍用 Authorization header |
| Host registry | hash、generation、presence、一次性 code、原子 `0600` 持久化 | 当前仅支持单进程 registry |
| `RelayHostConnector` | 出站重连、多路复用、本地 auth 改写、proxy 清理 | 未配置时不启动，保留 loopback-only 默认值 |
| Web/PWA bundle | Relay Host endpoint、Host-specific storage/PWA scope | 本地 `/ws` 路径和原 token key 保持不变 |
| Composition Root / Keychain | 环境导入、早期清除、生命周期托管 | Headless acceptance 不访问真实 Keychain/Relay |

## 数据流与接口变更

```text
Admin provision -> Host credential(hash + generation in registry)
Mac --Authorization + host_id--> Relay Host WSS
Admin pairing -> one-time code -> Client access token(host + generation + exp)
Browser --host_id + auth frame--> Relay --connection ID/envelope--> Mac connector
Mac connector --local pairing auth--> loopback WebRelay -> Host Protocol
```

Relay envelope 固定为 magic `BRLY`、version、kind 和 16-byte connection ID，
其余字节不解析。client auth 成功前不得创建虚拟连接。Host credential 的最终
校验与隧道注册必须原子完成；client token 的 generation 校验与隧道选择也必须
基于同一 registry 临界区，避免轮换并发窗口让旧凭证接入新隧道。

## 兼容或迁移

- 没有数据库迁移；Relay 首次启动创建自己的 JSON registry。
- macOS 首次带环境变量启动会把 credential 导入 Keychain，之后从偏好与 Keychain
  恢复。没有完整三元组时保持未配置状态。
- 原本的本地 Web URL、Cloudflare Tunnel 和 Tailscale Serve 行为不变。

## 风险、失败模式与回滚

- credential 轮换与并发 WebSocket upgrade 存在 TOCTOU 风险；通过 registry 内原子
  复核/连接以及 generation-bound tunnel lookup 消除。
- 慢端可能积压内存；每个 route 使用固定容量，写 deadline 超时或溢出只关闭该连接。
- Relay/Host 断线必须关闭全部虚拟 route；Host connector 使用指数退避重连并清理本地 proxy。
- registry 写失败不得伪装成 not-found，也不应把未持久化 credential 当作成功配置。
- 可通过不配置三项控制面设置完全回退到本地模式；Relay 服务本身可独立停止。

## 测试与验证策略

- Go 单元与真实 WebSocket 测试：Host 隔离、一次性/过期 pairing、重启持久化、
  `0600` 权限、撤销/轮换失效、Origin、文本/二进制双向转发和连接清理。
- Go `vet`、race detector 与独立 binary build。
- WebRelay Swift 测试：envelope round-trip、本地 auth 改写、Relay endpoint 与 token
  不进入 query。
- TmuxRuntime 测试：控制面环境变量不会传入 shell/tmux。
- `scripts/verify.sh` 作为最终全量回归；Docker daemon 可用时再执行镜像构建验证，
  daemon 不可用属于环境限制并记录。
