# 元数据在线补全

镜：JabRef 保守合并 + Zotero 源注册表 + calibre 标识符优先。实现：
`Sources/LiteratureCore/MetadataFetchService.swift`（单文件，零第三方依赖，
网络面仅 URLSession）。

## 一、隐私契约（代码注释与本文双写，违反即不合格）

- 请求只含标识符（DOI 或 arXiv ID）或标题、作者。缺少标题时，查询会使用规范化后的文件名；
- 书库**路径、指纹、批注、命中计数、任何其他库内容一律不出机**；
- **不上传文件本体**；
- UA 固定串 `LiteratureSearch/7.4`，只含应用名与版本，无任何本机标识；
- 请求域白名单仅五个注册域：
  `api.crossref.org`、`export.arxiv.org`、`dblp.org`、
  `api.semanticscholar.org`、`openlibrary.org`（单元测试逐条锁定以上全部）。
- 粘贴的 DOI / arXiv ID 只作查询输入，不持久化入库。

**被源站限流的风险**照 JabRef 官方文档原话如实告知：其在线检索页明言
「JabRef is not intended to be a tool for mass download of citations…If you
use the search functionality too extensively you might get blocked」。该链路
一次手动触发每源至多一次、无自动重试，即为此约束的设计化落实。

## 二、链序（一次手动触发总请求 ≤ 5，零自动重试，超时 15s/请求）

| 级 | 条件 | 源 | 端点 |
|---|---|---|---|
| ① | 有 DOI（详情页粘贴） | Crossref | `GET https://api.crossref.org/works/<doi>` |
| ② | 否则有 arXiv ID（详情页粘贴） | arXiv API | `GET https://export.arxiv.org/api/query?id_list=<id>`；回得 DOI 时**同一次点击内**续查 Crossref 一次 |
| ③ | 仍缺 → 标题+作者 | DBLP | `GET https://dblp.org/search/publ/api?q=…&format=json` |
| ④ | 再查 | Semantic Scholar | `GET https://api.semanticscholar.org/graph/v1/paper/search?query=…` |
| ⑤ | 再查（链尾） | Open Library | `GET https://openlibrary.org/search.json?title=…&author=…&limit=1&fields=…`（公开免钥） |

任一级查得即按上序补一级；失败/超时/坏 JSON **静默降级下一级**；单源故障
只降级该源（适配器契约 lookup 不抛＋调用侧隔离双保险）；全链失败出报告
（不弹错，详情页状态行显示补全结果）。

**站点适配器契约**：`Sources/LiteratureCore/MetadataSiteAdapter.swift`
——protocol（`sourceID` 审计标签／`host` 域白名单登记／`lookup` 吞错返 nil）
＋统一条目契约（复用 `FetchedMetadata`，不造第二套）。示范实现：arXiv（薄
封装既有解析，零复制）＋Open Library（新源，⑤ 位）。crossref/arxiv/dblp/ss
既有内联实现保持不动，迁移列后续批候选。

**文件名规范化反查降级处理**：title 缺失时 ③④⑤ 模糊查询串改用
`FileNameNormalization.normalizedTitleGuess(from:)`（去扩展名／`_` `.` `-`
归空格／去方括号段／压缩空白；空或纯数字不猜）——outcome note 如实记
「查询串来自文件名规范化」，不冒充用户输入。

## 三、回填语义（JabRef 式保守合并）

- 读现状行，**只填 nil 字段**，绝不覆盖既有值（服务层过滤 +
  `updateMetadata` 的 COALESCE 双保险）；
- 经既有 `IndexStore.updateMetadata(..., source: "fetch:<源名>")` 写入，
  source 审计标签延续「确定性来源可溯」纪律；
- 回填报告（每书：各源结果/补到字段/跳过原因）显示于详情页，并落
  `Application Support/LiteratureSearch/fetch-report.json`（原子写，环形
  保留最近 10 次）。

## 四、触发面（手动唯一）

- 设置页 → 引注与 OCR → 「元数据在线补全」：总开关（**默认关**，
  UserDefaults `metadataFetchEnabled`）+ 逐源五开关（**默认关**，
  `metadataFetchSource.<源名>`；开关由 `MetadataSource.allCases` 驱动，
）；总开关关 → 逐源开关禁用 +
  详情页按钮禁用 + 说明文案。
- 详情页「在线补全元数据」按钮：粘贴 DOI / arXiv ID（可选）→ 点击触发。
- **无导入自动触发、无定时、无后台**（本次约束：不建常驻进程、不轮询）。

## 五、测试与安全审

- `MetadataFetchTests`（RunnerMain 登记）9 例全桩注入、零真实网络：链序
  断言、只填 nil、总/逐源开关零请求、超时与坏 JSON 降级、报告环形 10、
  请求 URL/UA 隐私契约断言（域白名单/UA 串/不含路径与指纹）。
- 全新网络面，安全审查须覆盖请求域、UA、日志与错误路径。

## 六、预期管理（如实）

中文法学书在 DBLP / Semantic Scholar 命中率低属预期——两库以计算机与理
科文献为主；该链路的主要受益者是论文域（DOI 常见）。图书（尤其中文 scanned
书）大概率落到「全链零命中、无字段补全」，此时报告照实显示，不做任何猜测
性回填。未来可挂本地 PDF 抽取（grobid 思路，抽取在本地、上传仍只有查询
串）——架构已留 `MetadataHTTPLoading` 同级的源扩展位，当前不实施。
