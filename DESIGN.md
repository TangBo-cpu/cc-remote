---
name: CC Remote Warm Console
description: A warm-paper mobile control surface for supervising and steering desktop Claude Code sessions.
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
    fontFamily: "Noto Sans SC, PingFang SC, Microsoft YaHei, sans-serif"
    fontSize: "21px"
    fontWeight: 700
    lineHeight: 1.25
    letterSpacing: "-0.02em"
  title:
    fontFamily: "Noto Sans SC, PingFang SC, Microsoft YaHei, sans-serif"
    fontSize: "16px"
    fontWeight: 700
    lineHeight: 1.35
  body:
    fontFamily: "Noto Sans SC, PingFang SC, Microsoft YaHei, sans-serif"
    fontSize: "15px"
    fontWeight: 400
    lineHeight: 1.55
  assistant-body:
    fontFamily: "Noto Serif SC, Source Han Serif SC, serif"
    fontSize: "15px"
    fontWeight: 400
    lineHeight: 1.65
  label:
    fontFamily: "Noto Sans SC, PingFang SC, Microsoft YaHei, sans-serif"
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
    backgroundColor: "{colors.terracotta}"
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
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.header}"
    height: "76px"
    padding: "12px"
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

# Design System: CC Remote Warm Console

## Overview

**Creative North Star: "暖纸控制台 / Warm Console"**

CC Remote 是桌面 Claude Code 的手机控制面，不是缩小的终端，也不是套着卡片的普通 AI 聊天应用。界面像一张安静、可信的工作台纸面：内容有阅读感，控制有明确触感，状态在短暂扫视中即可判断。

视觉个性来自暖白纸面、陶土动作色、炭黑文字、克制的衬线叙述与精确的留白。品牌表达服从操作：每屏只突出当前状态和一个下一步动作，不以玻璃、渐变、发光、巨型状态卡或大面积颜色制造“科技感”。

**Key Characteristics:**

- 暖纸色连续背景，组件与正文处在同一色温。
- 陶土色只承担品牌、当前动作和主按钮，不承担所有状态。
- 顶部是紧凑会话头，正文是主要画面，底部是轻量输入台。
- 状态由图标、文字和色调三重表达，绝不只靠红绿圆点。
- 当前事件可展开，已完成事件压缩为一行证据。

## Colors

系统以暖纸中性色为主体，以陶土色提供稀少而明确的动作信号。

### Primary

- **Terracotta Action:** 只用于发送、允许、重试、当前执行节点和少量品牌标记。
- **Terracotta Deep:** 用于陶土色上的强调文字、按压态及低面积警示。

### Neutral

- **Warm Paper:** 页面连续背景，不叠加环境光斑或渐变。
- **Paper Surface:** 顶部会话头、活动卡和轻量信息区。
- **Elevated Paper:** 底部输入台及必须从正文中抬起的操作面。
- **Graphite Ink:** 标题、正文与关键图标。
- **Reading Gray:** 辅助信息；关键状态不得只用该颜色的小字表达。
- **Quiet Control:** 次级按钮、模型选择和图标底。

### Named Rules

**The Rare Terracotta Rule.** 单屏陶土色面积保持克制；它首先表示“现在可做或正在发生”，不是通用装饰色。

**The No Green Status Rule.** 在线、完成和可用状态使用图标、文案与中性明度表达，不再引入绿色状态体系。

## Typography

**Display Font:** Noto Sans SC

**Body Font:** Noto Sans SC

**Assistant Reading Font:** Noto Serif SC

**Label/Mono Font:** Noto Sans SC / JetBrains Mono

无衬线字体负责导航、状态与控制；衬线字体仅用于 Claude 的连续叙述，使正文具有阅读感；等宽字体只用于命令、路径、代码和数值证据。实现时必须打包或明确加载字体，不假设所有 Android 设备已安装 Noto 字体。

### Hierarchy

- **Headline:** 页面标题与关键决策，通常 21px、700。
- **Title:** 会话名、活动标题、文件名与状态标题，通常 16px、700。
- **Body:** 普通说明和用户消息，15px、1.55 行高。
- **Assistant Body:** Claude 连续回复，15px、1.65 行高。
- **Label:** 状态、元信息和按钮文字，最低 12px。
- **Code:** 命令和 Diff，12–13px，行高不低于 1.45。

**The Reading Voice Rule.** 衬线字体只出现在助手的叙述内容；按钮、状态、用户输入和系统提示始终使用无衬线字体。

## Layout

