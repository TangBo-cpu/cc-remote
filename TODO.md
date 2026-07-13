# TODO

## 当前已完成

### Daemon

- [x] daemon 默认只监听 `127.0.0.1:8787`
- [x] 终端显示 App 扫码用 JSON payload 二维码
- [x] `/api/pair` 使用 nonce 换取 Bearer token
- [x] daemon 只保存 token hash，不保存 token 明文
- [x] HTTP API 使用 `Authorization: Bearer <token>`
- [x] WebSocket 使用首条 `{ "type": "auth", "token": "..." }` 鉴权
- [x] 未鉴权 WebSocket 不接受 `prompt` / `stop`
- [x] logout / re-pair 关闭旧 WebSocket
- [x] Claude bridge 使用本机 `claude` CLI stream-json
- [x] Claude bridge 保留 `--resume <claudeSessionId>`
- [x] stale Claude Code session 报 `No conversation found with session ID` 时清理并新会话重试
- [x] auth state 写入串行化，避免并发写 `.data/state.json` 临时文件 race
- [x] Claude bridge 对重复 `session_id` 去重，避免同一轮 prompt 重复写状态
- [x] `POST /api/new-conversation` 可清空当前 `claudeSessionId`
- [x] 电脑端使用 `cc-remote` 一键启动
- [x] 单 daemon 注册多个项目，并在重复执行 `cc-remote` 时切换当前项目
- [x] 项目下创建多条独立会话，每条会话独立保存 Claude session 和 transcript

### Flutter App

- [x] 创建 `mobile/` Flutter 项目
- [x] 加依赖：`mobile_scanner`、`flutter_secure_storage`、`http`、`web_socket_channel`
- [x] Android 增加 Camera / Internet 权限
- [x] 实现 QR JSON 解析和校验
- [x] 实现配对确认 sheet
- [x] 实现 `POST /api/pair`
- [x] token 存入 Secure Storage
- [x] 启动时读取 token 并调用 `/api/status`
- [x] 显示已配对设备和工作区
- [x] 实现 Logout 并清本地 token
- [x] 实现 WebSocket connect + auth 消息
- [x] 发送 prompt 时发送 `{ "type": "prompt", "text": "..." }`
- [x] 收到 `text` 时追加到当前 assistant message
- [x] 收到 `done` / `error` / `stopped` 时更新运行状态
- [x] Stop 按钮发送 `{ "type": "stop" }`
- [x] 断线时显示重连入口，不自动重发 prompt
- [x] 区分“已配对”和“已连接”
- [x] daemon 离线时显示“电脑端离线”并禁用发送
- [x] App 回到前台时重新探测 daemon 状态
- [x] 不再在没有返回文本时留下空 assistant 气泡
- [x] 设置里可开启新对话并清空当前 transcript
- [x] 输入 `/` 获取 Claude Code 真实斜杠指令并实时筛选
- [x] 指令建议列表支持独立滚动
- [x] 用户与 assistant 使用左右消息气泡
- [x] 任务运行时显示思考动效、状态文字和实时计时
- [x] 运行中显示工具调用，结束后清理临时活动卡片
- [x] 显示当前模型和剩余上下文
- [x] App 本地保存当前 transcript
- [x] daemon 原子保存当前对话权威快照
- [x] WebSocket 重连后恢复断线期间的输出
- [x] daemon 重启后恢复当前对话并标记中断任务
- [x] 接入 Claude Code stdio 双向权限控制协议
- [x] 手机端允许一次或拒绝工具请求
- [x] 等待审批状态随 transcript 快照恢复
- [x] 支持六种 Claude Code 权限模式
- [x] `bypassPermissions` 默认开启，可用 `-DisableBypassPermissions` 关闭；手机确认后只对单次任务生效
- [x] 左侧工作区抽屉：浏览文件、查看 Git 修改和 diff
- [x] daemon 提供只读 `GET /api/workspace`、`/api/workspace/file`、`/api/workspace/diff`
- [x] 手机端项目与会话切换面板
- [x] 新会话、会话恢复和旧单会话 transcript 自动迁移
- [x] Android 后台本地通知：任务完成、失败、停止和等待权限
- [x] 通知开关持久化，点击通知返回对应会话

### 文档和保存点

- [x] README 更新为 App-first token 协议
- [x] mobile README 更新为真实 WebSocket 对话流程
- [x] 移动端活动与会话上下文功能已合并回 `master`：`3cad17f merge: mobile activity and session context UI`
- [x] 文档同步代码现状：权限审批、transcript 恢复、工作区只读、bypass 默认策略

