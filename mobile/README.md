# CC Remote Mobile

Flutter 手机 App，用于扫码配对本机 CC Remote daemon，并远程控制本机 Claude Code CLI。

## 当前能力

App 已支持扫码确认、Secure Storage、启动恢复、离线重连、WebSocket 流式对话、停止任务、斜杠指令、Markdown、模型与剩余上下文、六种权限模式、一次性工具审批、多项目与多会话、只读工作区、Git diff、图片与文件附件，以及 Android 后台本地通知。

当前界面是浅色活力 Signal Console。顶部连接舱采用紧凑双栏布局，右侧显示目录、电脑、模型和上下文。中间是 transcript，底部黑色 Command Dock 负责权限、附件、输入、发送和停止。

## 开发运行

先在电脑项目目录启动 daemon：

```powershell
cc-remote
```

再运行 App：

```powershell
cd E:\Code-All\cc-remote\mobile
flutter pub get
flutter analyze
flutter test
flutter run
```

## Android 构建与安装

```powershell
cd E:\Code-All\cc-remote\mobile
flutter build apk --debug
adb devices -l
adb install -r build\app\outputs\flutter-apk\app-debug.apk
adb shell monkey -p com.example.cc_remote -c android.intent.category.LAUNCHER 1
```

连接多台设备时给 `adb` 增加 `-s <device-id>`。如果手机拦截 USB 安装，先在手机上确认安装授权，再重试相同命令。

## 配对流程

```text
扫描 daemon 终端二维码
  -> 解析并校验 PairingPayload
  -> 确认电脑名、origin 和有效期
  -> POST /api/pair
  -> 保存 origin、token 和 deviceName
  -> GET /api/status
  -> 建立 WebSocket 并发送 auth
  -> 进入主控制台
```

二维码示例：

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

## 会话流程

WebSocket 鉴权后，App 接收项目 catalog、当前 transcript、权限能力、指令、模型和上下文。发送任务时携带当前 `sessionId`、文本、附件 ID 和权限模式。

输入 `/` 会显示 daemon 同步的 Claude Code 指令。运行中会显示思考计时和安全化工具活动。完成后临时活动收起，最终回复保留。断线时不自动重发任务，重连后以 daemon 的 transcript snapshot 恢复。

项目只能从电脑端注册。App 可以切换项目与会话，并在当前项目创建新会话。运行任务或上传附件时禁止切换。

## 权限与附件

权限模式包括询问权限、自动编辑、自动判断、不询问、规划模式和跳过权限。跳过权限需要 daemon 允许，并在手机端二次确认，只影响下一次任务。

附件可以来自相机、相册或文件选择器。一次最多 5 个，单个最大 25MB。附件先上传到当前会话，再随 prompt 发送。历史图片通过鉴权接口显示预览。

## 通知

App 在后台或锁屏时可以发送任务完成、失败、停止和等待权限通知。设置中可以关闭通知，点击通知会返回对应会话。

通知依赖 App 仍有 WebSocket 连接。进程被系统彻底杀死后无法继续接收事件，后续需要 FCM。

## 连接状态

已配对表示本地保存了 origin 和 token。已连接表示 WebSocket 已完成鉴权。电脑端离线时保留配对和 transcript，禁用发送并提供重新连接。401 表示配对失效，App 会清除本地 token 并返回扫码页。

## 代码入口

`lib/main.dart` 是应用状态和主要页面。`lib/signal_console_theme.dart` 是主题与视觉部件。`lib/workspace_drawer.dart` 是只读工作区。`lib/attachments.dart` 是附件选择与上传。`lib/notification_service.dart` 是本地通知。

更完整的设计和架构说明见 `../docs/mobile-ui-app-design.md`、`../docs/mobile-app-architecture.md` 和 `../docs/flutter-app-design.md`。

## 当前验证状态

主分支通过 `flutter analyze` 和 46 项 Flutter 测试。最新版已安装到 Android 真机并检查主界面。第二轮 session resume 和 Stop 长任务仍需专项真机验证。
