# CC Remote Flutter App 设计架构

## 1. 产品定位

Flutter App 是 CC Remote 的主入口，不是网页壳。

目标体验：

```text
电脑启动 daemon
  -> 本地终端显示二维码
  -> 手机 App 扫码配对
  -> App 连接 tbhaoshuai.ccwu.cc
  -> Cloudflare Tunnel 转发到电脑本地 daemon
  -> daemon 调用本机 Claude Code
  -> App 显示 Claude Code 流式输出并可 Stop
```

第一版只做一台电脑、一个授权 token、一个 Claude Code session。

## 2. MVP 范围

### 必须有

- 扫码配对。
- 安全保存 token。
- 自动恢复已配对状态。
- WebSocket 连接 daemon。
- 发送 prompt。
- 流式显示 Claude 输出。
- Stop 当前任务。
- Logout / 清除配对。
- 基础错误展示和手动重连。

### 暂不做

- 多电脑管理。
- 多项目目录切换。
- 文件上传/下载。
- 历史记录云同步。
- 推送通知。
- 权限审批 UI。
- 后台长时间保活。
- 复杂状态管理框架。

## 3. 技术选型

| 能力 | 推荐方案 | 说明 |
|---|---|---|
| App 框架 | Flutter | Android/iOS 一套代码，适合后续打包 |
| 扫码 | `mobile_scanner` | 简单稳定，支持二维码 |
| 安全存储 | `flutter_secure_storage` | iOS Keychain / Android Keystore |
| HTTP | `http` | MVP 足够 |
| WebSocket | `web_socket_channel` | Dart 官方生态常用库 |
| 状态管理 | `ChangeNotifier` + `ValueNotifier` | MVP 足够，不先引入 Riverpod/Bloc |
| 路由 | `Navigator` | 两三个页面不用上复杂路由 |

推荐依赖：

```yaml
dependencies:
  flutter:
    sdk: flutter
  mobile_scanner: ^6.0.0
  flutter_secure_storage: ^9.2.0
  http: ^1.2.0
  web_socket_channel: ^3.0.0
```

## 4. 目录结构

```text
mobile/
  pubspec.yaml
  lib/
    main.dart
    app.dart

    screens/
      bootstrap_screen.dart
      pair_screen.dart
      chat_screen.dart
      settings_screen.dart

    services/
      token_store.dart
      pairing_service.dart
      remote_api.dart
      remote_ws.dart

    models/
      pairing_payload.dart
      pairing_result.dart
      server_message.dart
      chat_message.dart
      app_status.dart

    controllers/
      session_controller.dart
      chat_controller.dart

    widgets/
      status_banner.dart
      transcript_view.dart
      prompt_bar.dart
      message_bubble.dart
```

### 分层原则

```text
screens      只负责 UI 组合和用户交互
controllers 负责页面状态和调用 service
services    负责网络、存储、协议
models      负责数据结构和 JSON 解析
widgets     纯 UI 小组件
```

不要在 widget 里直接写 HTTP/WebSocket 细节。

## 5. 页面设计

### 5.1 BootstrapScreen

启动页，决定进入哪个页面。

职责：

1. 从 Secure Storage 读取 token。
2. 如果没有 token，进入 `PairScreen`。
3. 如果有 token，调用 `/api/status`。
4. status 成功，进入 `ChatScreen`。
5. status 失败，清 token 或提示重新配对。

UI：

```text
CC Remote
正在检查连接…
```

### 5.2 PairScreen

扫码配对页。

UI：

```text
CC Remote

扫描电脑终端里的二维码

[打开扫码]

说明：
1. 在电脑上启动 cc-remote daemon
2. 确保 Cloudflare Tunnel 指向本机 127.0.0.1:8787
3. 扫描终端二维码完成配对
```

交互：

- 点击“打开扫码”进入相机扫码视图。
- 扫到二维码后暂停扫描。
- 解析 payload。
- 调用 `/api/pair`。
- 成功后保存 token，进入 `ChatScreen`。
- 失败则显示错误并允许重新扫码。

