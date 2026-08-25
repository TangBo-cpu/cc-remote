---
name: CC Remote Chat Warm Console
description: A warm-paper chat and transcript control surface for supervising and steering desktop Claude Code sessions.
colors:
  paper: "#F5F4EE"
  surface: "#F8F7F2"
  surface-elevated: "#FBFAF7"
  control: "#ECEBE5"
  ink: "#2B2A27"
  muted: "#65625C"
  inactive: "#8B877F"
  inactive-light: "#B8B4AB"
  terracotta: "#DA7756"
  terracotta-deep: "#A65338"
  danger: "#9E4D35"
typography:
  headline:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif"
    fontSize: "21px"
    fontWeight: 700
    lineHeight: 1.25
    letterSpacing: "-0.02em"
  title:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif"
    fontSize: "16px"
    fontWeight: 700
    lineHeight: 1.35
  body:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif"
    fontSize: "15.5px"
    fontWeight: 400
    lineHeight: 1.58
  assistant-body:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif"
    fontSize: "15.5px"
    fontWeight: 400
    lineHeight: 1.6
  label:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif"
    fontSize: "12px"
    fontWeight: 500
    lineHeight: 1.35
  code:
    fontFamily: "JetBrains Mono, SFMono-Regular, Consolas, monospace"
    fontSize: "12px"
    fontWeight: 500
    lineHeight: 1.45
rounded:
  compact: "8px"
  control: "12px"
  surface: "16px"
  header: "22px"
  pill: "999px"
spacing:
  xxs: "4px"
  xs: "8px"
  sm: "12px"
  md: "16px"
  lg: "20px"
  xl: "24px"
  xxl: "32px"
components:
  button-primary:
    backgroundColor: "{colors.terracotta-deep}"
    textColor: "{colors.surface-elevated}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    height: "52px"
    padding: "0 20px"
  button-secondary:
    backgroundColor: "{colors.control}"
    textColor: "{colors.ink}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    height: "52px"
    padding: "0 20px"
  session-header:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    rounded: "{rounded.pill}"
    height: "44px"
    padding: "0"
  composer:
    backgroundColor: "{colors.surface-elevated}"
    textColor: "{colors.ink}"
    rounded: "{rounded.surface}"
    height: "110px"
    padding: "14px 12px 12px"
  activity-card:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.surface}"
    padding: "14px 16px"
---

# Design System: CC Remote Chat Warm Console

## Overview

**Creative North Star: "暖纸控制台 / Warm Console"**

**Scope:** 本文档中的颜色、表面、组件和排版 token 只约束聊天控制台、transcript、活动轨与输入台。启动、配对、设置、恢复及其他系统界面不继承暖纸 palette，可以通过各自的 surface brief 建立更强、更艺术化的视觉世界；它们仍共享状态语言、交互反馈、可访问性与原生平台行为。当前启动页与设置页视觉世界记录在 [`.impeccable/surfaces/mobile-lib-main-dart.md`](.impeccable/surfaces/mobile-lib-main-dart.md)。

聊天控制台是桌面 Claude Code 的手机控制面，不是缩小的终端，也不是套着卡片的普通 AI 聊天应用。界面像一张安静、可信的工作台纸面：内容有阅读感，控制有明确触感，状态在短暂扫视中即可判断。

聊天界面的视觉个性来自暖白纸面、陶土动作色、炭黑文字、克制的系统默认字体与精确的留白。品牌表达服从操作：每屏只突出当前状态和一个下一步动作，不以玻璃、渐变、发光、巨型状态卡或大面积颜色制造“科技感”。这些限制不自动扩展到非聊天界面。

**Key Characteristics:**

- 暖纸色连续背景，组件与正文处在同一色温。
- 陶土色只承担品牌、当前动作和主按钮，不承担所有状态。
- 顶部是分离式浮动会话控制，正文是主要画面，底部是轻量输入台。
- 状态由图标、文字和色调三重表达，绝不只靠红绿圆点。
- 当前事件可展开，已完成事件压缩为一行证据。

## Colors

系统以暖纸中性色为主体，以陶土色提供稀少而明确的动作信号。

### Primary

