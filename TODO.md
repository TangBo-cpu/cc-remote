# TODO

本文同步到 `master` 当前版本。Signal Console 手机端主链路、工作区冷启动对齐、流式性能合批和可靠性自动化已经完成，并通过电脑端与 Flutter 回归测试。

## 已完成

### 电脑端与协议

- [x] daemon 只监听 `127.0.0.1:8787`
- [x] 一次性 JSON 二维码和 Bearer token 配对
- [x] WebSocket 首条 `auth` 消息鉴权
- [x] logout 与重新配对撤销旧连接
- [x] 本机 `claude` CLI stream-json 桥接
- [x] Claude session 恢复与 stale session 自动重试
- [x] 权限请求双向控制和六种权限模式
- [x] transcript、审批状态、模型和上下文持久化
- [x] 多项目注册、多会话创建与切换
- [x] 冷启动按 `WORKSPACE_DIR` / 启动目录注册并激活项目
- [x] 只读工作区、文件内容和 Git diff API
- [x] 会话附件上传、隔离保存和路径脱敏
- [x] `cc-remote` 一键启动与重复运行时注册项目
- [x] 流式 `text` 短时合批推送，任务结束前 flush 尾包
- [x] daemon HTTP、WebSocket、鉴权和静态暴露黑盒测试
- [x] Claude CLI fixture 覆盖 session resume 和 Windows Stop 进程树清理
- [x] 实际 daemon、WebSocket 和 Claude CLI 完成两轮 resume 与 Stop 验证

### Flutter App

- [x] 扫码、配对确认和 Secure Storage
- [x] 启动恢复、离线态、前台重连和退出配对
- [x] prompt、流式输出、停止和错误状态
- [x] Claude Code 斜杠指令搜索与滚动选择
- [x] 思考计时、安全化工具活动和 Markdown 输出
- [x] 流式期间轻量文本渲染，结束后再 Markdown
- [x] 流式 `setState` 合批与本地 transcript 落盘节流
- [x] 权限模式选择和一次性工具审批
- [x] 项目与会话面板、新会话和 transcript 恢复
- [x] 项目完整路径显示（会话面板与设置页）
- [x] 工作区文件与 Git diff 抽屉
- [x] 拍照、图片和文件附件
- [x] Android 后台本地通知与通知开关
- [x] 浅色活力主题、紧凑双栏连接舱和 Command Dock
- [x] 小屏、横屏、键盘、大字体和缩放溢出回归测试
- [x] Claude 普通回复使用瓷白实体气泡、边框和正常留白
- [x] 最新调试版真机安装和主界面检查

### 文档

- [x] 根 README 与当前启动、安装和协议一致
- [x] 移动端 README 与当前 UI 和调试流程一致
- [x] UI 设计文档改为当前活力浅色方案
- [x] 系统架构与 Flutter 实现文档去掉初版假设

## 待专项验证

- [x] 真机连续发送第二条 prompt，确认 `--resume <claudeSessionId>` 延续上下文
- [ ] 真机 Stop 中断长任务并确认没有残留 Claude 进程
- [x] logout 后旧 Bearer token 与旧 WebSocket 均失效
- [x] 错误 Origin 和 Host 被 daemon 拒绝，WebSocket upgrade 同样受限
- [ ] 手机浏览器通过公网域名访问 `/api/health`
- [x] 确认 `.data/` 不会被本地或公网静态服务暴露
- [ ] 冷启动切换到另一项目目录后，手机 catalog 与 Claude cwd 同步
- [ ] 公网隧道下首字延迟与流式顺滑度对照本机

## 后续功能

- [ ] 多设备授权、设备列表和单设备撤销
- [ ] 会话全文搜索
- [ ] FCM 推送，覆盖 App 进程被系统彻底杀死的场景
- [x] daemon API 与 WebSocket 端到端自动化测试
- [ ] 一键重置配对接口
- [ ] 桌面托盘二维码窗口
- [ ] 应用签名、版本发布和商店材料
- [ ] Claude 进程预热 / 长驻 bridge，继续压首包延迟
- [ ] 可选局域网直连调试入口（默认仍走 tunnel）

## 保持不做

- [ ] 手机端注册任意电脑目录
- [ ] 任意 shell API
- [ ] 工作区远程编辑、暂存和提交
- [ ] 默认无确认跳过 Claude Code 权限
