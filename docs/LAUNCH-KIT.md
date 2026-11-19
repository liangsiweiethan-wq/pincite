# PinCite（页锚）v0.3.0 中英双语多社群宣发工具包

适用版本：`v0.3.0` · 仓库主页：https://github.com/liangsiweiethan-wq/pincite · 下载页：https://github.com/liangsiweiethan-wq/pincite/releases/tag/v0.3.0

> 使用提示：下方所有文案均可直接复制发布；首次安装无公证 DMG 的终端解除隔离命令统一为 `xattr -cr /Applications/LiteratureSearch.app`。

---

## 1. GitHub Release Notes（中英双语）

```markdown
## PinCite v0.3.0 (页锚)

**Pinpoint every quote to its exact PDF page — locally, verifiably, with zero third-party dependencies.**
**把每一句引文稳稳钉回 PDF 原页 —— 本地优先、指纹验真、零第三方依赖。**

### Highlights / 核心更新
- **Rebranded to PinCite (页锚)** with unified `0.3.0 (3)` versioning across macOS, iOS, watchOS, Widgets, and Share Extension.
- **Zero-warning Swift 6 readiness**: eliminated all 341 compiler warnings across production and test targets (`-Xswiftc -warnings-as-errors`) with all **1,130 synthetic test cases** passing on both local macOS and GitHub Actions `macos-15` CI.
- **Runtime & concurrency fixes**:
  - Fixed `TTSSpeaker` weak delegate deallocation so read-aloud completion updates UI state reliably.
  - Replaced blocking waits in OCR subprocess drivers with async continuations + lock-guarded timeout state (removing an unconditional 5-second post-exit wait).
  - Resolved `async` lock and `@Sendable` capture diagnostics (`ReadingStatsStore`, `SnapshotWindowController`, `RefreshEngine`, `AppState`, `RefreshConsoleStore`) and added explicit `TimeZone` injection for timezone-independent reading stats.
- **Cold-open speedup**: cached `FTS5Probe` capabilities in-process and skipped redundant open-time `meta` writes.

### Installing the Ad-Hoc DMG / 无公证预览版安装步骤
1. Download `PinCite-0.3.0-macOS-adhoc.dmg` and drag `LiteratureSearch.app` (displayed as **PinCite**) into `/Applications`.
2. Strip the macOS quarantine attribute once before first launch (or Control-click → Open):
   ```bash
   xattr -cr /Applications/LiteratureSearch.app
   ```
3. Verify download integrity against `SHA256SUMS.txt`:
   ```bash
   shasum -a 256 -c SHA256SUMS.txt
   ```
```

---

## 2. LINUX DO（开源自荐 · 技术极客 / AI 工作流向）

**推荐板块：** `开发调优` / `开源分享`

**标题：**
`[开源自荐] PinCite（页锚）：零三方依赖的原生 macOS 文献精查工具 —— 本地秒搜上千 PDF、指纹验真回跳、自带 MCP 防 AI 编造页码`

