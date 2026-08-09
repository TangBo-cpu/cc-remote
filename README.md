# CC Remote

CC Remote 是一个手机端 Flutter App，用来远程控制本机 Claude Code。电脑端 daemon 负责配对、鉴权、会话保存、工作区读取和 Claude Code CLI 调用，网页只保留为调试壳。

```text
Flutter App
  -> HTTPS / WSS
  -> Cloudflare Tunnel
  -> 127.0.0.1:8787
  -> CC Remote daemon
  -> local Claude Code CLI
```

## 当前版本

当前公开版本是 [`v1.1.0`](https://github.com/TangBo-cpu/cc-remote/releases/tag/v1.1.0)。Android 用户可以从 Release 页面下载 APK；当前安装包使用测试签名，适合个人测试，不应作为应用商店正式包分发。

当前主分支已经完成手机端主链路和浅色活力界面。界面使用暖纸色背景、黑色轮廓、薄荷绿、亮黄和珊瑚色，顶部连接舱采用紧凑双栏布局，目录、模型和剩余上下文集中在右侧。底部 Command Dock 负责权限模式、附件、输入、发送和停止。

已经支持扫码配对、Bearer token、WebSocket 首包鉴权、流式输出、停止任务、六种权限模式、手机端一次性工具审批、斜杠指令、多项目与多会话、transcript 恢复、模型与上下文显示、只读工作区、Git diff、图片与文件附件、Android 后台本地通知、WebSocket 自动重连和活动任务恢复。

最近补齐了工作区冷启动对齐：daemon 启动时会按 `WORKSPACE_DIR` / 启动目录注册并激活项目，和“daemon 已在跑时再执行 `cc-remote`”语义一致。手机「项目与会话」面板与设置页会显示完整项目路径。流式回复做了文本合批、流式轻渲染和本地落盘节流，减轻手机经隧道时的卡顿体感。历史 Claude session 已失效时，daemon 会识别 CLI 的原始错误、清除旧 session ID，并自动以新会话重试本轮请求。

当前限制是单设备授权。工作区不提供远程编辑、暂存和提交。手机不能注册任意电脑目录，只能切换电脑端已注册项目。会话全文搜索与 FCM 远程推送尚未实现。

## 启动电脑端

在准备交给 Claude Code 的项目目录运行：

```powershell
cc-remote
```

命令会启动 daemon 和 Cloudflare Tunnel，并在终端显示手机配对二维码。按 `Ctrl+C` 会停止本次启动的 daemon 和 tunnel。

如果 daemon 已经运行，在另一个项目目录再次执行 `cc-remote`，命令会把该目录注册到现有 daemon，并切换到该项目，不会重复启动服务。如果 daemon 重新冷启动，也会按本次启动目录激活对应项目，不会一直停在上次活动项目。手机端随后可以在「项目与会话」面板中切换已注册项目，并看到完整路径。

项目内也可以使用：

```powershell
.\cc-remote.cmd
```

常用参数：

```powershell
cc-remote -NoTunnel
cc-remote -WorkspaceDir "C:\Projects\cc-remote" -DeviceName "My PC"
cc-remote -DisableBypassPermissions
```

## 手动运行 daemon

```powershell
npm install
$env:PUBLIC_ORIGIN = "https://cc-remote.example.com"
$env:WORKSPACE_DIR = "C:\Projects\cc-remote"
$env:DEVICE_NAME = "My PC"
npm run dev
```

不设置 `PUBLIC_ORIGIN` 时默认使用 `http://127.0.0.1:8787`，适合本机调试。

固定 Cloudflare Tunnel 可以这样启动：

```powershell
cloudflared tunnel --config ".run\cloudflared-cc-remote.yml" run
```

健康检查：

```text
https://cc-remote.example.com/api/health
```

正常响应：

```json
{"ok":true,"service":"cc-remote"}
```

## Flutter App

Android APK：

- [查看 `v1.1.0` Release](https://github.com/TangBo-cpu/cc-remote/releases/tag/v1.1.0)
- [直接下载 `cc-remote-v1.1.0-android.apk`](https://github.com/TangBo-cpu/cc-remote/releases/download/v1.1.0/cc-remote-v1.1.0-android.apk)

下载后在 Android 手机上允许当前来源安装未知应用，并打开 APK 完成安装。

开发运行：

```powershell
cd C:\Projects\cc-remote\mobile
flutter pub get
flutter analyze
flutter test
flutter run
```

开发者构建并安装 Android 调试版：

```powershell
cd C:\Projects\cc-remote\mobile
flutter build apk --debug
adb devices -l
adb install -r build\app\outputs\flutter-apk\app-debug.apk
adb shell monkey -p com.example.cc_remote -c android.intent.category.LAUNCHER 1
```

如果连接了多台设备，在 `adb` 命令中增加 `-s <device-id>`。

## 配对协议

daemon 启动后会打印一次性 JSON 二维码：

```json
{
  "type": "cc-remote-pair",
  "version": 1,
  "origin": "https://cc-remote.example.com",
  "nonce": "base64url-random-nonce",
  "deviceName": "My PC",
  "expiresAt": 1780000000000
}
```

二维码 5 分钟过期，只能使用一次。App 扫码后先显示设备和服务地址，用户确认后调用 `/api/pair` 换取 token。token 明文只返回这一次，App 将其保存到 Secure Storage，daemon 只保存 token hash。

## HTTP API

无需鉴权：

```text
GET  /api/health
POST /api/pair
```

需要 `Authorization: Bearer <token>`：

```text
GET  /api/status
GET  /api/projects
GET  /api/sessions/:sessionId
POST /api/projects/:projectId/sessions
POST /api/sessions/:sessionId/select
POST /api/sessions/:sessionId/title
POST /api/sessions/:sessionId/archive
DELETE /api/sessions/:sessionId
POST /api/sessions/:sessionId/attachments
GET  /api/sessions/:sessionId/attachments/:attachmentId/content
GET  /api/workspace
GET  /api/workspace/file?path=src/daemon.ts
GET  /api/workspace/diff?path=src/daemon.ts
GET  /api/workspace/diff?path=src/daemon.ts&staged=1
POST /api/new-conversation
POST /api/stop
POST /api/logout
```

`POST /api/local/projects/register` 只供本机启动脚本使用，通过本地控制 token 鉴权，不对手机开放。

附件按会话上传。单轮最多 5 个，单个文件最大 25MB。文件保存到 daemon 的 `.data/uploads/`，不会写入用户项目。工作区接口只允许读取已注册项目内未被 Git 忽略的文本文件和 diff。

## WebSocket 协议

连接 `/ws` 后第一条消息必须是：

```json
{ "type": "auth", "token": "..." }
```

发送任务：

```json
{
  "type": "prompt",
  "promptId": "...",
  "sessionId": "...",
  "text": "帮我检查这个项目",
  "attachmentIds": ["..."],
  "permissionMode": "manual"
}
```

其他客户端消息：

```json
{ "type": "stop" }
{ "type": "select_session", "sessionId": "..." }
{ "type": "permission_response", "requestId": "...", "decision": "allow" }
```

服务端消息包括 `status`、`catalog`、`prompt_accepted`、`transcript_snapshot`、`permission_capabilities`、`permission_request`、`permission_resolved`、`permission_expired`、`commands`、`session_info`、`activity`、`text`、`done`、`stopped` 和 `error`。

`activity` 只发送安全化后的思考状态、工具名和摘要，不发送私有思考文本或完整工具结果。`text` 在 daemon 侧会短时合批后再推送，任务结束前会 flush 尾包。会话消息带 `projectId` 和 `sessionId`；daemon 接管任务后返回带相同 `promptId` 的 `prompt_accepted`。App 只会在确认丢失时重发同一个 `promptId`，daemon 的有界收据缓存会返回原确认而不再次启动 Claude。重连后再以 `transcript_snapshot`、`running`、`stopping`、`runId` 和 `startedAt` 恢复任务内容与 Stop 中间态。

## 配置

| 环境变量 | 默认值 | 说明 |
|---|---|---|
| `HOST` | `127.0.0.1` | daemon 监听地址 |
| `PORT` | `8787` | daemon 监听端口 |
| `PUBLIC_ORIGIN` | `http://127.0.0.1:8787` | 手机访问的源站 |
| `WORKSPACE_DIR` | 当前目录 | 启动时注册并激活的项目目录 |
| `CLAUDE_BIN` | `claude` | Claude Code CLI 路径 |
| `CLAUDE_ARGS` | 未设置 | 以 `|` 分隔的额外 Claude CLI 参数，主要用于测试或特殊启动参数 |
| `DEVICE_NAME` | 当前主机名 | 配对时显示的电脑名 |
| `ALLOW_BYPASS_PERMISSIONS` | `1` | 是否允许手机为单次任务选择跳过权限 |
| `MAX_WS_CONNECTIONS` | `16` | WebSocket 最大连接数 |
| `WS_AUTH_TIMEOUT_MS` | `10000` | WebSocket 首包鉴权超时（毫秒） |

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

daemon 默认只监听 loopback，公网入口通过 Cloudflare Tunnel。二维码不包含长期 secret。HTTP 使用 Bearer token，WebSocket 使用首条 `auth` 消息。退出配对或重新配对会撤销旧 token 并关闭旧连接。

手机不能注册任意目录，不能调用任意 shell，不能远程编辑工作区。`bypassPermissions` 可由电脑端关闭；启用时手机仍需二次确认，并且只对下一次任务生效。

## 重置配对

停止 daemon，删除 `.data/state.json`，再重新启动并扫码。
