# CC Remote Mobile

Flutter 手机 App，用于扫码配对本机 CC Remote daemon，并远程控制本机 Claude Code CLI。

## 当前能力

App 已支持扫码确认、Secure Storage、启动恢复、WebSocket 自动重连、活动任务恢复、流式对话、停止任务、Claude / Codex 会话引擎、Codex 默认完全访问沙箱、Codex 动态模型选择与独立偏好持久化、斜杠指令（Claude Code 原生指令；Codex 会话原生 /compact、/review 与已启用 skills）、六档思考强度、Markdown 来源链接、跨项目会话搜索、模型和上下文状态同步、一次性工具审批、多项目与多会话、只读工作区、Git diff、图片与文件附件，以及 Android 后台本地通知。

v1.5.0 使用浅色 / 深色界面，默认跟随系统，可在设置中固定外观。外观选择本地持久化，切换时保留会话与草稿。输入区、浮动控件和面板使用中性玻璃材质；壁纸、背景预设与偏好预览已移除。

ChatScreen 顶部导航与状态条浮动在对话上方，背板带渐隐模糊，transcript 可向上滚动至屏幕顶部；初始位置留出导航与恢复卡片间距，搜索跳转自动避让顶部遮罩。Composer 悬浮在 transcript 底部，使用 32px 圆角、中性玻璃表面与柔和阴影。会话导航列表保留彩色身份标记与蓝色导航强调色。附件按钮有独立浅灰底座，工具行保留附件、思考强度、模型、权限、上下文余量和发送 / 停止；实际命中区至少 48px。思考强度仍支持自动与五个手动档位，沿圆弧滑动选择，点击中心回到自动；`max` 不保存为跨会话默认。键盘打开时输入区贴合 IME，消息列表只缩短可见高度。助手正文直接排在页面上，用户消息保留浅灰气泡，Markdown、代码复制、工具折叠和阅读字号继续可用；正文使用手机系统默认字体，阅读字号默认 100%。页面保留平台转场、predictive back 与减少动态效果支持。

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