## 真机 UI 验证

本地脚本和真机 App 已完成 WebSocket auth、流式输出、`done`、指令列表与会话上下文展示验证。连续会话和 Stop 中断仍需单独验证：

- [x] 本地启动 daemon 并通过 `/api/health`
- [x] 本地脚本模拟 App 调用 `/api/pair`
- [x] 本地脚本模拟 App WebSocket auth 成功
- [x] 本地脚本模拟 App 发送 `回复 pong，只输出 pong`
- [x] daemon 启动本机 `claude` CLI
- [x] 本地脚本模拟 App 收到真实 `pong` 输出
- [x] 本地脚本模拟 App 收到 `done`
- [x] `.data/state.json` 写入 `claudeSessionId`
- [x] 本地脚本模拟 App 验证长输出多段 `text`
- [x] 真机 App 扫新二维码并显示已连接
- [x] 真机 App 显示真实 Claude Code 流式输出
- [x] 真机 App 收到 `done`
- [x] 真机 App 获取真实斜杠指令并支持筛选和滚动
- [x] 真机 App 显示思考计时、工具调用、模型和剩余上下文
- [ ] 第二条 prompt 验证 `--resume <claudeSessionId>` 生效
- [ ] Stop 可中断长任务
- [ ] Stop 后无残留 Claude 进程

## 下一步验证清单

### Daemon / API

- [x] 本机启动 daemon 后可打印二维码
- [x] `GET /api/health` 可返回 `{ "ok": true }`
- [x] 旧 daemon 占用 `127.0.0.1:8787` 时可定位并杀掉
- [ ] 无 token 访问 `/api/status` 返回 401
- [x] Bearer token 访问 `/api/status` 返回已授权状态
- [ ] logout 后旧 Bearer token 失效
- [ ] stale `claudeSessionId` 自动清理并重试新会话

### Cloudflare Tunnel

- [x] 设置 `PUBLIC_ORIGIN=https://tbhaoshuai.ccwu.cc`
- [x] tunnel 指向 `http://127.0.0.1:8787`
- [x] 电脑端访问 `https://tbhaoshuai.ccwu.cc/api/health` 成功
- [ ] 手机浏览器访问 `https://tbhaoshuai.ccwu.cc/api/health` 成功
- [x] 手机 App 经域名配对成功
- [x] 手机 App 经 `wss://tbhaoshuai.ccwu.cc/ws` 连接成功并 auth
- [ ] 验证错误 Origin 无法调用 mutating API
- [ ] 验证错误 Host 被拒绝

### App 端到端

- [x] 手机扫码配对成功
- [x] App 显示已配对设备
- [x] 关闭重开 App 后可恢复已配对状态
- [x] daemon 离线时显示“电脑端离线”
- [x] App logout 可清理本地 token
- [x] 本地脚本模拟 App 发送 prompt 后 daemon 启动本机 `claude` CLI
- [x] 本地脚本模拟 App 能收到流式 `text`
- [x] 本地脚本模拟 App 能收到 `done`
- [x] 真机 App 能显示真实流式 `text`
- [x] 真机 App 能在 `done` 后恢复可发送状态
- [ ] Stop 可中断长任务
- [ ] Stop 后无残留 Claude 进程

## 已知限制

- [ ] 只有单设备授权态，没有多设备管理
- [x] 多项目注册与切换
- [ ] 网页/PWA 只作为调试壳，不是主产品入口
- [ ] 没有文件上传/下载；工作区只读，不提供远程编辑/暂存/提交
- [ ] 会话列表已有，尚未提供全文搜索、归档和删除
- [ ] 接入 FCM，覆盖 App 进程被系统杀死或长期 Doze 的通知

## 后续可加

- [ ] daemon API / WebSocket 自动化测试覆盖 token 协议
- [ ] 设备列表和撤销单个设备
- [ ] 多会话历史列表和搜索
- [ ] Claude CLI 真实 stream-json fixture 测试
- [ ] Cloudflare Access 可选保护
- [ ] 文件上传到固定临时目录，再让 Claude Code 读取
- [ ] 一键重置配对接口
- [ ] 桌面托盘二维码窗口

## 发布前检查

- [x] `npm run typecheck`
- [ ] `npm run build`
- [x] `npm test`
- [x] `cd mobile; flutter analyze`
- [x] `cd mobile; flutter test`
- [ ] 确认 `.data/` 不会被静态服务暴露
- [x] 确认 `.run/` 不会被提交
- [x] 确认 daemon 仍只监听 `127.0.0.1`
- [x] 确认没有加入 `--dangerously-skip-permissions`