**正文：**
```markdown
各位佬友们好，开源一个我自己写论文 / 查长文档打磨出来的原生 macOS 工具：**PinCite（页锚）**，MIT 协议，今天刚把 `v0.3.0` 完整打包推上 GitHub。

### 为什么要造这个轮子？
用本机几百上千份中英文 PDF 查精确引文与页码时，现有工具各有一个硬伤：
1. **Spotlight / 预览**：能搜词，但长文跳回来丢精确区间，还经常把「PDF 物理页码」和「书上印刷页码」混成一锅。
2. **本地 / 云端 AI RAG**：切片分块直接丢失原页精确 UTF-16 边界，问它第几页最容易张口编造。
3. **不想传云端**：很多专业文献、内部资料和批注笔记不适合上传第三方服务器。

所以我用纯 Swift 重头写了 **PinCite（页锚）**：**零第三方 SwiftPM 依赖**、全部基于 macOS 原生系统框架（`SwiftUI`、`AppKit`、`PDFKit`、`SQLite3`、`CryptoKit`、`Network`）。

---

### 几个比较硬核的工程取舍
1. **原件只读 + SHA-256 Fail-Closed 回跳**：每条搜索命中存下 `1-based` 物理页、原文 UTF-16 `[start, end)` 区间，以及文件 SHA-256 指纹。回跳前重新核对文件指纹，原 PDF 被替换或改动宁可拒绝打开提示重绑，绝不静默跳错页。
2. **页码“三轨分离”，绝不瞎猜**：
   - 物理页（1 起 PDF 页序，恒知）；
   - `/PageLabels`（仅当 PDF 结构显式声明时才信，防止扫描件被强行伪造 `1,2,3...`）；
   - 印刷页（仅认用户手动导入的 CSV 页码映射表）。未知就诚实显示未知。
3. **双库物理分离 + 中英混合检索引擎**：`index.db` 存书目/批注/三轨页码，`fulltext.db` 专存页文本、SQLite FTS5 Trigram、Unicode61 拉丁词级投影（`pages_wfts`）和短词精确回退，另带拼音定位书名。
4. **笔记主权 & 21 种引注格式**：高亮、下划线、页面笔记、笔迹全落自有 SQLite 库，永不改写原 PDF；内置 GB/T 7714-2015、中文法学刊物、Bluebook、OSCOLA、Chicago 18、APA 7 等 21 种体例。
5. **给本地 AI Agent 供“真凭实据”的接口（默认全部关闭）**：
   - 原生 **stdio MCP 服务**：`literaturesearch-cli mcp-serve`（可以直接接 Claude Desktop / Cursor / 本机 Agent，让模型查精确页码再下笔，不再幻觉编页码）；
   - 可选 **127.0.0.1 环回只读 HTTP API**：每次启动生成独立随机 Bearer Token。
6. **工程纪律**：1,130 项纯合成测试用例 + `-warnings-as-errors` 零告警编译，GitHub Actions `macos-15` CI 每次提交实测全绿。

---

### 30 秒体验（无需导自己的真书库）
- 下载 DMG：https://github.com/liangsiweiethan-wq/pincite/releases/tag/v0.3.0
- 注：暂时没有个人苹果开发者账号公证，用的 ad-hoc 签名，拖进 `/Applications` 后在终端执行一次解除隔离即可启动：
  ```bash
  xattr -cr /Applications/LiteratureSearch.app
  ```
- DMG 里自带一份 3 页合成样书 `PinCite-QuickStart.pdf`，选为书库点索引，搜索 `pinpoint` 或 `页码三分离` 就能直接验证指纹回跳效果。
- 源码仓库：https://github.com/liangsiweiethan-wq/pincite

当前 macOS UI 默认简体中文，应用内英/中一键切换和 `AppState` 模块拆分放在 `v0.4.0`。欢迎各位佬友试用拍砖，如果戳中你的检索痛点，求个 Star 支持一下！
```

---

## 3. 小红书（图文笔记 · 中文爆款版 + 留学党双语版）

### A. 中文主帖（适配科研 / 硕博 / 法学生 / 人文社科）

**备选标题（三选一）：**
1. `写论文找死人的原页出处？我开源了一个本地 Mac 精查神器📌`
2. `求求别再用 AI 编页码了！这个零联网开源软件帮我守住论文引文最后一道防线`
3. `本地上千篇 PDF 秒定位原页+自动算引注，还绝不改写原文件｜开源免费`

**配图 5 张分镜建议（直接用苹果截图/Figma 做卡片）：**
1. **封面图**：米白纸感底色 + 大字「写论文核对引文页码？1 秒钉回 PDF 原页」+ 副标题「免费开源 · 纯离线 · 不改原 PDF · 防 AI 编页码」。
2. **图 2（痛点对比卡）**：左栏「常见踩坑（预览乱跳、AI 编造页码、PDF 物理页 ≠ 书上页码）」vs 右栏「PinCite（指纹验真回跳、三轨页码绝不瞎猜）」。
3. **图 3（搜索 + 精确高亮回跳界面 / QuickStart 示例）**：框出「命中原文 + 物理页/印刷页分开标 + 点击直接高亮原句」。
4. **图 4（21 种引注 + 笔记主权）**：展示「法学引注 / GB/T 7714 / Chicago / APA / Bluebook 一键生成，高亮全存独立库不污染原 PDF」。
5. **图 5（3 步安装指南）**：展示 GitHub Releases 下载 -> 拖入应用程序 -> 终端一行命令解决无签名提示。