基准画板为 390×844。页面左右安全边距为 20px，主要工作宽度为 350px。空间遵循 4px 基础单位和 8px 主节奏；页面不做卡片墙，而是在连续纸面上用少量容器建立必要层级。

顶部会话头保持紧凑，正文获得最大高度。底部输入台固定在安全区上方，标准尺寸为 350×110；键盘弹出时随系统 inset 上移。视觉按钮可为 36×36，但所有交互命中区域至少 44×44。

小屏、横屏和大字体下优先保证：状态文案完整、主动作可达、输入台不遮挡当前内容。辅助路径、模型名和设备名允许单行截断；正文尊重系统文字缩放。

## Elevation & Depth

系统默认无阴影、无模糊、无玻璃和无渐变。深度来自三档相邻暖纸色、1px 低对比边界、内容密度与固定位置关系。仅系统弹层可以使用平台默认遮罩；不要为普通卡片添加漂浮阴影。

**The Tonal Depth Rule.** 先用纸面色阶和间距表达层级；只有系统级模态层才获得真正的空间抬升。

## Shapes

形状语言收敛为少量柔和几何：页面容器 16px，紧凑会话头 22px，按钮与字段 12px，圆形图标控制 36px。胶囊只用于极短的模型或状态标签，不把长文本塞进胶囊。

图标采用同一套 20/24px 线性图标，约 1.8–2px 描边、圆角端点和统一光学尺寸。禁止混用 Unicode 字符、Material 实心图标和手绘线框。Penpot 中的 plus、chevron、arrow-up、stop、retry 作为几何基准；Flutter 实现选择一个经验证的单一图标源，或把同源 SVG 固化为本地资产。

## Components

### Compact Session Header

- 将菜单、产品名、会话名、连接状态、设备名、新建和更多融合在一个 350px 宽的暖纸表面。
- 会话名是主信息；连接状态和设备名在下一行。
- 在线状态使用中性节点和“已连接”文字；离线、停止和失败必须换图标与文案，而不是仅换颜色。
- 顶部不再叠加独立的大状态卡。

### Transcript

- 用户消息靠右，使用略深于背景的暖灰气泡。
- Claude 回复靠左，优先直接排在纸面上；仅在必须形成对象边界时使用轻量表面。
- 回复正文使用衬线字体，系统说明与活动文字使用无衬线字体。
- 空状态不做营销欢迎页，只给与当前会话相关的下一步。

### Activity Event

- 当前动作由 2px 以内的短轨道节点、状态标签、文件或命令标题和次级说明组成。
- 已完成事件折叠为一行；点击后查看实时活动或证据。
- 执行中使用陶土节点；完成使用中性节点；失败使用深砖红文字和错误图标；停止使用方形 stop 图标。
- 不把整页做成永久连接轨道，不同时展开所有工具事件。

### Composer

- 标准尺寸为 350×110、16px 圆角、暖白抬升纸面。
- 上半区保留输入文字与多行增长空间；下半区依次放 36px 扩展按钮、模型选择和 36px 发送或停止按钮。
- 权限模式进入扩展按钮的 sheet，不常驻占用一行；模型选择保留为紧凑胶囊。
- 空闲显示发送；运行中显示停止；停止中显示禁用 stop 与明确文案；离线显示待发送数量和重连入口。
- 视觉尺寸不等于命中尺寸，所有控制维持至少 44px 触控区域。

### Permission Decision

- 使用独立决策页，按“命令 → 工作目录 → 风险与影响 → 授权范围 → 动作”排序。
- 首要动作是“仅本次允许”，次要动作是“拒绝并返回”。
- 单次审批不能被视觉上暗示为永久授权；更改授权范围只进入产品已支持的权限模式。

### Recovery and Terminal States

- 离线、重连失败、任务失败、停止中、已停止和停止超时复用同一信息骨架。
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
- **Do** 保持背景、消息、活动部件和输入台处于同一暖纸色温。
- **Do** 用主机事件驱动已停止、完成和失败终态。

### Don't:

- **Don't** 使用毛玻璃、蓝紫渐变、绿色状态体系、大黑色控制舱或彩色偏移阴影。
- **Don't** 堆叠圆角卡片、灰胶囊和大面积状态色。
- **Don't** 用小于 12px 的关键状态文字，或只用颜色表达结果。
- **Don't** 让权限模式、运行中标签和信号轨长期占据输入台独立一行。
- **Don't** 因本地计时器超时就宣称桌面任务已经停止。
