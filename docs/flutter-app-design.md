# CC Remote Flutter 实现说明

## 实现原则

Flutter App 是产品主入口。当前实现集中在少量文件中，优先保证状态一致、断线可恢复和真机布局稳定。

当前开发代码已实现 Cool Glass 主界面，视觉规范以根目录 `DESIGN.md` 和 `docs/mobile-ui-app-design.md` 为准。界面改造保持本节描述的协议与状态行为，不把尚无数据来源的文案写成事实。

## 入口与路由

`CcRemoteApp` 创建 Material App 和当前主题。`DemoShell` 持有应用级状态，监听页面前后台变化，并在 `boot`、`pair` 和 `chat` 三个路由之间切换。

启动时加载 Secure Storage、通知偏好和本地 transcript。存在已保存 session 时调用 `/api/status`，恢复电脑名、工作区、项目 catalog、活动会话、模型和上下文，再建立 WebSocket。

## 主要文件

`main.dart` 包含配对、HTTP、WebSocket、项目与会话、transcript、权限模式、主要页面和组件。`signal_console_theme.dart` 包含 Cool Glass 的颜色、字体、圆角、弹层主题、动效和视觉基础部件（含共享 `AppOptionRow`）。`effort_gauge.dart` 实现 Composer 思考强度仪表与系统级模态层。`workspace_drawer.dart` 实现文件树、文件阅读和 Git diff。`attachments.dart` 实现相机、相册、文件选择与 multipart 上传。`notification_service.dart` 封装 Android 本地通知和偏好保存。`reading_font_size.dart` 保存连续阅读字号，默认 `1.0`。

## 页面与组件

`BootstrapScreen` 只显示恢复状态。`PairScreen` 负责相机扫描、紧凑横屏布局和错误恢复。`PairReviewSheet` 在换 token 前确认设备、origin 和二维码有效期。

`ChatScreen` 由 `ConnectionHeader`、可选 `ConsoleStatusStrip`、`TranscriptView` 和 `PromptBar` 组成。`ConnectionHeader` 是分离式紧凑会话头（菜单 + 新建/更多），不在 chrome 内堆连接文案；非 `connected` 相位时在头下方显示 `ConsoleStatusStrip`。模型选择位于输入台。“···”菜单不显示剩余上下文 token，底栏最多保留具有屏读语义的当前模型名。

`TranscriptView` 展示用户消息、Claude 回复（`AssistantBubbleFrame`：`surfaceElevated` + 细描边，短文本 hug；无标记纯文本用 `Text`，有 Markdown 标记时流式期间即用共享 `MarkdownStyleSheet`）、活动状态、审批卡，以及空状态下的连接中卡 / 离线重连卡 / 已连接快捷芯片。助手 Markdown 链接只接受绝对 `http` / `https` URL，点击后由 `url_launcher` 交给系统浏览器；无效协议保持不可跳转。`MessageBlock` 与附件组件负责历史内容。`ActivityBlock` 合并思考和工具活动，任务结束后清理临时活动。

`PromptBar` 处理权限模式、附件预览、多行输入、思考强度、模型选择、上下文余量、发送和停止。当前为叠在 transcript 上的 bounded `Liquid Strong` Composer：上方输入，下方工具行依次为圆形附件 `+`、思考强度小仪表、模型胶囊、图标化权限入口、紧凑上下文百分比，以及 `accent` 圆形发送/停止。点击小仪表后页面整体柔焦，只保留悬浮大仪表清晰；沿圆弧滑动吸附低、中、高、超高、最大，点击中心切回自动，松手后写入既有偏好。模型选择器使用共享 `AppOptionRow` sheet 与 Phosphor Fill 身份图标。`+` 只开附件；权限图标点开既有 sheet（含 bypass 二次确认），并保留当前模式的 tooltip / 屏读语义。上下文余量使用无底色浅灰细环，深灰短弧表示已消耗比例，右侧只显示剩余百分比；完整 token 数通过 tooltip / 屏读语义提供，不影响指令建议区高度。输入以 `/` 开头且没有空格时，`CommandSuggestions` 继续按前缀优先规则筛选 daemon 同步的 Claude Code 指令。