**小红书正文：**
```text
写论文、做法条检索或文献综述的时候，最崩溃的瞬间永远不是“找不到资料”，而是👇
正文写完了，回头去几百上千份 PDF 里**核对逐字原文和准确页码**！

❌ Mac 自带预览搜中文经常漏字，点过去不知道停在具体哪一句；
❌ 扫描书的 PDF 第 15 页其实是正文第 1 页，工具不区分的话引注必错；
❌ 用 AI 工具问出处，它经常一本正经给你编一个根本不存在的页码；
❌ 很多私有资料根本不想上传到云端服务器。

于是我写并开源了 **PinCite（页锚）**——专门在 Mac 本地做「精准页码核对」的工具，MIT 协议完全免费，零云端、零追踪：

1️⃣ **点结果直接钉回 PDF 原页高亮区**
中英文都能按页精查，还支持按书名拼音搜索！回跳前先核对文件指纹，就算书库文件被移动或修改也不会悄悄跳错页。

2️⃣ **物理页 / PDF 页标 / 印刷页严格分开，绝不瞎猜**
PDF 第 14 页对应印刷第 1 页？没依据就不乱标，支持导入自己的页码对照表，科研引用最怕的页码错位彻底解决。

3️⃣ **绝不弄脏你的原版 PDF**
所有高亮、下划线、页面笔记都存在软件独立数据库里，原 PDF 全程只读不动；导出批注只另存新副本。

4️⃣ **内置 21 种中西文引注格式**
法学期刊体例、GB/T 7714-2015、APA 7、MLA 9、Chicago 18、Bluebook 等原生自带，还能通过 MCP 接给本机 AI 工具，让 AI 只引查得到的真页码。

📦 获取方式（完全免费开源）：
GitHub 搜 `liangsiweiethan-wq/pincite` 进 Releases 下载 `PinCite-0.3.0-macOS-adhoc.dmg` 即可～

⚠️ 新手安装小贴士（非常重要！）：
因为还没办苹果付费公证，软件拖进“应用程序”后第一次打开前，打开系统“终端”，复制运行这一行就行：
`xattr -cr /Applications/LiteratureSearch.app`
（安装包里自带了一本 3 页测试样书 `PinCite-QuickStart.pdf`，先别急着导大书库，拿它 10 秒就能试出效果！）

有 Mac 做科研或写长文的姐妹兄弟自取，欢迎评论区提需求！✨

#Mac效率神器 #科研工具 #写论文必备 #学术写作 #文献管理 #法学生 #人文社科 #开源软件 #读研日常 #PinCite
```

### B. 小红书 · 海外硕博 / 留学生中英双语短版

**标题：**
`写英文 Paper 核对 Exact Page 救星｜开源零联网 Mac 本地 PDF 精查 PinCite`

**正文：**
```text
写英文 Essay / Thesis / Legal Memo 最怕什么？
Citation format 扣分事小，**quote 和 page number 对不上直接被查成学术不端嫌疑**才致命😵‍💫

开源自用 Mac 工具 **PinCite（页锚）**，专门治“本地海量 PDF 查 verbatim quote + pinpoint page”：

✅ **UTF-16 exact span highlight**：搜到句子点一下，直接定位到原 PDF 那一页、那一行。
✅ **Strict 3-Track Page Truth**：Physical Page vs. PDF `/PageLabels` vs. Printed Book Page 严格分离，no fabricated page numbers。
✅ **SHA-256 Fail-Closed**：防止重命名/覆盖 PDF 后 silently jump 到错页。
✅ **21 Citation Formats Built-in**：Bluebook、OSCOLA、Chicago 18、APA 7、MLA 9、GB/T 7714 一键出，还自带 stdio MCP 给本机 AI Agent 提供可溯源页码。
✅ **100% Local & Zero Dependencies**：原生 Swift 开发，零三方包、零上传。

🔗 GitHub（MIT 开源免费）：`liangsiweiethan-wq/pincite` -> Releases 下载 macOS DMG。
💡 初次打开先在 Terminal 跑一句 `xattr -cr /Applications/LiteratureSearch.app` 解除未公证限制即可～

#留学生日常 #Essay神器 #论文写作 #Mac软件推荐 #LawSchool #PhDLife #Zotero好搭档 #开源工具 #PinCite
```

---

## 4. X / Twitter（英文 Thread · 中文 Thread · 双语单条精选）

### A. English Thread (4 Posts — Build in Public / Indie Dev / Academic Tech)