### 5.3 ChatScreen

主控制页。

UI：

```text
顶部：
  Jayson PC · 已连接 / 运行中 / 已断开
  [设置]

中间：
  transcript 消息列表

底部：
  多行输入框
  [发送] [停止]
```

交互：

- 发送 prompt 后：
  - 添加 user message。
  - 禁用发送按钮。
  - 启用 Stop。
  - WebSocket 发送 `{ type: "prompt", text }`。
- 收到 `text`：
  - 追加到当前 assistant message。
- 收到 `done`：
  - 标记当前 assistant message 完成。
  - 启用发送按钮。
  - 禁用 Stop。
- 收到 `stopped`：
  - 标记当前 assistant message 为已停止。
- 断线：
  - 显示断线状态。
  - 不自动重发 prompt。
  - 给“重新连接”入口。

### 5.4 SettingsScreen

设置页。

MVP 只放：

```text
电脑：Jayson PC
服务地址：https://tbhaoshuai.ccwu.cc
状态：已连接

[重新连接]
[退出配对]
```

退出配对：

1. 调用 `POST /api/logout`。
2. 本地删除 token。
3. 关闭 WebSocket。
4. 回到 `PairScreen`。

## 6. 状态机

App 全局状态：

```text
booting
  -> unpaired
  -> pairing
  -> paired
  -> connecting
  -> connected
  -> running
  -> disconnected
  -> error
```

状态含义：

| 状态 | 含义 | UI 行为 |
|---|---|---|
| `booting` | 启动检查 token | 显示加载 |
| `unpaired` | 没有 token | 显示扫码页 |
| `pairing` | 正在换 token | 显示配对中 |
| `paired` | 有 token 但未连 WS | 准备连接 |
| `connecting` | 正在连 WS | 禁用输入 |
| `connected` | WS 已鉴权 | 可发送 prompt |
| `running` | Claude 正在执行 | 禁用发送，启用 Stop |
| `disconnected` | WS 断开 | 显示重连 |
| `error` | 当前操作失败 | 显示错误 |

MVP 不做自动任务恢复：断线期间 Claude 可能还在跑，但 App 不保证补回输出。

## 7. 数据模型

### 7.1 PairingPayload

二维码 JSON：

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

Dart model：

```dart
class PairingPayload {
  final String type;
  final int version;
  final Uri origin;
  final String nonce;
  final String deviceName;
  final DateTime expiresAt;
}
```

校验规则：

- `type == "cc-remote-pair"`
- `version == 1`
- `origin.scheme == "https"`
- `nonce.isNotEmpty`
- `expiresAt` 晚于当前时间

### 7.2 PairingResult

```dart
class PairingResult {
  final String token;
  final String deviceName;
  final Uri origin;
}
```

### 7.3 ChatMessage

```dart
enum ChatRole { user, assistant, system }

enum ChatMessageState { streaming, done, stopped, error }

class ChatMessage {
  final String id;
  final ChatRole role;
  final String text;
  final ChatMessageState state;
  final DateTime createdAt;
}
```

MVP 可以只放内存，不持久化 transcript。

### 7.4 ServerMessage

WebSocket 服务端消息：

```dart
sealed class ServerMessage {}

class StatusMessage extends ServerMessage {
  final bool authenticated;
  final bool running;
  final bool hasClaudeSessionId;
}

class TextMessage extends ServerMessage {
  final String text;
}

class DoneMessage extends ServerMessage {
  final int? exitCode;
  final String? claudeSessionId;
}

class StoppedMessage extends ServerMessage {}

class ErrorMessage extends ServerMessage {
  final String message;
}
```

如果 Dart sealed class 写起来麻烦，MVP 可以先用普通 enum + data class，不强求。

## 8. Service 设计

### 8.1 TokenStore

职责：安全保存 token 和 origin。

接口：

