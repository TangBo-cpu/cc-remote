# CC Remote Mobile

Flutter 手机 App，用于扫码配对本机 CC Remote daemon。

## 当前状态

已实现：

- 扫描 daemon 终端二维码。
- 解析 `cc-remote-pair` JSON payload。
- 显示配对确认 sheet。
- 调用 `POST /api/pair` 换取 token。
- 用 `flutter_secure_storage` 保存 token。
- 启动时读取 token 并调用 `/api/status`。
- 显示已连接设备和工作区。
- Logout 调用 `/api/logout` 并清本地 token。
- 连接 daemon WebSocket。
- 发送首条 auth 消息。
- 发送 prompt 到 daemon。
- 接收 Claude Code `text`、`done`、`error`、`stopped` 消息。
- Stop 发送 `{ "type": "stop" }`。

未实现：

- transcript 持久化。
- 断线期间输出恢复。
- 多设备管理。

## 运行

```powershell
cd E:\Code-All\cc-remote\mobile
flutter pub get
flutter test
flutter run
```

电脑端同时需要启动 daemon：

```powershell
cd E:\Code-All\cc-remote
$env:PUBLIC_ORIGIN = "https://tbhaoshuai.ccwu.cc"
$env:WORKSPACE_DIR = "E:\Code-All\cc-remote"
$env:DEVICE_NAME = "tb"
npm run dev
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

下一步真机验证：发送 `回复 pong，只输出 pong`，确认 App 显示真实 Claude Code 输出。
