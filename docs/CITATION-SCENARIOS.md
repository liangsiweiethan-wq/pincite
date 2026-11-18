# 引注导出：法学场景映射

本文说明引注格式的设计与覆盖范围；代码源是 `Sources/LiteratureSearchUI/CitationFormatter.swift`，两者冲突时以代码为准。

## 三层结构

1. **引擎层**：`CitationFormatRegistry` 按 `CitationStyle` 取 `CitationFormatDescriptor`，其 `template: (BookCitationMeta, Int?) -> String` 是唯一执行通道；缺字段在模板内一律省略，绝不编造。
2. **样式层**：21 个体例注册在 `CitationStyle` 与 `CitationFormatRegistry.all`，分为中文期刊族（9）、英文国际族（11）、其他（1）。新增体例 = 追加一个 case + descriptor，引擎零改动。
3. **数据层**：`BookCitationMeta.parse` 从文件名与元数据保守解析 author/title/publisher/year/edition/journalForm；解析失败字段留 nil。页码基准见 [PAGE-BASIS.md](PAGE-BASIS.md)。

## 生成契约

> 生成只依赖「文件名（已是引注形态）+ 元数据 + 物理页码」，绝不读取书内容；元数据未知时不编造（缺作者/出版社时退回文件名本体）。一切渲染经 `CitationFormatRegistry` 的模板分发，缺字段一律省略。

页码进模板的取值序为「printed 可得 → 印刷页；否则物理页」，格式字符串不变。两者皆未知时，页码段整段省略。

## 场景 × 承担函数

| # | 场景 | 承担函数 | 页码基准 |
|---|---|---|---|
| 1 | 中文著作·全字段（作者：书名+版次+出版社+年份） | `zhFamily`（CJK 分支） | 印刷页优先，未知/未声明省略进物理页降级处理 |
| 2 | 中文著作·部分字段（任意缺项） | 同上（逐字段省略） | 同上 |
| 3 | 中文著作·裸元数据（仅文件名） | `isBare` → `bareText`（文件名本体） | 同上 |
| 4 | 中文论文（文件名含「…：…，载《刊名》…」嵌套书名号） | `parse` 栈式配对判 `journalForm` → `zhFamily` 论文分支 | 同上 |
| 5 | 拉丁字母著作（英文等） | `zhFamily` 拉丁分支（书目级无句点尾巴） | `, p. N.`（物理页降级处理同序） |
| 6 | 中文检索平台体例 | `beidaFabao` | 同序 |
| 7 | GB/T 7714-2015 | `gbt7714` | 同序 |
| 8 | Bluebook | `bluebook` | 同序 |
| 9 | OSCOLA | `oscola` | 同序 |
| 10 | APA 7th | `apa7` | 同序 |
| 11 | MLA 9th | `mla9` | 同序 |
| 12 | Chicago 18（注释体） | `chicago18Notes` | 同序 |
| 13 | Chicago 18（作者—年份体） | `chicagoAuthorDate` | 同序 |
| 14 | Harvard | `harvard` | 同序 |
| 15 | Vancouver | `vancouver` | 同序 |
| 16 | IEEE | `ieee` | 同序 |
| 17 | AGLC | `aglc` | 同序 |
| 18 | McGill Guide | `mcgill` | 同序 |
| 19 | AMA 11th | `ama` | 同序 |
| 20 | 间接引用（「参见」前缀） | `citation(indirect: true)` | 同上 |
| 21 | 书目级（无页码） | `bookCitation`、`bibliography` | 不取页 |
| 22 | 引文级（原文片段 + 出处） | `quotation` | 同上 |
| 23 | 批量导出（BibTeX） | `bibtex`、`bibtexBatch`、`bibtexKey` | 不取页 |

期刊论文、学位论文、法庭文书、判例引用、法条、合同、译著、古籍等场景的**独立模板**尚未实现。现有代码只认「著作类 + 中文期刊文件名形态」（上表 #4）。机构作者/无作者：无作者时 author 省略，无独立机构作者形态处理。

## 21 体例

| # | case 名 | displayName | 分组 | 模板函数 |
|---|---|---|---|---|
| 1 | `faxueYinzhuShouce` | 中文引注手册体例 | chinese | zhFamily |
| 2 | `zhongguoFaxue` | 中文期刊体例 A | chinese | zhFamily |
| 3 | `faxueYanjiu` | 中文期刊体例 B | chinese | zhFamily |
| 4 | `beidaFabao` | 中文检索平台体例 | chinese | beidaFabao |
| 5 | `gbt7714` | GB/T 7714-2015 | chinese | gbt7714 |
| 6 | `zhongwaiFaxue` | 中文期刊体例 C | chinese | zhFamily |
| 7 | `zhengfaLuntan` | 中文期刊体例 D | chinese | zhFamily |
| 8 | `falvKexue` | 中文期刊体例 E | chinese | zhFamily |
| 9 | `bijiaofaYanjiu` | 中文期刊体例 F | chinese | zhFamily |
| 10 | `bluebook` | The Bluebook | englishIntl | bluebook |
| 11 | `oscola` | OSCOLA | englishIntl | oscola |
| 12 | `apa7` | APA 7th | englishIntl | apa7 |
| 13 | `mla9` | MLA 9th | englishIntl | mla9 |
| 14 | `chicago18Notes` | Chicago 18 (notes) | englishIntl | chicago18Notes |
| 15 | `chicago18AuthorDate` | Chicago 18 (author-date) | englishIntl | chicagoAuthorDate |
| 16 | `harvard` | Harvard | englishIntl | harvard |
| 17 | `vancouver` | Vancouver | englishIntl | vancouver |
| 18 | `ieee` | IEEE | englishIntl | ieee |
| 19 | `aglc` | AGLC | englishIntl | aglc |
| 20 | `mcgill` | McGill Guide | englishIntl | mcgill |
| 21 | `ama` | AMA 11th | englishIntl | ama |

## 页码基准

引注页码取值序：**印刷页（printed）可得 → 印刷页；否则物理页（physical）降级处理；两者皆未知 → 页码段整段省略**。印刷页为声明制（sidecar 导入，`page_map` 表 > `pages.printed_page` 列两路合成），消费面经 `PageNumberService` 统一取页；物理页从不冒充印刷页。存储基准恒为物理页。
