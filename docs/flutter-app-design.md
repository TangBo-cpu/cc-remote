# CC Remote Flutter 实现说明

## 实现原则

Flutter App 是产品主入口。当前实现集中在少量文件中，优先保证状态一致、断线可恢复和真机布局稳定。

当前代码仍是上一版 Signal Console；下一轮 UI 目标以根目录 `DESIGN.md` 和 `docs/mobile-ui-app-design.md` 为准。改造必须保持本节描述的协议与状态行为，不把 Penpot 草案中尚无数据来源的文案写成事实。

## 入口与路由

`CcRemoteApp` 创建 Material App 和当前主题。`DemoShell` 持有应用级状态，监听页面前后台变化，并在 `boot`、`pair` 和 `chat` 三个路由之间切换。

启动时加载 Secure Storage、通知偏好和本地 transcript。存在已保存 session 时调用 `/api/status`，恢复电脑名、工作区、项目 catalog、活动会话、模型和上下文，再建立 WebSocket。

## 主要文件

`main.dart` 包含配对、HTTP、WebSocket、项目与会话、transcript、权限模式、主要页面和组件。`signal_console_theme.dart` 包含颜色、字体、圆角、动效和视觉基础部件；下一轮先在这里建立 Warm Console tokens。`workspace_drawer.dart` 实现文件树、文件阅读和 Git diff。`attachments.dart` 实现相机、相册、文件选择与 multipart 上传。`notification_service.dart` 封装 Android 本地通知和偏好保存。

## 页面与组件

`BootstrapScreen` 只显示恢复状态。`PairScreen` 负责相机扫描、紧凑横屏布局和错误恢复。`PairReviewSheet` 在换 token 前确认设备、origin 和二维码有效期。

`ChatScreen` 由 `ConnectionHeader`、`TranscriptView` 和 `PromptBar` 组成。下一轮保留这三个职责，但将连接头重构为单一紧凑会话头：会话身份与连接事实居中，项目、工作区、设置等次级入口进入菜单；模型选择移入输入台。

`TranscriptView` 展示用户消息、Claude Markdown 回复、活动状态、审批卡和离线重连卡。`MessageBlock` 与附件组件负责历史内容。`ActivityBlock` 合并思考和工具活动，任务结束后清理临时活动。

`PromptBar` 处理权限模式、附件预览、多行输入、模型选择、发送和停止。下一轮改为 110px 暖白 Composer：上方输入，下方依次为扩展、模型和发送/停止。权限模式进入扩展 sheet，不再常驻一行。输入以 `/` 开头且没有空格时，`CommandSuggestions` 继续按前缀优先规则筛选 daemon 同步的 Claude Code 指令。

`SessionNavigatorSheet` 展示项目和各自会话，允许切换或创建会话。`SettingsSheet` 管理通知、重连和退出配对。`WorkspaceDrawer` 只读显示活动项目文件与 Git diff。

## 核心状态

保存的配对信息由 `SavedSession` 表示，包含 origin、token、deviceName 和 workspaceDir。项目与会话 catalog 使用 `RemoteProjectCatalog`、`RemoteProjectSummary` 和 `RemoteSessionSummary`。

transcript 使用 `TranscriptMessage`，角色分为 user、assistant、system 和 activity。daemon 快照由 `RemoteTranscriptSnapshot` 解析，包含消息、运行状态、权限模式、审批请求、Claude session id 和 session info。

运行状态由 `connected`、`remoteOffline`、`running`、`stopping` 和 `uploadingAttachments` 等字段共同表达。第一轮 UI 改造继续直接映射这些事实，不另设重复状态机对象；停止超时是“仍在运行但最近停止请求未确认”的视图状态，不能当成已停止。

## 网络行为

配对成功后 token 写入 `flutter_secure_storage`。HTTP 使用 Bearer token。WebSocket 从扫码 origin 推导 `ws` 或 `wss` 地址，连接后先发送 `auth`。

发送任务前，App 将附件上传到当前会话，得到附件 ID，再发送 prompt。纯附件任务允许文本为空。发送后立即在本地追加用户消息和思考活动，等待 daemon 权威事件修正状态。

WebSocket 处理 `status`、`catalog`、`transcript_snapshot`、`permission_capabilities`、`permission_request`、`permission_resolved`、`permission_expired`、`commands`、`session_info`、`activity`、`text`、`done`、`stopped` 和 `error`。

会话消息必须与当前 `projectId` 和 `sessionId` 匹配。重新连接后，daemon snapshot 覆盖本地推测状态，避免重复消息或丢失断线输出。

## 权限模式

App 支持 `manual`、`acceptEdits`、`auto`、`dontAsk`、`plan` 和 `bypassPermissions`。默认是 `manual`。权限请求只能允许一次或拒绝；Warm Console 可以将审批呈现为独立决策面，但不能新增协议不支持的永久授权操作。

如果 daemon 关闭 bypass 能力，选择项禁用。选择 bypass 时必须弹出确认，任务结束后自动恢复询问权限。

## 附件

附件来源包括相机、相册和文件。选择后在 Composer 上方或内部短条预览。一次最多 5 个，单个最大 25MB。上传期间禁止发送、删除附件和切换会话。

图片历史使用 daemon 鉴权 content API 加载缩略图，普通文件显示名称和大小。App 与 transcript 只保存附件描述，不保存 daemon 本机绝对路径。

## 错误与恢复

二维码格式错误、过期、网络失败和配对失败都留在 PairScreen，并提供重新扫描。HTTP 401 清除 token，回到配对页。普通网络错误保留配对和 transcript，主控制台显示电脑端离线。

运行中断线不自动重发 prompt。重新连接后通过 transcript snapshot 判断任务是否继续、完成或中断。Stop 进入停止中状态，禁用重复点击；收到 `stopped`、`done` 或 `error` 后恢复输入。

## 布局要求

主界面使用 SafeArea。Warm Console 参考画板为 390×844，水平安全边距 20px，顶部会话头约 76px，Composer 视觉尺寸 350×110。视觉图标可为 36px，但语义命中区至少 44px。键盘出现时 transcript 和指令建议让出空间，状态和主动作不能被遮挡。

系统大字体、小屏、横屏和键盘场景都有回归测试。中文显示需要真机验证，测试环境的 Ahem 字体只用于布局。

## 测试范围

`mobile/test/widget_test.dart` 覆盖启动、配对、设置确认、会话导航、工作区、指令筛选、权限模式、审批卡、运行和停止状态、减少动态效果、小屏大字体、双栏连接舱溢出、横屏扫码、离线重连、Markdown 回复和活动展示。

`mobile/test/attachments_test.dart` 覆盖附件上传、限制和错误清理。提交前运行：

```powershell
cd mobile
flutter analyze
flutter test
```

## 后续拆分条件

只有当 `main.dart` 的状态修改开始出现跨功能冲突，或需要独立集成测试替身时，再拆出 session controller、remote client 和 screen 文件。拆分必须保持现有协议和视觉行为，不以文件数量作为目标。
