# PinCite (页锚) Launch & Promotion Kit

Ready-to-paste release copy for launching `v0.3.0` (`https://github.com/liangsiweiethan-wq/pincite`).

---

## 1. GitHub Release Notes (`v0.3.0`)

```markdown
## PinCite v0.3.0 (页锚)

**Pinpoint every quote to its exact PDF page — locally, verifiably, with zero dependencies.**

### Highlights in v0.3.0
- **Rebranded to PinCite (页锚)** with unified `0.3.0` versioning across macOS, iOS, watchOS, Widgets, and Share Extension.
- **Zero-warning Swift 6 readiness**: eliminated all 341 compiler warnings across production and test targets (`-Xswiftc -warnings-as-errors`).
- **Runtime & concurrency fixes**:
  - Fixed `TTSSpeaker` weak delegate deallocation so read-aloud completion updates UI state reliably.
  - Replaced blocking semaphore/thread waits in OCR subprocess drivers with async continuations + lock-guarded timeout state (removing an unconditional 5-second post-exit wait).
  - Resolved `async` lock and `@Sendable` capture diagnostics in `RefreshEngine`, `AppState`, `SnapshotWindowController`, and `RefreshConsoleStore`.
- **Cold-open speedup**: cached `FTS5Probe` capabilities in-process and skipped redundant open-time `meta` writes.

### Installing the ad-hoc DMG (No Apple Notarization Yet)
1. Download `PinCite-0.3.0-macOS-adhoc.dmg` and drag the app into `/Applications`.
2. Before first launch, remove the macOS quarantine flag (or Control-click the app -> Open):
   ```bash
   xattr -cr /Applications/LiteratureSearch.app
   ```
3. Verify download integrity against `SHA256SUMS.txt`:
   ```bash
   shasum -a 256 -c SHA256SUMS.txt
   ```
```

---

## 2. Hacker News (`Show HN`)

**Title:**
`Show HN: PinCite – Local-first macOS PDF search that pins quotes to exact pages`

**Post body:**
```text
Hi HN,

I built PinCite (Swift/SwiftUI, zero third-party dependencies) because verifying exact quotes and page numbers across thousands of CJK and English PDFs kept failing with Spotlight, Preview, and RAG chatbots.

Key design choices:
1. Exact page & UTF-16 span tracking: hits store the 1-based physical page, UTF-16 [start, end) bounds from a normalized->original offset map, and the file's SHA-256 fingerprint. Reopening checks the fingerprint first so edited/moved PDFs fail closed instead of opening the wrong page.
2. Three-track page truth: physical PDF index, raw /PageLabels (only trusted if declared in PDF structure—PDFKit fabricates 1,2,3... otherwise), and user-imported printed-page CSV maps. Unknown pages stay unknown—never guessed.
3. Read-only library + zero cloud: built strictly on SQLite FTS5, PDFKit, CoreText, and CryptoKit. Notes live in PinCite's own SQLite DB.
4. Opt-in integrations: built-in stdio MCP server (`literaturesearch-cli mcp-serve`), optional loopback HTTP API (127.0.0.1 with per-launch token), and 21 conservative academic/legal citation formats.

Built with 1,124+ synthetic test cases (no external test runner dependencies) and zero compiler warnings under `-warnings-as-errors`.

Repo: https://github.com/liangsiweiethan-wq/pincite
Happy to discuss the SQLite two-DB split (`index.db` + `fulltext.db`), CJK/Latin indexing, or Swift/AppKit interop!
```

---

## 3. Reddit (`r/macapps` / `r/academia` / `r/LocalLLaMA`)

**Title (`r/macapps` / `r/academia`):**
`PinCite v0.3.0 — Free, open-source, 100% offline macOS app to pinpoint quotes across thousands of PDFs (21 citation styles + MCP)`

**Body:**
```text
If you write papers, legal memos, or long-form research and need to verify exact quotes + page numbers across large local PDF folders without uploading files to the cloud:

- **Zero dependencies, native macOS:** Built in SwiftUI + AppKit + SQLite FTS5 + PDFKit.
- **Exact jump-back:** Click a search hit -> verifies SHA-256 fingerprint -> jumps straight to the PDF page and highlights the exact span.
- **Never guesses page numbers:** Keeps physical pages, PDF `/PageLabels`, and printed book pages strictly separate.
- **21 citation formats built-in:** Bluebook, OSCOLA, Chicago 18, APA 7, MLA 9, IEEE, GB/T 7714-2015, etc.
- **MCP & Loopback API for local agents:** Expose verified page-level search to Claude Desktop / Cursor / local tools via `literaturesearch-cli mcp-serve` (off by default).

Source & DMG: https://github.com/liangsiweiethan-wq/pincite
```

---

## 4. 中文社区宣发（V2EX / 知乎 / 即刻 / 小红书）

**标题：**
`开源一个零依赖 macOS 本地文献精查工具 PinCite（页锚）：中英 PDF 秒级定位原文并指纹验真回跳`

**正文：**
```markdown
做人文社科或学术写作时，最耗时间、最容易出错的不是「找资料」，而是**写完一段话后去几千份 PDF 里核对逐字引文和准确页码**：
- Spotlight / 预览能搜词，但经常丢坐标，或者把 PDF 物理页和印刷页码混在一起；
- 文献管理器偏重题录，不擅长海量 PDF 内文秒级回跳；
- AI / 云端 RAG 不仅要上传隐私书库，还经常编造页码、漏掉精确出处。

所以我开源了 **PinCite（页锚）**（Swift 原生、零第三方依赖、MIT 协议）：

1. **回到原件且指纹验真**：每条命中都记录 1-based 物理页、原文 UTF-16 精确区间与 SHA-256 指纹；打开前先核对指纹，防止文件改名或替换后默默跳错页。
2. **页码三轨分离，绝不瞎猜**：物理页（恒知）、PDF `/PageLabels`（仅文档显式声明时采信）、印刷页（仅用户导入页码表时采信）严格分离，未知就诚实显示未知。
3. **中英文混排 + 拼音书名检索**：SQLite FTS5 Trigram + 拉丁词级索引双路协同，支持中英子串、多词 AND、拼音定位书名。
4. **内置 21 种引注体例 & 笔记主权**：支持中文法学期刊、GB/T 7714-2015、Bluebook、Chicago、APA 等体例；高亮与批注存在软件自有数据库，绝不篡改原版 PDF。
5. **内置 MCP 与本机只读 API**：通过 `literaturesearch-cli mcp-serve` 可直接接入本机 AI 工具，让智能体只引用可溯源的物理页段落。
6. **工程标准**：1,124+ 项纯合成测试全过，开启 `-warnings-as-errors` 零告警编译，默认零网络、零遥测。

仓库与 macOS 安装包（支持 Apple Silicon，附 3 页样例 PDF 开箱即试）：
https://github.com/liangsiweiethan-wq/pincite
```
