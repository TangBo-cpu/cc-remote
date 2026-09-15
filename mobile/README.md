# CC Remote Mobile

Flutter 手机 App，用于扫码配对本机 CC Remote daemon，并远程控制本机 Claude Code CLI。

## 当前能力

App 已支持扫码确认、Secure Storage、启动恢复、WebSocket 自动重连、活动任务恢复、流式对话、停止任务、Claude / Codex 会话引擎、Codex 三档沙箱、Claude 斜杠指令与六档思考强度、Markdown 来源链接、跨项目会话搜索、模型和上下文状态同步、一次性工具审批、多项目与多会话、只读工作区、Git diff、图片与文件附件，以及 Android 后台本地通知。

仓库代码已是 Cool Glass。公开安装包仍是 `v1.3.1`；Cool Glass 含 Apple 风格设置、持久化权限模式、上下文余量、恢复对话自动定位到底部、Phosphor Fill 身份图标、助手气泡 hug 与默认 100% 阅读字号。

Composer 悬浮在 transcript 之上：列表可滚入 dock 背后，dock 使用 bounded `Liquid Strong` 玻璃以免滚动叠字掉帧；工具行为圆形附件按钮（仅附件）、思考强度仪表、模型胶囊、图标化权限入口、紧凑上下文余量，以及 `accent` 圆形发送/停止。权限图标保留完整模式 tooltip / 屏读语义和 44px 命中区；上下文使用无底色浅灰细环，深灰短弧表示已消耗比例，右侧只显示剩余百分比，完整 token 数通过 tooltip / 屏读语义提供。点击小仪表后背景整体柔焦，只保留大仪表清晰；沿圆弧滑动吸附低、中、高、超高、最大，点击中心切回自动。思考强度与 Claude Code `/effort` 对齐为六档；`max` 不保存为跨会话默认。底边平时用 `viewPadding` 抬离系统手势条，键盘打开时取消底部间隙和阴影并与 IME 连续衔接。长列表滚动侧：消息四角统一 22px，助手阅读面使用 `surfaceElevated` + 细描边气泡，短文本 hug 内容；无 soft shadow、共享 Markdown 样式表、无标记纯文本跳过 Markdown、有标记时流式期间即渲染、活动轨去掉 `IntrinsicHeight`；恢复或切换到对话时默认定位到最新消息，用户主动上翻后不会被后续刷新强制拉回。“···”菜单底栏最多保留当前模型名，并提供对应屏读语义。chrome 使用 `lucide_icons_flutter`；会话、项目与模型身份标记使用 `phosphor_icons` Fill。页面路由保留平台转场与 predictive back，bottom sheet / dialog 统一为 220ms 进入 / 160ms 退出，reduced motion 时空间动画归零；应用不打包自定义字体，UI 与助手正文使用手机系统默认字体，阅读字号默认 100%。思考态由 `CustomPainter` 绘制固定中心的花形帧动画，系统关闭动画时固定为完整花形；其他活动 running 仍使用 `CircularProgressIndicator`。项目不依赖 `flutter_animate`。

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

当前公开版本是 [`v1.3.1`](https://github.com/TangBo-cpu/cc-remote/releases/tag/v1.3.1)：

- [直接下载 Android APK](https://github.com/TangBo-cpu/cc-remote/releases/download/v1.3.1/cc-remote-v1.3.1-android.apk)

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

WebSocket 鉴权后，App 接收项目 catalog、当前 transcript、权限能力、指令、模型和上下文。发送任务时携带唯一 `promptId`、当前 `sessionId`、文本、附件 ID、权限模式、模型覆盖项和 Claude Code `effort`；daemon 接管后返回 `prompt_accepted`。

Claude 会话输入 `/` 会显示 daemon 同步的 Claude Code 指令，Codex 会话不发现斜杠指令。运行中会显示思考计时和安全化工具活动；调用 `Skill` 时会显示具体 Skill 名称。完成后临时活动收起，最终回复保留。连接异常时 WebSocket 按退避间隔自动重连；只有尚未收到确认的 Prompt 会使用同一 `promptId` 重发，daemon 去重后不会重复启动当前引擎任务。重连后再以 daemon 的 transcript snapshot 和运行状态恢复内容、活动任务与 Stop 中间态。

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

`lib/main.dart` 是应用状态和主要页面。`lib/signal_console_theme.dart` 是主题与视觉部件（含 CTA / 字体 token）。`lib/effort_gauge.dart` 是 Composer 思考强度仪表与系统级模态层。`lib/workspace_drawer.dart` 是只读工作区。`lib/attachments.dart` 是附件选择与上传。`lib/notification_service.dart` 是本地通知。UI 与助手正文使用手机系统默认字体，`pubspec.yaml` 不声明自定义正文字体，因此 Noto/LXGW 不会打包进 APK。阅读字号默认 100%。

更完整的设计和架构说明见 `../docs/mobile-ui-app-design.md`、`../docs/mobile-app-architecture.md` 和 `../docs/flutter-app-design.md`。

## 当前验证状态

`v1.3.1` 发布门禁已通过：`flutter analyze` 零问题，Flutter 137 项测试通过；daemon 测试按当前配置执行。本地 Cool Glass 构建仍用 `1.3.1+5`，覆盖安装保留配对数据；日常调试构建产物为 `app-debug.apk`。
