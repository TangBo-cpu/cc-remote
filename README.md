# CC Remote

手机 App 远程操控本机 Claude Code 的本地 daemon。

目标链路：

```text
手机 App
  -> https://tbhaoshuai.ccwu.cc
  -> Cloudflare Tunnel
  -> http://127.0.0.1:8787
  -> 本机 daemon
  -> 本机 Claude Code CLI
```

电脑端 daemon 负责显示配对二维码、签发 App token、鉴权 HTTP/WebSocket、调用本机 `claude` CLI。网页/PWA 只保留为调试壳，不是主产品入口。

## 运行

```powershell
npm install
$env:PUBLIC_ORIGIN = "https://tbhaoshuai.ccwu.cc"
$env:WORKSPACE_DIR = "E:\\Code-All\\cc-remote"
$env:DEVICE_NAME = "Jayson PC"
npm run dev
```

本机调试可不设 `PUBLIC_ORIGIN`，默认是 `http://127.0.0.1:8787`。

启动后终端会打印 App 扫码用 JSON payload 和二维码：

```json
{
  "type": "cc-remote-pair",
  "version": 1,
  "origin": "https://tbhaoshuai.ccwu.cc",
  "nonce": "base64url-random-nonce",
  "deviceName": "Jayson PC",
  "expiresAt": 1780000000000
}
```

二维码 5 分钟过期，一次性使用。App 扫码后调用 `/api/pair` 换取 Bearer token。

## Cloudflare Tunnel

把公网域名转发到本机 daemon：

```powershell
cloudflared tunnel --url http://127.0.0.1:8787
```

正式使用固定域名时，确保 `PUBLIC_ORIGIN` 等于手机访问的 HTTPS 域名：

```powershell
$env:PUBLIC_ORIGIN = "https://tbhaoshuai.ccwu.cc"
npm run dev
```

## HTTP API

### Health

```http
GET /api/health
```

无需鉴权。

### Pair

```http
POST /api/pair
Content-Type: application/json

{
  "nonce": "..."
}
```

成功：

```json
{
  "ok": true,
  "token": "base64url-app-token",
  "deviceName": "Jayson PC"
}
```

### Authenticated APIs

后续 HTTP 请求使用：

```http
Authorization: Bearer <token>
```

需要鉴权：

```text
GET  /api/status
POST /api/stop
POST /api/logout
```

## WebSocket 协议

连接地址：

```text
wss://tbhaoshuai.ccwu.cc/ws
```

连接后第一条消息必须鉴权，不把 token 放 URL query：

```json
{ "type": "auth", "token": "..." }
```

鉴权成功后可发送：

```json
{ "type": "prompt", "text": "帮我检查这个项目" }
```

```json
{ "type": "stop" }
```

服务端会发送：

```text
status, claude_event, text, done, stopped, error
```

## 配置项

| 环境变量 | 默认值 | 说明 |
|---|---|---|
| `HOST` | `127.0.0.1` | daemon 监听地址 |
| `PORT` | `8787` | daemon 监听端口 |
| `PUBLIC_ORIGIN` | `http://127.0.0.1:8787` | 手机 App 访问的 HTTPS 源站 |
| `WORKSPACE_DIR` | 当前目录 | Claude Code 工作目录 |
| `CLAUDE_BIN` | `claude` | Claude Code CLI 可执行文件 |
| `DEVICE_NAME` | 当前主机名 | 二维码和 App 内显示的电脑名 |

## 校验

```powershell
npm run typecheck
npm run build
npm test
```

## 安全边界

- daemon 默认只监听 `127.0.0.1`。
- 公网入口只通过 Cloudflare Tunnel。
- QR payload 只含一次性 nonce，不含长期 secret。
- daemon 只保存 `sha256(token)`，不保存 token 明文。
- HTTP 使用 Bearer token。
- WebSocket 使用首条 `auth` 消息鉴权。
- logout / re-pair 会关闭旧 WebSocket。
- 手机端不能修改 `WORKSPACE_DIR`。
- 不开放任意 shell API。
- 不默认加 `--dangerously-skip-permissions`。

## 重置配对

停止 daemon 后删除 `.data/state.json`，再重新启动并扫码配对。
