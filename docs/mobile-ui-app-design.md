# CC Remote 手机端 UI 实现规格

## 文档状态

本文记录 Flutter Warm Console 的当前实现规格与后续验收目标，视觉依据是 Penpot 的 11 张 `CCR / 01` 至 `CCR / 11` 画板和已落地的 Flutter 组件。根目录 [`DESIGN.md`](../DESIGN.md) 是颜色、排版、圆角、间距和共享组件的规范源；本文负责页面流程、状态映射和工程验收。

截至 2026-08-15，`mobile/lib/main.dart`、`mobile/lib/signal_console_theme.dart` 与 `mobile/lib/workspace_drawer.dart` 已完成 Warm Console 主界面、设置/菜单、Composer 和 Lucide 图标迁移，并保持原有网络、会话、附件、权限和 transcript 行为。后续已落地：`terracotta-deep` CTA、打包 Noto 字体、助手 elevated 气泡、权限卡工作目录、`ConsoleStatusStrip`（含连接中）、连接中空状态卡与聚焦描边对比。公开的 `v1.1.0` APK 仍使用上一版界面；开发 release 已装真机，逐屏视觉验收与恢复终态面板仍待补齐。

## 目标与非目标

目标：

- 将手机端收敛为“暖纸控制台 / Warm Console”。
- 补齐配对、会话选择、运行控制、权限处理、Diff 查看与恢复状态的统一体验。
- 让连接、运行、停止、失败和断线在短暂扫视中可判断。
- 保留现有协议与安全边界，优先通过 UI 重组完成改造。

非目标：

- 不增加底部 Tab，不把手机改造成文件编辑器或终端。
- 不允许手机注册任意工作目录、执行任意 shell、暂存或提交 Git。
- 不为视觉草案虚构 daemon 尚未提供的进度、风险、错误结构或队列数量。
- 不以模仿 ChatGPT 或 Claude 为目标；只吸收其移动端的内容优先、紧凑导航和低装饰密度。

## 视觉基线

- 基准画板为 390×844，页面水平安全边距 20px，主要内容宽度 350px。
- 页面背景、消息区、活动区和输入台保持同一暖白色温。
- 浅陶土（`terracotta`）只用于品牌大面积与执行节点；实心 CTA / 发送 /「仅本次允许」使用 `terracotta-deep` + elevated 字色。
- 在线与完成不使用绿色；状态由图标、文案和色调共同表达。
- Flutter 打包 `NotoSansSC`（Regular/Bold）与 `NotoSerifSC`（Regular）到 `mobile/fonts/`；助手正文用衬线。
- 默认无玻璃、无渐变、无普通卡片阴影、无彩色偏移阴影。
- 关键状态与按钮辅助文字最低 12px；正文 15px；Diff 代码 12–13px。
- 视觉图标按钮可为 36×36，实际命中区至少 44×44。
- 图标统一为 20/24px 线性风格，不能混用 Unicode、Material 实心图标和自绘字符。
- 输入聚焦描边使用 `terracotta-deep`（约 1.4px）。

完整设计 token 见 [`DESIGN.md`](../DESIGN.md)。

## 页面与画板映射

### 01 Pair Device

用户目标：让手机安全地连接桌面主机。

- 标题直接说明“连接你的桌面主机”。
- 扫码是主动作，手动输入配对码是次路径。
- 显示端到端传输与一次性配对说明，但不使用大角色或装饰插画占据首屏。
- 扫码成功后仍进入确认步骤，展示电脑名、origin 与二维码有效性，再调用 `POST /api/pair`。
- 错误、过期和相机权限失败必须保留“重新扫描”与手动输入入口。

### 02 Choose Session

用户目标：恢复最近任务或选择其他会话。

- 顶部显示会话选择与“新建”动作。
- 最近会话作为主列表，其他会话降低权重。
- 每项至少显示会话名、项目或路径摘要、最近状态与时间。
- 切换或创建会话在任务运行、附件上传或停止中禁用。
- 固定说明“切换会话不会中断桌面端正在运行的任务”仅在协议事实成立时显示。

### 03 Run Control

用户目标：查看当前桌面任务、继续指令或停止。

页面从上到下只有四层：

1. 分离式浮动会话控制。
2. transcript 正文。
3. 当前活动与已完成证据。
4. 底部 Composer。

