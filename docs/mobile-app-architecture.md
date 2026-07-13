# CC Remote 手机 App 整体架构设计

## 当前结论

CC Remote 的手机端按 Flutter App 做。网页只保留为本地调试入口，不再作为产品主路径。现有 daemon 已经进入 App token 协议，二维码是 JSON payload，HTTP 使用 Bearer token，WebSocket 建立后第一条消息鉴权。

这份文档负责约束 App、daemon、协议和实现顺序。视觉和交互以 `docs/mobile-ui-app-design.md` 为准，参考图放在 `docs/mobile-ui-reference/`。

第一版只服务一台电脑、一个 token、一个 Claude Code session。已跑通扫码配对、恢复连接、发送 prompt、流式输出、Stop、Logout、权限审批、transcript 恢复和工作区只读浏览。多电脑、多会话历史列表、文件上传/下载、推送通知和商店材料仍不进入当前范围。

## 产品路径

用户在电脑 PowerShell 中运行 `cc-remote` 启动 daemon。daemon 只监听 `127.0.0.1:8787`，终端显示 CC Remote 配对二维码。手机 App 扫码后读取公网 `origin` 和一次性 `nonce`，调用 `/api/pair` 换取 token。之后 App 通过 Cloudflare Tunnel 访问电脑本地 daemon，daemon 再调用本机 Claude Code CLI。

```text
电脑端运行 cc-remote
  -> 终端显示 JSON 二维码
  -> Flutter App 扫码确认
  -> POST /api/pair 换 token
  -> token 存入 Secure Storage
  -> WebSocket 连接并发送 auth
  -> App 发送 prompt
  -> daemon spawn 本机 claude
  -> App 流式显示输出并可 Stop
```

## 总体拓扑

```text
┌──────────────────────────┐
│ Flutter Mobile App        │
│ - scan QR                 │
│ - secure token            │
│ - transcript UI           │
│ - permission approval     │
│ - workspace drawer        │
│ - prompt / stop / logout  │
└────────────┬─────────────┘
             │ HTTPS / WSS
             ▼
┌──────────────────────────┐
│ Cloudflare Tunnel         │
│ public origin             │
└────────────┬─────────────┘
             │ http://127.0.0.1:8787
             ▼
┌──────────────────────────┐
│ Local daemon              │
│ Node.js / TypeScript      │
│ src/daemon.ts             │
│ src/authState.ts          │
│ src/claudeBridge.ts       │
│ src/transcriptState.ts    │
│ src/workspaceService.ts   │
└────────────┬─────────────┘
             │ spawn("claude")
             ▼
┌──────────────────────────┐
│ Local Claude Code CLI     │
│ current desktop auth      │
└──────────────────────────┘
```

## 仓库结构

当前 daemon 继续留在 `src/`，不要为了目录洁癖先拆 `daemon/`。手机端在 `mobile/`。文档继续放在 `docs/`。

```text
cc-remote/
  src/
    daemon.ts
    authState.ts
    claudeBridge.ts
    transcriptState.ts
    workspaceService.ts
    web/

  mobile/
    lib/
      main.dart
      workspace_drawer.dart
    pubspec.yaml
    test/

  docs/
    mobile-app-architecture.md
    flutter-app-design.md
    mobile-ui-app-design.md
    mobile-ui-reference/
```

当前 Flutter 实现是单文件主入口 `main.dart` 加 `workspace_drawer.dart`，尚未拆成完整 `screens/services/controllers` 分层。`docs/flutter-app-design.md` 保留更细的目标分层设计，以实际代码结构为准。

## 现有 daemon 事实

daemon 启动时读取这些环境变量。`HOST` 默认 `127.0.0.1`，`PORT` 默认 `8787`，`PUBLIC_ORIGIN` 默认本地地址，正式手机访问时应设成 Cloudflare Tunnel 的 HTTPS 地址。`WORKSPACE_DIR` 默认当前目录，`CLAUDE_BIN` 默认 `claude`，`DEVICE_NAME` 默认电脑 hostname。`ALLOW_BYPASS_PERMISSIONS` 默认 `1`，设为 `0` 可关闭手机端 `bypassPermissions`。

启动后 daemon 会生成一次性配对 payload，终端打印 JSON 并渲染二维码。payload 格式如下。

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

nonce 只保存 hash，5 分钟过期，一次配对后作废。配对成功后 daemon 只保存 token hash，不保存 token 明文。已有 token 或重新配对会递增 `authGeneration`，旧 WebSocket 会被关闭。

## HTTP 协议

`GET /api/health` 不需要鉴权，只返回 daemon 是否存活。

```json
{
  "ok": true
}
```

`POST /api/pair` 不需要 Bearer token，但需要合法 nonce。第一版请求体只需要 `nonce`。`appName`、`platform`、设备列表以后再加。

```http
POST /api/pair
Content-Type: application/json

{
  "nonce": "base64url-random-nonce"
}
```