- **Terracotta Action:** 浅陶土，只用于大面积品牌标记、当前执行节点和装饰性色条，不承担小字或 CTA 文字。
- **Terracotta Deep:** 主按钮填充、陶土语义文字与按压态；保证浅色纸面上的文字/按钮对比度。
- **CTA pair:** 主按钮使用 `terracotta-deep` 底 + `surface-elevated` 字；浅 `terracotta` 不直接做实心 CTA 字色。

### Neutral

- **Warm Paper:** 页面连续背景，不叠加环境光斑或渐变。
- **Paper Surface:** 顶部浮动控制、活动卡和轻量信息区。
- **Elevated Paper:** 底部输入台及必须从正文中抬起的操作面。
- **Graphite Ink:** 标题、正文与关键图标。
- **Reading Gray:** 辅助信息；关键状态不得只用该颜色的小字表达。
- **Quiet Control:** 次级按钮、模型选择和图标底。

### Named Rules

**The Rare Terracotta Rule.** 单屏陶土色面积保持克制；它首先表示“现在可做或正在发生”，不是通用装饰色。

**The No Green Status Rule.** 在线、完成和可用状态使用图标、文案与中性明度表达，不再引入绿色状态体系。

## Typography

**Display Font:** Platform System UI

**Body Font:** Platform System UI

**Assistant Reading Font:** Platform System UI

**Label/Mono Font:** Platform System UI / System Monospace

UI 与助手叙述统一使用当前平台的系统 UI 字体；Android、iOS 和桌面端分别沿用设备原生字体与字形回退。应用不打包自定义字体，等宽字体只用于命令、路径、代码和数值证据。

默认阅读尺寸为基准字号的约 95%（UI 正文约 14.7px / 1.58，助手正文同比例、1.6 行高），轻微字距；用户可在设置中用滑杆连续调节阅读缩放（约 0.85×–1.40×，步进 0.05，默认 0.95），并与系统文字缩放相乘后夹在 0.85–1.6。

### Hierarchy

- **Headline:** 页面标题与关键决策，通常 21px、700。
- **Title:** 会话名、活动标题、文件名与状态标题，通常 16px、700。
- **Body:** 普通说明约 15.5px、1.58 行高；用户消息约 15px、1.6 行高。
- **Assistant Body:** Claude 连续回复，15.5px、1.6 行高。
- **Label:** 状态、元信息和按钮文字，最低 12px。
- **Code:** 命令和 Diff，12–13px，行高不低于 1.45。

**The Reading Voice Rule.** 中文 UI 与助手叙述统一使用当前平台的系统 UI 字体；命令、路径、代码与 Diff 仍用等宽。

## Layout

基准画板为 390×844。页面左右安全边距为 20px，主要工作宽度为 350px。空间遵循 4px 基础单位和 8px 主节奏；页面不做卡片墙，而是在连续纸面上用少量容器建立必要层级。

顶部只保留 44px 高的分离式浮动控制，正文获得最大高度。底部输入台固定在安全区上方，标准尺寸为 350×110；键盘弹出时随系统 inset 上移。视觉按钮可小于命中区，但所有交互命中区域至少 44×44。

小屏、横屏和大字体下优先保证：状态文案完整、主动作可达、输入台不遮挡当前内容。辅助路径、模型名和设备名允许单行截断；正文尊重系统文字缩放。

## Elevation & Depth

聊天控制台默认无毛玻璃、无模糊、无渐变。深度优先来自三档相邻暖纸色、1px 低对比边界与内容密度；对话气泡与 Composer 可使用极轻的暖灰阴影（拟态抬升）帮助分层，禁止彩色偏移阴影或漂浮黑影。系统级思考强度模态层是受控例外：允许 sigma 4 背景柔焦、低透明暖色径向光场，以及大仪表的弧线柔影、浅灰金属环、指针阴影和轴心高光；不扩展为聊天控制台的通用毛玻璃或渐变规范。仅系统弹层可以使用平台默认遮罩。

**The Tonal Depth Rule.** 先用纸面色阶和间距表达层级；只有系统级模态层才获得真正的空间抬升。

## Shapes