顶部参考 Claude 手机端：左侧仅保留圆形菜单，右侧是新建与更多组成的短胶囊，中间不显示产品名、会话名、连接状态或设备名。非「已连接」相位时，会话头下方显示紧凑 `ConsoleStatusStrip`。模型留在 Composer，路径和设备信息进入设置或 sheet，剩余上下文 token 不显示。

用户消息使用暖灰气泡；Claude 连续回复靠左使用 elevated paper 轻量气泡 + 衬线阅读字体。空 transcript：已连接给快捷下一步；离线给重连卡；连接中给独立状态卡。当前活动可展开，已完成活动折叠为一行。运行中必须始终能看到停止入口。

### 04 Permission Request

用户目标：理解风险后做一次明确决策。

内容顺序固定为：

1. “允许 Claude 运行命令？”或与实际工具相符的标题。
2. 命令或工具摘要。
3. 工作目录。
4. 权限与影响。
5. 授权范围。
6. “拒绝并返回”与“仅本次允许”。

默认授权范围是当前请求。不得把一次性审批包装成永久授权；更改权限模式进入单独 sheet。

当前协议只稳定提供 `toolName`、`detail`、`title`、`displayName`、`description` 和 `decisionReason`。工作目录优先取当前会话 `workspaceDir`；缺失时显示「以桌面主机当前工作区为准（路径暂不可用）」，不虚构绝对路径。风险分级和影响条目必须由可验证字段推导；信息不足时显示保守的工具说明，不虚构“不会访问密钥”等承诺。若产品需要更结构化的风险项，应单独扩展协议并增加 daemon/Flutter 测试。

### 05 Review Diff

用户目标：快速理解桌面工作区变更。

- 顶部显示文件数与增删摘要；默认统一视图。
- 按文件导航，支持跳到变更与错误行。
- 代码采用等宽字体，12–13px，行高至少 1.45；长行允许水平滚动或安全换行。
- 明确“变更仅保存在桌面工作区；手机端不会自动提交”。
- 保持只读，不增加暂存、提交或编辑。

现有 `WorkspaceDrawer` 和 `/api/workspace/diff` 可作为数据源；若要得到可靠的总增删数量，应从 diff 文本解析并测试，而不是在 UI 中估算。

### 06 Offline Recovery

用户目标：确认内容未丢并恢复连接。

- 会话头显示“连接已断开 / 记录已保留”。
- 正文明确手机无法连接哪台主机，恢复后将从权威快照继续同步。
- 恢复卡只有一个主动作“立即重连”。
- Composer 降级为离线状态面，保留草稿和附件，并显示“离线”。

当前客户端知道连接状态和本地草稿，但没有稳定暴露 WebSocket 的自动重连次数与下一次倒计时。实现初版只显示“自动重连中”；若要显示“第 2 次尝试”，先从 WebSocket 客户端暴露真实数据。待发送数量只能统计本地尚未收到 `prompt_accepted` 的内容。

### 07 Task Failed

用户目标：理解失败原因并选择恢复动作。

- 明确任务在哪个阶段停止、工作区是否保留。
- 显示 daemon 提供的错误原文或安全化摘要。
- 主动作“查看错误并重试”；次动作“查看当前 Diff”进入更多菜单或弱化位置。
- 不根据错误字符串猜测精确文件行号，除非解析器有测试覆盖。

### 08 Stopping

用户目标：确认停止请求已经发送且无需重复点击。

- 显示“停止请求已发送”“正在停止”和已等待时长。
- 停止按钮禁用，使用方形 stop 图标与“等待主机确认”文字。
- 不允许再次提交停止请求。

### 09 Stopped

用户目标：确认桌面任务已真正结束。

- 只有收到 WebSocket `stopped`，或权威 transcript 中保留了明确“已停止”终态证据后进入。普通 `running: false` 只能证明任务不再运行，不能区分完成、失败与停止。
- 显示工作区和 transcript 仍保留。
- Composer 恢复发送能力，主动作可为“继续告诉 Claude”。

### 10 Stop Timeout

用户目标：理解手机没有收到确认，不误判为已停止。

- 本地等待超时后显示“停止超时 / 主机未确认停止”。
- 任务仍按运行中处理，允许再次发送停止请求或查看详情。
- 不将 `running` 清为 false，不显示“已停止”。

现有 `stopRun()` 已在网络超时后追加“停止请求未确认，任务仍在运行”，可以直接映射此画板。

### 11 Reconnect Failed

用户目标：知道自动恢复失败后还能做什么。

