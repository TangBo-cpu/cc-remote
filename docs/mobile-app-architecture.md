# CC Remote 整体架构

## 系统边界

CC Remote 由 Flutter 手机 App、本机 TypeScript daemon、Cloudflare Tunnel 和本机 Claude Code / Codex CLI 组成。电脑端可通过 Windows 原生启动器或命令行启动服务与配对。网页位于 `src/web/`，只用于调试，不是产品主入口。

```text
Flutter App
  -> HTTPS / WSS
  -> Cloudflare Tunnel
  -> local daemon on 127.0.0.1:8787
  -> 常驻 Claude Code stream-json 或 Codex App Server
```

当前是单设备授权模型。一个 daemon 可以注册多个项目，每个项目拥有多条独立会话，每条会话绑定一个引擎（`claude` 或 `codex`），新建会话时选择且不可更改。已配对手机可浏览电脑目录，提交已有目录的绝对路径，并在该目录新建会话；已有会话仍绑定原项目。

## 仓库结构

```text
cc-remote/
    src/
    daemon.ts                 HTTP、WebSocket 和运行编排
    authState.ts              配对、token hash 和授权代际
    engineBridge.ts           引擎无关类型、EngineBridge 接口与归一化
    claudeBridge.ts           Claude Code stream-json 桥接
    codexBridge.ts            Codex App Server JSON-RPC 桥接
    projectSessionState.ts    项目、会话和活动上下文
    transcriptState.ts        权威 transcript 和运行状态
    workspaceService.ts       只读文件与 Git diff
    attachmentStore.ts        附件隔离存储
    attachmentUpload.ts       multipart 上传
    localControlState.ts      本机控制凭据
    pairingQr.ts              配对二维码矩阵
    web/                      调试网页

  desktop/
    src/main.rs               Win32 窗口、二维码绘制和系统托盘
    src/service.rs            设置、本地 HTTP 控制和子进程管理
    assets/                   图标源文件与多尺寸 ICO
    smoke-test.ps1            隔离原生窗口与配对检查

  scripts/build-desktop.ps1   daemon 与 Windows 启动器构建

  mobile/lib/
    main.dart                 App shell、网络状态和主要页面
    signal_console_theme.dart 浅深色色板、主题与共享视觉部件
    appearance_preference.dart 外观持久化、控制器与作用域
    effort_gauge.dart          Composer 思考强度仪表与模态层
    workspace_drawer.dart     只读工作区和 Git diff
    attachments.dart          选择、上传和附件模型
    notification_service.dart Android 本地通知

  tests/                      daemon 单元测试
  mobile/test/               Flutter 逻辑与组件测试
```

Flutter 当前仍以 `main.dart` 集中管理应用状态。这个结构与现有规模匹配。后续只有在功能继续增长时才拆 controllers、services 和 screens，不为目录形式提前重构。

## 启动与项目注册

`cc-remote` 启动脚本检查 `127.0.0.1:8787`。没有运行实例时，它启动 daemon 和可选 tunnel，并把当前目录写入 `WORKSPACE_DIR`。daemon 冷启动后会调用 `registerProject(WORKSPACE_DIR)`，把该目录注册为项目并设为活动上下文；这与“daemon 已在跑时再执行 `cc-remote`”的行为对齐，避免重启后一直停在上次活动项目。

已有新版 daemon 时，脚本通过 `/api/local/projects/register` 注册当前目录并切换活动项目。该接口使用本机私有控制 token，不接受手机 Bearer token。手机使用独立的目录浏览与新建会话接口，不能用手机 token 调用本机控制接口。

Windows 启动器复用相同的本地控制接口。没有运行实例时，它直接启动编译后的 Node.js daemon 和可选 cloudflared；已有 daemon 时，只注册并切换所选项目。daemon 的工作目录始终为仓库，项目路径通过 `WORKSPACE_DIR` 传入，启动器设置保存在 `.data/desktop.json`。关闭窗口后保留托盘与服务，退出只停止它启动的进程树。使用说明见 [`../desktop/README.md`](../desktop/README.md)。