成功响应会返回 token 和设备名。

```json
{
  "ok": true,
  "token": "base64url-app-token",
  "deviceName": "Jayson PC"
}
```

失败响应使用 401。

```json
{
  "ok": false,
  "error": "invalid_pairing_code"
}
```

`GET /api/status` 需要 `Authorization: Bearer <token>`。

```json
{
  "authorized": true,
  "running": false,
  "deviceName": "Jayson PC",
  "workspaceDir": "E:\\Code-All\\cc-remote",
  "paired": true,
  "hasClaudeSessionId": true
}
```

`POST /api/stop` 需要 Bearer token。它会尝试停止当前 Claude 子进程，并广播状态。

```json
{
  "stopped": true
}
```

`POST /api/logout` 需要 Bearer token。它会清掉服务端 token hash，递增授权代际，并关闭旧 WebSocket。

```json
{
  "ok": true
}
```

`POST /api/new-conversation` 需要 Bearer token。它会清空当前 `claudeSessionId` 和 daemon 对话快照。

```json
{
  "ok": true
}
```

工作区读取接口同样需要 Bearer token，只允许访问启动时固定的 `WORKSPACE_DIR`：

```text
GET /api/workspace
GET /api/workspace/file?path=src/daemon.ts
GET /api/workspace/diff?path=src/daemon.ts
GET /api/workspace/diff?path=src/daemon.ts&staged=1
```

文件列表遵循 Git 忽略规则。文件与 diff 只读，不提供远程编辑、暂存或提交入口。

## WebSocket 协议

连接地址由扫码 payload 的 `origin` 推导。`https` 对应 `wss`，路径固定为 `/ws`。token 不放 URL query。连接后第一条消息必须是 `auth`。

```json
{
  "type": "auth",
  "token": "base64url-app-token"
}
```

鉴权成功后服务端返回状态。

```json
{
  "type": "status",
  "authenticated": true,
  "running": false,
  "hasClaudeSessionId": true
}
```

App 发送 prompt。`permissionMode` 可选，默认 `manual`。

```json
{
  "type": "prompt",
  "text": "帮我检查这个项目",
  "permissionMode": "manual"
}
```

收到 `permission_request` 后，App 返回一次性审批结果：

```json
{
  "type": "permission_response",
  "requestId": "...",
  "decision": "allow"
}
```

`decision` 只接受 `allow` 或 `deny`。原始工具输入保留在 daemon，手机不能修改执行参数。

App 停止任务。

```json
{
  "type": "stop"
}
```

服务端会发送这些消息。鉴权后先发送 `transcript_snapshot` 和 `permission_capabilities`，恢复 daemon 持久化的当前对话、断线期间输出和待审批请求。`permission_request` 由 Claude Code stdio 控制协议产生，App 只能返回允许一次或拒绝，不能修改原始工具输入。`commands` 提供 Claude Code 真实斜杠指令。`session_info` 提供当前模型、上下文窗口和剩余 token。`activity` 提供安全化的思考与工具调用状态，不暴露私有思考文本或工具结果正文。`text` 直接追加到当前 assistant message。`done`、`stopped`、`error` 用来结束当前运行态并更新 transcript。

```json
{ "type": "text", "text": "..." }
```

```json
{ "type": "claude_event", "event": {} }
```

```json
{ "type": "done", "exitCode": 0, "claudeSessionId": "..." }
```

```json
{ "type": "stopped" }
```

```json
{ "type": "error", "message": "..." }
```

## Flutter App 结构

Flutter App 的细节以 `docs/flutter-app-design.md` 为准。当前依赖为 `mobile_scanner`、`flutter_secure_storage`、`http` 和 `web_socket_channel`。状态管理仍在 `main.dart` 内，两三个页面不用上复杂路由。

当前实际代码结构：

```text
mobile/lib/
  main.dart              # 配对、会话、WS、权限模式、审批卡、transcript
  workspace_drawer.dart  # 工作区文件列表、文件内容、Git diff
```

设计稿中的 `screens/services/controllers` 分层仍可作为后续拆分目标，但不是当前仓库事实。

## App 状态流

启动时进入 `booting`，读取 Secure Storage。没有 token 进入 `unpaired`。有 token 就调用 `/api/status`：成功进入主控制台并建立 WebSocket；失败但 token 未过期时保留已配对态，显示 `offline`；401 时清 token 并回到扫码配对。扫码后先进入配对确认 sheet，用户确认后才调用 `/api/pair`。配对成功保存 `origin`、`token` 和 `deviceName`，再进入主控制台。

运行时状态分两层：已配对不等于已连接。`connected` 代表 WebSocket 已 auth，可发送 prompt。`running` 禁用发送并显示 Stop。`offline` 保留本地 transcript 缓存，禁用输入，显示“电脑端离线”和重新连接。App 回到前台会重新调用 `/api/status` 探测 daemon，鉴权后用 daemon 快照恢复完整 transcript。`authExpired` 清理 token 并回到扫码配对。`error` 只显示当前操作错误，不清空 transcript。

