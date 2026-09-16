# CC Remote

**在手机上远程控制本机 Claude Code。**

扫码配对后，你就能在冷玻璃控制台里发指令、看流式回复、审批工具权限、浏览工作区与 Git 变更——电脑端 daemon 继续跑 Claude Code CLI，手机只是随身控制台。

[下载 Android APK · v1.4.0](https://github.com/TangBo-cpu/cc-remote/releases/download/v1.4.0/cc-remote-v1.4.0-android.apk)
·
[Release 说明](https://github.com/TangBo-cpu/cc-remote/releases/tag/v1.4.0)

```text
手机 App  ──HTTPS / WSS──▶  Cloudflare Tunnel  ──▶  本机 daemon (:8787)  ──▶  Claude Code CLI / Codex CLI
```

<p align="center">
  <img src="docs/images/cool-glass-chat.jpg" alt="Cool Glass 对话" width="280" />
</p>

<p align="center"><sub>Cool Glass Console · 当前界面</sub></p>

---

## 它能做什么

| 场景 | 体验 |
| --- | --- |
| 出门前丢一条任务 | 手机发 prompt，桌面 Claude 继续跑；流式回复实时回传 |
| 想换引擎 | 新建会话时选 Claude 或 Codex；Codex 会话用三档沙箱模式控制写入范围 |
| 工具要权限 | 手机弹出决策卡：看命令摘要与工作目录，拒绝或仅本次允许 |
| 想确认改了什么 | 只读工作区 + Git diff，手机不提交、不改文件 |
| 断线了 | transcript 与草稿保留，自动重连；回来后从权威快照继续 |
| 字号不合适 | 设置里连续滑杆，默认 100% |

**安全边界（产品承诺）：**

- daemon 默认只听 `127.0.0.1`，公网走 Tunnel
- 一次性扫码配对，Bearer token；退出配对即撤销
- 手机不能注册任意目录、不能跑任意 shell、不能远程编辑 / 提交

---

## 界面参考

| 对话 | 项目与会话 | 选择模型 |
| :---: | :---: | :---: |
| <img src="docs/images/cool-glass-chat.jpg" width="220" alt="对话" /> | <img src="docs/images/cool-glass-sessions.png" width="220" alt="项目与会话" /> | <img src="docs/images/cool-glass-models.png" width="220" alt="选择模型" /> |

| 主控制台 | 工作区 | 启动 |
| :---: | :---: | :---: |
| <img src="docs/images/cool-glass-home.png" width="220" alt="主控制台" /> | <img src="docs/images/cool-glass-workspace.jpg" width="220" alt="工作区" /> | <img src="docs/images/cool-glass-startup.jpg" width="220" alt="启动" /> |

冷白纸面与冷灰层级、克制的单一蓝色只用于主动作与选中态、短回复 hug 的助手气泡、冷玻璃 Composer；顶部只有圆形菜单 + 新建/更多胶囊，模型放在输入台。设计规格见 [`DESIGN.md`](DESIGN.md)。

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

1. 安装 [v1.4.0 APK](https://github.com/TangBo-cpu/cc-remote/releases/download/v1.4.0/cc-remote-v1.4.0-android.apk)（测试签名，个人使用）
2. 允许「未知来源」安装
3. 打开 App → 扫终端二维码 → 确认电脑名与服务地址 → 进入控制台

### 4. 开始对话

在 Composer 输入任务，或点空状态快捷芯片。运行中可随时停止；需要权限时在手机上点一次「仅本次允许」或拒绝。

---

## 功能清单

**连接与会话**

- 扫码配对 / Secure Storage / 启动恢复
- WebSocket 鉴权、自动重连、活动任务恢复
- 多项目、多会话；完整项目路径展示
- 会话级引擎切换：Claude Code 或 Codex CLI（新建会话时选择）
- 会话 transcript 持久化与恢复
- 跨项目会话全文搜索、匹配片段高亮与命中消息精确跳转

**对话与控制**

- 流式输出（合批推送；无标记走 Text，有 Markdown 标记时流式期间即渲染）
- Claude Streaming Input 与 Codex App Server 常驻复用，后续轮次不重复启动 CLI
- 助手 Markdown 中的搜索来源 / 引用链接可点击，仅允许 `http` / `https` 并交给系统浏览器打开
- 停止任务、花形思考状态与本轮运行计时、安全化工具活动
- Composer 思考强度仪表与六档思考强度（自动 + 低、中、高、超高、最大五手动档）
- Claude Code 斜杠指令
- 模型选择（Composer 模型胶囊 + 共享 AppOptionRow sheet，Phosphor Fill 身份图标）
- 六种权限模式 + 一次性工具审批
- Codex 沙箱模式三档（read-only / workspace-write / danger-full-access），danger 发送一次后自动回落 read-only
- 图片 / 文件附件（每轮最多 5 个，单文件 ≤ 25MB；Codex 会话仅支持图片）

**工作区（只读）**

- 浏览已注册项目文件
- 查看 Git diff（含未跟踪摘要）

**通知与偏好**

- Android 后台本地通知（完成 / 失败 / 等待权限）
- 连续字号滑杆（约 0.85×–1.40×，默认 1.0）
- 聊天背景等对话偏好

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
flutter build apk --release
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
- HTTP：健康检查无需鉴权；项目、会话、附件、工作区等需 Bearer
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

当前公开版：**[v1.4.0](https://github.com/TangBo-cpu/cc-remote/releases/tag/v1.4.0)**
APK：[`cc-remote-v1.4.0-android.apk`](https://github.com/TangBo-cpu/cc-remote/releases/download/v1.4.0/cc-remote-v1.4.0-android.apk)

Cool Glass 控制台：冷灰蓝玻璃、语义色、Phosphor Fill 身份图标、助手气泡 hug、流式 Markdown、默认 100% 阅读字号。安装包使用测试签名，适合个人测试。
