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

未实现：

- transcript 持久化。
- 断线期间输出恢复。
- 多设备管理。
- 手机端权限审批流。

## 运行

电脑端优先使用一键命令：

```powershell
cc-remote
```

如果全局命令不可用，在项目根目录运行：

```powershell
.\cc-remote.cmd
```

手机端调试运行：

```powershell
cd E:\Code-All\cc-remote\mobile
flutter pub get
flutter analyze
flutter test
flutter run
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
send { "type": "prompt", "text": "..." }
append server text events
handle done/error/stopped
send { "type": "stop" }
```

## 连接状态

App 状态分两层：

| 状态 | 含义 |
|---|---|
| 已配对 | 手机本地 Secure Storage 里有 origin/token/deviceName |
| 已连接 | WebSocket 已连上 daemon 且 auth 成功 |
| 正在连接 | 已配对，正在探测 daemon 或建立 WebSocket |
| 电脑端离线 | 已配对，但 `/api/status` 或 WebSocket 连接失败 |

App 回到前台时会重新调用 `/api/status`。电脑端关闭后，App 保留配对信息，但显示“电脑端离线”，发送按钮禁用。

## 下一步真机验证

发送：

```text
回复 pong，只输出 pong
```

确认：

- App 显示真实 Claude Code 输出。
- App 收到 `done`。
- daemon 写入 `.data/state.json` 的 `claudeSessionId`。
- 第二条 prompt 使用 `--resume <claudeSessionId>` 生效。
- Stop 可以中断长任务。
