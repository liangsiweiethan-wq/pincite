---
title: LiteratureSearch design system
platform: macOS
source: Sources/LiteratureSearchApp/DesignSystem.swift
---

## Overview

面向研究者的文献全文检索工具。视觉基调：**书房，而不是仪表盘**，以纸色、桌面色和墨色构成层次；衬线标题搭配无衬线正文，动效限于透明度与轻微位移。视觉 token 的实现位于 `Sources/LiteratureSearchApp/DesignSystem.swift`。

三条不变式：

1. **OCR 琥珀只表达出处，不作装饰。** 凡出现琥珀色，旁边必有可核对的书目与页码。
2. **危险与确认分层。** 即将外发（AI 请求）用 `.borderedProminent`（墨色 tint）+ 预览卡；不可逆/异常用 `error` 红文，不用弹窗轰炸。
3. **失败要说出原因。** 零命中、截断、跳转失效都必须给出具体理由文本（用 `StatusRow`/`info` 色），不留裸空白。

## Themes（三态主题）

`DS.Theme`（`@AppStorage("dsTheme")`，唯一状态源；`ThemeToggle` 写同一键）：

| 用户选择 | 系统外观 | 实际生效档 |
|---|---|---|
| `system` | `.aqua`（浅色） | 明（纸） |
| `system` | `.darkAqua`（深色） | 墨灰 |
| `graphite` | 任意 | 墨灰（不随系统） |
| `obsidian` | 任意 | 玄青（不随系统） |

三态色由 `DS.Color.palette(_:_:)` 唯一解析入口合成（`hex @N%` 一律预混合到上下文底：卡片场景底=`paper`，窗口/页面外衬底=`desk`，实现为 `DS.Color.overlay(hex:alpha:on:)`，禁止误读为全局透明度）。主题切换时内容根视图 `.id(dsTheme)` 重建 + `NSWindow.appearance` 设置双管齐下，系统控件（菜单、滚动条、Form 行）随主题刷新。重建范围限定内容根视图，不对列表行逐个 `.id`。

**主题环境注入**：`\.dsTheme`（`DSThemeKey`，`EnvironmentValues.dsTheme: DS.Theme`）在 RootView 的 `.id(dsTheme)` 重建点随同一值注入，子视图读 `@Environment(\.dsTheme)` 即可，不再重复 `@AppStorage("dsTheme") + @Environment(\.colorScheme)` 样板。环境只承载主题值——`DS.Color.palette` 仍是唯一色彩解析入口，语义不变。

## Colors

颜色定义见 `DS.Color`。三档色板（明 / 墨灰 / 玄青）：

| token | 明（纸） | 墨灰 | 玄青 | 用途 |
|---|---|---|---|---|
| `paper` | `#FBFAF7` | `#26272B` | `#141518` | 卡片/命中卡/统计牌底（实色） |
| `desk` | `#F2F0EA` | `#1B1C1F` | `#000000` | 窗口/页面外衬底（桌面色）；墨灰档 `#1B1C1F` 与 paper `#26272B` 拉开灰阶分层；玄青档 PDF 区外缘即此色（保留纯黑） |
| `ink` | `#1F1C18` | `#E8E6E1` | `#ECEAE4` | 主文字（墨色，非纯黑）；prominent 按钮 tint |
| `ink-secondary` | `#6E6A61` | `#A8A59C` | `#9B9890` | 说明文字、元数据 |
| `ink-secondary-highlight` | `#4A463F` | `#CFCCC4` | `#C6C3BB` | secondary 文字的 hover/按下加深（唯一合法的 secondary 强调路径） |
| `ink-tertiary` | `#9A958A` | `#76736B` | `#6B6862` | 引注行、版权页行、徽章文字 |
| `stroke` | `#1F1C18` @10% | `#FFFFFF` @10% | `#FFFFFF` @12% | 卡片/行 1px 描边（hairline 美学，靠 paper/desk 底色差分隔） |
| `stroke-strong` | `#1F1C18` @22% | `#FFFFFF` @22% | `#FFFFFF` @26% | hover 加深、输入框描边、过滤激活态 |
| `select` | `#566879` | `#7F93A6` | `#8799AC` | **仅**选中态/可点链接/选中描边；降饱和的石板灰蓝（对比度 ≥4.5:1） |
| `select-tint` | `#566879` @10% | `#7F93A6` @16% | `#8799AC` @18% | 选中浅底（命中卡不用蓝填充；一律 overlay 预混合） |
| `accent-ocr` | `#A15C1F` | `#DB994D` | `#E8A558` | OCR/来源信号专用（合法位置见下） |
| `highlight-native` | `#E8D48A` | `#D8C67E` | `#CDBB72` | PDF 命中高亮（柔和米黄；页面不反色） |
| `highlight-ocr` | `#E4C08A` | `#DDB57E` | `#C8A86E` | OCR 页命中高亮（柔和琥珀） |
| `seal` | `#8A3220` | `#C4705C` | `#CE7A66` | 印章点缀专用（方形小印/统计牌角标/空态刻痕条/关于页），克制使用 |
| `error` | `#B02924` | `#F27870` | `#FF8D84` | 引用失效、守卫拒绝 |
| `warning` | `#996B0D` | `#E0A847` | `#EDB95C` | 截断、覆盖不全 |
| `success` | `#366E45` | `#70BA85` | `#82CB98` | 校验通过、覆盖完整 |
| `info` | `#4D617D` | `#9EB3CF` | `#AEC2DE` | 零命中原因等中性说明 |
| `surface` | `regularMaterial` | `regularMaterial` | `ultraThinMaterial` | 浮层导航条等振动材质；玄青档降材质厚度防发灰 |

