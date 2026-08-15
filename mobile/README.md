# CC Remote Mobile

Flutter 手机 App，用于扫码配对本机 CC Remote daemon，并远程控制本机 Claude Code CLI。

## 当前能力

App 已支持扫码确认、Secure Storage、启动恢复、WebSocket 自动重连、活动任务恢复、流式对话、停止任务、斜杠指令、Markdown、模型选择与上下文状态同步、六种权限模式、一次性工具审批、多项目与多会话、只读工作区、Git diff、图片与文件附件，以及 Android 后台本地通知。

`v1.2.0` 已发布“暖纸控制台 / Warm Console”主界面：Claude 风格的分离式顶部浮动控制、非已连接相位的 `ConsoleStatusStrip`、内容优先 transcript（更宽助手 elevated 气泡 + 衬线）、连续字号滑杆（默认约 95%）、轻拟态抬升、连接中/离线分空状态、权限卡工作目录、分层活动状态、Warm Console 设置与菜单，以及贴底的暖白 Composer（`terracotta-deep` 发送/停止）。

Composer 底栏使用圆形扩展按钮、暖色模型胶囊和 `terracotta-deep` 圆形发送/停止按钮，不显示剩余上下文 token。“···”菜单底栏最多保留当前模型名，并提供对应屏读语义。主界面和工作区统一使用 `lucide_icons_flutter`；字体打包 `NotoSerifSC` 于 `fonts/`（UI 与助手统一衬线）。思考态是原生脉冲 brain 图标，活动 running 状态仍使用 `CircularProgressIndicator`。项目不依赖 `flutter_animate`。

## 开发运行

先在电脑项目目录启动 daemon：

```powershell
cc-remote
```

再运行 App：

```powershell
cd C:\Projects\cc-remote\mobile
flutter pub get
flutter analyze
flutter test
flutter run
```

## Android 安装

当前公开版本是 [`v1.2.0`](https://github.com/TangBo-cpu/cc-remote/releases/tag/v1.2.0)：

- [直接下载 Android APK](https://github.com/TangBo-cpu/cc-remote/releases/download/v1.2.0/cc-remote-v1.2.0-android.apk)

下载后在 Android 手机上允许当前来源安装未知应用，并打开 APK 完成安装。当前 APK 使用测试签名，适合个人测试，不应作为应用商店正式包分发。

## Android 调试构建

```powershell
cd C:\Projects\cc-remote\mobile
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
  "origin": "https://cc-remote.example.com",
  "nonce": "...",
  "deviceName": "My PC",
  "expiresAt": 1780000000000
}
```

## 会话流程

WebSocket 鉴权后，App 接收项目 catalog、当前 transcript、权限能力、指令、模型和上下文。发送任务时携带唯一 `promptId`、当前 `sessionId`、文本、附件 ID 和权限模式；daemon 接管后返回 `prompt_accepted`。

输入 `/` 会显示 daemon 同步的 Claude Code 指令。运行中会显示思考计时和安全化工具活动；调用 `Skill` 时会显示具体 Skill 名称。完成后临时活动收起，最终回复保留。连接异常时 WebSocket 按退避间隔自动重连；只有尚未收到确认的 Prompt 会使用同一 `promptId` 重发，daemon 去重后不会重复启动 Claude。重连后再以 daemon 的 transcript snapshot 和运行状态恢复内容、活动任务与 Stop 中间态。

项目只能从电脑端注册：在目标目录运行 `cc-remote`，或 daemon 已在跑时再执行一次。App 可以切换已注册项目与会话，并在当前项目创建新会话，但不能添加任意磁盘路径。运行任务或上传附件时禁止切换。

## 权限与附件

权限模式包括询问权限、自动编辑、自动判断、不询问、规划模式和跳过权限。跳过权限需要 daemon 允许，并在手机端二次确认，只影响下一次任务。

附件可以来自相机、相册或文件选择器。一次最多 5 个，单个最大 25MB。附件先上传到当前会话，再随 prompt 发送。历史图片通过鉴权接口显示预览。

## 通知

App 在后台或锁屏时可以发送任务完成、失败、停止和等待权限通知。设置中可以关闭通知，点击通知会返回对应会话。

通知依赖 App 仍有 WebSocket 连接。进程被系统彻底杀死后无法继续接收事件，后续需要 FCM。

## 连接状态

已配对表示本地保存了 origin 和 token。已连接表示 WebSocket 已完成鉴权。连接建立中（已配对但尚未 `wsReady`，且非电脑端离线）显示状态条「正在连接」与 transcript 连接中空状态卡。电脑端离线时保留配对和 transcript，禁用发送并提供重新连接。401 表示配对失效，App 会清除本地 token 并返回扫码页。

## 代码入口

`lib/main.dart` 是应用状态和主要页面。`lib/signal_console_theme.dart` 是主题与视觉部件（含 CTA / 字体 token）。`lib/workspace_drawer.dart` 是只读工作区。`lib/attachments.dart` 是附件选择与上传。`lib/notification_service.dart` 是本地通知。`fonts/` 为打包的 Noto 子集。

更完整的设计和架构说明见 `../docs/mobile-ui-app-design.md`、`../docs/mobile-app-architecture.md` 和 `../docs/flutter-app-design.md`。

## 当前验证状态

当前开发代码通过 `flutter analyze`；`mobile/test/` 合计约 90 项测试（含连接中状态条/空状态、权限工作目录与 fallback）。开发 release 已装 Android 真机；本轮 Warm Console a11y/UX 改动的逐屏视觉清单仍待勾选。第二轮 session resume 与 Stop 长任务均已完成真机验证，Stop 后 daemon 没有残留 Claude 子进程。
