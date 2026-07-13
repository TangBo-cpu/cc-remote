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
- 输入框键入 `/` 可读取 Claude Code 的真实斜杠指令，支持搜索和滚动选择。
- 对话使用左右消息气泡，任务运行时显示思考动效、状态文字和实时计时。
- 运行中显示安全化的工具调用状态，任务结束后自动收起本轮活动卡片。
- 顶部显示当前 Claude 模型和剩余上下文。
- 左侧工作区抽屉可浏览当前目录文件、查看 Git 修改和 diff。
- 一个 daemon 可注册多个项目，每个项目可创建和恢复多条独立会话。
- 手机端可切换项目与会话；每条会话独立保存 Claude session、上下文和 transcript。
- App 退到后台或锁屏后，任务完成、失败、停止和等待权限时发送 Android 系统通知。
- 通知可在 App 设置中关闭，点击通知会回到对应会话。
- 在其他项目目录再次运行 `cc-remote`，会把该目录注册到正在运行的 daemon。
- daemon 原子保存当前对话快照，App 重连后补回断线期间的输出。
- daemon 重启后恢复当前对话；未完成任务会归一化为已中断。
- 支持 Claude Code `manual`、`acceptEdits`、`auto`、`dontAsk`、`plan` 和 `bypassPermissions` 模式。
- `manual` 模式下可在手机端允许一次或拒绝 Claude Code 工具请求。
- 本地脚本模拟 App 已验证 WebSocket auth、单条 `pong`、长输出多段 `text`、`done` 和 `claudeSessionId` 写入。
- App 设置里可开启新对话，daemon 会清空当前 `claudeSessionId`。
- Stop 按钮发送 WebSocket `{ "type": "stop" }`。
- App 状态机区分“已配对”和“已连接”，daemon 离线时显示“电脑端离线”。
- App 回到前台时重新探测 daemon 状态。
- daemon auth state 写入串行化，避免并发写 `.data/state.json` 临时文件冲突。
- stale Claude Code session 自动清理并用新会话重试一次。
- 电脑端实际使用 `cc-remote` 一键启动。
- 当前开发分支已合并回 `master`。

未完成：

- 还没做多设备管理。
- 还没做文件上传/下载，工作区只读。
- 会话标题支持自动生成，全文搜索和归档还没做。
- App 进程被系统彻底杀死后的可靠推送尚未接 FCM。

最新 Android 调试版已完成真机安装和核心对话流程验证。手机端工具审批、权限模式、工作区抽屉、transcript 恢复均已落地。

## 一键启动电脑端

在任意 PowerShell 目录运行：

```powershell
cc-remote
```

它会同时启动 Cloudflare Tunnel 和 daemon。终端会显示手机配对用的二维码，按 `Ctrl+C` 会停止 daemon，并清理本次启动的 tunnel。

daemon 已经运行时，在另一个项目目录再次执行 `cc-remote`，不会重复启动服务，而是注册并切换到该项目。手机端随后可在“项目与会话”中来回切换。项目只能从电脑端注册，手机端不能填写任意路径。

项目内的底层脚本仍可作为故障排查入口：

```powershell
.\cc-remote.cmd
```

可选参数：

```powershell
cc-remote -NoTunnel
cc-remote -WorkspaceDir "E:\\Code-All\\cc-remote" -DeviceName "tb"
cc-remote -DisableBypassPermissions
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
输入 `/` 搜索 Claude Code 指令
接收 text/done/error/stopped
显示思考计时和运行中的工具调用
显示当前模型和剩余上下文
POST /api/new-conversation
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
GET  /api/projects
GET  /api/sessions/:sessionId
POST /api/projects/:projectId/sessions
POST /api/sessions/:sessionId/select
POST /api/new-conversation
POST /api/stop
POST /api/logout
```

工作区读取接口同样需要 Bearer token，只允许访问当前已注册项目的目录：

```text
GET /api/workspace
GET /api/workspace/file?path=src/daemon.ts
GET /api/workspace/diff?path=src/daemon.ts
GET /api/workspace/diff?path=src/daemon.ts&staged=1
```

文件列表遵循 Git 忽略规则。文件与 diff 只读，不提供远程编辑、暂存或提交入口。

`POST /api/new-conversation` 保留兼容性，实际会在当前项目下创建一条新会话。项目和会话切换只允许在没有 Claude 任务运行时执行。

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
{ "type": "prompt", "sessionId": "...", "text": "帮我检查这个项目", "permissionMode": "manual" }
```

```json
{ "type": "stop" }
```

切换会话：

```json
{ "type": "select_session", "sessionId": "..." }
```

服务端会发送：

```text
status, transcript_snapshot, permission_capabilities, permission_request, permission_resolved, permission_expired, commands, session_info, activity, claude_event, text, done, stopped, error
```

鉴权后先发送 `catalog`，其中包含项目、会话和当前选择。会话相关消息都带 `projectId` 与 `sessionId`。`transcript_snapshot` 发送当前会话的权威快照，`commands` 提供当前项目的 Claude Code 斜杠指令。`session_info` 提供当前模型、上下文窗口和剩余 token。`activity` 只暴露思考状态、工具名称和安全化摘要，不传递私有思考文本或工具结果正文。

收到 `permission_request` 后，App 可发送一次性审批结果：

```json
{ "type": "permission_response", "requestId": "...", "decision": "allow" }
```

`decision` 只接受 `allow` 或 `deny`。原始工具输入保留在 daemon，手机不能修改执行参数。

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
| `ALLOW_BYPASS_PERMISSIONS` | `1` | 默认允许手机为单次任务选择 `bypassPermissions`；设为 `0` 可关闭 |

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
- 手机端不能注册或填写任意工作目录，项目只能通过电脑端 `cc-remote` 注册。
- 不开放任意 shell API。
- 不默认加 `--dangerously-skip-permissions`。
- `bypassPermissions` 需要电脑端显式开启，并在手机端二次确认；任务结束后恢复 `manual`。

## 重置配对

停止 daemon 后删除 `.data/state.json`，再重新启动并扫码配对。