语义色三档化：`ocr`/`error`/`warning`/`success`/`info` 由 `DS.Color.palette` 三档解析（`DS.Color.forStatus` 同步三档化）。玄青档调值对纯黑纸底 `#141518` 的对比度 ≥8.1:1（WCAG 相对亮度基准）。`highlight-native`/`highlight-ocr` 玄青档对应 `#CDBB72`/`#C8A86E`；代码中遗留的两态 adaptive 静态量仅作过渡兼容，新代码一律走 `palette`。

**accent-ocr 合法位置清单**：来源徽章、OCR 状态行、预览卡标注、**书脊条(OCR)**。预览卡的琥珀由"底色块+粗描边"收敛为 1px hairline 标注（同位置缩量，非新位置）。

**select 语义加注**：「不新增第二强调色」指装饰 accent；`select` 是选中态语义色，降饱和后仍是全场唯一功能性冷色，不属装饰强调色。

**琥珀约束**：不得用于按钮、进度条、选中态、装饰。

**系统灰约束**：`CapsuleBadge`/`StatusRow` 的 color 为必填构造参数（无 `.secondary` 默认）——绕过 DS token 的写法在编译期失败；视图禁写 `.secondary`/`.tertiary`/`.quaternary` 与 `Color.primary.opacity`，secondary 强调一律走 `ink-secondary-highlight`。

状态→色唯一映射 `DS.Color.forStatus(_:theme:scheme:)`：统计牌色点、覆盖页圆点、徽章同调一处定义，防映射漂移。

## Typography

界面字族（正文 voice）：系统黑体（SF Pro / 苹方），只用语义字阶与**字重**表达层级，**全文禁用伪加粗**（`.bold()` 一律改 `.weight(.medium/.semibold)` 或升档）。

| token | SwiftUI | 字重 | 用途 |
|---|---|---|---|
| `display` | `.system(size: 30)` SF Symbol | — | 空态主图形（墨色 tertiary） |
| `title` | `.headline` | medium | 统计牌数值、面板头（UI chrome 标题） |
| `body` | `.callout` | regular | 答案正文、书目行 |
| `meta` | `.caption` | regular | 页码轨、状态行 |
| `micro` | `.caption2` | regular | 徽章、辅助脚注、时间戳 |

衬线 display 字阶（书卷对比的标题 voice，`DS.Font`，Songti SC Bold → Songti SC → system serif 回退链，永不 nil）：

