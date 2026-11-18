# 架构

## 模块

```
Sources/LiteratureCore            可测试核心（无 AppKit 依赖；PDFKit/CoreText/SQLite3/CryptoKit）
  FTS5Probe                       运行时探测 FTS5 / trigram / unicode61（内存库，无副作用）
  SQLiteDatabase                  SQLite3 C API 薄封装（prepare/bind/step/事务）
  IndexStore                      schema + 书目/页 CRUD + FTS 同步 + 候选页查询（NSLock 串行化）
  SearchNormalization             搜索归一化（NFKC + 小写 + 去零宽/软连字符 + 空白折叠）
                                  产出 starts/ends 映射（归一化字符 → 原文 UTF-16 偏移）
  PDFTextExtractor                逐页抽取（物理页 1-based），归一化副本，selectionBounds()
  PageLabels                      /PageLabels 原始字节声明检测 + PDFKit 标签读取 + 规则求值
  PageNumberService               印刷页唯一查询入口（page_map > pages.printed_page > nil）
  Fingerprint                     流式 SHA-256（1 MiB 分块），页与内容指纹绑定
  ExclusionPolicy / GlobMatcher   配置子串/glob + 符号链接逃逸检测
  IndexingEngine                  显式、可取消、增量索引（扫描 → 差异 → 清理，进度回调）
  SearchService                   字面多词 AND 检索；未知字段显式为 nil；原文片段
  AIAssistantService              配置（默认 nil）/ 预览 / 确认门控发送 / 响应解析
  ReferenceResolver               结构化引用仅接受输入 ID，页界与指纹校验
  DeepLink                        literaturesearch://search?q=…
  SharedHistoryStore              App Group 共享面（历史 + 覆盖，无原文字段）
  SyntheticPDFMaker               合成夹具 PDF（CoreText 绘制，含中文；手拼 /PageLabels PDF）
Sources/LiteratureSearchUI        无 SwiftUI 依赖的路由、本地化、引注格式
Sources/literaturesearch-cli      probe / index / search / pdf-info / genpdf 等显式命令
Sources/LiteratureSearchApp       SwiftUI 应用：security-scoped 选目录、索引控制、检索、
                                  PDFView 跳页 + 高亮（指纹不匹配即拒绝旧引用）、AI 门控、深链
app/                              Xcode 工程、iOS、watchOS、Widget 与 Share 扩展
app/Support                       Info.plist、entitlements、App Group
app/LiteratureSearch.xcodeproj    由 Scripts/generate-project.swift 确定性生成
Tests/LiteratureCoreTests         合成测试套件与共享注册表（128 套件 / 1,124 用例）
```

## 数据流

**索引。** 用户选择目录（security-scoped bookmark）→ 枚举文件并执行排除判定（含 real-path 逃逸检测）→ 按指纹比较新增、跳过或更新 → PDFKit 逐页抽取并归一化 → 在同一个事务中提交书目、指纹、逐页数据和 FTS。只有完整扫描且确认文件已不存在后，才清理对应书目与页。书 ID 默认取初始指纹前 20 个十六进制字符并加前缀 `b`。如 ID 已被其他路径占用，新副本的 ID 由指纹与实际路径共同计算。更新文件内容会保留其已有 ID。

**检索。** 查询归一化 → 分词 → 每个词的候选页（trigram ≥ 3 字符走 FTS MATCH，短词走 ESCAPE LIKE；FTS 出错回退 LIKE）→ 交集 → 在归一化文本中逐页定位 → 映射回原文 UTF-16 区间 → 生成原文片段。命中携带指纹；打开原文前重算指纹，不匹配即按旧引用拒绝。

**页内定位。** `PDFPage.selection(for: NSRange)`（UTF-16 区间）→ `selection.bounds(for: page)`。测试覆盖中文与英文命中的非零矩形。

**页码三分离。**

| 基准 | 定义 | 来源 | 政策 |
|---|---|---|---|
| physical | PDF 物理页（1 起） | 解析即得 | 恒知，全库唯一存储基准 |
| pageLabel | PDF `/PageLabels` 声明的页标签 | 文档结构 | 仅当文档目录结构声明时采信；未声明即未知 |
| printed | 纸质版次页脚页码 | 用户 sidecar 导入 | 显式对或全书 offset；未声明即未知，不跑 OCR、不启发式猜测 |

详见 [PAGE-BASIS.md](PAGE-BASIS.md)。

## 关键实证

1. SQLite FTS5 的 external-content 表列名必须与内容表列名一致，否则删除报 `no such column: T.content`。schema 按此建模。
2. PDFKit 的 `PDFPage.label` 在文档未声明 `/PageLabels` 时会伪造 `1`,`2`,…，因此以原始字节是否含 `PageLabels` 作为可信前提。
3. `PDFPage.selection(for:)` 能把 UTF-16 区间映射到页内矩形，中文与英文命中均非零。
4. `swift test` 通过 swift-testing 桥运行合成用例；`swift run literaturesearch-tests` 提供可执行入口。

## 线程与并发

`IndexStore` 内部用 `NSLock` 串行化（SQLite 句柄不跨模块共享语句）。`IndexingEngine` 为 async，逐个文件检查 `Task.isCancelled`；测试用进度回调在首个文件后取消，验证不会跑完全量。应用层 `AppState` 为 `@MainActor`，进度经 Task 回到主线程。

## App Group 与 Widget

应用写 `shared-state.json`（历史 ≤ 20 条，去重置顶；覆盖快照）。路径解析优先 App Group 容器，不可用时回退 Application Support（未签名开发环境）。Widget 只被动读取，约 15 分钟刷新，经 `widgetURL` / `Link` 深链 `literaturesearch://search?q=…` 在应用内预填并执行搜索。小组件不执行检索、不展示原文。

## 测试结构

- 合成套件在 `Tests/LiteratureCoreTests/`，由 `AllSuites.swift` 统一注册；`Tests/SwiftTestBridge/` 将同一批用例接入 swift-testing（`swift test`）。`swift run literaturesearch-tests` 提供独立可执行入口。