```dart
class TokenStore {
  Future<SavedSession?> load();
  Future<void> save(SavedSession session);
  Future<void> clear();
}
```

保存内容：

```json
{
  "origin": "https://tbhaoshuai.ccwu.cc",
  "token": "...",
  "deviceName": "Jayson PC"
}
```

实现：`flutter_secure_storage`。

### 8.2 PairingService

职责：解析二维码并换取 token。

接口：

```dart
class PairingService {
  Future<PairingPayload> parseQr(String raw);
  Future<PairingResult> pair(PairingPayload payload);
}
```

请求：

```http
POST {origin}/api/pair
Content-Type: application/json

{
  "nonce": "...",
  "appName": "CC Remote",
  "platform": "android"
}
```

### 8.3 RemoteApi

职责：普通 HTTP API。

接口：

```dart
class RemoteApi {
  Future<RemoteStatus> status(SavedSession session);
  Future<void> stop(SavedSession session);
  Future<void> logout(SavedSession session);
}
```

请求头：

```http
Authorization: Bearer <token>
```

### 8.4 RemoteWs

职责：WebSocket 生命周期和协议。

接口：

```dart
class RemoteWs {
  Stream<ServerMessage> get messages;

  Future<void> connect(SavedSession session);
  void sendPrompt(String text);
  void stop();
  Future<void> close();
}
```

连接流程：

```text
connect wss://host/ws
  -> send { type: "auth", token }
  -> wait status authenticated=true
  -> ready
```

不在 URL query 里放 token。

## 9. Controller 设计

### 9.1 SessionController

管理 App 是否已配对、当前电脑信息、连接状态。

职责：

- 启动时加载 token。
- status 检查。
- 配对成功后保存 session。
- logout 后清理 session。

核心状态：

```dart
class SessionState {
  final AppStatus status;
  final SavedSession? session;
  final String? error;
}
```

### 9.2 ChatController

管理 WebSocket 和消息流。

职责：

- 连接 WS。
- 发送 prompt。
- 收流式 text。
- stop。
- 断线处理。

核心状态：

```dart
class ChatState {
  final bool connected;
  final bool running;
  final List<ChatMessage> messages;
  final String? error;
}
```

MVP 用 `ChangeNotifier`：

```dart
class ChatController extends ChangeNotifier {}
```

## 10. 网络错误处理

### Pairing 错误

| 错误 | UI 文案 |
|---|---|
| QR 格式错误 | 这不是 CC Remote 配对二维码 |
| QR 过期 | 配对二维码已过期，请重新启动或刷新电脑端二维码 |
| 网络失败 | 无法连接电脑，请检查 Cloudflare Tunnel |
| 401 | 配对码无效或已使用 |
| 5xx | 电脑端 daemon 出错 |

### WebSocket 错误

| 错误 | UI 行为 |
|---|---|
| 连接失败 | 显示“重新连接” |
| auth 失败 | 清 token，回到配对页 |
| 运行中断线 | 不自动重发 prompt，提示输出可能不完整 |
| stop 失败 | 显示错误，不清空 transcript |

## 11. UI 细节

### 11.1 ChatScreen 布局

```text
┌─────────────────────────┐
│ Jayson PC        设置    │
│ 已连接 / 运行中           │
├─────────────────────────┤
│ user: ...               │
│ assistant: ...          │
│ assistant streaming...  │
├─────────────────────────┤
│ 输入框                  │
│ [发送] [停止]            │
└─────────────────────────┘
```

### 11.2 输入框规则

- 支持多行。
- 空内容不能发送。
- `running` 时禁止发送。
- Stop 只在 `running` 时启用。
- 发送后不自动清 transcript，只清输入框。

### 11.3 Transcript 规则

- user 消息右侧。
- assistant 消息左侧。
- system 消息居中小字。
- `text` event 追加到当前 assistant 消息。
- `done` 后 assistant message 状态变 done。
- `stopped` 后状态变 stopped。

## 12. 安全设计