| token | 定义 | 用途 |
|---|---|---|
| `display-serif-page` | `displaySerif(24)` | 页面大标题（覆盖/历史/书库页头、关于页） |
| `display-serif-empty` | `displaySerif(20)` | 空态标题（EmptyStateView） |
| `display-serif-group` | `displaySerif(17)` | 结果组头书名、summaryHeader 查询词、AI 预览卡标题 |
| `display-serif-section` | `displaySerif(13)` | 设置/详情/综合对比区块头 |

宋体阅读态（阅读语境，**默认开启**，设置区开关 `@AppStorage("readingSerif")`）：

| token | 定义 | 参数 |
|---|---|---|
| `reading-serif` | Songti SC（`NSFont(name:)` 探测，缺失回退系统字体），15pt | 列表行距 `lineSpacing(6)` ≈1.4×；详情正文 `lineSpacing(9)` ≈1.6×；`tracking(0.2)`；字重 regular/medium，**禁 bold** |
| `reading-serif-meta` | Songti SC 12.5pt | 宋体引注行下限，不得再降；颜色仍走 `ink-tertiary` |

规则：衬线只出现在上表标题位与阅读语境（命中 snippet 长文、详情正文）；界面控件（按钮/输入框/菜单/徽章）永远黑体。等宽数字一律 `.monospacedDigit()`（页码轨、计数、统计牌数值）。最小可读字号：meta ≥ 11pt，micro 仅用于徽章/时间戳。

## Layout

4 的倍数节奏：`4 / 8 / 12 / 16 / 24 / 32 / 48`（`DS.Spacing`；`xxl=32` 用于 PDF 页外衬底与阅读态边距；`xxxl=48` 用于空态垂直留白与关于页等大构成间隙）。

- 组件内部 `xs`；同组 `xs–sm`；卡片内边距 `md`；区块 `lg`（主区块 24，行内密度不动）；页面容器水平 `md`；内容页地面统一 `desk` token（检索/历史/覆盖/收藏/每日一句/书库设置，纸卡与纸面输入框浮在桌面上），不吃窗口系统默认灰底；阅读区外缘 `xxl`；空态垂直 `xxl–xxxl`。
- 列表行高不做全局统一：命中行按内容自适应（垂直内边距 md=16 起，行间 hairline 分隔），但同一列表内间距一致；历史行 xs→sm、收藏行 sm→md、高亮行 xxs→xs。
- 三栏壳（导航/结果/正文）由系统 `NavigationSplitView` 管理，不自绘分隔、不改列宽。
- **三栏宽度契约**：窗口最小 1180×640（RootView）；三栏列宽 导航 min180/ideal200/max260 · 结果 min440/ideal520/max560（max 560，结果列表不需要宽列）· 正文（详情）min480/ideal720/max1400（ideal 720、max 1400，splitter 可拖）——读原文是主任务，详情栏默认拿到窗口大头。
- 详情栏布局契约：PDF 区 `layoutPriority(1)` 吃满栏内全部剩余高度；AI 为可折叠 Section（默认折叠，展开限高 360 + 内部滚动），AI 未配置时整块不渲染；元数据编辑器收进 sheet（ReadingChrome 头部按钮唤起）。**布局验收点：AI 未配置时详情栏除 ReadingChrome 头部条外全是 PDF。**
- `DS.Layout.chromeWrapThreshold = 640`：ReadingChrome 宽⇄折两行的断点，行为契约写死在 DS.Layout，不散落魔法数。
- `fileFacts` 行距 4pt 写死数值，不借用 spacing token（token 语义不越界）。

## Motion

唯一动效语言：`DS.Motion`——`duration 0.2s`（进入/退出）、`hoverDuration 0.15s`（状态交叉淡化）、`offset 6pt`（进入位移上限）、`enter = easeInOut(duration)`。**只有透明度与 ≤6pt 位移**；禁弹簧、缩放、视差。Reduce Motion 下一律传 nil（`DSAppear` 与 ReadingChrome 同纪律）。`.dsAppear()` 修饰符 = opacity+rise 进入过渡，供空态/卡片/面板一次性出现；**不得**用于 LazyVStack 复用行。PaperCard hover 描边升 stroke-strong 自带 0.15s 交叉淡化。

## Elevation & Depth

不用投影、不用渐变。层级靠实色纸底 + 细描边 + 材质表达：