`PermissionRequestCard` 为全宽决策面：命令 → 工作目录（`session.workspaceDir` 或 fallback 文案）→ 影响 → 范围 →「仅本次允许」/「拒绝并返回」。

`SessionNavigatorPage` 通过 reduced-motion aware 的 `AppMaterialPageRoute` 进入，正常情况委托 Android predictive back / iOS Cupertino 平台转场，系统减少动态效果时路由时长归零。页面使用白色 `Scaffold`、系统返回、顶部搜索和 38px 视觉圆 / 48px 命中区的新建操作。默认视图展示当前项目会话，保留「所有项目」入口和少量项目快捷项；项目与会话采用纯白画布上的扁平列表，项目行与标题使用同一项目册图标，当前项目以纯蓝渐变选中容器、白色图标和粗体文字强化。项目子视图使用 220ms 横向 shared-axis 淡入、160ms 返回；搜索框在 AppBar 内展开，主体使用轻微缩放淡化，转场后再获取焦点。系统 Back 在子视图先返回会话主页。新建会话时先弹出引擎选择器（Claude / Codex），会话创建后引擎不可更改。搜索使用 300ms 防抖、加载线、匹配片段高亮、项目/角色/匹配数信息和空态/错误态。搜索结果由 daemon 权威 transcript 生成，点击后复用既有会话切换与消息定位契约。`SettingsSheet` 是约 94% 高的 Preference Gallery，聊天背景页复用设置容器，模型选择器使用共享 `AppOptionRow` sheet，`WorkspaceDrawer` 只读显示活动项目文件与 Git diff。所有 bottom sheet / dialog 通过 `appOverlayAnimationStyle` 统一为 220ms 进入 / 160ms 退出，reduced motion 时使用 `AnimationStyle.noAnimation`。

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

主界面使用 SafeArea。Cool Glass 参考画板为 390×844，水平安全边距 20px，顶部会话头约 76px，Composer 视觉尺寸 350×110。视觉图标可为 36px，但语义命中区至少 44px。键盘出现时 transcript 和指令建议让出空间，状态和主动作不能被遮挡。

IME 动画的真实 `viewInsets.bottom` 只用于 `AppBackground` 外层避让；传给聊天子树的 `MediaQuery.viewInsets` 被稳定为“关闭 0 / 打开 1”两态，避免长 transcript、Markdown 与 Composer 随键盘每个高度帧重复 build。`ChatScreen` 不再使用覆盖整页的 `LayoutBuilder`，指令建议通过 `Flexible` 在剩余高度内收缩，Composer 使用独立 `RepaintBoundary`。最终键盘避让距离、底部圆角和阴影切换保持不变。

系统大字体、小屏、横屏和键盘场景都有回归测试。中文 UI 使用手机系统默认字体，应用不在 APK 中打包 Noto、LXGW 等正文字体；widget 测试环境的 Ahem 字体只用于布局几何。

## 测试范围

`mobile/test/widget_test.dart` 覆盖启动、配对、Cool Glass 设置与菜单、当前模型屏读语义、菜单去上下文 token、Composer 上下文余量与权限图标语义、恢复 transcript 自动定位到底部、会话导航与全文搜索跳转、工作区、指令筛选、Composer 44/36px 尺寸、思考仪表滑动 / 自动档 / 屏读调节 / 320px 窄屏、权限模式、审批卡（含工作目录与 fallback）、运行和停止状态、花形思考动画 / 本轮计时 / live region、原生进度指示器、共享恢复面板、减少动态效果、小屏大字体、横屏扫码、离线重连、Markdown 来源链接、回复和活动展示。键盘回归会模拟连续 inset 帧，确认已打开期间消息与 Composer 实例不重复重建。实际测试总数以 `flutter test` 输出为准。

`mobile/test/attachments_test.dart` 覆盖附件上传、限制和错误清理。提交前运行：

```powershell
cd mobile
flutter analyze
flutter test
```

## 后续拆分条件

只有当 `main.dart` 的状态修改开始出现跨功能冲突，或需要独立集成测试替身时，再拆出 session controller、remote client 和 screen 文件。拆分必须保持现有协议和视觉行为，不以文件数量作为目标。