**Post 1 (Hook):**
```text
AI PDF tools hallucinate page numbers.
Spotlight forgets the exact quote span.
Preview blurs physical vs. printed book pages.

So I open-sourced PinCite (v0.3.0) — a local-first native macOS PDF search tool that pins every quote to its verified page.

Zero dependencies. 100% offline. MIT licensed. 🧵👇
```

**Post 2 (Core Engineering):**
```text
2/4 How PinCite refuses to lie about citations:

• Every hit binds to 1-based physical page + exact UTF-16 [start, end) bounds + SHA-256 fingerprint
• Jump-back re-verifies the file digest (fail-closed if modified)
• 3 strict page tracks: physical index vs. raw /PageLabels vs. user CSV map — unknown stays unknown
```

**Post 3 (Workflow + Agent MCP):**
```text
3/4 Built for serious reading & agent grounding:

• Dual-DB SQLite FTS5 Trigram + Latin word index + Pinyin title search
• Read-only library: highlights & notes live in PinCite's own DB
• 21 built-in citation styles (Bluebook, OSCOLA, Chicago 18, APA 7, GB/T 7714)
• Opt-in stdio MCP server (`literaturesearch-cli mcp-serve`) so local agents cite verified pages
```

**Post 4 (CTA):**
```text
4/4 Pure Swift 6 + Apple frameworks (`0` external SwiftPM dependencies, `1,130` synthetic tests passing on `macos-15` CI).

macOS DMG (with a 3-page QuickStart PDF) & source:
https://github.com/liangsiweiethan-wq/pincite

Preview uses ad-hoc signing (`xattr -cr` note included). Feedback & PRs welcome! #macOS #Swift #LocalFirst #AcademicTwitter #MCP
```

---

### B. 中文 Thread（4 条 · 独立开发者 / AI 效率圈）

**第 1 条（Hook）：**
```text
Spotlight 找不准原文选区，预览分不清物理页和印刷页，AI RAG 还动不动就编造一个假页码。

于是我开源了 PinCite（页锚）v0.3.0：一款纯本地原生 macOS 文献精查工具，把每一句引文稳稳钉回 PDF 原页。

零第三方依赖 · 100% 离线 · MIT 开源 🧵👇
```

**第 2 条（技术内核）：**
```text
2/4 为什么说它比“普通搜词”严谨得多？

• 每条命中绑定 1 起物理页、原文 UTF-16 精确区间和原文件 SHA-256 指纹
• 回跳前先校验指纹（Fail-Closed），文档替换或修改立刻拦截
• 物理页 / PDF /PageLabels / 印刷页三轨分离，没有依据绝不猜页码
```

**第 3 条（生产力与 Agent MCP）：**
```text
3/4 给深度写作者与本地 Agent 准备的能力：

• SQLite FTS5 Trigram + 拉丁词级检索 + 书名拼音定位
• 原 PDF 严格只读，高亮与批注归自有数据库（笔记主权）
• 内置 21 种引注体例 + 原生 stdio MCP（`literaturesearch-cli mcp-serve`），让本机 AI 引用真实可查的物理页
```

**第 4 条（发布引导）：**
```text
4/4 纯 Swift 原生编写（0 外部依赖，1,130 项全合成测试已在 `macos-15` CI 跑绿）。

源码与 macOS 安装包（内置 3 页测试样书，开箱即试）：
https://github.com/liangsiweiethan-wq/pincite

当前采用 ad-hoc 无公证签名，拖入应用程序后跑一句 `xattr -cr /Applications/LiteratureSearch.app` 即可启动。欢迎拍砖与 Star！#开源 #macOS #LocalFirst #MCP
```

---

### C. X 双语单条精选版（One-Shot Post）

```text
Open-sourced PinCite (页锚) v0.3.0 — a 100% local, zero-dependency macOS app to pinpoint quotes across thousands of CJK & English PDFs.

• Exact UTF-16 jump-back + SHA-256 fail-closed verification
• Strict 3-track pages (no hallucinated numbers)
• 21 citation styles + built-in stdio MCP for local agents
• 1,130 synthetic tests passing cleanly on Swift 6 CI

开源本地零依赖 macOS 文献精查工具：精准高亮回跳 + 指纹验真 + 页码三分离 + 21 种引注 + MCP 桥。

Repo & DMG: https://github.com/liangsiweiethan-wq/pincite
```

---

## 5. V2EX（`/go/share` 分享创造 · 极客克制风）