- 纸卡 = `paper` 实色底 + `stroke` 1px 圆角描边（`.paperCard()`），hover/active 仅描边升 `stroke-strong`（0.15s 淡化），无填充变化。
- 材质只留给浮层导航条（`surface` token）与预览卡这类"悬在纸上"的层；`CardSurface` 保留给材质场景（描边走 `stroke` token）。
- 浮层投影唯一豁免 = 命令面板（`.shadow` 轻投影）；其余浮层（收藏回执胶囊、迷你命中胶囊）一律无投影，靠实色纸底 + 描边立足（回执胶囊去投影）。
- 模态确认一律用系统 sheet/alert，不自绘浮层。

## Shapes

圆角：`small 8 / medium 10 / large 12 / seal 3`（`DS.Radius`；`seal` 仅方形小印）。

- 纸卡默认 `large`；命中卡/书目卡/引注面板 `small`；统计牌 `medium`；徽章一律 `Capsule()`。
- 图标用 SF Symbols 线性风格，与文字同色或语义色，不用彩色 emoji 图形。
- 方形印章意象（`seal` 色）合法触点（仍克制）：书库 Section 标题（`SealBadge` 10×10）、统计牌角标、空态标题下 24×2 刻痕条、关于页印章。书脊条（2pt 来源色条）全应用仅组头一处。

## Components

**`paper-card`**— `paper` 实色底 + `stroke` 1px 描边 + 可配圆角；hover/active 仅 `stroke→stroke-strong`（0.15s）；无投影。用于命中卡、零命中原因卡、统计牌、引注面板、书目卡、步骤卡、统计卡外壳。属性：`backgroundColor: {colors.paper}`、`rounded: {radius.large}`、`padding: {spacing.sm}`。

**`capsule-badge`** — 唯一徽章样式：`micro` 文本 + 语义色文字 + 同色 12% 底 Capsule；`color` 必填（编译期防系统灰）。来源=native 墨色 / OCR 琥珀；计数=secondary；其余语义色仅状态。

**`status-row`** — 图标 + 一句话状态行：SF Symbol（caption）+ 文本（meta），`color` 必填。任何长文本必须可换行（fixedSize 纵向）。

**`empty-state`** — 居中空态：30pt 符号（ink-tertiary）+ **衬线标题**（`display-serif-empty`）+ 24×2 朱砂刻痕条（`seal`，品牌触点）+ 可选 `body` 辅助句；`.dsAppear()` 淡入。必须给下一步动作提示。高亮列表面板（popover）空态同此规格（`highlighter` 符号）。

**`seal-badge`** — 方形小印：10×10、`seal` 圆角 3、1px seal 描边空心或填实；`filled: true` 用于关于页。合法位置见 Shapes 节。

**`stat-plate`** — PaperCard(medium) 内：8px 语义色点 + 数值 `title`(headline) medium `.monospacedDigit()` + 标签 caption；整牌 Button（点=过滤，激活态描边升 stroke-strong，附「清除过滤」）。窄窗 `LazyVGrid(adaptive minimum 120)`：<640pt 两列、<420pt 一列。

**`citation-line`**— `meta`/`micro` + `ink-tertiary` + 限 1 行 + 尾部渐隐遮罩（仅超过限宽时触发）。替代散落的引注 Text 样式；渐隐是功能性文本截断的受控豁免，不得当通用遮罩模板复用。内部为单次几何度量，外观与语义不变。

**`reading-chrome`**— 36pt 高浮层导航条：header（来源胶囊+书名+关闭）+ 本文内搜索 + 命中导航，浮于 PDF 区顶部 8px；`surface` 材质 + `stroke` 描边 + `small` 圆角。输入契约 `ReadingChrome(guardInfo:)`：guardInfo ≠ nil 时整个浮层常显（守卫信息永不隐退的结构性保证）；guardInfo == nil 时鼠标离开 2s 自动隐退（VoiceOver 开启不隐退；键盘输入活动期间同样不隐退），隐退时右下角常驻命中计数迷你胶囊（迷你胶囊可点，点按唤起浮层）；低于 `DS.Layout.chromeWrapThreshold`(640) 折两行；ESC 只收起搜索激活态。全部图标控件有 accessibilityLabel，浮层 `.accessibilityElement(children: .contain)`。书名标题落 `display-serif-group`（衬线落地）；header 行新增模式按钮组——专注阅读 toggle（常驻）+ 元数据 sheet 入口 + AI 折叠 Section 开关（AI 未配置或专注阅读中隐藏，后者即"专注=收起一切非 PDF 内容"）。

