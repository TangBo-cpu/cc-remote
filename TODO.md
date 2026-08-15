# TODO

本文同步到当前开发版本。手机端主链路、工作区冷启动对齐、流式性能合批和可靠性自动化已经完成；Warm Console 主界面与 a11y/UX 补强已进入开发代码，并完成多机 release 安装；逐屏视觉清单与恢复终态面板仍待收尾。

## 已完成

### 电脑端与协议

- [x] daemon 只监听 `127.0.0.1:8787`
- [x] 一次性 JSON 二维码和 Bearer token 配对
- [x] WebSocket 首条 `auth` 消息鉴权
- [x] logout 与重新配对撤销旧连接
- [x] 本机 `claude` CLI stream-json 桥接
- [x] Claude session 恢复；历史 session 失效时清除旧 ID 并自动重试
- [x] 权限请求双向控制和六种权限模式
- [x] transcript、审批状态、模型和上下文持久化
- [x] 多项目注册、多会话创建与切换
- [x] 冷启动按 `WORKSPACE_DIR` / 启动目录注册并激活项目
- [x] 只读工作区、文件内容和 Git diff API
- [x] 会话附件上传、隔离保存和路径脱敏
- [x] `cc-remote` 一键启动与重复运行时注册项目
- [x] 流式 `text` 短时合批推送，任务结束前 flush 尾包
- [x] daemon HTTP、WebSocket、鉴权和静态暴露黑盒测试
- [x] Claude CLI fixture 覆盖 session resume、失效 session 自动重试和 Windows Stop 进程树清理
- [x] 实际 daemon、WebSocket 和 Claude CLI 完成两轮 resume 与 Stop 验证

### Flutter App

- [x] 扫码、配对确认和 Secure Storage
- [x] 启动恢复、离线态、WebSocket 自动重连、前台探测和退出配对
- [x] prompt 接收确认与去重、流式输出、停止和错误状态
- [x] 断线重连后恢复活动任务、Stop 中间态和思考计时
- [x] Claude Code 斜杠指令搜索与滚动选择
- [x] 思考计时、安全化工具活动（含具体 Skill 名称）和 Markdown 输出
- [x] 流式期间轻量文本渲染，结束后再 Markdown
- [x] 流式 `setState` 合批与本地 transcript 落盘节流
- [x] 权限模式选择和一次性工具审批
- [x] 项目与会话面板、新会话和 transcript 恢复
- [x] 项目完整路径显示（会话面板与设置页）
- [x] 工作区文件与 Git diff 抽屉
- [x] 拍照、图片和文件附件
- [x] Android 后台本地通知与通知开关
- [x] 浅色活力主题、紧凑双栏连接舱和 Command Dock（历史里程碑；现已被 Warm Console 取代）
- [x] 小屏、横屏、键盘、大字体和缩放溢出回归测试
- [x] Claude 普通回复使用 elevated paper 实体气泡、边框和衬线正文
- [x] 最新调试/release 版真机安装和主界面检查

### Warm Console 实现

- [x] 建立根目录 `DESIGN.md` 与 Impeccable 设计 sidecar
- [x] Penpot 补齐配对、会话选择、运行控制、权限、Diff 与恢复终态
- [x] UI 实现文档同步到最新 Warm Console
- [x] 迁移主题 tokens 并将主界面、工作区统一为 Lucide 线性图标
- [x] 重构紧凑会话头、transcript 活动展示和贴底 Composer
- [x] 完成 Composer 圆形扩展/发送/停止、暖色模型胶囊和上下文 token 隐藏
- [x] 按 Warm Console 整理设置与“···”菜单，菜单底栏最多保留模型名
- [x] 思考态改为 brain 脉冲，活动 running 保留原生进度指示器
- [x] 移除 `flutter_animate`，仅保留 `lucide_icons_flutter` 作为本轮新增视觉依赖
- [x] `terracotta-deep` CTA、打包 Noto 字体、助手 elevated 气泡
- [x] 权限决策展示 `workspaceDir`（缺失时 fallback 文案）
- [x] `ConsoleStatusStrip` 覆盖连接中等非已连接相位；连接中空状态独立于离线卡
- [x] 输入聚焦描边使用 `terracotta-deep`
- [ ] 继续逐屏验收配对、会话选择、权限决策与 Diff
- [x] 用共享 `ConsolePresentation` 统一 Header / Composer / 状态条的离线、失败、停止中、已停止和停止超时语义
- [ ] 补齐共享恢复信息面板与有明确失败事实的重连失败视图
- [x] 更新组件测试，覆盖 Composer 尺寸、模型语义、菜单去 token、活动状态、连接中状态条/空状态与权限工作目录
- [ ] 完成 Android 真机 Warm Console 逐屏视觉验收清单

### 文档

- [x] 根 README 与当前启动、安装和协议一致
- [x] 移动端 README 与当前 UI 和调试流程一致
- [x] UI 设计文档更新为当前 Warm Console 实现与验收规格（含 2026-08-15 a11y/UX 补强）
- [x] 系统架构与 Flutter 实现文档去掉初版假设

## 待专项验证

- [x] 真机连续发送第二条 prompt，确认 `--resume <claudeSessionId>` 延续上下文
- [x] 真机 Stop 中断长任务并确认没有残留 Claude 进程
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
- [x] 发布 `v1.1.0` GitHub Release 和 Android APK
- [x] 发布 `v1.2.0` GitHub Release 和 Android APK（Warm Console + 连续字号 + 宽气泡）
- [ ] Android 正式签名和应用商店材料
- [ ] Claude 进程预热 / 长驻 bridge，继续压首包延迟
- [ ] 可选局域网直连调试入口（默认仍走 tunnel）

## 保持不做

- [ ] 手机端注册任意电脑目录
- [ ] 任意 shell API
- [ ] 工作区远程编辑、暂存和提交
- [ ] 默认无确认跳过 Claude Code 权限