**标题：**
`开源了一个零依赖的原生 macOS 文献精查工具 PinCite（页锚）：中英 PDF 秒搜原页 + 指纹验真回跳`

**正文：**
```markdown
写人文社科、法律备忘录或长文时，有个高频但很难受的场景：手头存了几百上千份中英文 PDF，正文写完后要回头核对精确引文和准确页码。

试用过几类现有方案：
- 系统 Spotlight / 预览能搜到文件，但回到 PDF 常丢精确选区，且遇到扫图/序言页码偏移时把物理页和印刷页混在一起；
- 通用文献管理偏重题录元数据，大库内文逐字回跳弱；
- 云端 PDF RAG 需要传私密书库，分块后还丢精确坐标，最容易幻觉错页。

所以折腾了这个纯原生的 **PinCite（页锚）**，MIT 开源，v0.3.0 刚推上去：https://github.com/liangsiweiethan-wq/pincite

### 工程上的几个关键约束
1. **Zero dependencies**：只用苹果原生框架（`SwiftUI`、`AppKit`、`PDFKit`、`SQLite3`、`CryptoKit`、`Network`），无任何外部 SwiftPM 依赖，默认零联网、零遥测。
2. **双库物理分离 + 中英混搜**：`index.db` 存元数据和批注，`fulltext.db` 专放页文本和 SQLite FTS5 Trigram / 词级投影（`pages_wfts`），辅以书名拼音检索。
3. **Fail-Closed 回跳验真**：命中记录物理页、`[start, end)` UTF-16 偏移和原文件 SHA-256，打开前重验摘要，文件改名替换后拒绝对错位页面做“假回跳”。
4. **页码三轨分离**：物理页（恒知）、`/PageLabels`（仅原 PDF 结构真写了才采信，PDFKit 自己生成的假 `1,2,3...` 不信）、印刷页（仅认 CSV 映射表）。
5. **可接入本地工作流**：内置 `literaturesearch-cli mcp-serve`（stdio MCP），以及默认关闭、每次启动生成临时 Token 的 `127.0.0.1` 只读 API，方便给本机 AI Agent 提供可核查出处。

### 坦诚交代当前限制
- **无 Apple 公证签名**：暂未申请付费 Apple Developer ID，DMG 用 `codesign --sign -` 临时签名，拖入 `/Applications` 后首次运行需执行 `xattr -cr /Applications/LiteratureSearch.app`（或右键打开）。
- **界面语言**：目前桌面端 UI 为简体中文，计划在 `v0.4.0` 补上应用内英/中双语切换及 `AppState` 拆分。
- **质量现状**：128 个套件共 1,130 项纯合成测试已通过（含 33 项 `DesignGuard` 架构和隐私红线断言），GitHub Actions `macos-15` 全绿。

Releases 页提供了 `PinCite-0.3.0-macOS-adhoc.dmg`（里面顺手附了个 3 页纯合成样例 PDF，方便不导个人书库直接体验），也欢迎看源码或提 Issue 交流。
```

---

## 6. 知乎（回答模板：科研 PDF 检索 / 防止 AI 编页码 / 学术写作工具推荐）

**适用问题：** “有什么好用的 macOS 本地多 PDF 全文检索工具？” / “写论文如何高效核对几百篇参考文献的逐字引用和页码？”

