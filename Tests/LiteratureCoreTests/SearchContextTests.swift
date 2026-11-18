import Foundation
@testable import LiteratureCore
import LiteratureSearchUI

// MARK: - 父子块上下文扩展＋高亮组装纯函数测试
// （合成库三页书：中页前后齐、首页无 prev、末页无 next、无 auto_toc
// 如实 nil；高亮组装多 match 合并、越界边界、OCR 契约、窗口一致性）

enum SearchContextSuite {
    static func makeThreePageStore() throws -> IndexStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lit-ctx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try IndexStore(path: dir.appendingPathComponent("index.db"))
        let book = IndexStore.BookRow(
            id: "bCtx", realPath: "/tmp/lit-tests/ctx.pdf", rootPath: "/tmp/lit-tests",
            relPath: "ctx.pdf", fileName: "ctx.pdf",
            title: nil, author: nil, version: nil, language: nil, metaSource: nil,
            firstFingerprint: "fp-ctx", fingerprint: "fp-ctx", fileSize: 1, mtime: 0,
            pageCount: 3, status: "ok", indexedAt: 0)
        try store.upsertBook(book)
        let texts = [
            "第一章 关键词出现在这里。",
            "第二页 关键词再次出现。第二页正文。",
            "第二章 无关键词的收尾页。",
        ]
        var rows: [IndexStore.PageRow] = []
        for (i, text) in texts.enumerated() {
            let n = normalizeForSearch(text)
            rows.append(IndexStore.PageRow(bookID: "bCtx", pageNumber: i + 1, textOriginal: text,
                                           textNorm: n.text, normStarts: n.starts, normEnds: n.ends))
        }
        try store.replacePages(bookID: "bCtx", rows)
        return store
    }

    static var tests: [TestDesc] {
        [
            // 中页：prev/page/next 齐。
            TestDesc(suite: "SearchContext", name: "middlePageHasBothNeighbors") {
                let store = try makeThreePageStore()
                let service = SearchService(store: store)
                let ctx = try expectNotNil(try service.contextExpansion(bookID: "bCtx", page: 2))
                try expectEqual(ctx.page.pageNumber, 2)
                try expectEqual(ctx.prevPage?.pageNumber, 1)
                try expectEqual(ctx.nextPage?.pageNumber, 3)
                try expectTrue(ctx.prevPage?.text.contains("第一章") == true)
                try expectTrue(ctx.page.text.contains("第二页") == true)
                try expectTrue(ctx.nextPage?.text.contains("第二章") == true)
                // auto_toc 未建：sectionLabel nil 不猜。
                try expectNil(ctx.sectionLabel)
                try expectNil(ctx.sectionLevel)
            },

            TestDesc(suite: "SearchContext", name: "firstPageHasNoPrevLastPageHasNoNext") {
                let store = try makeThreePageStore()
                let service = SearchService(store: store)
                let first = try expectNotNil(try service.contextExpansion(bookID: "bCtx", page: 1))
                try expectNil(first.prevPage)
                try expectEqual(first.nextPage?.pageNumber, 2)
                let last = try expectNotNil(try service.contextExpansion(bookID: "bCtx", page: 3))
                try expectEqual(last.prevPage?.pageNumber, 2)
                try expectNil(last.nextPage)
            },

            TestDesc(suite: "SearchContext", name: "autoTOCSectionLabelWhenPresentAndNilWhenAbsent") {
                let store = try makeThreePageStore()
                let service = SearchService(store: store)
                // 无 auto_toc → nil（如实）。
                let bare = try expectNotNil(try service.contextExpansion(bookID: "bCtx", page: 2))
                try expectNil(bare.sectionLabel)
                _ = try store.rebuildAutoTOCIfNeeded(bookID: "bCtx")
                let withTOC = try expectNotNil(try service.contextExpansion(bookID: "bCtx", page: 2))
                try expectTrue(withTOC.sectionLabel?.hasPrefix("第一章") == true)   // page≤2 的最后一个
                try expectEqual(withTOC.sectionLevel, 1)
                let p3 = try expectNotNil(try service.contextExpansion(bookID: "bCtx", page: 3))
                try expectTrue(p3.sectionLabel?.hasPrefix("第二章") == true)
            },

            TestDesc(suite: "SearchContext", name: "unknownBookOrPageReturnsNil") {
                let store = try makeThreePageStore()
                let service = SearchService(store: store)
                try expectNil(try service.contextExpansion(bookID: "bNope", page: 1))
                try expectNil(try service.contextExpansion(bookID: "bCtx", page: 99))
                try expectNil(try service.contextExpansion(bookID: "bCtx", page: 0))
            },

            // ── 高亮组装纯函数 ──

            TestDesc(suite: "SearchContext", name: "highlightAssemblyMergesAndOffsetsRanges") {
                let full = "甲乙丙丁戊己庚辛壬癸"
                // 两个 range（0..<2 与 4..<6），间隔段如实切分。
                let r = SnippetHighlighter.assemble(fullText: full, ranges: [0..<2, 4..<6], context: 40)
                try expectTrue(r.highlighted)
                try expectEqual(r.text, full)
                let kinds = r.segments.map(\.isHighlighted)
                try expectEqual(kinds, [true, false, true, false])
                try expectEqual(r.segments[0].text, "甲乙")
                try expectEqual(r.segments[1].text, "丙丁")
                try expectEqual(r.segments[2].text, "戊己")
                try expectEqual(r.segments[3].text, "庚辛壬癸")
            },

            TestDesc(suite: "SearchContext", name: "highlightAssemblyOverlappingRangesMerge") {
                let full = "重叠区间合并"
                let r = SnippetHighlighter.assemble(fullText: full, ranges: [0..<2, 1..<4], context: 40)
                let highlightedSegments = r.segments.filter(\.isHighlighted)
                try expectEqual(highlightedSegments.count, 1)
                try expectEqual(highlightedSegments.first?.text, "重叠区间")
            },

            TestDesc(suite: "SearchContext", name: "highlightAssemblyOutOfBoundDegradesHonestly") {
                // range 全越界：highlighted=false（降级纯文本，不猜）。
                let r1 = SnippetHighlighter.assemble(fullText: "短文本", ranges: [50..<60])
                try expectFalse(r1.highlighted)
                // 空串：窗口 nil → 空。
                let r2 = SnippetHighlighter.assemble(fullText: "", ranges: [0..<1])
                try expectFalse(r2.highlighted)
                try expectEqual(r2.text, "")
                // 部分越界：窗口内部分保留（裁剪语义）。
                let r3 = SnippetHighlighter.assemble(fullText: "前后裁剪测试文本", ranges: [0..<2, 6..<100], context: 40)
                try expectTrue(r3.highlighted)
                try expectTrue(r3.segments.contains { $0.isHighlighted && $0.text == "前后" })
            },

            TestDesc(suite: "SearchContext", name: "assemblyTextEqualsCoreSnippetByteForByte") {
                let full = "这是一段用于窗口一致性自证的文本，关键词落在中段位置附近，用于验证省略号与前窗口裁剪。"
                let ranges: [Range<Int>] = [10..<13, 25..<28]
                try expectTrue(SnippetHighlighter.matchesCoreSnippet(fullText: full, ranges: ranges),
                               "assembled text must equal SearchService.snippet byte for byte")
                // 窗口截断场景同样一致。
                let long = String(repeating: "前缀字", count: 60) + "关键词" + String(repeating: "后缀字", count: 60)
                try expectTrue(SnippetHighlighter.matchesCoreSnippet(
                    fullText: long, ranges: [long.utf16.count - 70..<long.utf16.count - 67]))
            },

            // OCR 契约：组装只对给定文本生效（range 属来源页文本）。
            TestDesc(suite: "SearchContext", name: "highlightCoordinatesBelongToSourcePageTextOnly") {
                let ocrPageText = "OCR 页自己的文本 关键词在此。"
                let r = SnippetHighlighter.assemble(fullText: ocrPageText, ranges: [11..<14])
                try expectTrue(r.highlighted)
                try expectEqual(r.segments.filter(\.isHighlighted).first?.text, "关键词")
                // 组装不触碰任何文件（纯字符串函数——签名即契约）。
            },
        ]
    }
}
