import Foundation
import PDFKit
@testable import LiteratureCore


enum BurnExportFrontMatterDailySuite {

    // MARK: 桩件

    static func tmpResidueCount(in dir: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix(".tmp-burn-") }.count ?? -1
    }

    static var tests: [TestDesc] {
        [
            // ── 前置页屏蔽 ──

            TestDesc(suite: "BurnFMDaily", name: "frontMatterBoundaryPageVisibleAndDefaultOff") {
                try expectTrue(FrontMatterFilter.isVisible(page: 15, bodyStartPage: 15),
                               "边界页 = body_start 本身不屏蔽")
                try expectFalse(FrontMatterFilter.isVisible(page: 14, bodyStartPage: 15))
                try expectTrue(FrontMatterFilter.isVisible(page: 16, bodyStartPage: 15))
                // 默认关语义：未设置（nil）/坏值 → 全可见（现状零漂移）。
                try expectTrue(FrontMatterFilter.isVisible(page: 1, bodyStartPage: nil))
                try expectTrue(FrontMatterFilter.isVisible(page: 1, bodyStartPage: 0),
                               "越界 body_start 视为未设置（fail-closed 反向：屏蔽是 opt-in）")
            },

            TestDesc(suite: "BurnFMDaily", name: "partitionCountsBlockedExactly") {
                struct Hit { var page: Int }
                let hits = [Hit(page: 2), Hit(page: 3), Hit(page: 15), Hit(page: 16)]
                let (visible, blocked) = FrontMatterFilter.partition(hits, page: { $0.page },
                                                                     bodyStartPage: 15)
                try expectEqual(visible.map(\.page), [15, 16])
                try expectEqual(blocked.count, 2, "被屏蔽计数 = 2（frontMatterBlockedCount 数据源）")
                let allVisible = FrontMatterFilter.partition(hits, page: { $0.page }, bodyStartPage: nil)
                try expectEqual(allVisible.visible.count, 4, "关闭态零过滤")
                try expectTrue(allVisible.blocked.isEmpty)
            },

            TestDesc(suite: "BurnFMDaily", name: "bodyStartMetaRoundtripAndClear") {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("fm-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let store = try IndexStore(path: dir.appendingPathComponent("index.db"))
                try expectNil(FrontMatterFilter.readBodyStartPage(store: store, bookID: "b1"),
                              "未设置 = nil（默认关）")
                try FrontMatterFilter.writeBodyStartPage(15, store: store, bookID: "b1")
                try expectEqual(FrontMatterFilter.readBodyStartPage(store: store, bookID: "b1"), 15)
                try FrontMatterFilter.writeBodyStartPage(nil, store: store, bookID: "b1")
                try expectNil(FrontMatterFilter.readBodyStartPage(store: store, bookID: "b1"),
                              "清除 = 空串读 nil")
                try expectThrows(try FrontMatterFilter.writeBodyStartPage(0, store: store, bookID: "b1"),
                                 "非法值 fail-closed 拒写")
                // 坏值（非整数）读 nil 不抛。
                try store.setMetaValue(FrontMatterFilter.metaKey("b2"), "abc")
                try expectNil(FrontMatterFilter.readBodyStartPage(store: store, bookID: "b2"))
            },

            TestDesc(suite: "BurnFMDaily", name: "bodyStartDetectorThreeSignals") {
                // 印刷页码从 1 重启（有目录佐证）→ 直接采用该页。
                var pages = [String](repeating: "目录 …… 3\n第四章 …… 88\n第五章 …… 120", count: 5)
                pages.append("第一章 权威\n正文开始")            // 物理页 6
                pages.append("第一节\n内容\n1")                  // 页尾 1
                pages.append("内容\n2")
                pages.append("内容\n7")                          // 此前 >1 出现
                let d = BodyStartDetector.detect(pageTexts: pages)
                try expectEqual(d.bodyStartPage, 7, "印刷页码 1 重启于物理页 7（重启信号最强）")
                // 版权页（ISBN）回退：后首个非目录页。
                var book2 = [String](repeating: "目录 …… 2", count: 3)   // 物理页 1-3 目录
                book2.append("ISBN 978-7-5366-9820-1\n某某出版社")        // 物理页 4 版权页
                book2.append("目录 …… 5\n附录 …… 9\n索引 …… 11")          // 物理页 5 仍是目录（3 行点线）
                book2.append("第一章\n正文")                               // 物理页 6 → 候选
                let d2 = BodyStartDetector.detect(pageTexts: book2)
                try expectEqual(d2.bodyStartPage, 6, "版权页 4 → 跳过目录 5 → 候选 6")
                // 无信号 → nil（不猜）。
                let plain = [String](repeating: "普通正文无特征", count: 12)
                try expectNil(BodyStartDetector.detect(pageTexts: plain).bodyStartPage)
                // 空数组/零限不得 fatal（首落版
                // `1...max(limit, 0)` 对空输入构空区间越界——回归断言固定）。
                let empty = BodyStartDetector.detect(pageTexts: [])
                try expectNil(empty.bodyStartPage)
                try expectTrue(empty.signals.contains("输入为空（无页可扫）"),
                               "空输入如实留痕不静默")
                try expectNil(BodyStartDetector.detect(pageTexts: ["有页"], scanLimit: 0).bodyStartPage,
                              "scanLimit=0 同走早退")
            },






            TestDesc(suite: "BurnFMDaily", name: "burnExportRoundtripFourKindsAndOriginalUntouched") {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("burn-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let original = dir.appendingPathComponent("sample.pdf")
                try SyntheticPDFMaker.write(pages: [
                    .init(lines: ["The Fictional Order and sample authority", "第二章 权威与理由"]),
                    .init(lines: ["second page body text here"]),
                ], to: original)
                let fpBefore = try Fingerprint.sha256Hex(ofFileAt: original)
                let destination = dir.appendingPathComponent("sample-annotated.pdf")
                let source = BurnExportSource(
                    highlights: [
                        .init(pageNumber: 1, utf16Start: 0, utf16End: 18, colorHex: "#FFDF3E",
                              style: "highlight", note: "关键句", anchorText: ""),
                        .init(pageNumber: 1, utf16Start: 0, utf16End: 999_999, colorHex: "#FFDF3E",
                              style: "highlight", note: "", anchorText: "权威与理由"),
                        .init(pageNumber: 99, utf16Start: 0, utf16End: 3, colorHex: "#FFDF3E",
                              style: "highlight", note: "", anchorText: "越界页跳过"),
                    ],
                    inkStrokes: [
                        InkStroke(strokeUUID: "ink-1", bookID: "b", pageNumber: 2, deviceID: "d",
                                  createdAt: 0, color: "#8EC9FF", lineWidth: 2,
                                  points: [InkPoint(x: 0.1, y: 0.1), InkPoint(x: 0.6, y: 0.4),
                                           InkPoint(x: 0.9, y: 0.2)]),
                    ])
                let report = try PDFBurnExporter.export(source: source, from: original,
                                                        to: destination,
                                                        fingerprint: { try Fingerprint.sha256Hex(ofFileAt: $0) })
                try expectEqual(report.highlightsApplied, 2, "显式区间 + 锚文本回退各 1")
                try expectEqual(report.highlightsSkipped, 1, "越界页跳过计数")
                try expectEqual(report.inkApplied, 1)
                try expectTrue(report.reopenedOK && report.pageCountConsistent,
                               "重开成功且页数一致")
                try expectTrue(report.samplePageTextNonEmpty, "抽查页文本非空")
                try expectEqual(try Fingerprint.sha256Hex(ofFileAt: original), fpBefore,
                               "原件 shasum 导出前后一致")
                // 重开注释层：只有自有库四类（hit 瞬态层结构性不在）。
                let reopened = try expectNotNil(PDFDocument(url: destination))
                let p1 = try expectNotNil(reopened.page(at: 0))
                // type 字符串 SDK 间有 "/Highlight" 与 "Highlight" 两形——宽容比对。
                let kinds = p1.annotations.map { ($0.type ?? "").lowercased() }
                try expectTrue(kinds.contains { $0.contains("highlight") },
                               "第 1 页应含高亮注记（实得：\(kinds)）")
                try expectFalse(kinds.contains { $0.contains("square") },
                                "hit/瞬态层不入导出（副本只含四类）")
                try expectTrue(p1.annotations.allSatisfy {
                    let c = $0.contents ?? ""
                    return c.isEmpty || c == "关键句"
                }, "批注文本只来自自有库 note（hit/瞬态层结构性不在）")
            },

            // ── 分诊接口位（阈值基准；默认导入链零调用）──

            TestDesc(suite: "BurnFMDaily", name: "ingestTriageFiveVerdictsAndThresholds") {
                try expectEqual(PDFIngestTriage.minCharsPerPage, 30, "阈值：MIN_CHARS_PER_PAGE=30")
                try expectEqual(PDFIngestTriage.pageHasText, 10, "阈值：PAGE_HAS_TEXT=10")
                // missing：计数空。
                try expectEqual(PDFIngestTriage.classify(charsPerPage: []).verdict,
                                PDFIngestTriage.Verdict.missing)
                // scanned：全部页 0 字。
                try expectEqual(PDFIngestTriage.classify(charsPerPage: [0, 0, 0]).verdict,
                                PDFIngestTriage.Verdict.scanned)
                // native_ok：全部页 ≥30（页间弱页记 page_review）。
                let ok = PDFIngestTriage.classify(charsPerPage: [30, 500, 12])
                try expectEqual(ok.verdict, PDFIngestTriage.Verdict.nativeOk)
                try expectEqual(ok.pageReview, [3], "native 档内 <30 的页记复核")
                // mixed：有页 ≥10 也有页 <10；page_review = 低于 10 的物理页。
                let mixed = PDFIngestTriage.classify(charsPerPage: [0, 9, 10, 200])
                try expectEqual(mixed.verdict, PDFIngestTriage.Verdict.mixed)
                try expectEqual(mixed.pageReview, [1, 2], "page_review = <PAGE_HAS_TEXT 的物理页")
                // unreadable：页在但全为 1..9 的微字符（有字无文本层语义边界）。
                // 0 字 = scanned；1-9 字全档 = mixed（无独立 unreadable
                // 判据——unreadable 由打开失败表达，见 IndexingEngine.triagePDF）。
                let unreadable = PDFIngestTriage.classify(charsPerPage: [0]).verdict
                try expectEqual(unreadable, PDFIngestTriage.Verdict.scanned)
                try expectEqual(PDFIngestTriage.Verdict(rawValue: "native_ok"),
                                PDFIngestTriage.Verdict.nativeOk, "rawValue 与分诊枚举一致")
            },

            TestDesc(suite: "BurnFMDaily", name: "ingestTriageMetaRoundtrip") {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("triage-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let store = try IndexStore(path: dir.appendingPathComponent("index.db"))
                try expectNil(PDFIngestTriage.load(store: store, bookID: "b1"), "未分诊 = nil 不猜")
                let outcome = PDFIngestTriage.classify(charsPerPage: [0, 9, 40, 120])
                try PDFIngestTriage.persist(outcome, store: store, bookID: "b1")
                let loaded = try expectNotNil(PDFIngestTriage.load(store: store, bookID: "b1"))
                try expectEqual(loaded.verdict, PDFIngestTriage.Verdict.mixed)
                try expectEqual(loaded.pageReview, [1, 2])
            },

            TestDesc(suite: "BurnFMDaily", name: "burnExportRefusesOverwriteAndSymlink") {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("burn2-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let original = dir.appendingPathComponent("book.pdf")
                try SyntheticPDFMaker.write(pages: [.init(lines: ["hello page"])], to: original)
                let source = BurnExportSource(highlights: [], inkStrokes: [])
                // 已存在 → 拒导。
                let existing = dir.appendingPathComponent("taken.pdf")
                try Data("x".utf8).write(to: existing)
                try expectThrows(try PDFBurnExporter.export(source: source, from: original,
                                                            to: existing,
                                                            fingerprint: { try Fingerprint.sha256Hex(ofFileAt: $0) }),
                                 "绝不覆盖既有文件")
                // symlink → 拒写（即使指向库内文件）。
                let victim = dir.appendingPathComponent("victim.pdf")
                try SyntheticPDFMaker.write(pages: [.init(lines: ["victim"])], to: victim)
                let link = dir.appendingPathComponent("evil.pdf")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)
                try expectThrows(try PDFBurnExporter.export(source: source, from: original,
                                                            to: link,
                                                            fingerprint: { try Fingerprint.sha256Hex(ofFileAt: $0) }),
                                 "symlink 目标 fail-closed")
                // symlink 指向原件本身 → 同样拒。
                let link2 = dir.appendingPathComponent("evil2.pdf")
                try FileManager.default.createSymbolicLink(at: link2, withDestinationURL: original)
                try expectThrows(try PDFBurnExporter.export(source: source, from: original,
                                                            to: link2,
                                                            fingerprint: { try Fingerprint.sha256Hex(ofFileAt: $0) }))
                // 正常命名避让助手：-annotated 冲突 → -2。
                let taken2 = dir.appendingPathComponent("book-annotated.pdf")
                try Data("x".utf8).write(to: taken2)
                let avoid = PDFBurnExporter.exportDestination(for: original, in: dir)
                try expectEqual(avoid.lastPathComponent, "book-annotated-2.pdf", "重名避让")
            },


            TestDesc(suite: "BurnFMDaily", name: "burnExportWriteFailureCleansUp") {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("burn4a-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let original = dir.appendingPathComponent("book.pdf")
                try SyntheticPDFMaker.write(pages: [.init(lines: ["hello page"])], to: original)
                let destination = dir.appendingPathComponent("book-annotated.pdf")
                let source = BurnExportSource(highlights: [], inkStrokes: [])
                struct WriteBoom: Error {}
                try expectThrows(
                    try PDFBurnExporter.export(source: source, from: original, to: destination,
                                               fingerprint: { try Fingerprint.sha256Hex(ofFileAt: $0) },
                                               writeTransform: { _, _ in throw WriteBoom() }),
                    "写中途失败必须抛错")
                try expectFalse(FileManager.default.fileExists(atPath: destination.path),
                                "目标位置不留半文件")
                try expectEqual(tmpResidueCount(in: dir), 0, "无 .tmp-burn-* 残留")
            },

            TestDesc(suite: "BurnFMDaily", name: "burnExportReplaceFailureCleansUp") {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("burn4b-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let original = dir.appendingPathComponent("book.pdf")
                try SyntheticPDFMaker.write(pages: [.init(lines: ["hello page"])], to: original)
                let destination = dir.appendingPathComponent("book-annotated.pdf")
                let source = BurnExportSource(highlights: [], inkStrokes: [])
                try expectThrows(
                    try PDFBurnExporter.export(source: source, from: original, to: destination,
                                               fingerprint: { try Fingerprint.sha256Hex(ofFileAt: $0) },
                                               writeTransform: { doc, tmp in
                                                   _ = doc.write(to: tmp)   // 写临时件成功
                                                   // 目标位置出现占位（前置检查之后、rename 之前）
                                                   try Data("occupied".utf8).write(to: destination)
                                               }),
                    "替换步失败必须抛错")
                // 目标位置的外来占位文件保持原样（export 无权删非自产文件——
                // fail-closed 不扩权）；本方临时件必须清场。
                let occupant = try Data(contentsOf: destination)
                try expectEqual(occupant, Data("occupied".utf8))
                try expectEqual(tmpResidueCount(in: dir), 0, "无 .tmp-burn-* 残留")
            },

            TestDesc(suite: "BurnFMDaily", name: "burnExportDefaultTransformUnchanged") {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("burn4c-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let original = dir.appendingPathComponent("book.pdf")
                try SyntheticPDFMaker.write(pages: [.init(lines: ["hello page"])], to: original)
                let destination = dir.appendingPathComponent("book-annotated.pdf")
                let report = try PDFBurnExporter.export(source: BurnExportSource(highlights: [], inkStrokes: []),
                                                        from: original, to: destination,
                                                        fingerprint: { try Fingerprint.sha256Hex(ofFileAt: $0) })
                try expectTrue(report.reopenedOK)
                try expectTrue(FileManager.default.fileExists(atPath: destination.path))
                try expectEqual(tmpResidueCount(in: dir), 0, "成功路径亦无临时件残留")
            },
        ]
    }

    static func SHA256_hex(_ data: Data) -> String {
        // 测试本地摘要（避免再引 CryptoKit import 到测试文件外泄依赖）。
        let digest = _SHA256(data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

import CryptoKit
func _SHA256(_ data: Data) -> SHA256.Digest { SHA256.hash(data: data) }
