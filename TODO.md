# TODO

本文同步到当前开发版本。手机端主链路、工作区冷启动对齐、流式性能合批和可靠性自动化已经完成。当前视觉是 Cool Glass Console（语义色、Phosphor Fill 身份图标、共享 option sheet）；Warm Console / 冰川蓝选择器是历史里程碑。助手短回复 hug 内容、流式期间即可 Markdown、代码块不再套第二层描边；默认阅读字号 100%。真机已覆盖安装；逐屏视觉清单与断线重连终态策略仍待收尾。

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
- [x] 会话级引擎切换：`engineBridge` 统一接口 + `codexBridge` Codex CLI 桥接（fixture 覆盖）
- [x] 新建会话可选 Claude / Codex；prompt 校验 engine 一致性，Codex 会话仅图片附件、三档沙箱模式且 danger 发送后自动回落
- [x] transcript `claudeSessionId` 更名 `engineSessionId` 并兼容旧数据；session 记录持久化 `engine` 字段
- [x] 实际 daemon、WebSocket 和 Claude CLI 完成两轮 resume 与 Stop 验证

### Flutter App

- [x] 扫码、配对确认和 Secure Storage
- [x] 启动恢复、离线态、WebSocket 自动重连、前台探测和退出配对
- [x] prompt 接收确认与去重、流式输出、停止和错误状态
- [x] 断线重连后恢复活动任务、Stop 中间态和思考计时
- [x] Claude Code 斜杠指令搜索与滚动选择
- [x] Composer 调整 Claude Code `effort`，覆盖自动、低、中、高、超高、最大并传递到 daemon
- [x] 思考计时、安全化工具活动（含具体 Skill 名称）和 Markdown 输出
- [x] 无标记纯文本走 `Text`；有 Markdown 标记时流式期间即用 `MarkdownBody`
- [x] 流式 `setState` 合批与本地 transcript 落盘节流
- [x] 权限模式选择和一次性工具审批
- [x] 新建会话时选择引擎（Claude / Codex）；Codex 会话沙箱模式选择与图片附件限制
- [x] 项目与会话导航页、新会话和 transcript 恢复
- [x] 项目完整路径显示（会话导航页与设置页）
- [x] 工作区文件与 Git diff 抽屉
- [x] 拍照、图片和文件附件
- [x] Android 后台本地通知与通知开关
- [x] 浅色活力主题、紧凑双栏连接舱和 Command Dock（历史里程碑；后经 Warm Console，现为 Cool Glass）
- [x] 小屏、横屏、键盘、大字体和缩放溢出回归测试
- [x] Claude 普通回复使用 `surfaceElevated` + 细描边阅读气泡、短文本 hug、统一 22px 圆角和系统默认正文
- [x] 最新调试/release 版真机安装和主界面检查

### Warm Console 实现（历史）

- [x] 建立根目录 `DESIGN.md` 与 Impeccable 设计 sidecar
- [x] Penpot 补齐配对、会话选择、运行控制、权限、Diff 与恢复终态
- [x] UI 实现文档当时同步到 Warm Console；现已改记 Cool Glass
- [x] 迁移主题 tokens；chrome 使用 Lucide，会话 / 项目 / 模型身份标记使用 Phosphor Fill
- [x] 重构紧凑会话头、transcript 活动展示和贴底 Composer
- [x] 完成 Composer 圆形附件 / 思考强度仪表 / 发送 / 停止、模型胶囊、权限图标和紧凑上下文余量
- [x] 按 Warm Console 整理设置与“···”菜单，菜单底栏最多保留模型名
- [x] 思考态改为固定中心的花形动画，活动 running 保留原生进度指示器
- [x] 移除 `flutter_animate`；chrome 保留 `lucide_icons_flutter`，身份标记使用 `phosphor_icons` Fill
- [x] `accent` CTA、系统默认 UI 字体、助手 elevated 气泡与 Markdown / 代码块层级
- [x] 权限决策展示 `workspaceDir`（缺失时 fallback 文案）
- [x] `ConsoleStatusStrip` 覆盖连接中等非已连接相位；连接中空状态独立于离线卡
- [x] 输入聚焦描边使用 `accent`
- [ ] 继续逐屏验收配对、会话选择、权限决策与 Diff
- [x] 用共享 `ConsolePresentation` 统一 Header / Composer / 状态条的离线、失败、停止中、已停止和停止超时语义
- [x] 补齐共享恢复/终态面板，统一连接中、断线、失败、停止中、停止未确认与已停止的事实、保留内容和单一主动作
- [x] WebSocket 客户端暴露自动重连次数、下一次重试时间和最近错误；共享恢复面板支持安全摘要与立即重连
- [x] 优化 IME 弹出性能：键盘动画高度只作用于外层避让，聊天子树仅感知打开/关闭；移除逐帧重建聊天页的外层 `LayoutBuilder`，指令建议使用 `Flexible` 自适应并隔离 Composer 绘制
- [ ] 若后续定义重试耗尽策略，再增加独立的重连失败终态；当前保持持续自动恢复
- [x] 更新组件测试，覆盖 Composer 尺寸、模型语义、菜单去 token、活动状态、连接中状态条/空状态与权限工作目录
- [ ] 完成 Android 真机 Cool Glass 逐屏视觉验收清单（思考强度仪表与共享模型 sheet 已局部验收）

### Cool Glass 实现

- [x] `DESIGN.md` 切到 Cool Glass tokens；聊天控制台用冷近白纸面 + bounded glass chrome
- [x] 会话 / 项目 / 模型身份标记改用 Phosphor Fill；chrome 仍用 Lucide
- [x] 模型 / 引擎 / 权限 / 沙箱共用 `AppOptionRow` sheet，去掉冰川蓝双栏
- [x] 助手短回复 hug 内容；流式期间即可 Markdown；代码块去掉内描边
- [x] 默认阅读字号 `1.0` / 100%

### 文档

- [x] 根 README 与当前启动、安装和协议一致
- [x] 移动端 README 与当前 UI 和调试流程一致
- [x] UI 设计文档更新为当前 Cool Glass 实现与验收规格（含语义色、Phosphor Fill、助手气泡 hug / 流式 Markdown、默认 100% 字号）
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

## Codex 切换待验证

- [ ] 真机新建 Codex 会话并确认流式回复、停止与断线恢复
- [ ] Codex `workspace-write` 下真实写入工作区文件，确认沙箱边界与活动展示
- [ ] Codex 会话发送非图片附件被拒、danger-full-access 发送后回落 read-only

## 后续功能

- [ ] 多设备授权、设备列表和单设备撤销
- [x] 会话全文搜索：daemon 权威 transcript 全局检索、会话级结果聚合、片段高亮、结果跳转与命中消息定位
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