启动器只自动恢复自己托管的固定隧道。隧道退出后按 1、2、4、8、15、30 秒退避重启，保留 daemon、活动任务、配对 token 和 origin；进程存活满 60 秒后才重置退避。用户请求停止后暂停恢复，直到再次显式启动。未接管的服务只刷新状态，Quick Tunnel 退出只提示，不自动换地址重启。

daemon 将项目与会话目录保存在 `.data/projects.json`，各会话 transcript 保存在 `.data/sessions/`。会话记录持久化 `engine` 字段，旧数据加载时默认归一化为 `claude`。附件保存在 `.data/uploads/`。旧版单会话 transcript 会在加载时迁移到默认项目的第一条会话。

## 配对与鉴权

daemon 生成一次性二维码，payload 包含 `type`、`version`、`origin`、`nonce`、`deviceName` 和 `expiresAt`。nonce 5 分钟过期，只保存 hash，使用一次后失效。

命令行将二维码打印到终端；Windows 启动器设置 `CC_REMOTE_DESKTOP=1`，通过本机接口取得二维码矩阵并在原生窗口绘制。生成新二维码不会撤销已配对手机的 token；新配对成功后才替换旧授权。

App 调用 `POST /api/pair` 换取 Bearer token。token 明文只返回给 App，App 存入 Secure Storage，daemon 只保存 hash。重新配对和 logout 会增加授权代际并关闭旧 WebSocket；关闭握手卡住时，daemon 会在 `WS_CLOSE_TIMEOUT_MS` 后强制释放连接。

普通 HTTP 请求使用 `Authorization: Bearer <token>`。WebSocket token 不放 URL，连接 `/ws` 后第一条消息必须是 `auth`。

WebSocket 升级会校验 `/ws`、Host、Origin 和连接上限。未认证连接必须在 `WS_AUTH_TIMEOUT_MS` 内完成首帧鉴权；非法首帧或鉴权失败会以 1008 关闭。鉴权成功后加入广播集合并接收权威快照。

daemon 按 `WS_HEARTBEAT_INTERVAL_MS` 发送标准 WebSocket ping，未收到 pong 的连接会被 terminate；连接错误也会被消费并 terminate，正常 close/error 后都会从连接集合移除。logout 或重新配对会增加授权代际，以 `authorization_changed` 关闭旧连接，并在 `WS_CLOSE_TIMEOUT_MS` 后强制释放未完成关闭握手的连接；旧授权代际收到后续消息时会以 `authorization_expired` 关闭。参数默认值与整数范围见根目录 README 的“配置（摘要）”。

## HTTP API

`GET /api/health` 和 `POST /api/pair` 不需要 Bearer token。其余手机 API 都需要授权。

本机控制接口位于 `/api/local/`，使用 `.data/local-control.json` 中的 token，通过 `x-cc-remote-local-token` 请求头传入。daemon 同时校验回环来源、Host 和 Origin，拒绝公网 Host；Origin 必须缺省或属于允许来源。手机 Bearer token 不能替代本机控制 token。

| 接口 | 用途 |
| --- | --- |
| `GET /api/local/status` | 服务、任务、配对与连接状态；未配对且二维码有效时返回 payload 与矩阵 |
| `POST /api/local/projects/register` | 注册并切换本机项目，活动任务期间拒绝切换 |
| `POST /api/local/pairing` | 生成新的配对 payload 与二维码矩阵 |
| `POST /api/local/shutdown` | 保存会话并退出；活动任务返回 409，显式 `force: true` 才允许停止 |

daemon 开始退出后，对新 HTTP 请求返回 503，并关闭 WebSocket。启动器在用户确认后才发送强制退出请求，并等待 daemon 结束后清理隧道。

项目与会话接口包括 `/api/status`、`/api/projects`、`/api/sessions/:id`、`/api/search/sessions`、创建会话、选择会话、重命名、归档和删除。全文搜索只接受 Bearer 鉴权请求，在 daemon 内存中的权威 transcript 上匹配标题、用户消息和助手消息，排除 system/activity 噪声；按会话聚合、最多返回 50 条安全片段。任一引擎任务运行时都禁止切换或创建会话。

