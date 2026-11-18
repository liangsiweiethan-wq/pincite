import Foundation
@testable import LiteratureCore

// 计数内存映射一致性测试。
// 验证 `matchingPageCounts` 的内存 rowid→bookID 映射统计与独立来源严格
// 一致：随机采样 100 / 1,000 / 50,000 个 rowid（含重复采样与不存在
// rowid），同时对照两条独立 oracle——
//   (a) 建库时的已知 书↔rowid 指派表；
//   (b) store.pages(rowIDs:) 全量物化后按 bookID 分组（SQL 点查路径）。
// 断言三字典大小一致、键集一致、每个键计数值一致。
// 并附写路径失效回归断言：replacePages / deleteBook 后计数必须即时反映
// 新状态（缓存未失效即失败）。
enum MatchingPageCountsMemoryParitySuite {
    static func makeStore() throws -> (IndexStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lit-mpc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try IndexStore(path: dir.appendingPathComponent("index.db")), dir)
    }

    /// 12 书 × 1,000 页；页文本极小（物化 oracle 快）。
    static func buildLibrary(_ store: IndexStore, books: Int = 12, pagesPerBook: Int = 1_000) throws {
        for b in 0..<books {
            let id = String(format: "bk%02d", b)
            let book = IndexStore.BookRow(
                id: id, realPath: "/tmp/lit-mpc/\(id).pdf", rootPath: "/tmp/lit-mpc",
                relPath: "\(id).pdf", fileName: "\(id).pdf",
                firstFingerprint: "fp-\(id)", fingerprint: "fp-\(id)", fileSize: 1, mtime: 0,
                pageCount: pagesPerBook, status: "ok", indexedAt: 0)
            try store.upsertBook(book)
            var rows: [IndexStore.PageRow] = []
            let n = normalizeForSearch("book\(b) filler page")
            for p in 1...pagesPerBook {
                rows.append(IndexStore.PageRow(bookID: id, pageNumber: p, textOriginal: "book\(b) page\(p)",
                                               textNorm: n.text, normStarts: n.starts, normEnds: n.ends))
            }
            try store.replacePages(bookID: id, rows)
        }
    }

    /// 确定性可复现采样器（LCG）。
    struct LCG {
        var state: UInt64
        init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 16
        }
        mutating func pick(_ upper: Int) -> Int { upper <= 0 ? 0 : Int(next() % UInt64(upper)) }
    }

    /// 两条独立 oracle 之一：(a) 建库指派表。
    static func expectedCounts(assignment: [String: String], sample: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        var seen = Set<String>()
        for raw in sample where seen.insert(raw).inserted {
            guard let bid = assignment[raw] else { continue }   // 不存在 rowid：忽略
            counts[bid, default: 0] += 1
        }
        return counts
    }

    /// 两条独立 oracle 之二：(b) 全量物化分组。注意 pages(rowIDs:) 按输入
    /// 重复度返回行（IndexStore.swift 末段按输入序逐个 append），SQL JOIN
    /// 计数语义是对「去重候选集」计数——故先显式去重样本再物化分组。
    static func materializedCounts(store: IndexStore, sample: [String]) throws -> [String: Int] {
        var seen = Set<String>()
        let distinct = sample.filter { seen.insert($0).inserted }
        var counts: [String: Int] = [:]
        for row in try store.pages(rowIDs: distinct) {
            counts[row.bookID, default: 0] += 1
        }
        return counts
    }

    static func assertParity(store: IndexStore, assignment: [String: String],
                             sample: [String], label: String) throws {
        let memory = try store.matchingPageCounts(rowIDs: sample)
        let byAssignment = expectedCounts(assignment: assignment, sample: sample)
        let byMaterialization = try materializedCounts(store: store, sample: sample)
        try expectEqual(memory.count, byAssignment.count, "[\(label)] dict size vs assignment oracle")
        try expectEqual(memory, byAssignment, "[\(label)] counts vs assignment oracle")
        try expectEqual(memory, byMaterialization, "[\(label)] counts vs materialization oracle")
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "MatchingPageCountsMemoryParity", name: "memoryMappingMatchesAssignmentAndMaterializationOracles") {
                let (store, _) = try makeStore()
                try buildLibrary(store)
                // rowid→book 指派表（来自 store 本身的 rowid 列举，建库即知归属）。
                var assignment: [String: String] = [:]
                var allRowIDs: [String] = []
                for b in 0..<12 {
                    let id = String(format: "bk%02d", b)
                    let ids = try store.candidateRowIDs(bookID: id)
                    try expectEqual(ids.count, 1_000, "[\(id)] rowid count")
                    for raw in ids {
                        try expectNil(assignment[raw], "rowid must map to exactly one book")
                        assignment[raw] = id
                    }
                    allRowIDs.append(contentsOf: ids)
                }
                for size in [100, 1_000, 50_000] {
                    var rng = LCG(seed: 2026_1003 &+ UInt64(size))
                    var sample: [String] = []
                    sample.reserveCapacity(size)
                    for _ in 0..<size { sample.append(allRowIDs[rng.pick(allRowIDs.count)]) }
                    if size == 50_000 {
                        // 混入不存在的 rowid（旧 SQL JOIN 语义：忽略不存在的键）。
                        for i in 0..<50 { sample.append(String(9_000_000_000 + i)) }
                        // 混入显式重复（临时表主键语义：去重计一次）。
                        sample.append(contentsOf: sample.prefix(20))
                    }
                    try assertParity(store: store, assignment: assignment, sample: sample, label: "n=\(size)")
                }
            },

            TestDesc(suite: "MatchingPageCountsMemoryParity", name: "cacheInvalidatesOnReplacePagesAndDeleteBook") {
                let (store, _) = try makeStore()
                try buildLibrary(store, books: 3, pagesPerBook: 200)
                var assignment: [String: String] = [:]
                for b in 0..<3 {
                    let id = String(format: "bk%02d", b)
                    for raw in try store.candidateRowIDs(bookID: id) { assignment[raw] = id }
                }
                let warm = Array(assignment.keys.prefix(100))
                // 预热常驻映射（触发 ensureRowidToBookIDMappingLocked 建缓存）。
                _ = try store.matchingPageCounts(rowIDs: warm)

                // 写点 1：replacePages（DELETE+INSERT ⇒ rowid 重排）。缓存若
                // 未失效，新 rowid 在旧映射里查无 ⇒ 计数丢失，此处即失败。
                let bk00 = try expectNotNil(try store.book(byID: "bk00"))
                _ = bk00
                let n = normalizeForSearch("reindexed content")
                var newRows: [IndexStore.PageRow] = []
                for p in 1...150 {
                    newRows.append(IndexStore.PageRow(bookID: "bk00", pageNumber: p,
                                                      textOriginal: "reindexed page\(p)",
                                                      textNorm: n.text, normStarts: n.starts, normEnds: n.ends))
                }
                try store.replacePages(bookID: "bk00", newRows)
                var assignment2: [String: String] = [:]
                for b in 0..<3 {
                    let id = String(format: "bk%02d", b)
                    for raw in try store.candidateRowIDs(bookID: id) { assignment2[raw] = id }
                }
                try expectEqual(assignment2.count, 550, "150 reindexed + 2×200 untouched")
                let sample2 = Array(assignment2.keys.prefix(300)) + Array(assignment2.keys.suffix(100))
                try assertParity(store: store, assignment: assignment2, sample: sample2, label: "after replacePages")

                // 写点 2：deleteBook（DELETE pages ⇒ 映射整体收缩）。
                try store.deleteBook(id: "bk01")
                var assignment3: [String: String] = [:]
                for raw in try store.candidateRowIDs(bookID: "bk00") { assignment3[raw] = "bk00" }
                for raw in try store.candidateRowIDs(bookID: "bk02") { assignment3[raw] = "bk02" }
                try expectEqual(assignment3.count, 350)
                let sample3 = Array(assignment3.keys)
                try assertParity(store: store, assignment: assignment3, sample: sample3, label: "after deleteBook")
                // 被删书的旧 rowid 不得再计入任何书。
                let stale = sample2.filter { assignment2[$0] == "bk01" }
                let counts = try store.matchingPageCounts(rowIDs: stale)
                try expectTrue(counts.isEmpty, "stale rowids of a deleted book must not count")
            },
        ]
    }
}
