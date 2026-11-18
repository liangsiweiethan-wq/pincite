# 页码基准语义

本文是页码语义的说明源。代码注释（`PageLabels.swift`、`PageNumberService.swift`、`IndexStore+PageMap.swift`）应与之同步。

## 三个基准

| 基准 | 定义 | 来源 | 信任政策 |
|---|---|---|---|
| **physical** | PDF 物理页（1 起） | 解析即得 | 恒知，**全库唯一存储基准** |
| **pageLabel** | PDF `/PageLabels` 树声明的页标签 | PDF 文档结构 | 仅当文档目录结构声明才采信（`CGPDFDocument.catalog` 校验）；未声明 = 未知，绝不猜 |
| **printed** | 纸质版次页脚的印刷页码 | **声明制**：仅来自用户 sidecar 导入 | 逐页显式对或全书 offset；来源记版次字符串（`source_edition`，等价于 dc:source）。未声明 = 未知，绝不猜（不跑 OCR、不启发式猜测） |

## 存储基准恒为物理页

位置记忆（`ReadingPositionStore` 的 `page`）、引句（`Quote.pageNumber`）、高亮坐标（`user_highlights.page_number`）、命中（`SearchHit.physicalPage`）全部以物理页存储。printed 与 pageLabel 只是**显示和引注换算轨**：换算不可得时显式显示「未知」，物理页从不冒充印刷页。

## 统一取页服务

`PageNumberService`（LiteratureCore）是 printed 页码的唯一查询入口，两路合成，优先序固定：

1. `page_map` 表逐页声明（sidecar 显式对或 offset 展开行）；
2. `pages.printed_page` 列（既有 import-meta 等通道写入的整书级值）；
3. 都无 → `nil`（未知）。

消费面包括引句绑定（`DailyQuoteView` 引注）、异版聚合组内命中行（`SearchResultListView` 引注，取本版自己的映射，不跨版换算——跨版页码对齐留待后续）、位置记忆显示（`DetailChromeView` 三轨文本）、高亮导出（`AppState` 三轨行）。`CitationFormatter.citation(printedPage:)` 只接收已解析值。

豁免与边界：

- CLI `search` 的两处全字段 dump（`LiteratureSearchCLI.swift`）直读 `hit.printedPage`（pages 列），用于保持检索输出逐字节稳定；page_map 声明不进该 dump。
- `PDFDetailView` 当前页引注优先序为 **printed → 声明页标签 → 物理页**。页标签只在文档声明 `/PageLabels` 且该页标签为阿拉伯数字（`^\d+$`）或罗马数字（`^[ivxlcdm]+$`，不分大小写）时采信；`Cover`、`Back5`、空标签一律不用，回退物理页。
- `FavoritesView` 收藏引注与 CLI `daily-quote` 引注串维持物理页基准。
- 异版聚合键（`VersionGroup` 文件名键）与计数语义不变。

## sidecar 导入（声明制）

- CLI：`literaturesearch-cli import-page-map --db <path> --csv <file.csv>`
- App：设置页 → 书库 → 「导入页码映射（CSV）」（手动触发，无自动/定时导入）。

CSV 两种来路（判别从严：首非空行含 `offset` 列名表头 → offset 模式；含 `physical`+`printed` 表头或**无表头** → 一律显式对。`fileName,offset` 形态**必须带表头**，无表头不识别，防歧义误导入）：

```csv
# 显式对：fileName,physical,printed[,source_edition]
示例书.pdf,5,13,2013年第4版
# offset（必须带表头）：printed = physical + offset，逐页展开
fileName,offset
某书.pdf,8
```

校验规则（违规行拒收并计数进报告，不中断整批）：`physical ∈ 1...pageCount`；`printed` 为非负整数；同书同物理页重复行拒；越界/非整数/缺列行拒；未匹配 `fileName` 的整书跳过（不猜）；offset 展开后 `printed ≤ 0` 的前置页（如罗马页）拒收并计数。回填写入**只 UPDATE `printed_page` 为 NULL 的行**——既有非空值绝不覆盖（conservative-merge，与元数据导入的「Unknown stays unknown」一致）。

## 基准切换（未实现）

存储基准恒为物理页，当前不提供基准切换 UI。若未来把 printed/pageLabel 升为存储基准，属破坏性操作：需要确认弹窗，并重校批注、位置记忆与高亮锚点。
