# CC Remote Flutter 实现说明

## 实现原则

Flutter App 是产品主入口。当前实现集中在少量文件中，优先保证状态一致、断线可恢复和真机布局稳定。

当前开发代码使用简洁的浅色 / 深色界面，默认跟随系统；视觉规范以根目录 `DESIGN.md` 和 `docs/mobile-ui-app-design.md` 为准。外观改造保留现有协议与状态行为。

## 入口与路由

`CcRemoteApp` 使用 `AppearanceController`、`AppearanceScope` 和浅深色 `ThemeData` 创建 Material App。控制器从 Secure Storage 恢复 `ThemeMode`，设置变化即时生效并串行保存，保存失败时恢复原选择。`DemoShell` 持有会话状态，监听页面前后台变化，并在 `boot`、`pair` 和 `chat` 三个路由之间切换；外观切换不替换这个子树。

启动时加载 Secure Storage、通知偏好和本地 transcript。存在已保存 session 时调用 `/api/status`，恢复电脑名、工作区、项目 catalog、活动会话、模型和上下文，再建立 WebSocket。

## 主要文件

`main.dart` 包含配对、HTTP、WebSocket、项目与会话、transcript、权限模式、主要页面和组件。`signal_console_theme.dart` 包含 `AppPalette`、浅深色主题、排版、弹层与共享组件。`appearance_preference.dart` 管理外观持久化与系统跟随。`effort_gauge.dart` 实现思考强度仪表与模态层；`workspace_drawer.dart` 实现只读文件树、文件阅读和 Git diff。附件、通知与阅读字号分别由 `attachments.dart`、`notification_service.dart` 和 `reading_font_size.dart` 管理。

## 页面与组件

`BootstrapScreen` 只显示恢复状态。`PairScreen` 负责相机扫描、紧凑横屏布局和错误恢复。`PairReviewSheet` 在换 token 前确认设备、origin 和二维码有效期。

`ChatScreen` 采用全高 `Stack` 布局，正文可向上滚动到屏幕最顶部及导航按钮背后。顶部由 `_ChatOverlayLayout` 承载：`ConnectionHeader`（菜单 + 新建/更多）使用独立 `SafeArea`，背板 `_ChatTopBackdrop` 为向下渐隐的单层模糊遮罩，不拦截手势；非 `connected` 相位时在头下方显示 `ConsoleStatusStrip`，断线时显示恢复卡片。`_ChatOverlayLayout` 动态测量遮罩高度并传递给 `TranscriptView.topPadding`，阅读字号缩放不影响导航头与状态卡片。模型选择位于输入台。“···”菜单不显示剩余上下文 token，底栏最多保留具有屏读语义的当前模型名。

`TranscriptView` 展示用户消息、助手回复、活动状态、审批卡和恢复面板。助手正文直接排在页面上，无气泡底色和外围描边；用户消息保留浅灰气泡，搜索命中仍使用临时高亮。初始列表与空状态顶部保留与遮罩高度对齐的 padding；全文搜索跳转通过 `RenderAbstractViewport` 计算并扣除顶部 overlay 遮罩高度，使命中目标停留在导航下方。无标记纯文本用 `Text`，有 Markdown 标记时流式期间即用共享 `MarkdownStyleSheet`。样式缓存按明暗分开，外观改变时重新生成缓存组件。链接只接受绝对 `http` / `https` URL，由系统浏览器打开。代码复制、全文选择和工具折叠继续可用。

`PromptBar` 使用 32px 圆角、中性玻璃表面和柔和阴影，附件按钮有独立浅灰底座，工具行不使用共同底板。保留附件、思考强度、模型、权限、上下文余量、发送和停止。思考强度模态层保留背景模糊与仪表光层，沿圆弧滑动选择五个手动档位，点击中心回到自动。模型选择器沿用 `AppOptionRow`；权限图标打开既有 sheet 并保留 bypass 二次确认、tooltip 与屏读语义。上下文百分比旁保留细环，完整 token 数在 tooltip 与屏读语义中提供。以 `/` 开头的输入仍按前缀规则筛选 daemon 同步的指令。

