import Foundation
@testable import LiteratureCore

// 性能与内存测试。
// 防止未来迭代无意中破坏两阶段物化或重新引入过度物化：
//   - 合成大候选集（20,000 页全部命中两词查询）下：
// diagnostics.materializeMs < 6,000ms（合成基准的回归闸）；
//     queryMs 保持正常（≥0）；
//   - 探针 pagesFullyMaterialized 恒等于 min(totalPageMatches, limit)
//     （limit=20 时全量物化页数严格为 20，绝不上浮到候选全集）。
// 注：合成库页文本极小，materializeMs 闸在该库上属宽松下界；抓住「回退
// 全量物化」的主力断言是 pagesFullyMaterialized 恒等式（全量物化实现下它
// 会变成 20,000 而非 20）。
enum MaterializationPhasePerformanceGateSuite {
    static func makeStore() throws -> (IndexStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lit-perfgate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try IndexStore(path: dir.appendingPathComponent("index.db")), dir)
    }

    /// 8 书 × 2,500 页，每页同时含 "state" 与 "law" ⇒ 两词交集＝全集 20,000。
    static func buildBigLibrary(_ store: IndexStore, books: Int = 8, pagesPerBook: Int = 2_500) throws {
        for b in 0..<books {
            let id = String(format: "gk%02d", b)
            let book = IndexStore.BookRow(
                id: id, realPath: "/tmp/lit-perfgate/\(id).pdf", rootPath: "/tmp/lit-perfgate",
                relPath: "\(id).pdf", fileName: "\(id).pdf",
                firstFingerprint: "fp-\(id)", fingerprint: "fp-\(id)", fileSize: 1, mtime: 0,
                pageCount: pagesPerBook, status: "ok", indexedAt: 0)
            try store.upsertBook(book)
            var rows: [IndexStore.PageRow] = []
            for p in 1...pagesPerBook {
                let raw = "state law case \(b)/\(p): the statute governs"
                let n = normalizeForSearch(raw)
                rows.append(IndexStore.PageRow(bookID: id, pageNumber: p, textOriginal: raw,
                                               textNorm: n.text, normStarts: n.starts, normEnds: n.ends))
            }
            try store.replacePages(bookID: id, rows)
        }
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "MaterializationPhasePerformanceGate", name: "topKOnlyMaterializationAndPhaseBudgetHold") {
                let (store, _) = try makeStore()
                try buildBigLibrary(store)
                // 本测锁定 legacy 两阶段物化守卫——置 wfts_dirty=1 令
                // "state law" 落子串路（词路的 Top-K 物化恒等式由
                // WordLevelIndexTests 专断言：candidates 走 FTS 计数，物化仍恰 Top-K）。
                try store.setMetaValue("wfts_dirty", "1")
                let service = SearchService(store: store)
                SearchPhaseTiming.forced = true
                defer { SearchPhaseTiming.forced = false }
                let start = Date()
                let result = try service.searchDetailed("state law", options: SearchOptions(limit: 20))
                let wallMs = Date().timeIntervalSince(start) * 1000
                // 计数与切片语义不变。
                try expectEqual(result.totalPageMatches, 20_000, "all pages hit both terms")
                try expectEqual(result.hits.count, 20, "slice == limit")
                try expectTrue(result.truncated)
                let rec = try expectNotNil(SearchPhaseTiming.lastSearchRecord)
                // 探针恒等式（主力守卫）：全量物化页数 ＝ min(total, limit)。
                try expectEqual(rec.lightRowsScanned, rec.candidates, "phase 1 lightly scans every candidate")
                try expectEqual(rec.lightRowsScanned, 20_000)
                try expectEqual(rec.pagesFullyMaterialized, min(rec.totalPageMatches, 20),
                                "full materialization must stay at Top-K, never the candidate set")
                try expectEqual(rec.pagesFullyMaterialized, 20)
                try expectEqual(rec.totalPageMatches, 20_000)
                try expectEqual(rec.pagesLoaded, rec.pagesFullyMaterialized)
                // 相位预算：物化相 < 6,000ms；整查询墙钟亦须
                // 远低于旧全量物化量级。
                let materializeLimit = perfLimit(6_000.0, relaxed: 30_000.0, "materializeMs")
                try expectTrue(rec.materializeMs < materializeLimit,
                               "materializeMs \(rec.materializeMs)ms must stay under the \(materializeLimit)ms gate")
                try expectTrue(rec.queryMs >= 0)
                try expectTrue(rec.verifyMs >= 0)
                let wallLimit = perfLimit(10_000.0, relaxed: 60_000.0, "whole query wallMs")
                try expectTrue(wallMs < wallLimit, "whole query \(wallMs)ms must stay sane")
                // 诊断面板字段同步：pagesLoaded = Top-K 全量物化数。
                let diag = try expectNotNil(service.lastQueryDiagnostics)
                try expectEqual(diag.pagesLoaded, 20)
                try expectEqual(diag.totalPageMatches, 20_000)
            },

            TestDesc(suite: "MaterializationPhasePerformanceGate", name: "bookScopeSmallSetKeepsInvariant") {
                let (store, _) = try makeStore()
                try buildBigLibrary(store, books: 2, pagesPerBook: 300)
                let service = SearchService(store: store)
                SearchPhaseTiming.forced = true
                defer { SearchPhaseTiming.forced = false }
                // 书域收窄后候选 300，limit 默认 100 ⇒ 物化恰 100。
                let result = try service.searchDetailed("state law",
                                                        options: SearchOptions(limit: 100,
                                                                               filter: SearchFilter(bookIDEquals: "gk00")))
                try expectEqual(result.totalPageMatches, 300)
                try expectEqual(result.hits.count, 100)
                let rec = try expectNotNil(SearchPhaseTiming.lastSearchRecord)
                try expectEqual(rec.pagesFullyMaterialized, min(rec.totalPageMatches, 100))
                try expectTrue(rec.materializeMs < perfLimit(6_000.0, relaxed: 30_000.0, "materializeMs"))
            },

            TestDesc(suite: "MaterializationPhasePerformanceGate", name: "fastPathPushdownBudgetAndLightRowInvariant") {
                let (store, _) = try makeStore()
                // 置 wfts_dirty=1 令 "state" 落子串轨—— 快路＋LIKE
                // 下推守卫原样保留（bidx_* 键不受影响）。
                try store.setMetaValue("wfts_dirty", "1")
                func addPages(_ id: String, count: Int, text: String) throws {
                    let book = IndexStore.BookRow(
                        id: id, realPath: "/tmp/lit-perfgate/\(id).pdf", rootPath: "/tmp/lit-perfgate",
                        relPath: "\(id).pdf", fileName: "\(id).pdf",
                        firstFingerprint: "fp-\(id)", fingerprint: "fp-\(id)", fileSize: 1, mtime: 0,
                        pageCount: count, status: "ok", indexedAt: 0)
                    try store.upsertBook(book)
                    var rows: [IndexStore.PageRow] = []
                    for p in 1...count {
                        let raw = "\(text) \(id)/\(p)"
                        let n = normalizeForSearch(raw)
                        rows.append(IndexStore.PageRow(bookID: id, pageNumber: p, textOriginal: raw,
                                                       textNorm: n.text, normStarts: n.starts, normEnds: n.ends))
                    }
                    try store.replacePages(bookID: id, rows)
                }
                for b in 0..<4 { try addPages(String(format: "fk%02d", b), count: 2_000, text: "state law case") }
                for b in 0..<2 { try addPages(String(format: "fx%02d", b), count: 500, text: "start team at extra") }
                _ = try store.rebuildBigramInvertedIndex()
                try store.db.exec("UPDATE bigram_index SET rowids = zeroblob(600000) WHERE bigram IN ('st','ta','at','te');")
                try expectNotNil(try store.candidateRowIDsViaFTS(term: "state"),
                                 "夹具必须真实激活快路")
                let service = SearchService(store: store)
                SearchPhaseTiming.forced = true
                defer { SearchPhaseTiming.forced = false }
                let result = try service.searchDetailed("state", options: SearchOptions(limit: 20))
                try expectEqual(result.totalPageMatches, 8_000, "真命中恰 8,000 页")
                try expectEqual(result.hits.count, 20)
                let rec = try expectNotNil(SearchPhaseTiming.lastSearchRecord)
                try expectEqual(rec.candidates, 9_000, "候选＝真命中＋假候选")
                try expectEqual(rec.lightRowsScanned, rec.totalPageMatches,
                                "快路下 Stage1 轻量行必须恰等于真命中数（假候选已在 C 层淘汰）")
                try expectEqual(rec.lightRowsScanned, 8_000)
                try expectTrue(rec.lightRowsScanned < rec.candidates, "假候选确有被短路（否则恒等式无意义）")
                try expectEqual(rec.pagesFullyMaterialized, min(rec.totalPageMatches, 20))
                try expectEqual(rec.pagesFullyMaterialized, 20)
                let fastPathLimit = perfLimit(2_500.0, relaxed: 15_000.0, "fast-path materializeMs")
                try expectTrue(rec.materializeMs < fastPathLimit,
                               "materializeMs \(rec.materializeMs)ms must stay under the \(fastPathLimit)ms gate")
            },
        ]
    }
}
