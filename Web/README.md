# Warren Web

响应式 Web/PWA 客户端使用 React + Vite。React 组件源码位于 `Web/src/`，生产构建产物写入 `Packages/WebRelay/Sources/WebRelay/Resources/`，供 macOS WebRelay 和 Go Relay Service 共同嵌入。

## 开发

```sh
npm --prefix Web install
mise run web:dev
```

Vite 开发服务器只负责前端资源，React 负责 UI 组件树和客户端状态；xterm 通过组件 ref 挂载到终端节点。若需连接本地 Warren WebSocket，可继续使用生产 WebRelay，或为 Vite 配置临时反向代理。

## 构建和验证

```sh
mise run web:build
mise run verify:web
```

不要直接编辑 `Packages/WebRelay/Sources/WebRelay/Resources/`。该目录是 Vite 构建产物，会在下一次构建时清空并重新生成。

运行时参数通过 `index.html` 的 meta 占位符注入：

- `__WARREN_INJECTED_PARAMS__`：本地 WebRelay 的 host 和 token 参数。
- `__WARREN_RELAY_HOST_ID__`：中心 Relay 的目标 Host ID。

SSH、WebSocket 协议和 Host 资源模型不属于 Vite 项目；它们仍由 Swift/Go 服务端维护。