**正文：**
```markdown
如果你的核心需求不是“管理文献题目和待读列表”，而是**面对电脑里攒下来的上千份 PDF，要在落笔前后快速核对「某句话到底出自哪本书的第几页、原文是不是一字不差」**，可以试试我刚开源的 **PinCite（页锚）**（MIT 协议，纯原生 macOS 软件，零云端、零收费）。

仓库与安装包地址：https://github.com/liangsiweiethan-wq/pincite

---

### 一、为什么普通搜索和 AI 解决不了“精准核对页码”？
做长文或学术引用时，最隐蔽的坑有三个：
1. **物理页和书上页码是两回事**：很多扫描专著有 15 页前言目录，PDF 物理第 16 页才是印刷第 1 页；更糟的是不少工具在 PDF 没声明页标时直接硬编一套 `1, 2, 3...`。
2. **文件一改名/重排版，旧摘录就指到风马牛不相及的页**：普通笔记只存文件路径 + 页码，原件一旦替换，回跳不会有任何提示。
3. **AI 总结 / 云端 RAG 极易张冠李戴**：切片入库天生破坏原页的精确起止边界，问它精确页码很容易出现“内容像但页码瞎编”的幻觉。

### 二、PinCite（页锚）怎么从底层解决这三个问题？
1. **页码三轨分离，未知就是未知**
   严格区分「物理页（PDF 1 起顺序）」「PDF `/PageLabels`（仅当原 PDF 结构显式写明才采信）」和「印刷页（仅认自己导入的页码对照表）」，绝不猜测编造。
2. **回跳先校 SHA-256 指纹 + UTF-16 精确高亮**
   每一条搜索命中都同时锚定原文 UTF-16 区间和文件 SHA-256。点回原书前先校验指纹，一旦发现文件被改过就会当场拦截提示重绑。
3. **中英混合秒搜 + 拼音定位书名**
   底层基于 SQLite FTS5 Trigram 与西文词级双索引（`index.db` 与 `fulltext.db` 物理分离），兼顾中文精准子串、多词 `AND` 和书名拼音直达。
4. **原件只读 + 内置 21 种引注格式**
   所有高亮、下划线、页面笔记全存在软件自己的数据库里，绝不改动原版 PDF；支持中文法学期刊、GB/T 7714-2015、Bluebook、OSCOLA、Chicago 18、APA 7 等 21 种格式一键输出。
5. **给本机 AI 配一条可溯源的 MCP 通道（默认关闭）**
   附带命令行工具 `literaturesearch-cli mcp-serve`，如果你在用本机 AI 辅助写作，可以让 Agent 通过 MCP 去本地真库检索物理页原句，而不是靠猜生成页码。

### 三、如何快速体验（30 秒无需导入个人大书库）
1. 在 GitHub Releases 下载 `PinCite-0.3.0-macOS-adhoc.dmg` 并将应用拖入「应用程序」。
2. 因目前未购 Apple 付费开发者签名，首次打开前请在终端执行一次：
   ```bash
   xattr -cr /Applications/LiteratureSearch.app
   ```
3. 镜像内随附了 3 页双语测试样书 `PinCite-QuickStart.pdf`，导入后直接搜 `pinpoint` 或 `页码三分离`，就能直观看到「物理页 vs 印刷页」和精确高亮回跳效果。
```

---

## 7. Hacker News (`Show HN`, Native English)

**Title:**
`Show HN: PinCite – Local-first macOS PDF search that pins quotes to exact pages`

**Post body:**
```text
Hi HN,

I built PinCite (`v0.3.0`, pure Swift/SwiftUI, zero third-party dependencies) because verifying exact verbatim quotes and page numbers across thousands of CJK and English PDFs kept failing with Spotlight, Preview, and RAG chatbots.

Key engineering choices:

1. Exact UTF-16 span & Fail-Closed SHA-256 jump-back: every search hit binds to a 1-based physical page, UTF-16 [start, end) offsets mapped back from normalized text, and the file's SHA-256 digest. Reopening re-verifies the fingerprint so renamed/edited PDFs fail explicitly instead of silently jumping to the wrong page.
2. Strict 3-track page truth: PinCite keeps physical page index (always known), raw PDF `/PageLabels` (trusted only when declared in raw PDF structure—not PDFKit's fabricated 1,2,3... fallback), and user-imported printed-page CSV maps strictly separate. Unknown numbers stay unknown.
3. Read-only library + zero telemetry: built solely on Apple system frameworks (SQLite3 FTS5, PDFKit, CoreText, CryptoKit). Highlights, ink, and notes live in PinCite's own SQLite DB (`index.db` + `fulltext.db` physical split); original PDFs are never altered.
4. Opt-in agent grounding: ships a stdio MCP server (`literaturesearch-cli mcp-serve`), optional loopback HTTP API (`127.0.0.1` with per-launch token), and 21 conservative academic/legal citation formatters.

Verified by 1,130 synthetic test cases built with `-Xswiftc -warnings-as-errors` (zero warnings, green on `macos-15` CI).

Repo & ad-hoc macOS DMG (includes a 3-page synthetic QuickStart PDF):
https://github.com/liangsiweiethan-wq/pincite

Happy to discuss the two-DB split, CJK Trigram + Latin word projection indexing, or Apple frameworks architecture!
```

---

## 8. Reddit（英文分场景定制版）

### A. `r/macapps` & `r/academia`