形状语言收敛为少量柔和几何：页面容器 16px，顶部菜单使用圆形，顶部动作组和模型使用短胶囊，按钮与字段 12px。胶囊只承载极短控制或标签，不把长文本塞进去。

图标默认采用 20/24px 线性图标，约 1.8–2px 描边、圆角端点和统一光学尺寸。禁止混用 Unicode 字符、Material 实心图标和手绘线框。Flutter 默认使用 `lucide_icons_flutter` 3.1.15；Project and Session Navigator 是受控例外，可使用 `phosphor_flutter` 2.1.0 的 Regular/Fill：Regular 用于普通导航、文件夹、搜索和会话，Fill 只用于当前选中状态。不得把该例外扩展到其他页面，也不得在同一语义层随意混排图标源。

## Components

### Compact Session Header

- 参考 Claude 手机端，拆成左侧 44px 圆形菜单与右侧 88×44px 新建/更多胶囊，中间保持透明。
- 顶部 chrome 不重复显示产品名、工作区、设备或连接状态；非「已连接」相位时，在会话头下方显示紧凑 `ConsoleStatusStrip`（图标 + 文案，必要时附主机名）。
- 新建使用小型深色圆形 plus 标记；更多保持线性 ellipsis，两个动作仍有独立 44px 命中区。
- “···”菜单底栏不显示剩余上下文 token，最多保留带屏读语义的当前模型名。
- 顶部不再使用整宽会话表面或独立大状态卡。

### Project and Session Navigator

- 面板使用约 92% 高度的 bottom sheet，保留顶部拖拽柄并适配底部安全区；它是临时导航上下文，不设计成独立页面。
- 项目与会话采用连续暖纸背景上的扁平列表，不堆叠卡片；通过字号、分组标题、缩进和留白建立层级。
- 默认视图先显示当前项目的会话，并保留「所有项目」入口和少量项目快捷项；完整项目列表在面板内子视图中选择，选择后返回会话视图。
- 搜索是按需子视图：为空时提供搜索提示，输入后展示跨项目结果，并保留清除、重试和返回当前上下文的明确入口。
- 活跃、运行中、普通、归档和失败状态不能只靠颜色区分；必须结合图标、文字、选中标记或 trailing 操作表达。
- 面板内 Phosphor 图标以 Regular 为默认，Fill 只用于当前会话或当前项目；视觉图标控制在 18–21px，交互命中区仍至少为 44×44。

### Transcript

- 用户消息靠右，使用无描边的暖陶灰气泡，四角统一为 22px。
- Claude 回复靠左，使用更宽的无描边 `surface` 阅读气泡（贴合 transcript 阅读栏、四角统一为 22px；滚动列表不做 per-bubble 阴影），与用户气泡通过纸面色阶区分；同一轮的活动与回复使用紧凑间距，新一轮用户消息前增加留白，避免窄卡感和卡片墙。
- 回复正文与系统说明、活动文字统一使用当前平台系统 UI 字体；命令与 Diff 使用等宽。
- Markdown 段落使用 12px 主节奏；标题上方留白大于下方，代码块使用 quiet-control 纸面、12px 圆角和等宽字体形成独立证据层。
- 空状态不做营销欢迎页：已连接给快捷下一步；离线给重连卡；连接中给独立「正在重新连接」状态卡（不复用离线卡）。

### Activity Event

- 当前动作由 2px 以内的短轨道节点、状态标签、文件或命令标题和次级说明组成。
- 已完成事件折叠为一行；点击后查看实时活动或证据。
- 执行中使用陶土节点；完成使用中性节点；失败使用深砖红文字和错误图标；停止使用方形 stop 图标。
- 思考中使用固定中心的暖陶花形帧动画；普通活动 running 使用 `CircularProgressIndicator`，不用延时动画替代真实进度语义。
- 不把整页做成永久连接轨道，不同时展开所有工具事件。

### Composer

