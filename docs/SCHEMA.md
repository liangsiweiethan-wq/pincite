# 数据 Schema

索引文件：`index.db`（SQLite，WAL，foreign_keys=ON）。schema_version 记录于 meta。

## meta
| 列 | 类型 | 说明 |
|---|---|---|
| key | TEXT PK | |
| value | TEXT | `schema_version`=1；`search_mode`=`fts5-trigram`\|`like-fallback`（创建时决定，粘性）；`sqlite_version` |

## books
| 列 | 类型 | 说明 |
|---|---|---|
| id | TEXT PK | `b` + 初始内容 SHA-256 前 20 hex（内容寻址；内容更新保持不变） |
| real_path | TEXT UNIQUE | 解析符号链接后的规范路径 |
| root_path | TEXT | 本次索引根（解析后），用于删除清理的归属判定 |
| rel_path / file_name | TEXT | 相对路径 / 文件名 |
| title / author / version | TEXT NULL | **NULL = 未知**（永不从文件名猜元数据） |
| first_fingerprint | TEXT | 首次索引内容指纹（ID 来源） |
| fingerprint | TEXT | 当前内容指纹；页与命中绑定此值，不匹配即旧引用 |
| file_size / mtime | INTEGER / REAL | 快速变更检测辅助 |
| page_count | INTEGER | 物理页总数（含无文本页，如扫描页） |
| status | TEXT | `ok` \| `error` |
| error | TEXT NULL | 最近一次索引失败的描述 |
| indexed_at | REAL | Unix 秒 |

## pages
| 列 | 类型 | 说明 |
|---|---|---|
| book_id | TEXT FK→books ON DELETE CASCADE | |
| page_number | INTEGER | **物理页，1-based**；PK(book_id, page_number) |
| label | TEXT NULL | 原件页标签；**NULL = 未知**（仅 PDF 声明 /PageLabels 时非空） |
| printed_page | TEXT NULL→INTEGER | 印刷页码；默认 NULL（未知，不猜），仅由页码映射导入写入 |
| text_original | TEXT | 原文，逐字保留（展示用） |
| text_norm | TEXT | 搜索归一化副本（NFKC+小写+去零宽/软连字符+空白折叠） |
| norm_starts / norm_ends | BLOB | little-endian Int32 数组：归一化文本每个输出字符 → 原文 UTF-16 [start,end) 偏移 |
| text_latin | TEXT NOT NULL DEFAULT '' | **schema v10**：拉丁词投影（LatinProjection.transform(text_norm)，仅保留 `[a-z0-9]+` 极大串）。存量行回填前为 ''；pages_wfts 的 external content 真源列 |

## pages_fts（search_mode=fts5-trigram 时）
```sql
CREATE VIRTUAL TABLE pages_fts USING fts5(
    text_norm,                 -- 列名必须与 pages.text_norm 一致（external content 约束）
    content='pages',
    content_rowid='rowid',
    tokenize='trigram'
);
```
插入：`INSERT INTO pages_fts(rowid, text_norm) VALUES(?, ?)`；删除/替换：先 `DELETE FROM pages_fts WHERE rowid IN (SELECT rowid FROM pages WHERE book_id=?)` 再动 pages。查询：`WHERE pages_fts MATCH ?`（词被 `"` 引号字面包裹；<3 字符词走 LIKE 回退：`text_norm LIKE '%'||escaped||'%' ESCAPE '\'`）。

