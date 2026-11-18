# 批注主权

> 与代码同源：`Sources/LiteratureCore/PDFBurnExport.swift` 文件头注释是代码侧说明。

## 三句架构

1. **原书 = 原文献（原件 PDF），永不写入。**
   全平台全链路对原件只读打开（`PDFDocument(url:)`）；`write(to:)` 只落导出副本路径。阅读器渲染、检索、批注编辑均不触碰原件字节。

2. **笔记唯一真源 = 自有库。**
   批注/高亮/下划线 = `user_highlights`（macOS 索引库同库；iOS 容器内独立 `annotations.db`，同 schema）；笔迹 = `ink_strokes`（append-only + 墓碑，`InkStrokesStore.swift`）；位置、标记、会话各归自有表。自有库可整库导出与重建（AnnotationBundle）。

3. **导出 = 副本（出口，不是存储）。**
   烧录导出（`PDFBurnExporter.export`）是显式动作产生的 `-annotated` 副本：原件只读打开 → 自有库读齐四类（高亮/下划线/批注文本/ink）→ PDFKit 原生注记烧录 → 写副本 → 重开校验。导出件不回流索引 root 扫描（重名避让 + `-annotated` 后缀命名；导出目录需排除）。

## 三道防线

| 风险 | 防线 | 落点 |
|---|---|---|
| 内链失效/写坏文件 | 写后 `PDFDocument(url:)` 重开：页数一致 + 抽查页文本非空 | `export()` 验证段 + `burnExportRoundtrip*` 用例 |
| symlink 覆盖 | 目标是 symlink / 路径解析后与字面不一致 / 解析指向原件 → fail-closed 拒写；目标已存在拒导（绝不覆盖）；`exportDestination` 提供 -2/-3 重名避让 | `validateDestinationSymlinks` + `burnExportRefusesOverwriteAndSymlink` |
| 原件被改动 | 导出前记录原件 SHA-256 fingerprint，导出后复核不变 | `export()` 首尾 fingerprint 对 + 用例断言前后一致 |

## 瞬态层

检索命中与 Smart Jump 引文下划线是**阅读器会话内存态**（`PDFDetailView` 页面对象临时注解，带 `litsearch.kind` 标记），不随文档写出、不入批注库、**结构性不入烧录导出**（导出文档由原件新开，四类内容只从自有库读取；重开注释层逐型计数断言见用例）。

## 边界

- macOS 侧 ink 库尚未装配（笔迹现产在 iPad 容器库）：桌面烧录导出当前实导高亮/下划线/批注文本三类。ink 管线已备（`BurnExportSource.inkStrokes` 注入口 + 四类齐全单测在 Core），ink 数据随同步贯通后即生效。
- `PDFAnnotation.add` 的路径类型存在平台分叉（macOS = NSBezierPath / iOS = UIBezierPath），代码以条件编译白名单处理（`PDFBurnExport.swift`，`iOSCompileGateTests` 白名单注记）。
