import Foundation
@testable import LiteratureCore

// MARK: - 相似文档推荐测试（bigram 共现；两本相近书互进对方 top、
// 无关书落榜、空倒排降级、单词书边界）

enum SimilarBooksSuite {
    static func makeStore() throws -> IndexStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lit-sim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try IndexStore(path: dir.appendingPathComponent("index.db"))
    }

    /// 建书（文本直接入 pages；norm 自算）。
    static func addBook(_ store: IndexStore, id: String, name: String, pages: [String]) throws {
        let book = IndexStore.BookRow(
            id: id, realPath: "/tmp/lit-tests/\(name)", rootPath: "/tmp/lit-tests",
            relPath: name, fileName: name,
            title: name, author: nil, version: nil, language: nil, metaSource: nil,
            firstFingerprint: "fp-\(id)", fingerprint: "fp-\(id)", fileSize: 1, mtime: 0,
            pageCount: pages.count, status: "ok", indexedAt: 0)
        try store.upsertBook(book)
        var rows: [IndexStore.PageRow] = []
        for (i, text) in pages.enumerated() {
            let n = normalizeForSearch(text)
            rows.append(IndexStore.PageRow(bookID: id, pageNumber: i + 1, textOriginal: text,
                                           textNorm: n.text, normStarts: n.starts, normEnds: n.ends))
        }
        try store.replacePages(bookID: id, rows)
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "SimilarBooks", name: "twoSimilarBooksReachEachOthersTopAndOutsiderMisses") {
                let store = try makeStore()
                // 主题 A（示例学科×权利）：两本高度重叠。
                try addBook(store, id: "bLaw1", name: "law1.pdf", pages: [
                    "权利的概念 示例学科导论 法律体系 规范体系 义务结构 权利体系",
                    "法律规范的权利分析 义务本位 权利本位 示例学科说 规范冲突",
                    "权利救济 法律程序 规范等级 体系融贯 法理方法论",
                ])
                try addBook(store, id: "bLaw2", name: "law2.pdf", pages: [
                    "权利本位的示例学科 法律规范的义务分析 规范体系与权利体系",
                    "示例学科说中的权利概念 义务结构 法律程序 规范等级 权利救济",
                    "体系融贯与规范冲突 法理方法论 权利分析",
                ])
                // 主题 B（数学）：与 A 无共现。
                try addBook(store, id: "bMath", name: "math.pdf", pages: [
                    "素数分布 椭圆曲线 群论 环与域 模空间 上同调理论",
                    "线性代数 矩阵分解 特征值 奇异值 数值分析",
                ])
                // bigram 倒排表就绪（replacePages 后置脏，先重建）。
                _ = try store.rebuildBigramInvertedIndex()
                let engine = SimilarBooksEngine(store: store, cacheTTL: 60)
                let top1 = try engine.similar(to: "bLaw1")
                try expectTrue(!top1.isEmpty, "similar list must not be empty")
                try expectEqual(top1.first?.bookID, "bLaw2",
                                "closest thematic sibling must rank first")
                try expectFalse(top1.contains { $0.bookID == "bMath" },
                                "unrelated book must miss the top")
                try expectTrue(top1.allSatisfy { $0.score > 0 && $0.score <= 1 })
                // 对称性：bLaw2 的 top 亦应含 bLaw1。
                let top2 = try engine.similar(to: "bLaw2")
                try expectTrue(top2.contains { $0.bookID == "bLaw1" })
                // 缓存：二次调用同结果。
                let again = try engine.similar(to: "bLaw1")
                try expectEqual(again, top1)
            },

            TestDesc(suite: "SimilarBooks", name: "emptyInvertedIndexDegradesToEmptyList") {
                let store = try makeStore()
                try addBook(store, id: "b1", name: "b1.pdf", pages: ["一些中文文本内容"])
                // 不重建倒排表（bidx_dirty=1）——降级空数组不报错。
                let engine = SimilarBooksEngine(store: store)
                let result = try engine.similar(to: "b1")
                try expectTrue(result.isEmpty)
            },

            TestDesc(suite: "SimilarBooks", name: "singleWordBookYieldsEmptySignature") {
                let store = try makeStore()
                try addBook(store, id: "bSingle", name: "s.pdf", pages: ["一"])
                try addBook(store, id: "bOther", name: "o.pdf", pages: ["权利法理规范体系文本"])
                _ = try store.rebuildBigramInvertedIndex()
                let engine = SimilarBooksEngine(store: store)
                // 单字书签名（bigram）为空 → 空列表。
                let result = try engine.similar(to: "bSingle")
                try expectTrue(result.isEmpty)
            },

            TestDesc(suite: "SimilarBooks", name: "invalidateClearsCache") {
                let store = try makeStore()
                try addBook(store, id: "bA", name: "a.pdf", pages: ["权利法理规范体系文本内容"])
                try addBook(store, id: "bB", name: "b.pdf", pages: ["权利法理规范体系义务结构"])
                _ = try store.rebuildBigramInvertedIndex()
                let engine = SimilarBooksEngine(store: store)
                let first = try engine.similar(to: "bA")
                engine.invalidate()
                let second = try engine.similar(to: "bA")
                // 相等性比较不含 computedAt（重算必然拿到新时间戳，整结构
                // expectEqual 永假）——按 bookID＋score 字符串载荷逐项比较。
                try expectEqual(first.map { "\($0.bookID)|\($0.score)" },
                                second.map { "\($0.bookID)|\($0.score)" })
            },

            // error 行与策略排除书不进推荐候选（与检索面基准一致）。
            TestDesc(suite: "SimilarBooks", name: "errorStatusBookMissesRecommendations") {
                let store = try makeStore()
                try addBook(store, id: "bGood", name: "g.pdf", pages: ["权利法理规范体系文本内容"])
                try addBook(store, id: "bErr", name: "e.pdf", pages: ["权利法理规范体系义务结构"])
                // 照 run 失败基准把 bErr 置 error 行。
                let errBook = try expectNotNil(try store.book(byID: "bErr"))
                var bad = errBook
                bad.status = "error"
                bad.error = "synthetic failure"
                try store.upsertBook(bad)
                _ = try store.rebuildBigramInvertedIndex()
                let engine = SimilarBooksEngine(store: store)
                let top = try engine.similar(to: "bGood")
                try expectFalse(top.contains { $0.bookID == "bErr" },
                                "error book must never be recommended")
            },

            TestDesc(suite: "SimilarBooks", name: "topBigramsFrequencyOrdering") {
                let texts = ["权利权利权利法理", "权利规范"]
                let top = SimilarBooksEngine.topBigrams(texts: texts, limit: 3)
                try expectEqual(top.first, "权利")
                try expectTrue(top.count <= 3)
                // idf：df 越高权重越低（stop-bigram 衰减）。
                let rare = SimilarBooksEngine.idf(df: 1, total: 100)
                let common = SimilarBooksEngine.idf(df: 90, total: 100)
                try expectTrue(rare > common)
                try expectEqual(SimilarBooksEngine.idf(df: 0, total: 100), 0)
            },
        ]
    }
}