**`book-spine`**— 行左缘 2pt 宽书脊色条（point 单位）：native→`ink`、OCR→`accent-ocr`，圆角与所在行一致。琥珀合法位置之一，旁边必有书目与页码。

**`preview-card`**（发送确认卡）— 确认按钮永远显式存在（`.borderedProminent`，墨色 tint），禁止回车误触直发；出处行含守卫核对锚点 bookID。琥珀为 1px hairline 标注（paper 底 + ocr 1px 描边 + paperplane 图标），卡内引用块用 `desk` 凹陷底；`.dsAppear()` 进入。

**`hit-row`** — 整行可点（Button + plain，保证辅助功能可达）；为 **hairline 行**（默认态去卡片化：无纸底无描边，垂直内边距 md=16 起 + 行间 `stroke` hairline 分隔，扫读更静）：页码轨行（`.monospacedDigit()`，OCR 徽章保留）+ snippet（`body`，限 2 行，宋体阅读态默认开 `reading-serif`）+ `citation-line` 引注。选中态 = `select` 1px 纯色描边 + 左 2pt 条（去掉 60% opacity，随 select 降饱和为石板灰蓝；双编码与圆角裁切保留，选中 0.15s 交叉淡化）；hover 无卡片可加深时不做 hover。上下文菜单双格式复制与加入综合不变。结果列表提供「收合全部」。

**`book-result-row`** — 书脊条 + 三行密度阶梯：①chevron+书名 **衬线**（`display-serif-group`）+作者 caption+Spacer+计数胶囊+书目详情 ⓘ；②来源胶囊（native=墨色 / OCR=琥珀）；③`citation-line` 版权页行。截断 warning 持续显式存在，双标计数基准（FTS 候选 vs 实际命中）如实并列。

**`about-section`**— 设置页「关于」组：填实印章 + `display-serif-page` 应用名 + 版本 caption + 一句话 tagline；垂直留白 `xxl`。品牌触点之一。

**`hairline`**— 页面内唯一法定分隔：`stroke` @60% 的 1px 横线（`Hairline()` / `.dsHairline(edge:)`）。替换全部手写 `Rectangle().fill(stroke).frame(height:1)` 与页面级 `Divider()`（含收藏页行间分隔）；contextMenu/菜单内部保留系统 `Divider`。浮层控件内部的竖分隔条（ReadingChrome 页内循环 ⇄ 书级步进之间）同此豁免，用系统 `Divider`。历史行整行描边分隔废弃，改行底 hairline + hover 背景微亮（`ink-tertiary` @8%）。

**`hover-fade`**— `.dsHoverFade()`：plain 行 hover 反馈 = 透明度 1.0 → 0.85，0.15s easeOut，无弹簧无缩放；用于收藏行、高亮行等无卡片可加深描边的交互行。有 PaperCard 的行继续用描边升 stroke-strong idiom，两者不叠加。

**`text-field`**— `.textFieldStyle(.dsTextField)`（`DSTextFieldStyle`）：`paper` 实色底 + `stroke` 1px hairline + `Radius.medium` 的唯一文本框样式，替换全部 `.roundedBorder` 系统灰底输入框（检索/筛选栏、设置页 AI 配置、书目元数据、收藏整理栏、覆盖页过滤、阅读浮层本文内搜索、AI 问题栏、高亮备注）。嵌在材质浮层里须保持无重量的输入（命令面板头部过滤框）保留 `.plain`。

**`command-palette`**— ⌘K 唤起（导航菜单同名命令，toggle），全窗 15% dim 背景（点击关闭）+ 居中 480pt 浮层：`surface` 材质 + `stroke` 描边 + medium 圆角 + 轻投影（浮层唯一例外，Elevation「不用投影」指纸面层级）；过滤输入 + 命令列表（聚焦搜索 / 专注阅读 / 轮换主题 / 五个页面跳转），↑↓ 移动、Enter 执行、ESC/⌘K 关闭，`.dsAppear()` 入场。只复用既有 AppState 通道，零新增守卫语义。

