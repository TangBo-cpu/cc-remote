# CC Remote 整体架构

## 系统边界

CC Remote 由 Flutter 手机 App、本机 TypeScript daemon、Cloudflare Tunnel 和本机 Claude Code CLI 组成。网页位于 `src/web/`，只用于调试，不是产品主入口。

```text
Flutter App
  -> HTTPS / WSS
  -> Cloudflare Tunnel
  -> local daemon on 127.0.0.1:8787
  -> Claude Code CLI
```

当前是单设备授权模型。一个 daemon 可以注册多个项目，每个项目拥有多条独立会话。项目只能从电脑端注册，手机不能提交任意文件系统路径。

## 仓库结构

```text
cc-remote/
  src/
    daemon.ts                 HTTP、WebSocket 和运行编排
    authState.ts              配对、token hash 和授权代际
    claudeBridge.ts           Claude Code stream-json 桥接
    projectSessionState.ts    项目、会话和活动上下文
    transcriptState.ts        权威 transcript 和运行状态
    workspaceService.ts       只读文件与 Git diff
    attachmentStore.ts        附件隔离存储
    attachmentUpload.ts       multipart 上传
    localControlState.ts      本机项目注册凭据
    web/                      调试网页

  mobile/lib/
    main.dart                 App shell、网络状态和主要页面
    signal_console_theme.dart 主题令牌与视觉部件
    workspace_drawer.dart     只读工作区和 Git diff
    attachments.dart          选择、上传和附件模型
    notification_service.dart Android 本地通知

  tests/                      daemon 单元测试
  mobile/test/               Flutter 逻辑与组件测试
```

Flutter 当前仍以 `main.dart` 集中管理应用状态。这个结构与现有规模匹配。后续只有在功能继续增长时才拆 controllers、services 和 screens，不为目录形式提前重构。

## 启动与项目注册

`cc-remote` 启动脚本检查 `127.0.0.1:8787`。没有运行实例时，它启动 daemon 和可选 tunnel，并把当前目录写入 `WORKSPACE_DIR`。daemon 冷启动后会调用 `registerProject(WORKSPACE_DIR)`，把该目录注册为项目并设为活动上下文；这与“daemon 已在跑时再执行 `cc-remote`”的行为对齐，避免重启后一直停在上次活动项目。

已有新版 daemon 时，脚本通过 `/api/local/projects/register` 注册当前目录并切换活动项目。该接口使用本机私有控制 token，不接受手机 Bearer token。手机只能切换已注册项目，不能提交任意文件系统路径。

daemon 将项目与会话目录保存在 `.data/projects.json`，各会话 transcript 保存在 `.data/sessions/`。附件保存在 `.data/uploads/`。旧版单会话 transcript 会在加载时迁移到默认项目的第一条会话。

## 配对与鉴权

daemon 生成一次性二维码，payload 包含 `type`、`version`、`origin`、`nonce`、`deviceName` 和 `expiresAt`。nonce 5 分钟过期，只保存 hash，使用一次后失效。

App 调用 `POST /api/pair` 换取 Bearer token。token 明文只返回给 App，App 存入 Secure Storage，daemon 只保存 hash。重新配对和 logout 会增加授权代际并关闭旧 WebSocket。

普通 HTTP 请求使用 `Authorization: Bearer <token>`。WebSocket token 不放 URL，连接 `/ws` 后第一条消息必须是 `auth`。

## HTTP API

`GET /api/health` 和 `POST /api/pair` 不需要 Bearer token。其余手机 API 都需要授权。

项目与会话接口包括 `/api/status`、`/api/projects`、`/api/sessions/:id`、创建会话、选择会话、重命名、归档和删除。活动 Claude 任务运行时禁止切换或创建会话。

工作区接口包括 `/api/workspace`、`/api/workspace/file` 和 `/api/workspace/diff`。路径必须位于活动项目内，Git 内部文件、被忽略文件和路径穿越会被拒绝。接口只读。

附件通过 `/api/sessions/:id/attachments` 上传，通过带会话归属的 content 接口读取。上传是事务式的，失败时清理已经写入的同批文件。附件路径不会进入 transcript 或手机 UI。