`GET /api/directories` 列出电脑磁盘与主目录，带 `path` 时只列该目录的直接子文件夹，最多返回 500 条并标记截断。`POST /api/projects/open-directory` 接收绝对路径和引擎，验证真实目录与读取权限，再注册或复用项目并创建一条新会话。新目录通过真实路径去重；项目目录与会话保存成功后才切换活动上下文，并广播 catalog、工作目录与 transcript。创建使用现有运行互斥锁，忙碌时返回 409；目录浏览不占用该锁。

工作区接口包括 `/api/workspace`、`/api/workspace/file` 和 `/api/workspace/diff`。路径必须位于活动项目内，Git 内部文件、被忽略文件和路径穿越会被拒绝。接口只读。

附件通过 `/api/sessions/:id/attachments` 上传，通过带会话归属的 content 接口读取。上传是事务式的，失败时清理已经写入的同批文件。附件路径不会进入 transcript 或手机 UI。

`POST /api/new-conversation` 是兼容入口，实际会在活动项目下创建新会话。`POST /api/stop` 请求当前桥接停止：Claude 终止当前进程树；Codex 优先发送 `turn/interrupt`，2 秒内没有结束时再终止 App Server。`POST /api/logout` 撤销配对。

## WebSocket 运行流

鉴权完成后，daemon 发送 `catalog`、`status`、`transcript_snapshot`、`permission_capabilities` 和当前 `session_info`。App 由此恢复项目、会话、运行状态、待审批请求、模型和剩余上下文。活动任务状态包含 `running`、`stopping`、`runId` 和 `startedAt`，用于在重连后恢复 Stop 按钮状态与思考计时。

`status` 中的 `connectionProbe: true` 表示 daemon 支持应用层存活探测。鉴权后的客户端可发送 `{ "type": "ping", "probeId": "..." }`，daemon 返回同 ID 的 `{ "type": "pong", "probeId": "..." }`，不改变会话或任务。`probeId` 必须是非空字符串，最长 128 个字符，否则返回 `invalid_probe_id`。

Flutter 的 `ensureConnected()` 会合并同一连接上的并发探测，默认等待 8 秒。探测绑定当前连接、generation 和 `probeId`；关闭或替换连接时取消旧探测，旧连接的回复不能确认新连接。超时记为 `websocket_liveness_timeout` 并进入现有退避重连；握手进行中不会重复建连。旧服务端没有声明能力时不发送应用层探测，原有心跳与重连机制继续生效。恢复前台调用 `ensureConnected(retryNow: true, probeTimeout: resumeProbeTimeout, reconnectNowOnProbeFailure: true)`，沿用默认 8 秒探测窗口，避免隧道延迟超过 2 秒时误断健康连接。健康连接继续使用；前台请求会将已有探测提升为失败后立即建连，发送失败或连接流关闭时也跳过退避。无连接时立即重试，自动恢复已经开始的握手继续完成。探测成功后，后续普通断线仍使用退避。后台时长不能证明连接失效，不再仅按后台时间关闭现有连接。

任务消息包含唯一 `promptId`、`sessionId`、文本、附件 ID、权限模式、模型覆盖项和 `effort`。prompt 还必须携带与会话一致的 `engine`，不一致会被拒绝（`engine_mismatch`）。daemon 接管后返回 `prompt_accepted`，并在有界收据缓存中按 ID 与载荷签名去重（签名包含 engine 与 sandboxMode）；重复消息只返回原确认，不再次启动引擎。随后 daemon 校验会话归属和附件归属：Claude 会话将可信附件路径拼入 prompt 并通过 `--add-dir` 允许读取隔离目录；Codex 会话只接受图片附件，以 `localImage` 输入交给 App Server。思考强度映射到 Claude Code 的 `--effort`；`auto` 使用 `CLAUDE_CODE_EFFORT_LEVEL=auto` 恢复模型默认。

Codex 会话使用三档沙箱模式 `read-only` / `workspace-write` / `danger-full-access` 替代 Claude 权限模式，默认完全访问（`danger-full-access`）且任务完成后持续生效，不自动降级为只读，保留显式切换并持久化到 transcript。Codex 会话支持动态拉取模型目录与斜杠指令（原生 `/compact` 压缩上下文、`/review` 代码审查及已启用的 skills），`permission_capabilities` 中 `allowBypassPermissions` 恒为 false 并下发可用沙箱档位。