- 显示最后一次连接结果和已保留内容。
- 主动作“再次重连”；次路径进入配对或连接诊断。
- 只有在客户端拥有明确的重连失败或退避耗尽事实时显示此终态；普通瞬时断线仍保持 06 自动重连状态。

## 共享组件

### CompactSessionHeader

- 当前实现由 `ConnectionHeader` 承担，不保留 `LegacyConnectionHeader`。
- 高度 44px，不再使用整宽暖纸表面。
- 左侧是独立圆形菜单；右侧是 88×44px 的新建/更多胶囊；中间透明留空。
- 顶部 chrome 不重复显示产品名、会话名、连接状态和设备名；非 `ConsolePhase.connected` 时在头下方渲染 `ConsoleStatusStrip`。
- 设备与路径分流到设置或 sheet；模型保留在 Composer，“···”菜单底栏最多显示模型名，不显示剩余上下文 token。

### TranscriptView

- 保留现有本地缓存、snapshot 覆盖与流式轻渲染逻辑。
- 用户消息靠右暖灰气泡；助手回复靠左 elevated paper 气泡 + 衬线；系统消息不使用营销式卡片。
- 空状态三分支：已连接快捷芯片 / 离线 `_OfflineReconnectCard` / 连接中 `_ConnectingStatusCard`。
- 权限请求为全宽决策面，顺序为命令 → 工作目录 → 影响 → 范围 → 动作。

### ActivityEvent

- 复用现有 `ActivityKind` 与 `ActivityState`。
- 当前 running 事件为完整卡；done/stopped 事件默认折叠；error 事件保留错误摘要。
- thinking running 使用 brain 图标与原生脉冲；其他活动 running 使用 `CircularProgressIndicator`。
- 任务轨只在活动局部出现，不贯穿整屏。

### Composer

- 标准视觉尺寸 350×110，16px 圆角。
- 上方是可增长文本区；下方工具行贴底，依次为圆形扩展、暖色模型胶囊、陶土色圆形发送或停止。
- 扩展按钮打开附件和权限模式；权限模式不再常驻一整行。
- 模型选择使用紧凑胶囊。
- 模型旁不显示剩余上下文 token，上下文数据不改变指令建议区高度。
- 视觉控制为 36px，命中区为 44px。
- 附件预览显示在输入台上方或输入台内部的可滚动短条，不改变核心控制顺序。
- 斜杠指令建议限制在最多三个首选项，完整结果可继续滚动。

### PermissionDecision

- 一次只能处理一个待审批请求。
- 操作期间禁用按钮并提供进度。
- 收到 `permission_resolved` 或 `permission_expired` 后关闭。

### RecoveryState

- 06、07、08、09、10、11 复用相同状态标题、事实说明、证据和单一主动作位置。
- 状态必须使用图标、文字和色调三重编码。

## 状态映射

| UI 状态 | 现有事实来源 | 允许的主动作 | 关键约束 |
|---|---|---|---|
| 连接中 | `!wsReady && !remoteOffline` | 等待；空 transcript 显示连接卡 | 状态条显示「正在连接」；不与离线卡混用 |
| 已连接 | `wsReady && !running` | 发送、新建、切换 | 不用绿色；状态条隐藏 |
| 运行中 | `running && !stopping` | 停止 | 停止入口始终可见 |
| 停止中 | `running && stopping` | 无，等待确认 | 禁止重复停止 |
| 已停止 | WebSocket `stopped` 或权威 transcript 的明确停止证据 | 继续输入 | 普通 `running: false` 不足以判定 |
| 停止超时 | `running && !stopping` 且最近停止请求超时 | 再次停止 | 仍视为运行中 |
| 离线 | `remoteOffline` | 立即重连 | transcript 与草稿保留；状态条 + 离线空状态卡 |
| 重连失败 | 明确的重连失败事实 | 再次重连 | 不与瞬时断线混淆 |
| 失败 | WebSocket `error` 或失败终态 | 查看错误并重试 | 保留原始错误证据 |
| 等待权限 | `pendingPermissions.isNotEmpty` | 允许一次或拒绝 | 一次处理一个请求；权限卡展示 `workspaceDir` |
| 上传中 | `uploadingAttachments` | 取消或等待 | 禁止切换会话与发送 |

UI 直接把这些事实映射为当前视图，不引入新的全局状态机对象。只有当 `main.dart` 的布尔组合持续产生冲突，才拆出独立 controller。