## pages_wfts（schema v10 词级索引）
```sql
CREATE VIRTUAL TABLE pages_wfts USING fts5(
    text_latin,                -- 列名必须与 pages.text_latin 一致（external content 约束）
    content='pages',
    content_rowid='rowid',
    tokenize='unicode61'       -- detail 默认 full（external content + detail=none 删除不可用的既有教训）
);
```
同步：三个触发器 `pages_wfts_ai/_ad/_au`（AFTER INSERT/DELETE/UPDATE ON pages；UPDATE 带 `WHEN old.text_latin IS NOT new.text_latin` 守卫）——应用层五写点只维护 text_latin 列，FTS 增删由触发器代做；绕过应用层的裸 SQL 写 pages 亦自动同步。删除时，'delete' 读取 old.text_latin，与插入值保持逐字节一致。recursive_triggers=OFF 时，FK 级联删除不会触发子表触发器，因此删书先显式 DELETE FROM pages，再删 books。meta 键：`wfts_ready`（回填完成=1；0=查询降级旧路）、`wfts_backfill_rowid`（断点）、`wfts_backfill_heartbeat`（在飞心跳）、`wfts_built_at`、`wfts_dirty`（自愈失败=1）、`wfts_probe_ok_v1`。回填：CLI `backfill-latin --db <path>`（20000 行/批，可断点续跑）。维护：回填完成后与大批删书后各 `'optimize'` 一次；ready=1 且索引空而 pages 有非空投影 → `'rebuild'` 自愈。

## 共享面（AppGroup，shared-state.json）
```jsonc
{ "history":  [ { "query": String, "at": Date(secondsSince1970), "hitCount": Int } ],  // ≤20，去重置顶
  "coverage": { "bookCount": Int, "pageCount": Int, "lastIndexedAt": Date?, "rootName": String? } }
```
类型上不含任何原文字段（snippet/text）；widget 唯一可读面。

## 排除配置（`<db目录>/exclusions.json`，可选）
```jsonc
{ "excludedPathSubstrings": [...], "excludedGlobs": ["drafts/*"], "excludedBookIDs": [...] }
```
排除规则由用户配置。路径规则同时检查符号链接路径和解析后的目标路径，解析后越出书库根目录的文件会被拒绝。

## user_highlights
用户划线高亮。utf16_start/utf16_end 为页文本 UTF-16 [start,end) 偏移；book_id 为 TEXT，**无外键**——用户数据须 survive 书目重建。created_at 为 Unix 秒（REAL）。
| 列 | 类型 | 说明 |
|---|---|---|
| id | INTEGER PK AUTOINCREMENT | |
| book_id | TEXT NOT NULL | 稳定的书 ID，内容相同的副本使用不同 ID |
| page_number | INTEGER NOT NULL | 物理页，1-based |
| utf16_start / utf16_end | INTEGER NOT NULL | UTF-16 偏移，`0 <= start < end <= 1_000_000` |
| color | TEXT NOT NULL | `yellow` \| `green` \| `blue` \| `red` |
| note | TEXT NOT NULL DEFAULT '' | 用户备注 |
| created_at | REAL NOT NULL | Unix 秒 |

索引：`idx_user_highlights_book(book_id, page_number)`。

## favorites
用户收藏：整书 / 单页 / 引文 / 搜索。target_json 为按 `kind` 键控的 JSON 载荷（kind 专属字段：book=bookID/fileName/title?；page=bookID/fileName/pageNumber/snippet/utf16Start?/utf16End?；quote=bookID/fileName/pageNumber/sentence；search=query）。tags 以逗号连接存入 TEXT。无外键——survive 书目重建。
| 列 | 类型 | 说明 |
|---|---|---|
| id | INTEGER PK AUTOINCREMENT | |
| kind | TEXT NOT NULL | `book` \| `page` \| `quote` \| `search` |
| target_json | TEXT NOT NULL | 载荷 JSON |
| category | TEXT NOT NULL DEFAULT '' | 分类 |
| tags | TEXT NOT NULL DEFAULT '' | 逗号分隔 |
| created_at | REAL NOT NULL | Unix 秒；`all()` 按 created_at 升序（创建顺序） |

索引：`idx_favorites_kind(kind)`、`idx_favorites_category(category)`。

> schema_version 现为 **10**（v9 → v10 新增 pages.text_latin 列、pages_wfts 虚表与三触发器；对旧库幂等迁移，原文内容不变。v6 之后各版（page_map、index_queue、classification_rules、book_classifications、reading_sessions、page_footprints）详见对应源代码注释与迁移函数）。
