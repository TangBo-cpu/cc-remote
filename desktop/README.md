# Windows 桌面启动器

启动器使用 Rust + Win32 原生控件。它负责启动本机服务与隧道、显示手机配对二维码，并提供系统托盘入口。Node.js、cloudflared、Claude Code 和 Codex CLI 使用电脑上已有的安装与凭据。

## 构建

电脑需要 Node.js 20+、Rust MSVC 工具链、Windows SDK / C++ build tools。使用公网隧道时，`cloudflared` 也需要在 PATH 中。Claude Code 或 Codex CLI 应已在本机完成登录。

在仓库根目录运行：

```powershell
npm install
npm run build:desktop
```

构建脚本先编译 daemon，再构建 Rust release 版本，将 `cc-remote-desktop.exe` 复制到仓库根目录。请保留仓库的 `dist/` 与 `node_modules/`，并把 EXE 留在仓库目录内；可创建指向它的桌面快捷方式。

更新构建前，请从托盘退出旧启动器，避免运行中的 EXE 阻止覆盖。退出会停止它启动的服务，活动任务需要确认。

## 日常使用

1. 双击 `cc-remote-desktop.exe`，选择要交给 Claude 或 Codex 的项目文件夹。
2. 服务地址通常留空。点击「启动服务」，等待隧道与本机服务就绪。
3. 打开手机 App，扫描窗口中的二维码并确认配对。
4. 关闭窗口后，服务继续运行。通过托盘图标打开窗口、停止服务或退出。

启动器保存成功启动时的设置。再次打开时，若保存的项目文件夹仍存在，会恢复设置并自动启动。重复打开同一端口的启动器会显示已有实例。

窗口显示服务、配对、手机连接与任务状态。「查看日志」显示最近 80 行启动日志。「停止服务」保留配对凭据；「退出」同时关闭启动器。两者只停止当前启动器启动的 daemon 和隧道；连接已有 daemon 时，启动器不会停止它。

活动任务需要确认后才能停止。正常退出会先请求 daemon 保存会话，再结束服务。启动器通过 Windows Job Object 管理自己启动的进程树，异常退出时也会清理这些子进程。

请求停止后，启动器会暂停隧道自动恢复；即使停止请求失败或超时，也不会在后台重新拉起隧道。只有再次显式启动服务才会恢复自动重试。连接已有 daemon 时仍会刷新状态，但不管理其进程或隧道。

## 隧道与配对

- 固定隧道：启动器读取 `.run/cloudflared-cc-remote.yml`，从 `hostname` 获取服务地址；也可在窗口填写地址。配置需指向当前 daemon 端口。托管的固定隧道退出后，启动器按 1、2、4、8、15、30 秒的间隔自动重启；重启失败继续退避，达到 30 秒后保持该间隔。确认进程仍存活且运行满 60 秒后，才重置退避。恢复只重启隧道，保留 daemon、正在执行的任务、配对 token 和服务地址。
- 临时隧道：没有固定隧道配置时，自动启动 Quick Tunnel 并读取临时地址。退出后只提示一次，不自动重启，避免悄悄更换手机保存的地址。重新启动后地址可能变化，手机需重新配对。
- 本机模式：勾选「本机模式（不启动隧道）」后跳过 cloudflared。daemon 仍监听 `127.0.0.1`，手机需要已有的端口转发或其他访问路径。

二维码有效期为 5 分钟，只能使用一次。「重新配对」会显示新的二维码；这一步不影响已配对设备，新手机扫码成功后即可使用，旧设备保持连接。要下线某台手机，在该手机的「设置 → 已配对设备」中撤销。二维码过期或服务地址变化时，可以重新配对。

## 数据与本地控制

daemon 始终以仓库为工作目录，所选项目通过 `WORKSPACE_DIR` 单独传入。切换项目不会把配对和会话数据搬到项目目录中。

| 路径 | 用途 |
| --- | --- |
| `.data/desktop.json` | 启动器的项目、服务地址、本机模式与端口设置 |
| `.data/state.json` | 手机配对状态（多设备记录、token hash） |
| `.data/local-control.json` | 本机控制 token |
| `.data/projects.json`、`.data/sessions/` | 项目、会话目录与 transcript |

启动器通过本机控制接口查询状态、注册项目、生成二维码和请求退出。这些接口使用 `x-cc-remote-local-token`，并校验回环来源、Host 和 Origin，不接受手机 Bearer token。

## 界面与资源

界面使用冷灰背景、白色工作区和蓝色主按钮。按钮保留原生鼠标与键盘行为，并绘制悬停、按下、焦点和禁用状态；支持 DPI 缩放，高对比度模式使用 Windows 系统颜色。关闭窗口时释放窗口与字体资源。

启动器无需 WebView、浏览器运行时或常驻 PowerShell。测试环境中的启动器工作集约 19 MiB，不包含 Node.js、cloudflared 和引擎进程；实际占用会随系统环境变化。

EXE、窗口和托盘使用 `assets/icon.ico`，包含 16 到 256 像素的图标。`assets/icon.svg` 是可编辑源文件，`assets/icon.png` 是 512 像素预览。构建使用 Windows SDK 资源编译器嵌入图标。

## 故障处理

- 无法找到仓库：把 EXE 放回仓库目录，并检查快捷方式的目标。
- 提示服务尚未构建：在仓库根目录运行 `npm run build:desktop`。
- 隧道失败或等待地址超时：打开「查看日志」，检查 cloudflared 是否可用，以及固定隧道配置和网络连接。固定隧道退出后会记录重试状态；临时隧道退出需手动重新启动，地址变化后重新配对。停止服务可能中断活动任务，请先确认任务状态。
- 连接现有服务失败：确认 daemon 使用当前代码，并以同一仓库为工作目录，以便读取对应的本机控制 token。
- 手机重启后无法连接：检查电脑端服务状态和服务地址；临时隧道地址变化时，重新扫码配对。

## 校验

从仓库根目录运行：

```powershell
cargo fmt --check --manifest-path desktop/Cargo.toml
cargo test --locked --manifest-path desktop/Cargo.toml
cargo clippy --locked --manifest-path desktop/Cargo.toml --all-targets -- -D warnings
node --import tsx --test tests/daemonLocalRegister.test.ts tests/daemonBusy.test.ts
pwsh -NoProfile -File desktop/smoke-test.ps1
```

当前 Rust 单元测试共 11 项，包含固定隧道退避重试、稳定运行后重置退避、停止后不再自动拉起，以及临时隧道和未接管服务的边界。恢复测试使用可控时钟与测试子进程，不启动真实公网隧道。

原生窗口检查需要已构建的 daemon 与启动器。脚本使用隔离测试目录和独立端口，检查启动、配对、重复打开、托盘、状态恢复及退出，在 `.run/` 保存截图，并输出资源占用结果。可用 `-Executable` 指定其他已构建的 EXE。

这些检查不覆盖真实公网隧道、手机实机扫码、真实 Claude / Codex 任务、多显示器混合缩放、高对比度实机效果或屏幕阅读器。

本轮隧道恢复改动尚未更新现有桌面二进制，也未进行电脑休眠唤醒或长时间公网连接验证。