## 图标规范

当前实现已全局统一使用 `lucide_icons_flutter` 3.1.15。主界面与工作区不再混用 Material Icons；本轮未引入 `flutter_svg` 或额外图标资产。

思考态使用 Lucide `brain`，普通活动 running 继续使用 Flutter 原生 `CircularProgressIndicator`。不使用 `flutter_animate`；入场动效被移除，保留思考脉冲、`SignalPressEffect` 和其他已有原生反馈。

必须统一的首批图标：menu、more-horizontal、plus、chevron-left/right/down、arrow-up、stop-square、rotate-cw、monitor、monitor-off、terminal、file-diff、check、alert-circle。

## 实现进度与后续顺序

截至 2026-08-15，Phase 1 的主题、会话头、活动展示、Composer、设置/菜单与 Lucide 图标迁移已落地；a11y/UX 补强（`terracotta-deep` CTA、Noto 打包、助手气泡、权限工作目录、连接中状态条/空状态、聚焦描边）已合入开发代码并装真机。Phase 3 已用共享 `ConsolePresentation` 统一 Header / Composer / 状态条语义；后续工作主要是恢复信息面板、重连失败事实和逐屏真机视觉验收。

### Phase 1：设计基础与主控制台

- 重写 `signal_console_theme.dart` 的色彩、排版、圆角与基础按钮主题。
- 重构 `ConnectionHeader`、`MessageBlock`、`AssistantBubbleFrame`、`ActivityBlock` 和 `PromptBar`。
- 删除不再使用的 `LegacyConnectionHeader`、Signal Console 吉祥物、彩色偏移阴影与旧装饰 painter。
- 保持网络、transcript、附件、命令筛选和 Stop 行为不变。

### Phase 2：主流程页面

- 重构 `PairScreen` 与 `PairReviewSheet`。
- 将 `SessionNavigatorSheet` 调整为 02 会话选择结构。
- 将 `PermissionRequestCard` 升级为 04 权限决策体验。
- 重构 `WorkspaceDrawer` 的文件列表和 Diff 视图。

### Phase 3：恢复与终态

- 已用纯展示映射覆盖离线、失败、停止中、已停止和停止超时；停止/失败终态从当前轮权威 transcript 证据推导，不新增第二套全局状态源。
- 待补共享恢复信息面板，统一事实说明、保留内容和单一主动作的位置。
- 仅在有真实连接失败事实时增加 11 重连失败状态。
- 对本地草稿、未确认 prompt 与重连信息建立可测试的显示规则。

### Phase 4：清理与可访问性

- 清理旧 token、旧组件和过时测试文案。
- 验证 44px 触控、屏读标签、live region、焦点顺序和非颜色状态表达。
- 真机检查中文字体、键盘、小屏、横屏、大字体与减少动态效果。

## 测试与验收

每个阶段至少运行：

```powershell
cd mobile
flutter analyze
flutter test
```

新增或更新的组件测试必须覆盖：

- 紧凑会话头在 390×844、小屏和大字体下不溢出。
- Composer 视觉控制 36px、语义命中区至少 44px，键盘出现不遮挡。
- “···”菜单不显示上下文 token，保留模型名时具有“当前模型”屏读语义。
- 思考态使用 brain 图标，其他活动 running 仍使用原生进度指示器，测试结束无 pending Timer。
- 权限页仅允许一次或拒绝，处理中禁用重复点击；有路径时展示工作目录，缺失时展示 fallback 文案。
- 离线保留 transcript、草稿与附件，重连动作可达；连接中空状态不复用离线卡，且 ChatScreen 显示状态条。
- stopping、stopped 和 stop-timeout 三态互不混淆。
- error、offline、connecting、stopping 等状态不只靠颜色。
- Diff 在长路径、长代码行和大字体下仍可阅读。
- 减少动态效果时关闭连续动画。

Penpot 对齐验收：

- 390×844 参考尺寸下，页面左右边距、会话头、活动卡和 Composer 与画板节奏一致。
- 单屏没有绿色状态、大黑色 Dock、玻璃、渐变或彩色偏移阴影。
- 运行控制首屏能看到连接事实（状态条或空状态）、当前动作、停止入口与输入上下文。

真机验收至少覆盖 Android 一台窄屏设备（开发 release 已装多机，视觉清单仍待逐项勾选）；Flutter 测试中的 Ahem 字体只能验证几何，打包 Noto 后的中文观感应在真机确认。