桥接层按活动会话维持一个长生命周期进程：Claude Code 使用 Streaming Input `stream-json`，初始化一次后连续写入多轮 user 消息；Codex 使用 stdio App Server，初始化一次后合并目录发现（`model/list`、`skills/list`）与运行，通过 `thread/start` / `thread/resume` 与 `turn/start` 运行并消费 `item/agentMessage/delta`，原生 `/compact` 通过 `thread/compact/start` 触发，原生 `/review` 通过 `review/start` 触发。模型、effort、权限模式或附加目录等 Claude 启动参数发生变化时才重启 Claude 进程；切换项目、会话或引擎时会关闭旧桥接进程。Codex 的停止优先调用 `turn/interrupt`，超时后再终止进程。

Claude 桥接设置 `CLAUDE_CODE_ENTRYPOINT=cc-app`，让手机会话出现在原生 `claude -r` 列表。daemon 在启动、Claude 任务结束和手机会话改名后同步原生历史：只处理自身 catalog 中的 Claude 会话，将旧 SDK 来源标识按原字节长度更新为 App 来源，并追加原生 `custom-title` 记录。消息、会话 ID 和消息链不变；首次更新前保留 `.cc-remote-history.bak` 备份，未写完整的 transcript 留待下次同步。该兼容行为已在 Claude Code 2.1.293 验证，依赖其会话来源和标题格式。

运行期间，daemon 将输出归一化为 `text`、`activity`、`session_info` 和 `permission_request`。Codex 会话复用同一套消息协议，活动与 session info 由 `codexBridge` 提取。`activity` 会移除私有思考文本、完整工具结果和附件本机路径，同时保留 `Skill` 工具的具体 Skill 名称。`text` 在 daemon 侧短时合批后再推送，任务进入 `done` / `stopped` / `error` 前会 flush 尾包，随后广播空闲状态和更新后的 catalog。所有会话级消息都带 `engine` 字段。

`transcript_snapshot` 是会话内容的权威来源。App 可以先显示本地缓存，WebSocket 鉴权后再以 daemon 快照补齐断线输出。WebSocket 客户端按退避间隔自动重连；每次连接首次完成鉴权后，未收到 `prompt_accepted` 的 Prompt 会使用原 `promptId` 重发，普通 `status` 广播不触发重发，已确认的 Prompt 不会重发。daemon 的去重依赖当前有界收据缓存，不保证跨 daemon 重启只执行一次。重连后通过同一份快照和活动任务状态继续展示运行中或停止中的任务。daemon 重启时，持久化为 running 的任务会归一化为 interrupted。

## Flutter 状态流

App 启动后读取 Secure Storage。没有 token 时进入配对页。有 token 时进入主控制台，并行建立 WebSocket、请求 `/api/status` 并读取缓存的 transcript；缓存读取不阻塞握手，host 快照先到达时缓存不再覆盖它。401 会清除本地配对并返回扫码页。其他失败会保留 token 和 transcript，显示电脑端离线状态，同时启动 WebSocket 自动恢复。

外观由 `CcRemoteApp` 中的 `AppearanceController` 管理，与 `DemoShell` 的会话状态分开。默认 `ThemeMode.system`，设置可选择浅色或深色；显式选择写入 Secure Storage 的 `cc_remote_appearance`。切换只更新 Material 主题，不替换会话子树。消息、Markdown 缓存、工作区与弹层从 `AppPalette.of(context)` 读取当前颜色，系统栏图标亮度随外观更新。旧背景设置不再读取，用户相册文件保留。

App 区分已配对、正在连接、已连接、运行中、停止中、上传中和离线。上传附件、运行任务或停止任务时，相关导航和重复操作会被禁用。WebSocket 完成鉴权即更新在线状态，即使会话不匹配导致后续业务状态帧被过滤，也不会继续显示离线。

