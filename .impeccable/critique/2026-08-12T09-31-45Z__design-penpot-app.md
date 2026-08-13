---
target: 当前 Penpot 三套 UI 草案
total_score: 24
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 3
timestamp: 2026-08-12T09-31-45Z
slug: design-penpot-app
---
Method: dual-agent (A: impeccable_design_review · B: impeccable_evidence)

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3/4 | 连接、运行和停止可见，但状态舱仍会与装饰层争夺注意力 |
| 2 | Match System / Real World | 3/4 | 连接、权限、命令语义自然，部分术语仍偏工具内部语言 |
| 3 | User Control and Freedom | 3/4 | 固定停止入口和 stopping 状态良好，停止完成确认仍需强化 |
| 4 | Consistency and Standards | 3/4 | 单套内部一致，但三套共享模板骨架，组件层级过于同质 |
| 5 | Error Prevention | 2/4 | 危险操作有红色区分，静态草案未证明误触保护和确认反馈 |
| 6 | Recognition Rather Than Recall | 3/4 | 权限、输入、活动均可见，命令及权限术语仍需要理解成本 |
| 7 | Flexibility and Efficiency | 2/4 | 有命令建议，但专家路径、折叠策略和快速回溯未在草案表达 |
| 8 | Aesthetic and Minimalist Design | 2/4 | 玻璃胶囊、光斑、卡片和大圆角叠加，装饰超过了必要量 |
| 9 | Error Recovery | 2/4 | 能表达错误和停止，但缺少明确的下一步与证据定位 |
| 10 | Help and Documentation | 1/4 | 静态界面几乎没有上下文帮助或术语解释 |
| **Total** | | **24/40** | **Acceptable：可用骨架成立，视觉世界需要重构** |

## Design Specificity Verdict

**LLM assessment**：三套都更像同一套 AI 生成的移动端控制台模板换肤，而不是三种有产品立场的方案。共同结构是“顶部浮动毛玻璃状态舱 → 中部聊天/活动卡 → 底部浮动毛玻璃 Command Dock”；共同装饰是低饱和环境光、大圆角、细描边、Noto Sans SC 与 JetBrains Mono。Porcelain 是暖白、薄荷、珊瑚的常见柔和 AI 助手配方；Graphite 是暗底、青绿 glow、终端卡片的常见 developer-tool 配方；System Frost 是冷灰磨砂、系统原生感的常见效率工具配方。三者差异主要来自色调，没有来自信息架构、密度、行为或工作人格。

**Deterministic evidence**：本轮 Penpot MCP 返回 `No Penpot instance connected for user token`；独立浏览器标签落在登录页，因此没有得到新的节点、尺寸、字体、模糊、对比度或触控目标验证结果。远程 Penpot URL 按规则不运行 CLI `detect.mjs`。本次视觉判断使用上一轮已验证的三张 390×844 画板记录，并以当前 Flutter 代码结构交叉核对。没有可靠的用户可见 overlay。

## Overall Impression

功能骨架是对的，视觉观点是弱的。最大机会不是再调一轮颜色，而是把 CC Remote 真正独有的“远程状态、执行时间线、随时中止、结果证据”变成构图本身；毛玻璃只应是局部材质，不应承担品牌识别。

## What's Working

- 连接状态、活动流、权限模式、输入与停止都在一屏，核心任务链没有丢。
- Graphite 的状态对比最明确；System Frost 的内容扫描效率最好。
- 停止操作位于拇指区，代码也已具备 `running → stopping → stopped` 的状态基础。

## Priority Issues

### P1 — 三套共享同一生成式模板骨架

**Why it matters**：换掉文案后，这套结构可以原样用于任意 AI 聊天或开发者工具，CC Remote 的远程控制属性没有进入视觉语法。

**Fix**：停止继续平行打磨三套。选一套作为底稿，把主构图改成“连接脊柱 + 执行时间线 + 命令台”：状态不再是顶部卡片中的一个标签，而是贯穿页面、连接当前动作与停止入口的持续信号。

**Suggested command**：`$impeccable shape`，重建主控制台的信息层级和产品专属视觉隐喻。

### P1 — 玻璃材质层数过多，装饰抢过状态

**Why it matters**：顶部玻璃胶囊、中间玻璃卡、底部玻璃 Dock、环境光斑和大圆角同时出现，产生最典型的 AI UI 味；远程运行状态反而不是第一眼焦点。

