# Warren Relay Service

Warren Relay 是可独立部署的远端控制面。它保存 Host 身份、在线状态和撤销 generation，并转发 WebSocket 帧；Project、Workspace、Session、tmux 和 Terminal 输出均只存在于 macOS Host。Relay 不记录或解析终端业务帧。

## 一键体验

在仓库根目录运行：

```bash
mise run relay:dev
```

该命令会自动生成本地开发 Secret、启动 Relay、注册当前 Mac、构建并启动 Warren、
等待 Host 上线、完成一次性配对并打开 Web/PWA。生成的开发状态放在忽略提交的
`.build/relay-dev/8080`，Secret 文件权限为 `0600`。本地 Relay 只监听 `127.0.0.1`，
用于体验完整流程，不会把 Mac 暴露到局域网或公网。

日常命令：

```bash
mise run relay:pair    # 再打开一个远端客户端
mise run relay:status  # 查看 Relay 与 Host 状态
mise run relay:stop    # 只停止 Relay，不退出 Warren、不结束 tmux
```

连接已经部署好的公网 Relay 也只需一个命令；管理员 token 仅在该 Mac 首次注册时需要：

```bash
WARREN_RELAY_URL=https://relay.example.com \
WARREN_RELAY_ADMIN_TOKEN='<admin-token>' \
mise run relay:connect
```

之后同一地址会在 `~/Library/Application Support/Warren/relay-cli/<relay-id>` 保存
Host ID 和权限为 `0600` 的 Host credential；Warren 自身仍将凭证导入 macOS Keychain。
因此后续可以省略管理员 token。若 Host 已在线，重复运行也不会重建或重启 App，只生成
新的配对 URL。若不希望自动打开浏览器，增加 `WARREN_RELAY_NO_OPEN=1`。

## 启动

先生成三项 Secret：管理员 token、至少 32 字节的签名密钥。生产环境必须由 HTTPS/WSS 反向代理终止 TLS。

```bash
export WARREN_RELAY_ADMIN_TOKEN='replace-admin-token'
export WARREN_RELAY_SIGNING_KEY='replace-with-at-least-32-random-bytes'
export WARREN_RELAY_PUBLIC_URL='https://relay.example.com'
export WARREN_RELAY_ALLOWED_ORIGIN='https://relay.example.com'
go run ./RelayService/cmd/warren-relay
```

或构建容器：

```bash
docker build -f RelayService/Dockerfile -t warren-relay .
docker run --read-only -p 8080:8080 -v warren-relay-data:/data \
  -e WARREN_RELAY_ADMIN_TOKEN \
  -e WARREN_RELAY_SIGNING_KEY \
  -e WARREN_RELAY_PUBLIC_URL \
  -e WARREN_RELAY_ALLOWED_ORIGIN \
  warren-relay
```

如果用 `--read-only`，运行时还需提供可写临时目录（例如 `--tmpfs /tmp`）；持久数据只写入 `/data`。

## Host 注册与连接

管理员为每台 Host 单独签发 credential；响应中的 credential 只显示一次，Relay 仅保存 SHA-256 hash。重复 provision 同一 Host 会轮换 credential 并撤销现有客户端令牌。

```bash
export WARREN_HOST_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
curl -sS -X POST https://relay.example.com/v1/hosts \
  -H "Authorization: Bearer $WARREN_RELAY_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"id\":\"$WARREN_HOST_ID\",\"name\":\"My Mac\"}"
```

首次在 Warren.app 的启动环境中配置返回的 credential。Warren 会导入 macOS Keychain，后续启动从 Keychain 读取；控制面 Secret 会从所有 tmux/shell 子进程环境剔除：

```bash
env WARREN_CONTROL_PLANE_URL=https://relay.example.com \
  WARREN_CONTROL_PLANE_HOST_ID="$WARREN_HOST_ID" \
  WARREN_CONTROL_PLANE_HOST_TOKEN='<host-credential>' \
  ./Warren.app/Contents/MacOS/Warren
```

Warren 只建立出站 WSS，默认不配置时仍仅监听 `127.0.0.1`。

## 配对、发现与撤销

管理员或该 Host 自己的 credential 可以生成 10 分钟、一次性 pairing code：

```bash
curl -sS -X POST https://relay.example.com/v1/hosts/<host-uuid>/pairing \
  -H "Authorization: Bearer $WARREN_RELAY_ADMIN_TOKEN"
```

客户端用 code 换取绑定 Host 和 credential generation 的 access token：

```bash
curl -sS -X POST https://relay.example.com/v1/pair \
  -H 'Content-Type: application/json' \
  -d '{"host_id":"<host-uuid>","pairing_code":"<one-time-code>"}'
```

响应中的 `web_url` 即响应式 Web/PWA 入口。撤销 Host 会断开出站隧道，同时使此前所有 access token 立即失效：

```bash
curl -sS -X DELETE https://relay.example.com/v1/hosts/<host-uuid> \
  -H "Authorization: Bearer $WARREN_RELAY_ADMIN_TOKEN"
```

## 安全边界

- 管理 API 使用独立 bootstrap token；每台 Host 使用独立 credential。
- pairing code 一次性、短期有效；client token 使用 HMAC-SHA256、绑定 Host 与 generation。
- client token 只出现在 URL fragment 与 WebSocket 首个 auth 帧，不进入 HTTP query 或常规 access log。
- Relay registry 以 `0600` 原子写入，仅保存 Host credential hash 和控制面元数据。
- 每条 WebSocket 消息上限 8 MiB，每个虚拟连接的内存队列有界；慢客户端被关闭。
- Relay 不把本地 Web pairing token 发给浏览器：Host connector 只在可信边缘重写首个 auth 帧。
- 生产部署必须使用 TLS、强随机 Secret、持久卷和严格的 `WARREN_RELAY_ALLOWED_ORIGIN`。

当前 registry 和 Host tunnel 位于单个 Relay 实例；部署应保持单副本并使用持久卷。横向扩容需要把 registry、presence 和 connection routing 迁移到共享存储/消息层后再启用。