App 回到前台时先启动或检查 WebSocket，探测结束后仍已鉴权的连接不再额外请求 HTTP 状态；连接未就绪时保留 HTTP 兜底。手动刷新仍请求 HTTP。后台持续至少 60 秒时允许立即重试，但不会仅因后台时间较长就关闭健康连接。已鉴权 WebSocket 的状态优先：迟到的 HTTP 响应不替换连接，也不覆盖最新任务、模型、catalog 和工作区；HTTP 失败不关闭健康连接。显式重新连接会使旧 HTTP 刷新失效。

多项目和多会话由 catalog 驱动。会话消息带 `projectId` 与 `sessionId`，App 忽略不属于当前会话的运行消息。通知点击后在安全状态下切换到对应会话。「项目与会话」面板和设置页展示完整项目路径，方便区分同名目录；搜索模式跨项目请求 daemon，并携带权威 transcript 的原始 `messageIndex`。App 切换到目标会话并收到快照后，将原始索引映射到过滤后的可见行；若本地提示导致索引漂移，则以角色和规范化片段寻找最近匹配，再滚动并短暂高亮命中气泡。

流式回复时，App 会短时合并 `text` 增量再刷新 UI；无 Markdown 标记走廉价 `Text`，有标记时流式期间即用 `MarkdownBody`，避免回合结束时排版跳变。本地 transcript 落盘在流式期间节流，终态强制写入。Markdown 中的来源 / 引用沿用助手文本本身的链接，不扩展 daemon 协议；Flutter 只允许绝对 `http` / `https` URL，并通过系统外部浏览器打开，非法或相对 URL 不触发跳转。

助手回复中的 `cite` / `filecite` 专用引用标记由 `assistant_citations.dart` 在显示层处理。当前 transcript 没有引用编号到网址或文件路径的映射，因此显示「来源链接未提供」或「文件引用未提供路径」，不构造跳转地址。流式输出中尚未收齐的引用暂不显示；行内代码与围栏代码中的字面标记保留。显示与「复制全部」使用处理后的文本，原始会话记录和用户消息保留原文。

恢复历史 Claude session 时，桥接层会在初始化失败时保留子进程退出码与 stderr，避免 CLI 的真实错误被通用初始化错误覆盖。若 daemon 识别到 session 已不存在，只清除旧 Claude session ID，并在同一轮请求中无 `--resume` 重试一次；其他初始化错误不会触发自动重试。桥接层和 daemon WebSocket 端到端测试均覆盖这一行为。

## 通知

Android 本地通知由已建立的 App WebSocket 触发，覆盖任务完成、失败、停止和等待权限。通知偏好本地持久化，点击通知返回对应会话。

App 进程被系统彻底杀死后没有常驻连接，因此不能继续接收事件。这个场景需要后续接入 FCM。

## 安全边界

daemon 默认只监听 loopback，公网访问由 tunnel 提供。已配对手机可以浏览电脑目录并在所选目录创建会话，目录接口只返回文件夹信息。工作区文件与 Git diff 接口保持只读，仍限制在活动项目内并遵循 Git 忽略规则。手机不能直接调用任意 shell，也不能用 Bearer token 访问本机控制接口。

权限模式映射 Claude Code 原生模式。`bypassPermissions` 可在电脑端关闭；即使开启，手机也需要二次确认，并只对单次任务生效。审批请求只能允许一次或拒绝，手机不能修改工具参数。Codex 会话没有逐工具审批，改用沙箱模式限定写入范围；daemon 在 Windows 上按 PATH 探测 `@openai/codex` 的 `codex.js` 启动器并用当前 Node 运行，可用 `CODEX_BIN` / `CODEX_ARGS` 覆盖。transcript 中 `claudeSessionId` 已更名为 `engineSessionId`，旧快照加载时自动迁移。

## 当前未完成

多设备管理、FCM 推送、发布签名和商店材料尚未实现。公网 health 检查、冷启动切项目 / 隧道首字延迟、真实账户连续轮次首字延迟，以及长任务 Stop 回归仍需专项验证。可选局域网直连属于后续性能项。

本轮连接稳定性改动完成了本地模拟、回环 WebSocket 和测试子进程验证，尚未更新实际运行的 App、daemon 或桌面启动器。Wi-Fi / 蜂窝切换、长短后台、锁屏、电脑休眠唤醒、真实隧道退出和长时间运行仍需验证；恢复机制不保证 daemon 重启后继续执行原任务。
