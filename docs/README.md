# 文档 / Documentation

Most technical notes in `docs/` are written in Chinese; the Swift source and CLI `--help` are the authority whenever prose and behaviour disagree.

> These documents record the main design trade-offs of **PinCite** (internal Swift module namespace `Literature*`): architecture, two-database index schema, the physical/label/printed page model, citation styles, the loopback API, deep links, note sovereignty, and online metadata fetching.

| 文档 / Document | 内容 / Summary |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | 模块划分、索引与检索数据流、页码三基准、测试结构 |
| [SCHEMA.md](SCHEMA.md) | `index.db` + `fulltext.db` 两库分离、Schema v13（迁移 V1–V14）、FTS5 与用户数据表 |
| [PAGE-BASIS.md](PAGE-BASIS.md) | 物理页 / 页标签 / 印刷页的语义与 CSV 页码导入规则 |
| [CITATION-SCENARIOS.md](CITATION-SCENARIOS.md) | 21 种引注体例、场景映射与页码取值序 |
| [LOCAL-API.md](LOCAL-API.md) | 环回只读 HTTP API 的鉴权、端点与网络边界 |
| [URI-SCHEME.md](URI-SCHEME.md) | `literaturesearch://` 深链动词规格 |
| [NOTE-SOVEREIGNTY.md](NOTE-SOVEREIGNTY.md) | 原件只读、笔记自有库、导出副本三原则 |
| [METADATA-FETCH.md](METADATA-FETCH.md) | 在线元数据补全的来源白名单、隐私契约与保守合并 |
| [VISUAL-DESIGN.md](VISUAL-DESIGN.md) | 视觉系统：色彩、字体、布局、动效与组件 |
| [LAUNCH-KIT.md](LAUNCH-KIT.md) | 开源宣发英文/中文文案包（GitHub Release / Show HN / Reddit / V2EX / 知乎） |