**Fix**：全屏最多保留一层真正的磨砂表面，建议只留给 Command Dock；顶部改成贴合系统栏的实色状态带，transcript 使用无容器正文和细分隔，不再每条卡片化；删掉无信息意义的环境光斑。

**Suggested command**：`$impeccable distill`，移除多余玻璃、阴影、光斑和容器层。

### P1 — 活动流与对话内容权重接近

**Why it matters**：用户难以在 300ms 内区分“正在发生什么”“已经完成什么”“最终结果是什么”，等待过程会变得焦虑。

**Fix**：当前动作常驻并显示运行时长；已完成工具事件压缩成可展开证据行；最终回答恢复为完整阅读层。不要让 thinking、tool、summary 都成为同样大小的卡片。

**Suggested command**：`$impeccable layout`，建立当前动作、历史证据、最终回答的三级结构。

### P2 — 三套差异只是换肤

**Why it matters**：用户无法根据工作方式选择方案，也无法判断哪套更适合产品；这会把评审变成色板投票。

**Fix**：如果仍保留三方向，应赋予不同的信息行为：Porcelain 面向长文本阅读，减少事件噪声；Graphite 面向实时监控，提高事件密度与时间标记；System Frost 面向日常效率，使用原生控件与最少容器。若不需要多主题，直接收敛到 System Frost 的内容骨架，并吸收 Graphite 的状态对比。

**Suggested command**：`$impeccable bolder`，让差异来自构图和行为，而不是颜色。

### P2 — 停止与错误恢复缺少闭环表达

**Why it matters**：远程执行是高风险场景。红色按钮只说明“危险”，不能说明是否已经收到停止请求、电脑是否确认、接下来怎么办。

**Fix**：停止区设计三态：停止任务 → 正在请求电脑停止（含时长）→ 已停止（短暂确认）；断线或失败时在同一区域提供唯一明确下一步，并保留最后事件证据。

**Suggested command**：`$impeccable clarify`，完善停止、断线和错误恢复文案与反馈。

## Persona Red Flags

**Alex（高频远程操作）**：共享模板没有突出运行时长和最后事件；停止延迟时难以判断任务是否仍在电脑端执行；完成事件没有快速折叠和回溯路径。

**Sam（无障碍依赖用户）**：Porcelain 的浅绿、白卡和透明边界存在对比风险；Graphite 的 glow 可能削弱低亮度可读性；状态不能只依赖红绿颜色，磨砂背景也会让对比随底图变化。

**Casey（分心的移动用户）**：上下两个浮动大容器压缩 390×844 的有效 transcript 高度；运行中需要同时扫描状态舱、活动卡和停止按钮；错误后缺少一个明确、靠近拇指区的恢复动作。

## Cognitive Load

8 项中失败 5 项，属于高负荷风险：分组、视觉层级、命令格式记忆、反馈时序和滚动定位需要改进。单一焦点、主要入口可发现性和底部主操作位置基本成立。页面没有明显超过四个同级决策，但大量同权卡片形成了持续的视觉噪声。

## Emotional Journey

连接时能建立安心感；发送命令时有掌控感；进入思考和工具运行后，由于当前动作与历史卡片不够分层，焦虑上升；点击停止后若只显示按钮变化，用户仍会怀疑电脑端是否收到；结果完成时有释然，但最终回答没有获得足够的“结束感”。Porcelain 温和但易显得轻飘，Graphite 专业但更压迫，System Frost 冷静高效但缺少记忆点。

## Minor Observations

- JetBrains Mono 只应用于命令、路径、时间和事件 ID，不应扩散到普通对话。
- 红色应只服务停止、错误和不可逆权限，不参与环境装饰。
- Frost 的扁平内容方向最接近正确答案，但仍需保留可点击边界和当前动作锚点。
- 毛玻璃在 Flutter 真机上还需验证性能、低端 Android 降级和动态背景下的对比。

## Questions to Consider

- 去掉所有 blur 和环境光斑后，这个产品还剩下什么独特性？
- 用户只看屏幕 300ms，能否回答“是否连接、是否仍在执行、最后做了什么”？
- 活动流究竟是实时监控还是事后证据？如果两者都是，为什么共用一个视觉层级？
- 三套是否真的服务三种工作人格，还是只是在邀请用户投票选色？
