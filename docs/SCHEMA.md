# 数据 Schema

PinCite 采用**两库物理分离**架构：

- **主库 `index.db`**（SQLite，WAL，`foreign_keys=ON`）：随快照/备份流转，承载书目元数据、用户批注、笔迹、收藏、页码映射、队列与统计；版本门禁 fail-closed，绝不静默降级打开未知新版库。
- **全文派生物 `fulltext.db`**（同连接 `ATTACH DATABASE ... AS ft`）：承载可再生的页面文本、FTS5 倒排虚表与加速索引；不随轻量用户数据备份，版本不符或损坏时整库删除并触发重排重建。

`currentSchemaVersion = 13`（含 V2–V14 迁移步骤），`currentFulltextFormatVersion = 1`。兼容早期的单库（`main.pages` 在位）只读/迁移路径，新库一律默认分离形态。

## meta（`index.db`）
| 列 | 类型 | 说明 |
|---|---|---|
| key | TEXT PK | |
| value | TEXT | `schema_version`=13；`index_schema_version`=13；`search_mode`=`fts5-trigram`\|`like-fallback`；`sqlite_version`；`normalization_version`=4；`wfts_ready`；`bidx_dirty`；`quickcheck_ok_at` |

## books（`index.db`）
| 列 | 类型 | 说明 |
|---|---|---|
| id | TEXT PK | `b` + 初始内容 SHA-256 前 20 hex（内容寻址；内容更新保持不变） |
| real_path | TEXT UNIQUE | 解析符号链接后的规范路径 |
| root_path | TEXT | 本次索引根（解析后），用于删除清理的归属判定 |
| rel_path / file_name | TEXT | 相对路径 / 文件名 |
| title / author / version / language / meta_source | TEXT NULL | **NULL = 未知**（永不从文件名猜元数据） |
| first_fingerprint | TEXT | 首次索引内容指纹（ID 来源） |
| fingerprint | TEXT | 当前内容指纹；页与命中绑定此值，不匹配即旧引用 |
| file_size / mtime | INTEGER / REAL | 快速变更检测辅助 |
| page_count | INTEGER | 物理页总数（含无文本页，如扫描页） |
| status | TEXT | `ok` \| `error` |
| error | TEXT NULL | 最近一次索引失败的描述 |
| indexed_at | REAL | Unix 秒 |
| ocr_status / ocr_error / ocr_driver_id | TEXT | **V11**：双引擎 OCR 状态机列 |
| content_category | TEXT NOT NULL DEFAULT '' | **V12**：目录分类标签 |

## pages（`fulltext.db` / legacy `index.db`）
| 列 | 类型 | 说明 |
|---|---|---|
| book_id | TEXT | 关联书目 ID（分离后在 `ft` 侧去外键，删书显式先删 `pages` 再删 `books`） |
| page_number | INTEGER | **物理页，1-based**；PK(book_id, page_number) |
| label | TEXT NULL | 原件页标签；**NULL = 未知**（仅 PDF 声明 `/PageLabels` 时非空） |
| printed_page | INTEGER NULL | 印刷页码；默认 NULL（未知，不猜），仅由页码映射导入写入 |
| text_original | TEXT | 原文，逐字保留（展示用） |
| text_norm | TEXT | 搜索归一化副本（NFKC + 小写 + 去零宽/软连字符 + 空白折叠） |
| norm_starts / norm_ends | BLOB | little-endian Int32 数组：归一化文本每个输出字符 → 原文 UTF-16 `[start, end)` 偏移 |
| source | TEXT NOT NULL DEFAULT 'native' | **V3**：`native` \| `ocr` |
| text_latin | TEXT NOT NULL DEFAULT '' | **V10**：拉丁词投影（`LatinProjection.transform(text_norm)`，仅保留 `[a-z0-9]+` 极大串）；`pages_wfts` 的 external content 真源列 |

## pages_fts 与辅助检索表（`fulltext.db`）
- **`pages_fts`（`fts5(text_bigram, tokenize='unicode61', detail='none')`）**：存放归一化文本的 2-gram 投影，加速 CJK 与短子串检索（`<2` 字符走 `LIKE` 扫描）。`expectedFTSTokenizerVersion = 2`。
- **`bigram_index`（`bigram TEXT PRIMARY KEY, rowids BLOB` WITHOUT ROWID）**：大端 UInt32 rowid 压缩倒排表，为热词提供毫秒级候选集求交。
- **`book_native_counts`（`book_id TEXT PRIMARY KEY, native_count INTEGER` WITHOUT ROWID）**：书级原生页数影子缓存，用于版本组代表书快速选择。
- **`idx_pages_stats`（V14 门控覆写索引）**：覆盖 `(book_id, CASE WHEN TRIM(text_norm)='' THEN 0 ELSE 1 END)`，在 `Options.allowPageStatsStatsIndex`（如 CLI `search`）下按需建立。

## pages_wfts（V10 词级索引，`fulltext.db`）
```sql
CREATE VIRTUAL TABLE IF NOT EXISTS ft.pages_wfts USING fts5(
    text_latin,                -- 列名与 pages.text_latin 一致（external content 约束）
    content='pages',
    content_rowid='rowid',
    tokenize='unicode61'       -- detail 默认 full
);
```
同步触发器：`pages_wfts_ai` / `_ad` / `_au`（`UPDATE` 带 `WHEN old.text_latin IS NOT new.text_latin` 守卫）。`meta` 键：`wfts_ready`、`wfts_backfill_rowid`、`wfts_backfill_heartbeat`、`wfts_built_at`、`wfts_dirty`、`wfts_probe_ok_v1`。支持 CLI `backfill-latin --db <path>` 断点续跑回填。

## 用户数据与声明表（`index.db`，全无级联删书外键）
- **`user_highlights`**（V5 + 加密/软删/视图来源升级）：高亮与下划线、可选加密备注 `BLOB`、软删墓碑 `deleted_at`、`row_uuid`、`view_source`。
- **`favorites`**（V5）：整书 / 单页 / 引文 / 搜索 / 智能检索收藏（`target_json`、`category`、`tags`）。
- **`daily_quotes`**：每日摘录缓存池与当日选句。
- **`ocr_books` / `ocr_pages`**（V3）：显式清单登记的 OCR 伴侣文件与双侧 SHA-256 指纹映射。
- **`page_map`**（V6）：CSV 导入的 `physical_page -> printed_page` 与 `source_edition` 声明映射。
- **`index_queue` / `index_pending`**（V7 & V13）：版本化可续后台队列（五态：`unavailable`、`unindexed`、`partial`、`indexed`、`queued`）及文件监听防抖落盘队列。
- **`classification_rules` / `book_classifications`**（V8）：用户定义分类规则（`any` / `exact` / `prefix_dir`）与匹配结果。
- **`reading_sessions` / `page_footprints`**（V9）：按书按日的阅读时长与页级足迹。

## 共享面（App Group，`shared-state.json`）
```jsonc
{ "history":  [ { "query": String, "at": Date(secondsSince1970), "hitCount": Int } ],  // ≤20，去重置顶
  "coverage": { "bookCount": Int, "pageCount": Int, "lastIndexedAt": Date?, "rootName": String? } }
```
类型上不含任何原文字段（`snippet`/`text`）；Widget 唯一可读面。
