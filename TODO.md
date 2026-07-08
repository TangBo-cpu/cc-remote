# TODO

## 当前已完成

- [x] daemon 只监听 `127.0.0.1:8787`
- [x] 终端显示 App 扫码用 JSON payload 二维码
- [x] `/api/pair` 使用 nonce 换取 Bearer token
- [x] daemon 只保存 token hash，不保存 token 明文
- [x] HTTP API 使用 `Authorization: Bearer <token>`
- [x] WebSocket 使用首条 `{ "type": "auth", "token": "..." }` 鉴权
- [x] 未鉴权 WebSocket 不接受 `prompt` / `stop`
- [x] logout / re-pair 关闭旧 WebSocket
- [x] Claude bridge 保留 stream-json 和 `--resume <claudeSessionId>`
- [x] `npm run typecheck`
- [x] `npm run build`
- [x] `npm test`

## 下一步 daemon 协议验证

- [ ] 本机启动 daemon：`npm run dev`
- [ ] 确认 `/api/health` 返回 `{ "ok": true }`
- [ ] 扫描终端 JSON 二维码，或复制 payload 中的 `nonce`
- [ ] `POST /api/pair` 返回 `{ "ok": true, "token": "..." }`
- [ ] 无 token 访问 `/api/status` 返回 401
- [ ] Bearer token 访问 `/api/status` 返回已授权状态
- [ ] WebSocket 未 auth 发送 `prompt` 会被拒绝
- [ ] WebSocket auth 成功后收到 `status` 消息
- [ ] WebSocket auth 后发送 prompt，确认能启动本机 `claude` CLI
- [ ] 确认 App/客户端能收到流式 `text`
- [ ] 确认 `.data/state.json` 写入 `claudeSessionId`
- [ ] 第二条 prompt 验证 `--resume <claudeSessionId>` 生效
- [ ] 发送长任务后 Stop，确认任务可中断且不会残留 Claude 进程
- [ ] logout 后旧 Bearer token 失效
- [ ] logout 后旧 WebSocket 被关闭

## Cloudflare Tunnel 验证

- [ ] 设置 `PUBLIC_ORIGIN=https://tbhaoshuai.ccwu.cc`
- [ ] 启动 tunnel 指向 `http://127.0.0.1:8787`
- [ ] 确认 `https://tbhaoshuai.ccwu.cc/api/health` 可访问
- [ ] 手机 App 经域名调用 `/api/pair` 成功
- [ ] 手机 App 经 `wss://tbhaoshuai.ccwu.cc/ws` 连接成功
- [ ] 验证错误 Origin 无法调用 mutating API
- [ ] 验证错误 Host 被拒绝

## Flutter App 后续

- [ ] 创建 `mobile/` Flutter 项目
- [ ] 加依赖：`mobile_scanner`、`flutter_secure_storage`、`http`、`web_socket_channel`
- [ ] 实现 QR JSON 解析和校验
- [ ] 实现 `POST /api/pair`
- [ ] token 存入 Secure Storage
- [ ] 启动时读取 token 并调用 `/api/status`
- [ ] 实现 WebSocket connect + auth 消息
- [ ] 实现 prompt 发送和流式文本显示
- [ ] 实现 Stop
- [ ] 实现 Logout 并清本地 token

## 已知限制

- [ ] 只有单设备授权态，没有多设备管理
- [ ] 只有单项目工作目录，通过 `WORKSPACE_DIR` 固定
- [ ] 网页/PWA 只作为调试壳，不是主产品入口
- [ ] 网页/PWA 仍可能不兼容当前 token 协议
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
- [ ] 确认 `.data/` 不会被静态服务暴露
- [ ] 确认 daemon 仍只监听 `127.0.0.1`
- [ ] 确认没有加入 `--dangerously-skip-permissions`