```text
booting
  -> unpaired
  -> scanning
  -> pairReview
  -> pairing
  -> pairedOffline
  -> connected
  -> running
  -> authExpired
```

## UI 对接边界

界面结构以浅色渐变、毛玻璃控制台为准。主屏不是聊天 App，也不是网页 dashboard。启动页只做状态检查。扫码页展示相机区域和配对确认 sheet。主控制台由连接头、会话状态带、transcript、权限模式选择、工具审批卡和底部 prompt bar 组成。左侧工作区抽屉提供只读文件与 Git diff。设置用半屏 sheet，放设备信息、新对话、重新连接和退出配对。

实现时优先参考这些图片。

```text
docs/mobile-ui-reference/01-light-glass-flow-overview.png
docs/mobile-ui-reference/02-startup-status-check.png
docs/mobile-ui-reference/03-qr-pairing-confirmation.png
docs/mobile-ui-reference/04-connected-empty-console.png
docs/mobile-ui-reference/05-running-transcript.png
```

## 安全边界

daemon 默认只监听 loopback。公网入口只通过 Cloudflare Tunnel。二维码里只有短期 nonce，没有长期 secret。token 明文只返回给 App 一次。App 只能把 token 存进 Secure Storage。HTTP 使用 Bearer token。WebSocket 未鉴权前只接受 `auth`。Logout 和重新配对都会撤销旧 token 和旧连接。

App 不提供修改 `WORKSPACE_DIR` 的入口，不开放任意 shell 命令。工作区文件与 Git diff 只读。权限模式直接映射 Claude Code 原生模式。`bypassPermissions` 默认由电脑端开启，可用 `ALLOW_BYPASS_PERMISSIONS=0` 或 `-DisableBypassPermissions` 关闭；开启后仍需手机二次确认，并只对单次任务生效。

## 当前实现状态

daemon 的 App token 主协议已经在代码里，Flutter App 也已经完成扫码配对、状态恢复、WebSocket 对话、Stop、Logout、离线状态、权限审批、transcript 恢复和工作区只读浏览。当前代码已合并回 `master`。

已完成：

1. 创建 `mobile/` Flutter 项目，接入基础依赖和浅色毛玻璃 UI 骨架。
2. 实现扫码配对。解析 JSON QR，校验 `type`、`version`、`origin`、`nonce` 和 `expiresAt`，展示配对确认 sheet，确认后调用 `/api/pair`，把 `origin`、`token`、`deviceName` 存进 Secure Storage。
3. 实现状态恢复。App 重启后读取本地 session，调用 `/api/status`。成功进入主控制台；daemon 离线时保留配对态并显示“电脑端离线”；401 时清 token 并回到配对页。
4. 实现 WebSocket 聊天。连接 `/ws`，发送 `auth`，处理 `status`、`transcript_snapshot`、`permission_*`、`commands`、`session_info`、`activity`、`text`、`done`、`stopped`、`error`，把文本流追加到当前 assistant message。
5. 实现 Stop、重新连接、Logout 和新对话。Stop 走 WebSocket `stop`。Logout 先调 `/api/logout`，再清本地 token。新对话走 `POST /api/new-conversation`。
6. 实现权限模式选择与手机端工具审批卡；`manual` 模式可 allow/deny 单次请求。
7. 实现 transcript 本地缓存与 daemon 权威快照恢复。
8. 实现工作区只读抽屉：`/api/workspace`、`/api/workspace/file`、`/api/workspace/diff`。
9. 电脑端使用 `cc-remote` 一键启动。
10. daemon 修复 auth state 并发写 race，stale Claude Code session 会自动清理并用新会话重试一次。

真机已验证真实指令、流式输出、`done`、消息气泡、思考计时、工具调用、模型和剩余上下文。`--resume` 和 Stop 中断长任务仍待专项验证。

## 第一版验收

已满足：电脑端 daemon 能显示 JSON 二维码。Flutter App 能扫码并展示确认 sheet。确认后 App 能保存 token，并在关闭重开后恢复已配对状态。主控制台能显示设备名、工作目录、连接状态、当前模型、剩余上下文和 transcript。输入框能发现、筛选并滚动选择 Claude Code 指令。App 能发送 prompt，并在运行中显示思考计时和工具调用。手机端可审批工具请求并切换权限模式。工作区抽屉可只读浏览文件与 Git diff。Logout 后旧 WebSocket 失效，旧 token 不能继续控制电脑。daemon 离线时 App 能显示“电脑端离线”。

待专项验证：第二条 prompt 通过 `--resume <claudeSessionId>` 延续上下文；运行中 Stop 能中断任务且没有残留 Claude 进程。

当前只持久化一份当前对话，不提供多会话历史列表。多设备、历史搜索、可写文件能力、推送和上架材料等核心链路稳定后再补。
