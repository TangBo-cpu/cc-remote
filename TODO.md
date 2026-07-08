# TODO

## 当前已完成

### Daemon

- [x] daemon 只监听 `127.0.0.1:8787`
- [x] 终端显示 App 扫码用 JSON payload 二维码
- [x] `/api/pair` 使用 nonce 换取 Bearer token
- [x] daemon 只保存 token hash，不保存 token 明文
- [x] HTTP API 使用 `Authorization: Bearer <token>`
- [x] WebSocket 使用首条 `{ "type": "auth", "token": "..." }` 鉴权
- [x] 未鉴权 WebSocket 不接受 `prompt` / `stop`
- [x] logout / re-pair 关闭旧 WebSocket
- [x] Claude bridge 保留 stream-json 和 `--resume <claudeSessionId>`
- [x] `npm test`

### Flutter App

- [x] 创建 `mobile/` Flutter 项目
- [x] 加依赖：`mobile_scanner`、`flutter_secure_storage`、`http`、`web_socket_channel`
- [x] Android 增加 Camera / Internet 权限
- [x] 实现 QR JSON 解析和校验
- [x] 实现配对确认 sheet
- [x] 实现 `POST /api/pair`
- [x] token 存入 Secure Storage
- [x] 启动时读取 token 并调用 `/api/status`
- [x] 显示已连接设备和工作区
- [x] 实现 Logout 并清本地 token
- [x] 实现 WebSocket connect + auth 消息
- [x] 发送 prompt 时发送 `{ "type": "prompt", "text": "..." }`
- [x] 收到 `text` 时追加到当前 assistant message
- [x] 收到 `done` / `error` / `stopped` 时更新运行状态
- [x] Stop 按钮发送 `{ "type": "stop" }`
- [x] 断线时显示重连入口，不自动重发 prompt
- [x] `flutter test`

### 文档和保存点

- [x] README 更新为 App-first token 协议
- [x] 当前配对壳状态已提交：`6777cda feat: add mobile pairing shell`

## 当前未完成：真机对话验证

App 已接入 WebSocket 对话，但还需要真机端到端验证：

- [ ] 手机 App 连接 `wss://tbhaoshuai.ccwu.cc/ws` 成功
- [ ] 发送 `回复 pong，只输出 pong`
- [ ] daemon 启动本机 `claude` CLI
- [ ] App 显示真实 `pong` 输出
- [ ] App 收到 `done`
- [ ] Stop 可中断长任务

## 下一步验证清单

### Daemon / API

- [x] 本机启动 daemon 后可打印二维码
- [x] `GET /api/health` 可返回 `{ "ok": true }`
- [x] 旧 daemon 占用 `127.0.0.1:8787` 时可定位并杀掉
- [ ] 无 token 访问 `/api/status` 返回 401
- [ ] Bearer token 访问 `/api/status` 返回已授权状态
- [ ] logout 后旧 Bearer token 失效

### Cloudflare Tunnel

- [x] 设置 `PUBLIC_ORIGIN=https://tbhaoshuai.ccwu.cc`
- [x] tunnel 指向 `http://127.0.0.1:8787`
- [x] 电脑端访问 `https://tbhaoshuai.ccwu.cc/api/health` 成功
- [ ] 手机浏览器访问 `https://tbhaoshuai.ccwu.cc/api/health` 成功
- [x] 手机 App 经域名配对成功
- [ ] 手机 App 经 `wss://tbhaoshuai.ccwu.cc/ws` 连接成功并 auth
- [ ] 验证错误 Origin 无法调用 mutating API
- [ ] 验证错误 Host 被拒绝

### App 端到端

- [x] 手机扫码配对成功
- [x] App 显示已连接设备
- [x] 关闭重开 App 后可恢复已配对状态
- [x] App logout 可清理本地 token
- [ ] 真机 App 发送 prompt 后 daemon 启动本机 `claude` CLI
- [ ] 真机 App 能收到流式 `text`
- [ ] 真机 App 能收到 `done`
- [ ] `.data/state.json` 写入 `claudeSessionId`
- [ ] 第二条 prompt 验证 `--resume <claudeSessionId>` 生效
- [ ] Stop 可中断长任务
- [ ] Stop 后无残留 Claude 进程

## 已知限制

- [ ] 只有单设备授权态，没有多设备管理
- [ ] 只有单项目工作目录，通过 `WORKSPACE_DIR` 固定
- [ ] 网页/PWA 只作为调试壳，不是主产品入口
- [ ] App 聊天功能已接 WebSocket，但尚未完成真机 Claude 输出验证
- [ ] 没有文件上传/下载
- [ ] 没有手机端权限审批流
- [ ] 没有任务历史持久化，重开 App 不恢复 transcript
- [ ] 没有后台任务恢复展示，WebSocket 断线期间的输出可能丢失

## 后续可加

- [ ] daemon API / WebSocket 自动化测试覆盖新 token 协议
- [ ] 设备列表和撤销单个设备
- [ ] Transcript 本地持久化
- [ ] Claude CLI 真实 stream-json fixture 测试
- [ ] Cloudflare Access 可选保护
- [ ] 文件上传到固定临时目录，再让 Claude Code 读取
- [ ] 权限请求/审批事件的手机端 UI
- [ ] 一键重置配对接口
- [ ] 桌面托盘二维码窗口

## 发布前检查

- [ ] `npm run typecheck`
- [ ] `npm run build`
- [ ] `npm test`
- [ ] `cd mobile; flutter test`
- [ ] 确认 `.data/` 不会被静态服务暴露
- [ ] 确认 `.run/` 不会被提交
- [ ] 确认 daemon 仍只监听 `127.0.0.1`
- [ ] 确认没有加入 `--dangerously-skip-permissions`
