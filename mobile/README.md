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
- 聊天 UI 壳。

未实现：

- WebSocket 对话。
- 发送 prompt 到 daemon。
- 接收 Claude Code 流式输出。
- Stop 真实中断 daemon 任务。

当前聊天页里的回复是本地占位，不是 Claude Code 输出。

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

## 下一步：真实对话

需要新增 `web_socket_channel`，然后实现：

```text
connect wss://tbhaoshuai.ccwu.cc/ws
send { "type": "auth", "token": "..." }
wait status authenticated=true
send { "type": "prompt", "text": "..." }
append server text events
handle done/error/stopped
send { "type": "stop" }
```
