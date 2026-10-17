# CC Remote

**在手机上远程控制本机 Claude Code。**

扫码配对后，你就能在手机上发指令、看流式回复、审批工具权限、浏览工作区与 Git 变更。电脑端 daemon 运行 Claude Code CLI 或 Codex CLI，手机负责远程控制与阅读。

[下载 Android APK · v2.0.3](https://github.com/TangBo-cpu/cc-remote/releases/download/v2.0.3/cc-remote-v2.0.3-android.apk)
·
[Release 说明](https://github.com/TangBo-cpu/cc-remote/releases/tag/v2.0.3)

```text
手机 App  ──HTTPS / WSS──▶  Cloudflare Tunnel  ──▶  本机 daemon (:8787)  ──▶  Claude Code CLI / Codex CLI
```

<p align="center">
  <img src="docs/images/cool-glass-chat.jpg" alt="Cool Glass 对话" width="280" />
</p>

<p align="center"><sub>v1.4.0 历史截图；v2.0.0 使用跟随系统的浅色 / 深色界面</sub></p>

---

## 它能做什么

| 场景 | 体验 |
| --- | --- |
| 出门前丢一条任务 | 手机发 prompt，桌面 Claude 继续跑；流式回复实时回传 |
| 想换引擎 | 新建会话时选 Claude 或 Codex；Codex 支持动态模型目录、原生指令与已启用 skills，默认完全访问沙箱 |
| 想换项目目录 | 手机浏览电脑文件夹或输入完整路径，选择 Claude Code / Codex 后在该目录新建对话；需同步更新 App 与 daemon |
| 工具要权限 | 手机弹出决策卡：看命令摘要与工作目录，拒绝或仅本次允许 |
| 想确认改了什么 | 只读工作区 + Git diff，手机不提交、不改文件 |
| 断线了 | transcript 与草稿保留，自动重连；回来后从权威快照继续 |
| 字号不合适 | 设置里连续滑杆，默认 100% |
| 外观随环境切换 | 默认跟随系统，也可固定浅色或深色 |
| 查看执行过程 | 思考与工具详情直接显示在消息中，标题可原地折叠，过程文字比正文小一档 |

**安全边界（产品承诺）：**

- daemon 默认只听 `127.0.0.1`，公网走 Tunnel
- 一次性扫码配对，Bearer token；退出配对即撤销
- 已配对手机可浏览电脑目录并在所选目录新建会话；工作区文件和 Git diff 接口保持只读，手机不直接执行 shell 或提交文件

---

## 界面参考（v1.4.0）

| 对话 | 项目与会话 | 选择模型 |
| :---: | :---: | :---: |
| <img src="docs/images/cool-glass-chat.jpg" width="220" alt="对话" /> | <img src="docs/images/cool-glass-sessions.png" width="220" alt="项目与会话" /> | <img src="docs/images/cool-glass-models.png" width="220" alt="选择模型" /> |

| 主控制台 | 工作区 | 启动 |
| :---: | :---: | :---: |
| <img src="docs/images/cool-glass-home.png" width="220" alt="主控制台" /> | <img src="docs/images/cool-glass-workspace.jpg" width="220" alt="工作区" /> | <img src="docs/images/cool-glass-startup.jpg" width="220" alt="启动" /> |

v2.0.2 使用中性背景和浅色 / 深色外观，助手正文直接排在页面上，用户消息保留浅灰气泡。运行中的过程默认展开，完成后默认收起；过程标题与正文左对齐，点击标题可原地展开详情。过程文字为 13 号，回复正文为 16 号，均跟随系统字号。以上图片是 v1.4.0 的历史参考；当前设计规格见 [`DESIGN.md`](DESIGN.md)。

---

## 三分钟上手

### 前提

| 需要 | 说明 |
| --- | --- |
| Node.js 20+ | 跑 daemon（`npm install` / `npm run dev`） |
| [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) | 本机已能执行 `claude` |
| [Codex CLI](https://developers.openai.com/codex/cli) | 可选；使用 Codex 会话时需包含 `app-server` 命令 |
| [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation/) | 默认公网隧道；仅本机调试可加 `-NoTunnel` |
| Android 手机 | 安装下方 APK（测试签名） |

当前**没有** npm 全局包：电脑端 = 克隆本仓库 + 本地依赖。`cc-remote` 是仓库根目录的启动脚本，不是 `npm i -g` 装出来的命令。

### 1. 电脑端（首次）

```powershell
git clone https://github.com/TangBo-cpu/cc-remote.git
cd cc-remote
npm install
```

可选：把仓库根目录加入 PATH，之后在任意项目目录都能直接敲 `cc-remote`（Windows 下实际执行的是根目录 `cc-remote.cmd` → `scripts/cc-remote.ps1`）。

### 2. 电脑端（日常）

在**要交给 Claude 的项目目录**启动（工作区默认 = 当前目录）：

```powershell
# PATH 已包含本仓库根目录时：
cc-remote

# 或未改 PATH，从任意目录显式调用：
& C:\path\to\cc-remote\cc-remote.cmd

# 或在仓库根指定工作区：
npm run cc-remote -- -WorkspaceDir "C:\path\to\your-project"
```

会启动 daemon + Cloudflare Tunnel，并在终端打印**手机配对二维码**。`Ctrl+C` 结束本次服务（隧道一并停）。

- daemon **已在跑**时，换到另一项目目录再执行一次，只注册并切换工作区，不重复起服务。
- 仅本机联调、不要隧道：`cc-remote -NoTunnel`（手机需能访问你的电脑，或自行做端口转发）。
- 固定隧道域名：配置 `.run/cloudflared-cc-remote.yml`，或设环境变量 / 传参 `-PublicOrigin https://your-host.example.com`。

### 3. 手机端

1. 安装 [v2.0.3 APK](https://github.com/TangBo-cpu/cc-remote/releases/download/v2.0.3/cc-remote-v2.0.3-android.apk)（沿用测试签名，个人使用；覆盖更新时不要卸载旧版）
2. 允许「未知来源」安装
3. 打开 App → 扫终端二维码 → 确认电脑名与服务地址 → 进入控制台

### 4. 开始对话

在 Composer 输入任务，或点空状态快捷芯片。运行中可随时停止；需要权限时在手机上点一次「仅本次允许」或拒绝。

在聊天页顶部打开「项目与会话」→「打开电脑目录」，可浏览电脑磁盘、主目录和最近项目，或输入完整绝对路径。选择 Claude Code / Codex 后点击「在此新建对话」。普通文件夹也可使用，旧对话保留原目录与历史，输入框草稿保留。任务或附件操作尚未结束时仍可浏览目录，创建和切换需等待操作结束。

从旧版本升级时，请同时更新手机 App 和电脑端源码，并重启 daemon。手机覆盖安装保留配对和设置，不要卸载旧版；已有会话无需迁移。

---

## 功能清单

**连接与会话**

- 扫码配对 / Secure Storage / 启动恢复
- WebSocket 鉴权、退避重连、前台存活探测与活动任务恢复
- 多项目、多会话；完整项目路径展示
- 手机浏览或输入电脑目录，按所选 Claude Code / Codex 引擎新建会话，已有会话保留原目录与历史
- 会话级引擎切换：Claude Code 或 Codex CLI（新建会话时选择）
- 会话 transcript 持久化与恢复
- 跨项目会话全文搜索、匹配片段高亮与命中消息精确跳转
- 手机 Claude 会话按标题出现在原生 `claude -r` 恢复列表；需要同步更新电脑端 daemon

**对话与控制**

- 流式输出（合批推送；无标记走 Text，有 Markdown 标记时流式期间即渲染）
- Claude Streaming Input 与 Codex App Server 常驻复用，后续轮次不重复启动 CLI
- 助手 Markdown 中的搜索来源 / 引用链接可点击，仅允许 `http` / `https` 并交给系统浏览器打开
- 停止任务、花形思考动画与运行计时、内联工具调用与命令详情、Skill 标识及原地折叠；滚动离屏和流式思考完成后保留折叠选择
- Composer 思考强度仪表与六档思考强度（自动 + 低、中、高、超高、最大五手动档）
- 斜杠指令与技能：Claude Code 原生指令；Codex 原生 `/compact`、`/review` 及当前项目已启用的 skills
- 模型选择：Claude 静态档位、Codex 动态模型目录与独立偏好
- 六种权限模式 + 一次性工具审批（Claude 会话）
- Codex 沙箱模式三档（read-only / workspace-write / danger-full-access），默认完全访问且持续生效，可显式改为只读或工作区可写
- 图片 / 文件附件（每轮最多 5 个，单文件 ≤ 25MB；Codex 会话仅支持图片）

**工作区（只读）**

- 浏览已注册项目文件
- 查看 Git diff（含未跟踪摘要）

**通知与偏好**

- Android 后台本地通知（完成 / 失败 / 等待权限）
- 连续字号滑杆（约 0.85×–1.40×，默认 1.0）
- 外观：跟随系统 / 浅色 / 深色，选择本地持久化

**当前不做 / 限制**

- 单设备授权（多设备列表与单设备撤销未做）
- 无 FCM（进程被杀后无法推送）
- 工作区不可编辑、暂存、提交
- APK 为测试签名，非应用商店包

---

## 开发者

### 校验

```powershell
npm run typecheck
npm run build
npm test
cd mobile
flutter analyze
flutter test
```

### 手动跑 daemon

```powershell
npm install
$env:PUBLIC_ORIGIN = "https://your-tunnel.example.com"
$env:WORKSPACE_DIR = "C:\path\to\project"
$env:DEVICE_NAME = "My PC"
npm run dev
```

不设 `PUBLIC_ORIGIN` 时默认 `http://127.0.0.1:8787`（本机调试）。

### Flutter

```powershell
cd mobile
flutter pub get
flutter run
# 或
flutter build apk --release --obfuscate --split-debug-info=build/symbols
```

### 常用启动参数

```powershell
cc-remote -NoTunnel
cc-remote -WorkspaceDir "C:\Projects\app" -DeviceName "My PC"
cc-remote -DisableBypassPermissions
```

### 配置（摘要）

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `HOST` / `PORT` | `127.0.0.1` / `8787` | 本机监听 |
| `PUBLIC_ORIGIN` | `http://127.0.0.1:8787` | 手机访问源 |
| `WORKSPACE_DIR` | 当前目录 | 启动时注册并激活的项目 |
| `DEVICE_NAME` | 主机名 | 配对显示名 |
| `ALLOW_BYPASS_PERMISSIONS` | `1` | 是否允许手机选「跳过权限」 |
| `CLAUDE_BIN` | `claude` | Claude CLI 路径 |
| `CODEX_BIN` / `CODEX_ARGS` | PATH 中的 `codex` | Codex CLI 路径与附加参数（`|` 分隔） |
| `MAX_WS_CONNECTIONS` | `16` | WebSocket 同时连接上限；合法范围 `1–64`，非法值回退默认值 |
| `WS_AUTH_TIMEOUT_MS` | `10000` | WebSocket 鉴权超时（毫秒）；合法范围 `1000–60000`，非法值回退默认值 |
| `WS_HEARTBEAT_INTERVAL_MS` | `30000` | WebSocket heartbeat 间隔（毫秒）；合法范围 `1000–120000`，非法值回退默认值 |
| `WS_CLOSE_TIMEOUT_MS` | `1000` | 授权变化后的关闭兜底超时（毫秒）；合法范围 `100–10000`，非法值回退默认值 |

### 协议与 API

- 配对：终端一次性 JSON 二维码（5 分钟、单次）→ `POST /api/pair` → token 仅返回一次
- 实时：`/ws` 首条必须 `{ "type": "auth", "token": "..." }`，之后 `prompt` / `stop` / `permission_response` 等；prompt 可带 `engine`（须与会话引擎一致），Codex 会话另带 `sandboxMode`
- HTTP：健康检查无需鉴权；项目、会话、目录、附件、工作区等需 Bearer
- 目录：`GET /api/directories` 浏览磁盘、主目录或一级子文件夹；`POST /api/projects/open-directory` 按绝对路径与引擎创建新会话，运行期间返回 409
- 本地项目注册：`POST /api/local/projects/register` 仅本机脚本，不对手机开放

完整消息类型、HTTP 路由与状态机说明见：

- [`docs/mobile-app-architecture.md`](docs/mobile-app-architecture.md)
- [`docs/flutter-app-design.md`](docs/flutter-app-design.md)
- [`docs/mobile-ui-app-design.md`](docs/mobile-ui-app-design.md)
- [`mobile/README.md`](mobile/README.md)

### 重置配对

停止 daemon，删除 `.data/state.json`，再启动并重新扫码。

---

## 版本

当前公开版：**[v2.0.3](https://github.com/TangBo-cpu/cc-remote/releases/tag/v2.0.3)**
APK：[`cc-remote-v2.0.3-android.apk`](https://github.com/TangBo-cpu/cc-remote/releases/download/v2.0.3/cc-remote-v2.0.3-android.apk)

v2.0.3 为各会话独立保存草稿、光标选区和阅读位置，切换会话或重启后恢复。修复偏好加载期间重复发送、切换会话和编辑草稿引发的发送竞态，以及退出搜索预览后的残留跳转；合并重复与过期的本地保存，减少存储写入。Android 版本为 `2.0.3+12`，电脑端 package 版本为 `2.0.3`。APK 沿用旧版测试签名，供个人使用；已有 v2.0.0 daemon 可继续使用，本版 release APK 的真机安装与界面仍待验收。