- 悬浮叠在 transcript 之上：不透明暖白纸面（`surfaceElevated`）、`composerFloat` 28px 圆角、`floatingComposer` 单层轻阴影；列表仍可滚入 dock 背后，但不做半透明叠字（滚动合成过重）。
- 标准最小高度约 110；底边用系统 `viewPadding` 抬离手势指示条，避免贴底被裁。
- 键盘打开时 Composer 取消底部安全区间隙与浮动阴影、底部两角收为直角，与 IME 形成连续输入面；关闭键盘后恢复 28px 全圆角与浮动层级。
- 上半区保留输入文字与多行增长空间；工具行贴底：暖色圆形附件 `+`、暖陶仪表思考强度，随后是模型胶囊、图标化权限入口与紧凑上下文余量，再接 `terracotta-deep` 圆形发送或停止。
- 输入框聚焦描边使用 `terracotta-deep`（约 1.4px），保证控制底上的焦点对比。
- `+` 仅附件；小仪表打开全屏柔焦浮层，大仪表沿圆弧滑动并吸附低、中、高、超高、最大五档，点击中心切回自动，模型不支持的档位由 CLI 降级；模型、权限与上下文余量共用一个 flex 槽并保持相邻，窄屏时优先收缩模型文案。
- 模型触发器保持暖色短胶囊；选择器是受控的冰川蓝渐变例外，采用双栏索引布局、深蓝当前行楔形指示和模型摘要，不改变聊天控制台暖纸色系。
- 权限入口只显示当前模式图标，保留完整 tooltip / 屏读语义与至少 44px 命中区；其旁以无底色的浅灰细环表示总窗口、深灰短弧表示已消耗比例，右侧只显示剩余百分比；完整 token 数通过 tooltip / 屏读语义提供，且不影响指令建议区高度。
- 空闲显示发送；运行中显示停止；停止中显示禁用 stop 与明确文案；离线显示待发送数量和重连入口。
- 视觉尺寸不等于命中尺寸，所有控制维持至少 44px 触控区域。

### Permission Decision

- 使用独立决策页，按“命令 → 工作目录 → 风险与影响 → 授权范围 → 动作”排序。
- 工作目录优先显示当前会话 `workspaceDir`；路径暂不可用时写「以桌面主机当前工作区为准（路径暂不可用）」，不虚构绝对路径。
- 首要动作是“仅本次允许”（`terracotta-deep` CTA），次要动作是“拒绝并返回”。
- 单次审批不能被视觉上暗示为永久授权；更改授权范围只进入产品已支持的权限模式。

### Recovery and Terminal States

- `ConsolePresentation` 统一相位：连接中、已连接、上传中、运行中、等待审批、停止中、停止未确认、已停止、执行失败、连接已断开。
- 离线、重连失败、任务失败、停止中、已停止和停止超时复用同一信息骨架；连接中与离线必须可区分。
- 每屏只保留一个主状态、一个事实说明和一个下一步动作。
- “停止超时”不等于“已停止”；只有主机 `stopped` 事件或权威 transcript 中明确的停止证据可以进入已停止终态。
- transcript、工作区和待发送内容在恢复页面中必须明确标注为已保留。

### Diff Viewer

- 顶部显示文件数和增删摘要，默认统一视图。
- 代码使用 12–13px 等宽字体、至少 1.45 行高，并允许按文件跳转和放大。
- 手机端只读；底部明确“变更仍在桌面工作区”，不提供提交或暂存。

## Do's and Don'ts

### Do:

- **Do** 让用户在 300ms 扫视内判断连接、运行和停止状态。
- **Do** 将当前动作与已完成证据分层，并把恢复动作放在上下文附近。
- **Do** 使用统一线性图标、文字标签和至少 44px 的触控目标。
- **Do** 在聊天控制台内保持背景、消息、活动部件和输入台处于同一暖纸色温。
- **Do** 用主机事件驱动已停止、完成和失败终态。

### Don't:

- **Don't** 使用毛玻璃、蓝紫渐变、绿色状态体系、大黑色控制舱或彩色偏移阴影。
- **Don't** 堆叠圆角卡片、灰胶囊和大面积状态色。
- **Don't** 用小于 12px 的关键状态文字，或只用颜色表达结果。
- **Don't** 让权限模式、运行中标签和信号轨长期占据输入台独立一行。
- **Don't** 因本地计时器超时就宣称桌面任务已经停止。