- token 只存在 Secure Storage。
- 不把 token 打印到日志。
- 不把 token 放 WebSocket URL。
- QR payload 里只有一次性 nonce，没有长期 secret。
- App logout 时同时调用 daemon logout 和本地清理。
- auth 失败时立即清理本地 token。
- App 不提供修改 `WORKSPACE_DIR` 的入口。
- App 不提供任意 shell 命令入口。

## 13. 与 daemon 的配套改造

当前 daemon 已完成 App/token 主协议。

已完成：

- [x] `/api/pair` 返回 token，不再设置 cookie。
- [x] `AuthState` 提供 `verifyBearerToken()` 和 `verifyToken()`。
- [x] `AuthState` 保留 token hash，不保存 token 明文。
- [x] WebSocket 支持第一条 `auth` 消息。
- [x] 未 auth 的 WebSocket 不接受 `prompt` / `stop`。
- [x] QR 生成 JSON payload。
- [x] logout 清 token hash、递增 authGeneration、关闭旧 WS。
- [x] auth state 写入串行化，避免并发写 `.data/state.json` 临时文件 race。
- [x] stale Claude Code session 自动清理并重试新会话。
- [x] 电脑端一键启动命令 `cc-remote` / `.\cc-remote.cmd`。

保留：

- [x] `web/` 调试页，但不作为主产品入口。

## 14. 实现顺序

### Step 1：daemon 协议迁移（已完成）

- 改 `/api/pair` 返回 token。
- 改 QR payload 为 JSON。
- 改 WS auth 消息。
- 保留现有 Claude bridge。
- 修复 auth state 并发写 race。
- stale Claude Code session 自动清理并重试新会话。
- 添加电脑端一键启动命令。
- 跑 `npm run typecheck && npm run build && npm test`。

### Step 2：创建 Flutter 项目（已完成）

```powershell
flutter create mobile
```

加依赖：

```powershell
cd mobile
flutter pub add mobile_scanner flutter_secure_storage web_socket_channel http
```

### Step 3：实现配对（已完成）

- `PairingPayload.fromJson`
- `PairingService.pair`
- `TokenStore.save`
- `PairScreen` 扫码

成功标准：

```text
电脑终端二维码 -> 手机扫码 -> App 显示已连接 Jayson PC
```

### Step 4：实现 WebSocket 聊天（已完成，真机 Claude 输出待验证）

- `RemoteWs.connect`
- auth 消息
- prompt 消息
- text/done/stopped/error 解析
- `ChatScreen` transcript

成功标准：

```text
App 发 prompt -> 电脑 Claude Code 执行 -> App 流式显示输出
```

### Step 5：Stop、Logout 和离线状态（已完成，Stop 真机中断待验证）

- Stop 当前任务。
- Logout 撤销 token。
- auth 失败回到 PairScreen。

成功标准：

```text
Stop 可中断长任务
Logout 后旧 App 不能继续控制电脑
```

## 15. 第一版验收标准

- [x] 电脑端 daemon 终端显示 JSON payload 二维码。
- [x] Flutter App 可扫码并配对。
- [x] token 存入 Secure Storage。
- [x] 关闭重开 App 后自动恢复已配对状态。
- [x] daemon 离线时 App 显示“电脑端离线”。
- [x] App 可发送 prompt 到 WebSocket。
- [ ] App 可在真机显示 Claude 真实流式输出。
- [ ] App 可真机 Stop Claude 长任务。
- [x] App 可 Logout。
- [x] Logout 后旧 WebSocket 失效。
- [x] daemon 仍只监听 `127.0.0.1`。
- [x] Cloudflare Tunnel 指向 `127.0.0.1:8787`。

## 16. 后续增强

第一版跑通后再考虑：

- 多电脑管理。
- 给电脑设置别名。
- transcript 本地持久化。
- 文件上传。
- 权限审批 UI。
- 后台通知。
- App deep link。
- 桌面托盘二维码窗口。
- Cloudflare Access 额外保护。
