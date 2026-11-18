import Foundation
@testable import LiteratureCore

enum RoundRobinStressSuite {
    static func makeStore() throws -> (IndexStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lit-rr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try IndexStore(path: dir.appendingPathComponent("index.db")), dir)
    }

    /// 书按 A→B→C 顺序写入（rowid 升序 ⇒ 命中首现序即 A,B,C）。
    /// 页文本含查询词「术语」，另带页序号便于核对物理页。
    @discardableResult
    static func addBook(_ store: IndexStore, id: String, name: String,
                        hitPages: Int, missPages: Int = 0) throws -> IndexStore.BookRow {
        var pages: [String] = []
        for i in 1...hitPages { pages.append("术语出现在第\(i)页 of \(id)") }
        if missPages > 0 {
            for i in 1...missPages { pages.append("无关内容 \(id) filler\(i)") }
        }
        let book = IndexStore.BookRow(
            id: id, realPath: "/tmp/lit-rr/\(name)", rootPath: "/tmp/lit-rr",
            relPath: name, fileName: name,
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
        return book
    }

    static func buildAsymmetricLibrary(_ store: IndexStore) throws {
        try addBook(store, id: "A", name: "a.pdf", hitPages: 200)
        try addBook(store, id: "B", name: "b.pdf", hitPages: 2)
        try addBook(store, id: "C", name: "c.pdf", hitPages: 50)
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "RoundRobinStress", name: "asymmetricQuotaRoundSequenceExactAndTruncationSafe") {
                let (store, _) = try makeStore()
                try buildAsymmetricLibrary(store)
                let service = SearchService(store: store)
                let result = try service.searchDetailed("术语", options: SearchOptions(limit: 20, perBookLimit: 4))
                // 计数语义：全集 252 页命中，limit 20 未触顶即轮次耗尽。
                try expectEqual(result.totalPageMatches, 252)
                try expectTrue(result.truncated, "252 > 20 must be marked truncated")
                let expectedBooks = ["A", "B", "C", "A", "B", "C", "A", "C", "A", "C"]
                let expectedPages = [1, 1, 1, 2, 2, 2, 3, 3, 4, 4]
                try expectEqual(result.hits.count, expectedBooks.count)
                for (i, hit) in result.hits.enumerated() {
                    try expectEqual(hit.bookID, expectedBooks[i], "slot#\(i) bookID")
                    try expectEqual(hit.physicalPage, expectedPages[i], "slot#\(i) physicalPage")
                }
                // 探针（即时读，防被后继查询覆盖）：全量物化页数＝切片长度，
                // 轻量扫描＝候选全集，绝不回浮到 252。
                if let rec = SearchPhaseTiming.lastSearchRecord {
                    try expectEqual(rec.pagesFullyMaterialized, result.hits.count)
                    try expectEqual(rec.lightRowsScanned, rec.candidates)
                    try expectEqual(rec.totalPageMatches, 252)
                }
                // 两阶段切片 ＝ 无截断全集 round-robin 输出（逐项相等）：
                // 无配额查询（limit=500 > 252）取全集命中序，再按同配额重放
                // 同一 round-robin 函数，应与两阶段切片逐项相等。
                let full = try service.searchDetailed("术语", options: SearchOptions(limit: 500))
                try expectEqual(full.hits.count, 252, "limit=500 without quota covers the full hit set")
                let reference = SearchService.roundRobinByBook(full.hits, perBookLimit: 4, limit: 20)
                try expectEqual(result.hits, reference, "two-phase slice == full-set round-robin")
            },

            TestDesc(suite: "RoundRobinStress", name: "limitCutMidRoundLosesNoEarlierRoundItem") {
                let (store, _) = try makeStore()
                try buildAsymmetricLibrary(store)
                let service = SearchService(store: store)
                // limit=8 先于轮次耗尽（perBookLimit=20）：三项 → 三项 →
                // 中 B 队列仅 2 条已耗尽被跳过，取 即满 8 项
                // （与重复序列 一致）。
                let result = try service.searchDetailed("术语", options: SearchOptions(limit: 8, perBookLimit: 20))
                let expectedBooks = ["A", "B", "C", "A", "B", "C", "A", "C"]
                let expectedPages = [1, 1, 1, 2, 2, 2, 3, 3]
                try expectEqual(result.hits.count, 8)
                for (i, hit) in result.hits.enumerated() {
                    try expectEqual(hit.bookID, expectedBooks[i], "slot#\(i) bookID")
                    try expectEqual(hit.physicalPage, expectedPages[i], "slot#\(i) physicalPage")
                }
                let full = try service.searchDetailed("术语", options: SearchOptions(limit: 500, perBookLimit: 20))
                let reference = SearchService.roundRobinByBook(full.hits, perBookLimit: 20, limit: 8)
                try expectEqual(result.hits, reference, "two-phase slice == full-set round-robin (mid-round cut)")
            },

            TestDesc(suite: "RoundRobinStress", name: "flatTopNStillExactWithoutQuota") {
                let (store, _) = try makeStore()
                try buildAsymmetricLibrary(store)
                let service = SearchService(store: store)
                // 无配额（legacy 平切）：前 20 项必须是全集命中序的前 20
                // （书 A 前 20 页），两阶段与全量物化一致。
                let result = try service.searchDetailed("术语", options: SearchOptions(limit: 20))
                try expectEqual(result.hits.count, 20)
                try expectEqual(result.totalPageMatches, 252)
                for (i, hit) in result.hits.enumerated() {
                    try expectEqual(hit.bookID, "A", "flat slice slot#\(i)")
                    try expectEqual(hit.physicalPage, i + 1, "flat slice slot#\(i)")
                }
                if let rec = SearchPhaseTiming.lastSearchRecord {
                    // 探针恒等式：全量物化页数 ＝ min(totalPageMatches, limit)。
                    try expectEqual(rec.pagesFullyMaterialized, min(rec.totalPageMatches, 20))
                }
            },
        ]
    }
}
