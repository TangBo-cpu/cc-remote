# CC Remote Mobile

Flutter 手机 App，用于扫码配对本机 CC Remote daemon，并远程发送任务给本机 Claude Code CLI。

## 当前状态

已实现：

- 扫描 daemon 终端二维码。
- 解析 `cc-remote-pair` JSON payload。
- 显示配对确认 sheet。
- 调用 `POST /api/pair` 换取 token。
- 用 `flutter_secure_storage` 保存 token。
- 启动时读取 token 并调用 `/api/status`。
- 显示已配对设备和工作区。
- Logout 调用 `/api/logout` 并清本地 token。
- 连接 daemon WebSocket。
- 发送首条 auth 消息。
- 发送 prompt 到 daemon。
- 接收 Claude Code `text`、`done`、`error`、`stopped` 消息。
- Stop 发送 `{ "type": "stop" }`。
- 区分“已配对”和“已连接”。
- daemon 离线时显示“电脑端离线”并禁用发送。
- App 回到前台时重新探测 daemon 状态。
- 输入 `/` 获取 Claude Code 真实指令，支持搜索和滚动选择。
- 用户与 Claude 回复使用左右消息气泡。
- 发送任务后显示 Claude 风格的思考动效、状态文字和实时计时。
- 运行中显示工具调用，完成后移除思考与工具卡片，只保留最终对话。
- 顶部显示当前模型和剩余上下文。
- 本地缓存当前 transcript，连接 daemon 后用权威快照补回断线输出。
- 可选择 Claude Code 六种权限模式。
- `manual` 模式下显示工具审批卡，支持允许一次和拒绝。
- 左侧工作区抽屉可浏览当前目录文件、查看 Git 修改和 diff。

未实现：

- 多会话历史列表和搜索。
- 多设备管理。
- 文件上传/下载；工作区只读。

## 运行

电脑端在 PowerShell 中直接运行：

```powershell
cc-remote
```

手机端调试运行：

```powershell
cd E:\Code-All\cc-remote\mobile
flutter pub get
flutter analyze
flutter test
flutter run
```

## 真机安装

HyperOS 会拦普通 `adb install` / `flutter install`，可能报 `INSTALL_FAILED_USER_RESTRICTED`。以后优先用 `adb push` 到手机临时目录，再用手机端 `pm install` 安装：

```powershell
cd E:\Code-All\cc-remote
flutter build apk --debug
adb push mobile\build\app\outputs\flutter-apk\app-debug.apk /data/local/tmp/CCRemote-debug.apk
adb shell pm install -r /data/local/tmp/CCRemote-debug.apk
adb shell monkey -p com.example.cc_remote -c android.intent.category.LAUNCHER 1
```

期望安装结果包含：

```text
Success
```

App 扫 daemon 终端里的二维码。

## 配对流程

```text
扫码 QR
  -> parse PairingPayload
  -> 显示确认 sheet
  -> POST {origin}/api/pair
  -> 保存 origin/token/deviceName
  -> GET {origin}/api/status
  -> 进入 ChatScreen
  -> connect WebSocket
```

QR payload：

```json
{
  "type": "cc-remote-pair",
  "version": 1,
  "origin": "https://tbhaoshuai.ccwu.cc",
  "nonce": "...",
  "deviceName": "tb",
  "expiresAt": 1780000000000
}
```

## WebSocket 对话流程

```text
connect wss://tbhaoshuai.ccwu.cc/ws
send { "type": "auth", "token": "..." }
wait status authenticated=true
send { "type": "prompt", "text": "...", "permissionMode": "manual" }
receive transcript_snapshot / permission_request / commands / session_info / activity
send { "type": "permission_response", "requestId": "...", "decision": "allow|deny" }
append server text events
handle done/error/stopped
send { "type": "stop" }
```

输入框以 `/` 开头时会打开指令建议。后续字符用于实时筛选，点击指令后回填输入框。建议列表有独立滚动区域。

任务运行时，`activity` 消息驱动思考计时和工具调用卡片。任务结束后这些临时状态会移除。`session_info` 用于显示模型名和剩余上下文，数据来自 Claude Code 的 init 与 result 事件。

App 离线时先显示本地缓存。WebSocket 鉴权后收到 `transcript_snapshot`，若 daemon 已有快照则以 daemon 为准，从而补回断线期间的输出。daemon 没有快照时保留升级前的本地内容。

权限模式入口位于输入框上方。`bypassPermissions` 默认可用；电脑端用 `-DisableBypassPermissions` 或 `ALLOW_BYPASS_PERMISSIONS=0` 可关闭。开启时需手机二次确认，并且只对下一次任务生效。

## 连接状态

App 状态分两层：

| 状态 | 含义 |
|---|---|
| 已配对 | 手机本地 Secure Storage 里有 origin/token/deviceName |
| 已连接 | WebSocket 已连上 daemon 且 auth 成功 |
| 正在连接 | 已配对，正在探测 daemon 或建立 WebSocket |
| 电脑端离线 | 已配对，但 `/api/status` 或 WebSocket 连接失败 |

App 回到前台时会重新调用 `/api/status`。电脑端关闭后，App 保留配对信息，但显示“电脑端离线”，发送按钮禁用。

## 新对话

设置 sheet 里提供“开启新对话”。点击后 App 调用 `POST /api/new-conversation`，daemon 清空当前 `claudeSessionId`，App 清空当前 transcript。

## 真机验证状态

最新 Android 调试版已安装到真机。扫码配对、真实指令加载与筛选、列表滚动、流式回复、消息气泡、思考计时、工具调用、模型和剩余上下文均已完成真机验证。权限模式、工具审批卡、transcript 恢复与工作区只读抽屉已在代码落地；第二条 `--resume` 与 Stop 中断长任务仍待专项验证。