`POST /api/new-conversation` 是兼容入口，实际会在活动项目下创建新会话。`POST /api/stop` 停止当前进程。`POST /api/logout` 撤销配对。

## WebSocket 运行流

鉴权完成后，daemon 发送 `catalog`、`status`、`transcript_snapshot`、`permission_capabilities` 和当前 `session_info`。App 由此恢复项目、会话、运行状态、待审批请求、模型和剩余上下文。活动任务状态包含 `running`、`stopping`、`runId` 和 `startedAt`，用于在重连后恢复 Stop 按钮状态与思考计时。

任务消息包含 `sessionId`、文本、附件 ID 和权限模式。daemon 校验会话归属和附件归属，将可信附件路径拼入交给 Claude 的 prompt，并通过 `--add-dir` 允许 Claude 读取隔离目录。

Claude Code 运行期间，daemon 将输出归一化为 `text`、`activity`、`session_info` 和 `permission_request`。`activity` 会移除私有思考文本、完整工具结果和附件本机路径，同时保留 `Skill` 工具的具体 Skill 名称。`text` 在 daemon 侧短时合批后再推送，任务进入 `done` / `stopped` / `error` 前会 flush 尾包，随后广播空闲状态和更新后的 catalog。

`transcript_snapshot` 是会话内容的权威来源。App 可以先显示本地缓存，WebSocket 鉴权后再以 daemon 快照补齐断线输出。WebSocket 客户端按退避间隔自动重连，但不自动重发 prompt；重连后通过同一份快照和活动任务状态继续展示运行中或停止中的任务。daemon 重启时，持久化为 running 的任务会归一化为 interrupted。

## Flutter 状态流

App 启动后读取 Secure Storage。没有 token 时进入配对页。有 token 时调用 `/api/status`。成功后进入主控制台并建立 WebSocket。401 会清除本地配对并返回扫码页。网络失败会保留 token 和 transcript，进入电脑端离线状态。

App 区分已配对、正在连接、已连接、运行中、停止中、上传中和离线。上传附件、运行任务或停止任务时，相关导航和重复操作会被禁用。App 回到前台会重新探测 daemon。

多项目和多会话由 catalog 驱动。会话消息带 `projectId` 与 `sessionId`，App 忽略不属于当前会话的运行消息。通知点击后在安全状态下切换到对应会话。「项目与会话」面板和设置页展示完整项目路径，方便区分同名目录。

流式回复时，App 会短时合并 `text` 增量再刷新 UI，运行中用轻量文本渲染，任务结束后再切回 Markdown；本地 transcript 落盘在流式期间节流，终态强制写入。

恢复历史 Claude session 时，桥接层等待子进程 `close` 后再汇总退出码与 stderr，避免初始化前退出覆盖 CLI 的真实错误。若 daemon 识别到 session 已不存在，只清除旧 Claude session ID，并在同一轮请求中无 `--resume` 重试一次；其他初始化错误不会触发自动重试。桥接层和 daemon WebSocket 端到端测试均覆盖这一行为。

## 通知

Android 本地通知由已建立的 App WebSocket 触发，覆盖任务完成、失败、停止和等待权限。通知偏好本地持久化，点击通知返回对应会话。

App 进程被系统彻底杀死后没有常驻连接，因此不能继续接收事件。这个场景需要后续接入 FCM。

## 安全边界

daemon 默认只监听 loopback。公网访问由 tunnel 提供。手机不能注册项目、不能修改工作区、不能调用任意 shell。工作区读取遵循路径限制和 Git 忽略规则。

权限模式映射 Claude Code 原生模式。`bypassPermissions` 可在电脑端关闭；即使开启，手机也需要二次确认，并只对单次任务生效。审批请求只能允许一次或拒绝，手机不能修改工具参数。

## 当前未完成

多设备管理、会话全文搜索、FCM 推送、发布签名和商店材料尚未实现。公网 health 检查，以及冷启动切项目 / 隧道首字延迟对照仍需专项验证。Claude 进程预热和可选局域网直连属于后续性能项。