当前公开版本是 [`v1.5.0`](https://github.com/TangBo-cpu/cc-remote/releases/tag/v1.5.0)：

- [直接下载 Android APK](https://github.com/TangBo-cpu/cc-remote/releases/download/v1.5.0/cc-remote-v1.5.0-android.apk)

下载后在 Android 手机上允许当前来源安装未知应用，并打开 APK 完成安装。APK 沿用 v1.4.0 的包名与测试签名；已有安装请直接覆盖更新，不要先卸载。此签名供个人使用，不应作为应用商店正式签名。

## Android 调试构建

```powershell
cd C:\Projects\cc-remote\mobile
flutter build apk --debug
adb devices -l
adb -s <device-id> install -r -t build\app\outputs\flutter-apk\app-debug.apk
adb -s <device-id> shell monkey -p com.example.cc_remote -c android.intent.category.LAUNCHER 1
```

用 `adb devices -l` 确认设备 ID 后替换 `<device-id>`。更新时使用 `install -r -t` 保留配对 token、数据与设置；不要用 `flutter install` 更新已安装应用。如果手机拦截 USB 安装，在手机上确认授权后重试相同命令。

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

输入 `/` 时按会话动态获取指令：Claude 会话展示 Claude Code 指令；Codex 会话按需获取原生指令（`/compact` 压缩上下文、`/review` 代码审查）以及当前项目已启用的 skills，支持搜索、补全和失败重试。运行中会显示思考计时和安全化工具活动；调用 `Skill` 时会显示具体 Skill 名称。完成后保留内联过程与最终回复，可手动收起。连接异常时 WebSocket 按退避间隔自动重连；每次连接首次完成鉴权后，尚未收到确认的 Prompt 会使用同一 `promptId` 重发，普通 `status` 广播不会再次触发重发。daemon 在当前收据缓存内去重；这不保证跨 daemon 重启只执行一次。重连后再以 daemon 的 transcript snapshot 和运行状态恢复内容、活动任务与 Stop 中间态。

思考和工具调用直接排在消息流中，默认显示已有内容与命令详情；点击标题只在原地折叠或展开。过程文字使用 13 号，回复正文使用 15 号，均跟随系统字号。命令可以选择复制，文件路径仍可打开工作区。工具保留彩色图标、Skill 名称、运行状态和耗时；思考花朵动画与计时独立于工具历史，折叠历史不会隐藏当前思考状态。减少动态效果时使用静态花形。

项目只能从电脑端注册：在目标目录运行 `cc-remote`，或 daemon 已在跑时再执行一次。App 可以切换已注册项目与会话，并在当前项目创建新会话，但不能添加任意磁盘路径。运行任务或上传附件时禁止切换。

## 权限与附件

权限模式包括询问权限、自动编辑、自动判断、不询问、规划模式和跳过权限。跳过权限需要 daemon 允许，并在手机端二次确认，只影响下一次任务。

附件可以来自相机、相册或文件选择器。一次最多 5 个，单个最大 25MB。附件先上传到当前会话，再随 prompt 发送。历史图片通过鉴权接口显示预览。

## 通知

App 在后台或锁屏时可以发送任务完成、失败、停止和等待权限通知。设置中可以关闭通知，点击通知会返回对应会话。

通知依赖 App 仍有 WebSocket 连接。进程被系统彻底杀死后无法继续接收事件，后续需要 FCM。

## 连接状态

已配对表示本地保存了 origin 和 token。已连接表示 WebSocket 已完成鉴权。连接建立中（已配对但尚未 `wsReady`，且非电脑端离线）显示状态条「正在连接」与 transcript 连接中空状态卡。电脑端离线时保留配对和 transcript，禁用发送并提供重新连接。401 表示配对失效，App 会清除本地 token 并返回扫码页。

- 启动时 `/api/status` 发生非 401 失败，App 保留配对和 transcript，并启动 WebSocket 自动恢复。
- 回到前台时先恢复或检查 WebSocket，已鉴权连接不再额外请求 HTTP 状态；连接未就绪时通过 HTTP 补充状态。手动刷新仍请求 HTTP。健康连接不会因为后台停留较久或 HTTP 失败而被直接替换。
- daemon 声明支持存活探测后，App 用 `ping` / `pong` 检查连接，默认 8 秒超时后进入退避重连；同一连接上的并发探测会合并。恢复前台时保留现有连接，用 8 秒探测窗口确认存活，不因隧道延迟误断健康连接，失败后立即重连。无连接时跳过退避立即重试，已经开始的握手继续完成，避免切回时取消自动重连。旧服务端未声明能力时，继续使用原有重连机制。
- WebSocket 完成鉴权即更新在线状态，不依赖当前会话的业务状态帧。迟到的 HTTP 响应不会覆盖已鉴权连接的最新任务、模型、项目目录和工作区状态。

## 代码入口

`lib/main.dart` 是应用状态和主要页面。`lib/signal_console_theme.dart` 是主题与视觉部件（含 CTA / 字体 token）。`lib/effort_gauge.dart` 是 Composer 思考强度仪表与系统级模态层。`lib/workspace_drawer.dart` 是只读工作区。`lib/attachments.dart` 是附件选择与上传。`lib/notification_service.dart` 是本地通知。UI 与助手正文使用手机系统默认字体，`pubspec.yaml` 不声明自定义正文字体，因此 Noto/LXGW 不会打包进 APK。阅读字号默认 100%。

更完整的设计和架构说明见 `../docs/mobile-ui-app-design.md`、`../docs/mobile-app-architecture.md` 和 `../docs/flutter-app-design.md`。

## 验证与发布状态

v1.5.0 安装包版本为 `1.5.0+8`。APK 以 release 模式构建，覆盖更新沿用配对数据；日常调试构建产物为 `app-debug.apk`。

连接恢复回归位于 `test/connection_stability_test.dart`、`test/websocket_client_test.dart` 和 `test/websocket_transport_test.dart`，覆盖启动离线、前后台恢复、HTTP 与 WebSocket 状态竞争、鉴权就绪及真实回环连接。可在 `mobile` 目录运行：

```powershell
flutter test --no-pub
flutter analyze --no-pub --no-fatal-infos
```

此版本同步 Android 与 daemon 源码。存活探测需要 App 与 daemon 都支持新协议；手机 Claude 会话进入原生 `claude -r` 恢复列表也需要更新并重启 daemon。Wi-Fi / 蜂窝切换、锁屏、电脑休眠唤醒和长时间运行仍需真机验证。

上一轮完整 Flutter 测试结果为 286 项通过、11 项失败，失败涉及其他界面的配色、输入区和复制菜单等断言。尚未完成真机安装和界面验收；本次构建与回归验证结果见 v1.5.0 Release 说明。