**`theme-toggle`**— 设置区分段控件：跟随系统 / 墨灰 / 玄青，写 `@AppStorage("dsTheme")`；旁置宋体阅读态开关（默认开）。

## Do's and Don'ts

**Do**

- `DesignSystem.swift` 是视觉 token 的实现来源；本文件记录其设计约束。
- 标题 voice 用衬线 display 字阶（§Typography 清单），正文/控件 voice 永远黑体。
- 层级表达优先用**字重**（`.weight(.medium/.semibold)`）与字阶升降；需要"加粗"时先问是否该升一档字阶。
- 纸卡场景一律 `PaperCard`；材质只留给浮层导航条、预览卡这类"悬在纸上"的层。
- 命中卡/组头/统计牌的数字一律 `.monospacedDigit()`。
- 新增可点元素必须是 Button（辅助功能可达），禁裸 `onTapGesture`；图标按钮必须给 `accessibilityLabel`（label 文案进 L10n；L10n 只放纯字符串，macOS-only 类型不得进入）。
- 动效一律走 `DS.Motion`（0.2s/0.15s/6pt/easeInOut）；过渡仅使用透明度与小幅位移。
- 阅读态遵循"chrome 隐退、守卫信息不隐退"：staleReference、OCR 切换说明、配对缺失拒绝永远可见（由 `guardInfo` 契约结构性保证）。
- 暗色两档切换后逐屏走查：结果列表、命中卡、PDF 区、覆盖页、sheet 五处必看。
- 每个语义色在明/墨灰/玄青三档检查对比度（WCAG 相对亮度法）。

**Don't**

- 不引入第三方 UI 库、自定义字体文件、投影、渐变、emoji 图形。唯一豁免：`citation-line` 的功能性文本截断渐隐。
- 不用伪加粗（`.bold()`）渲染中文，小字号（meta/micro）尤其禁止。
- 不用系统灰（`.secondary`/`.tertiary`/`.quaternary`/`Color.primary.opacity`/`.gray`/`.white`/`Color.accentColor`）——secondary 强调走 `ink-secondary-highlight`；失效引用用 `error`、墨色实底上的文字用 `paper` 反色、激活/选中图标用 `select`；徽章/状态行的 color 必填 DS token。
- 不把琥珀色用于出处（来源徽章、OCR 状态行、预览卡标注、书脊条(OCR)）以外的任何地方；不新增第二强调色（`select` 是选中态语义色，见 Colors 节加注）。
- 不给 PDF 原书页区域做任何反色/染色/深色滤镜；`desk` 衬底只出现在页面外。
- 不把 `select` 当装饰 accent 用（渐变、图标、背景），它只属于选中态与可点链接。
- 印章式点缀（seal 触点）只出现在 Shapes 节列出的四处；新增使用须经过设计检查。
- 衬线只出现在 display 字阶清单与阅读语境；界面控件永远黑体。
- 不在视觉层塞内部 ID、路径、指纹哈希——引注给人类的字段（书名/页码/格式）；唯一登记豁免：AI 预览出处行的守卫核对锚点 bookID。
- 视图变更不得绕过发送确认卡或移动 `openGuard` 判定；双指纹守卫、旧引用拒绝文案、配对缺失拒绝文案必须保留；三轨页码诚实显示（`未知`不猜）；不把 OCR 坐标回映射到原件页。

## Vibe coding

- 现有技术栈为 SwiftUI + AppKit + PDFKit；优先复用 DS、SF Symbols 和 L10n；换栈或引入依赖先单独评估。
- 一个界面先解决一个主要任务；无关属性不拼 KV 表，静态数据不伪装成实时状态。
- 标题、状态、原因和下一步优先；没有信息价值的副标题、功能宣言和说明段删掉。
- 先用示例数据走查空态、错误态、窄窗和键盘路径，再调整装饰；设计规则不替代真机验收。
