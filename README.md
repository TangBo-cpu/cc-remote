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

## 当前状态

已完成：

- daemon App-first token 协议。
- 终端 JSON QR 配对。
- `/api/pair` 返回 Bearer token。
- HTTP Bearer 鉴权。
- daemon WebSocket 首条 `auth` 消息鉴权。
- Flutter App 扫码配对。
- Flutter App Secure Storage 保存 token。
- Flutter App 启动时 `/api/status` 恢复已配对状态。
- Flutter App logout 调用 daemon 并清本地 token。
- Flutter App WebSocket 连接 `/ws` 并发送首条 `{ "type": "auth", "token": "..." }`。
- Flutter App 发送 prompt 到 daemon。
- Flutter App 接收 `text`、`done`、`error`、`stopped`。
- Stop 按钮发送 WebSocket `{ "type": "stop" }`。
- App 状态机区分“已配对”和“已连接”，daemon 离线时显示“电脑端离线”。
- App 回到前台时重新探测 daemon 状态。
- daemon auth state 写入串行化，避免并发写 `.data/state.json` 临时文件冲突。
- stale Claude Code session 自动清理并用新会话重试一次。
- 电脑端一键启动命令：`cc-remote` / `.\cc-remote.cmd` / `npm run cc-remote`。
- 当前开发分支已合并回 `master`。

未完成：

- 还没做完整真机端到端验证 Claude Code 流式输出。
- 还没做 transcript 持久化。
- 还没做断线期间输出恢复。

下一步最小任务：启动 `cc-remote` 后，真机发 `回复 pong，只输出 pong`，验证 App 能收到 Claude Code 真实输出。

## 一键启动电脑端

```powershell
cc-remote
```

如果全局命令不可用，也可在项目根目录运行：

```powershell
.\cc-remote.cmd
```

这个命令会同时启动：

- Cloudflare Tunnel：`tbhaoshuai.ccwu.cc` -> `127.0.0.1:8787`
- daemon：打印 App 扫码二维码，调用本机 Claude Code CLI

按 `Ctrl+C` 会停止 daemon，并清理本次脚本启动的 tunnel。

也可以用 npm：

```powershell
npm run cc-remote
```

可选参数：

```powershell
.\cc-remote.cmd -NoTunnel
.\cc-remote.cmd -WorkspaceDir "E:\\Code-All\\cc-remote" -DeviceName "tb"
```

## 手动运行 daemon

```powershell
npm install
$env:PUBLIC_ORIGIN = "https://tbhaoshuai.ccwu.cc"
$env:WORKSPACE_DIR = "E:\\Code-All\\cc-remote"
$env:DEVICE_NAME = "tb"
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
  "deviceName": "tb",
  "expiresAt": 1780000000000
}
```

二维码 5 分钟过期，一次性使用。App 扫码后调用 `/api/pair` 换取 Bearer token。

如果端口被占用：

```powershell
$pids8787 = (Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort 8787 -State Listen).OwningProcess
Stop-Process -Id $pids8787 -Force
```

## Cloudflare Tunnel

把公网域名转发到本机 daemon：

```powershell
cloudflared tunnel --url http://127.0.0.1:8787
```

如果使用本项目 `.run` 下的固定 tunnel 配置：

```powershell
cloudflared tunnel --config ".run\cloudflared-cc-remote.yml" run
```

正式使用固定域名时，确保 `PUBLIC_ORIGIN` 等于手机访问的 HTTPS 域名：

```powershell
$env:PUBLIC_ORIGIN = "https://tbhaoshuai.ccwu.cc"
npm run dev
```

手机端先用浏览器验证：

```text
https://tbhaoshuai.ccwu.cc/api/health
```

期望：

```json
{"ok":true}
```

## Flutter App

```powershell
cd mobile
flutter test
flutter run
```

App 当前能力：

```text
扫码二维码
确认设备和服务地址
POST /api/pair
保存 token 到 Secure Storage
启动时 GET /api/status
显示已连接设备
连接 wss://tbhaoshuai.ccwu.cc/ws
发送 auth 消息
发送 prompt
接收 text/done/error/stopped
发送 stop
POST /api/logout
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
  "deviceName": "tb"
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

注意：daemon 和 Flutter App 已接入这套 WebSocket 协议。App 会在回到前台时重新探测 daemon；电脑端离线时保留配对态，但显示“电脑端离线”并禁止发送。

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
cd mobile
flutter analyze
flutter test
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