**Title:**
`PinCite v0.3.0 — Free, open-source, 100% offline native macOS app to pinpoint quotes across thousands of PDFs (21 citation styles + MCP)`

**Body:**
```text
If you write papers, legal memos, or long-form research and need to verify **exact verbatim quotes + accurate page numbers** across large local PDF folders without uploading files to the cloud:

- **Zero dependencies, native macOS:** Built strictly with SwiftUI, AppKit, SQLite FTS5, and PDFKit.
- **Verified jump-back:** Click any hit -> verifies SHA-256 fingerprint -> opens the exact PDF page and highlights the exact UTF-16 span.
- **Never guesses page numbers:** Keeps physical page, raw PDF `/PageLabels`, and printed book pages strictly separate.
- **Read-only source library:** Notes and highlights live in PinCite's own database; annotated exports always write a new copy.
- **21 built-in citation formats:** Bluebook, OSCOLA, Chicago 18, APA 7, MLA 9, Harvard, IEEE, GB/T 7714-2015, etc.
- **1,130 synthetic tests passing on Swift 6 CI**, zero telemetry, zero subscriptions.

Download (`PinCite-0.3.0-macOS-adhoc.dmg` includes a bundled 3-page test PDF) & source:
https://github.com/liangsiweiethan-wq/pincite

*(Note: preview DMG uses ad-hoc signing without Apple notarization — run `xattr -cr /Applications/LiteratureSearch.app` once after dragging to Applications, or Control-click -> Open. Desktop UI is currently Simplified Chinese with full EN/ZH toggle arriving in v0.4.0; CLI and docs are fully English-ready.)*
```

### B. `r/LocalLLaMA`（侧重离线 Agent 检索防幻觉）

**Title:**
`[Open Source] PinCite v0.3.0 — Give local MCP agents verified, SHA-256-anchored PDF page citations (zero cloud, pure Swift/SQLite FTS5)`

**Body:**
```text
One recurring issue when hooking local LLMs up to personal PDF collections via RAG is **citation drift**: vector chunking drops exact page boundaries and models hallucinate page numbers.

I just released **PinCite v0.3.0** (`MIT`, native macOS / Swift, zero external deps), which includes an opt-in **stdio MCP server** (`literaturesearch-cli mcp-serve`) backed by a deterministic SQLite FTS5 two-DB index (`index.db` + `fulltext.db`):

- Every search result returned to your local agent carries a 1-based physical page, exact UTF-16 `[start, end)` bounds, and file SHA-256 digest.
- Separates physical pages, raw PDF `/PageLabels`, and printed-page CSV maps so agents never confuse preface pagination with body pages.
- Strict fail-closed exclusions + read-only library + optional loopback HTTP API (`127.0.0.1` with ephemeral bearer token).
- Tested with 1,130 synthetic test cases under `-warnings-as-errors` on GitHub `macos-15` CI.

Repo & quick-start CLI (`genpdf` / `index` / `search` / `mcp-serve`):
https://github.com/liangsiweiethan-wq/pincite
```

---

## 9. 即刻 / 微信社群 / Discord 转发短推（中英双版）

### 中文短推（微信群 / 即刻 / 朋友圈）
```text
开源了一个自己打磨已久的原生 macOS 文献精查工具「PinCite（页锚）」v0.3.0 📌
专门解决长文/论文写到最后「核对逐字引文和准确页码」的痛点：
- 中英 PDF 秒级定位原页并高亮精确选区，回跳前先校对 SHA-256 防跳错页
- 物理页 / PDF 页标 / 印刷页三轨分离，未知就是未知，绝不瞎编页码
- 零第三方依赖、纯离线、原 PDF 全程只读，内置 21 种引注体例和 MCP 接口（可防本地 AI 编页码）
- MIT 开源免费，自带 3 页体验样书，1,130 项测试全绿：
https://github.com/liangsiweiethan-wq/pincite
```

### English Quick Blurb (Discord / Slack / Group Chats)
```text
Just shipped **PinCite v0.3.0** — an open-source, 100% offline, zero-dependency macOS app + CLI + stdio MCP server for pinpointing exact quotes across large CJK/English PDF libraries.
Every hit anchors to verified UTF-16 bounds, SHA-256 file fingerprint, and strict 3-track page truth (zero hallucinated page numbers), with 21 built-in citation styles and 1,130 passing tests.
Check it out / grab the DMG: https://github.com/liangsiweiethan-wq/pincite
```