`PermissionRequestCard` 为全宽决策面：命令 → 工作目录（`session.workspaceDir` 或 fallback 文案）→ 影响 → 范围 →「仅本次允许」/「拒绝并返回」。

`SessionNavigatorPage` 以左侧侧边栏呼出：贴边全高的平面面板从左滑入、遮罩随路由进度渐显（220ms easeOutCubic），宽度为 min(400, 屏宽 − 64)，右侧保留一条聊天窄边，点窄边、遮罩、关闭按钮或返回手势关闭；减少动态效果时转场时长归零。当前项目会话、所有项目和全文搜索仍为三个视图；项目与会话使用扁平列表，保留原版 `AppMark.of(id, index)` 彩色会话/项目身份图标与独立蓝色导航强调色（`navigatorAccent`），项目行使用带身份色的 Lucide 标准笔画文件夹图标，选中项使用高亮底色与图标提示。新建会话仍先选择 Claude / Codex，引擎创建后不可更改。搜索保留 300ms 防抖、片段高亮、错误重试和命中消息定位。`SettingsSheet` 使用扁平分组，提供外观、模型、字号与通知；外观只有跟随系统、浅色和深色，壁纸与偏好预览已移除。`WorkspaceDrawer` 只读展示活动项目的文件与 Git diff。Bottom sheet / dialog 保留 220ms 进入 / 160ms 退出，减少动态效果时关闭空间转场。

chrome 使用 `lucide_icons_flutter`；会话、项目与模型身份标记使用 `phosphor_icons` Fill。主题不打包自定义字体，UI 与助手正文使用当前手机的系统默认字体，阅读字号默认 100%。思考态使用 `AnimationController` 驱动固定中心的花形帧动画，由 `CustomPainter` 在圆点、四瓣、六瓣和八瓣星芒间生长 / 收缩；系统关闭动画时固定为完整花形。可见计时明确标为「本轮已运行」，屏读 live region 只播报一次「正在思考」，不会随秒数重复播报。普通活动 running 继续使用 `CircularProgressIndicator`。项目不依赖 `flutter_animate`，保留 `SignalPressEffect` 等已有原生交互效果。

## 核心状态

保存的配对信息由 `SavedSession` 表示，包含 origin、token、deviceName 和 workspaceDir。项目与会话 catalog 使用 `RemoteProjectCatalog`、`RemoteProjectSummary` 和 `RemoteSessionSummary`；全文搜索摘要使用 `RemoteSessionSearchResult`，只保存会话归属、片段、高亮范围和匹配数量，不复制完整历史。

transcript 使用 `TranscriptMessage`，角色分为 user、assistant、system 和 activity。daemon 快照由 `RemoteTranscriptSnapshot` 解析，包含消息、运行状态、权限模式、Codex 沙箱模式、审批请求、引擎 session id 和 session info。

运行状态由 `connected`、`remoteOffline`、`running`、`stopping` 和 `uploadingAttachments` 等字段共同表达。`ConsolePresentation` / `ConsolePhase` 把这些事实映射为连接中、已连接、上传中、运行中、等待审批、停止中、停止未确认、已停止、执行失败、连接已断开；Header、状态条与 Composer 共用同一解析结果。停止超时是“仍在运行但最近停止请求未确认”的视图状态，不能当成已停止。

## 网络行为

配对成功后 token 写入 `flutter_secure_storage`。HTTP 使用 Bearer token。WebSocket 从扫码 origin 推导 `ws` 或 `wss` 地址，连接 ready 后先发送 `auth`。

发送任务前，App 将附件上传到当前会话，得到附件 ID，再发送 prompt。纯附件任务允许文本为空。发送后立即在本地追加用户消息和思考活动，等待 daemon 权威事件修正状态。

WebSocket 处理 `status`、`catalog`、`transcript_snapshot`、`permission_capabilities`、`permission_request`、`permission_resolved`、`permission_expired`、`commands`、`session_info`、`activity`、`text`、`done`、`stopped` 和 `error`。

会话消息必须与当前 `projectId` 和 `sessionId` 匹配。重新连接后，daemon snapshot 覆盖本地推测状态，避免重复消息或丢失断线输出。

## 权限模式

App 支持 `manual`、`acceptEdits`、`auto`、`dontAsk`、`plan` 和 `bypassPermissions`。新会话默认是 `auto`，权限模式保存在当前会话中并作用于后续各轮。权限请求仍只能允许一次或拒绝；审批呈现为独立决策面，但不能新增协议不支持的永久授权操作。

如果 daemon 关闭 bypass 能力，选择项禁用。选择 bypass 时必须弹出确认，并持续到用户切换或新建会话。

Codex 会话不使用权限模式，改用三档沙箱模式（只读 / 工作区可写 / 完全访问），由 daemon 下发的 `codexSandboxModes` 驱动选择项；选择 `danger-full-access` 发送一次后自动回落为 `read-only`。Codex 会话的附件仅允许图片，违反时提示「Codex 会话只支持图片附件」。

## 附件

附件来源包括相机、相册和文件。选择后在 Composer 上方或内部短条预览。一次最多 5 个，单个最大 25MB。上传期间禁止发送、删除附件和切换会话。

图片历史使用 daemon 鉴权 content API 加载缩略图，普通文件显示名称和大小。App 与 transcript 只保存附件描述，不保存 daemon 本机绝对路径。

## 错误与恢复

二维码格式错误、过期、网络失败和配对失败都留在 PairScreen，并提供重新扫描。HTTP 401 清除 token，回到配对页。普通网络错误保留配对和 transcript，主控制台显示电脑端离线。

运行中断线不重发已收到 `prompt_accepted` 的 prompt；未收到确认的 prompt 会在重连后使用原 `promptId` 重试。重新连接后通过 transcript snapshot 判断任务是否继续、完成或中断。Stop 进入停止中状态，禁用重复点击；收到 `stopped`、`done` 或 `error` 后恢复输入。

## 布局要求

主界面聊天视图采用全高 Stack 布局，消除原水平硬裁切，基准尺寸为 390×844，正文水平边距 8px。顶部导航与底部 Composer 悬浮于 transcript 上下两端。Composer 最小高度约 110px，视觉图标可为 36px，实际命中区至少 48px。键盘出现时 transcript 和指令建议让出空间，状态和主动作不能被遮挡。

IME 动画的真实 `viewInsets.bottom` 只用于 `AppBackground` 外层避让；聊天子树的 inset 稳定为「关闭 0 / 打开 1」两态，避免 transcript、Markdown 与 Composer 随每个高度帧重建。指令建议使用 `Flexible`，Composer 使用独立 `RepaintBoundary`。键盘打开后输入区贴合 IME 并调整底部圆角。

系统大字体、小屏、横屏和键盘场景都有回归测试。中文 UI 使用手机系统默认字体，应用不在 APK 中打包 Noto、LXGW 等正文字体；widget 测试环境的 Ahem 字体只用于布局几何。

## 测试范围

`mobile/test/widget_test.dart` 覆盖启动、配对、设置、会话搜索、工作区、消息阅读、Composer、思考仪表、权限决策、恢复状态和小屏大字体布局。键盘回归模拟连续 inset 帧，确认已打开期间消息与 Composer 实例不重复重建。`appearance_test.dart` 覆盖外观持久化、保存失败、初始化竞态、系统跟随、文字对比度、设置内切换与会话 / 草稿保留，以及 Markdown 缓存更新。实际测试总数以 `flutter test` 输出为准。

`mobile/test/attachments_test.dart` 覆盖附件上传、限制和错误清理。提交前运行：

```powershell
cd mobile
flutter analyze
flutter test
```

## 后续拆分条件

只有当 `main.dart` 的状态修改开始出现跨功能冲突，或需要独立集成测试替身时，再拆出 session controller、remote client 和 screen 文件。拆分必须保持现有协议和视觉行为，不以文件数量作为目标。
