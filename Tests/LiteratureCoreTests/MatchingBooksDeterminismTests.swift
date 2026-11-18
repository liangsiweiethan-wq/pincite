import Foundation
@testable import LiteratureCore

enum MatchingBooksDeterminismSuite {
    /// 快路测试夹具：双书各一页含 "anchor cell"，
    /// ensureBigramIndexFresh 后倒排 built+clean。返回的库尚处"常规路"形态
    ///（bigram blob 小，快路谓词 nil）；需要激活快路的用例自行把目标词的
    /// 五个 bigram rowids 灌成 zeroblob 过 2MB 门槛（经 @testable 内部 db
    /// 直捣 SQL——灌大只影响门槛判定读的 length(rowids)，页/FTS 内容不动）。
    static func makeTwoBookFastPathLibrary() throws -> (IndexStore, SearchService, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lit-fastpath-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try IndexStore(path: dir.appendingPathComponent("index.db"))
        for id in ["bk-a", "bk-b"] {
            let name = "\(id).pdf"
            let book = IndexStore.BookRow(
                id: id, realPath: "/tmp/lit-fastpath/\(name)", rootPath: "/tmp/lit-fastpath",
                relPath: name, fileName: name,
                firstFingerprint: "fp-\(id)", fingerprint: "fp-\(id)", fileSize: 1, mtime: 0,
                pageCount: 1, status: "ok", indexedAt: 0)
            try store.upsertBook(book)
            let n = normalizeForSearch("anchor cell")
            try store.replacePages(bookID: id, [
                IndexStore.PageRow(bookID: id, pageNumber: 1,
                                   textOriginal: "anchor cell", textNorm: n.text,
                                   normStarts: n.starts, normEnds: n.ends),
            ])
        }
        _ = try store.ensureBigramIndexFresh()
        return (store, SearchService(store: store), dir)
    }

    /// 把 "anchor" 的五个 bigram blob 灌大（合计 3MB > 2MB 门槛）强制激活快路。
    static func inflateFastPathBlobs(_ store: IndexStore) throws {
        try store.db.exec("""
        UPDATE bigram_index SET rowids = zeroblob(600000)
        WHERE bigram IN ('an','nc','ch','ho','or');
        """)
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "MatchingBooksDeterminism", name: "tiedCountsResolveInTotalOrderAcrossRuns") {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lit-mbdet-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let store = try IndexStore(path: dir.appendingPathComponent("index.db"))
                var ids: [String] = []
                for i in 0..<50 {
                    let id = String(format: "bk%02d", (i * 7) % 50) + "-" + String((i * 13) % 50)
                    ids.append(id)
                    let name = "书\(i)-\(id).pdf"
                    let book = IndexStore.BookRow(
                        id: id, realPath: "/tmp/lit-mbdet/\(name)", rootPath: "/tmp/lit-mbdet",
                        relPath: name, fileName: name,
                        firstFingerprint: "fp-\(id)", fingerprint: "fp-\(id)", fileSize: 1, mtime: 0,
                        pageCount: 1, status: "ok", indexedAt: 0)
                    try store.upsertBook(book)
                    let n = normalizeForSearch("同词命中 唯一术语 anchor")
                    try store.replacePages(bookID: id, [
                        IndexStore.PageRow(bookID: id, pageNumber: 1,
                                           textOriginal: "同词命中 唯一术语 anchor", textNorm: n.text,
                                           normStarts: n.starts, normEnds: n.ends),
                    ])
                }
                let service = SearchService(store: store)
                let first = try service.matchingBooks("唯一术语")
                let second = try service.matchingBooks("唯一术语")
                try expectEqual(first.count, 50)
                try expectEqual(first, second, "matchingBooks must be a pure function of store state")
                // ASCII 单词形态（可能触发英文快路计数；两路排序现均为全序）：
                let third = try service.matchingBooks("anchor")
                let fourth = try service.matchingBooks("anchor")
                try expectEqual(third.count, 50)
                try expectEqual(third, fourth, "ASCII term path must be deterministic too")
                // 20 连跑随机扰动：交替「清查询缓存（缓存未命中路径）」
                // 与「全新 SearchService 实例（内存缓存冷启动路径）」，50 书全
                // 并列计数下输出必须 100% 逐项相等（字典随机迭代序漂移零容忍）。
                for run in 0..<20 {
                    if run % 2 == 0 {
                        try store.purgeQueryCaches()
                    } else {
                        let fresh = SearchService(store: store)
                        let hits = try fresh.matchingBooks("anchor")
                        try expectEqual(hits, third, "run \(run) fresh-instance run must equal anchor baseline")
                    }
                    let hits = try service.matchingBooks(run % 2 == 0 ? "anchor" : "唯一术语")
                    let baseline = run % 2 == 0 ? third : first
                    try expectEqual(hits, baseline, "run \(run) perturbed run must equal baseline")
                }
                // 并列段（全体）决胜键：fileName 升序，fileName 相异时 bookID 升序结算。
                for i in 1..<first.count {
                    let prev = first[i - 1]
                    let cur = first[i]
                    try expectTrue(prev.matchingPages >= cur.matchingPages, "count descending")
                    if prev.matchingPages == cur.matchingPages {
                        let tieOk = prev.fileName < cur.fileName
                            || (prev.fileName == cur.fileName && prev.bookID < cur.bookID)
                        try expectTrue(tieOk, "tie must resolve by fileName then bookID")
                    }
                }
            },
            // 回归断言：英文快路此前缺 metadata
            // filter 检查（只查 policy），单 ASCII 词激活快路时 GUI 传入的
            // bookIDEquals/authorContains 等过滤整体失效。灌大 blob 强制走真
            // 快路分支，bookIDEquals 只放行 bk-a。
            TestDesc(suite: "MatchingBooksDeterminism", name: "fastPathHonorsMetadataFilter") {
                let (store, service, dir) = try makeTwoBookFastPathLibrary()
                defer { Fixtures.cleanup(dir) }
                try inflateFastPathBlobs(store)
                let counts = try expectNotNil(try store.candidateBookCountsViaFTS(term: "anchor"),
                                              "夹具必须真实激活英文快路（否则本测试测不到该分支）")
                try expectEqual(Set(counts.keys), ["bk-a", "bk-b"])
                let plain = try service.matchingBooks("anchor")
                try expectEqual(Set(plain.map(\.bookID)), ["bk-a", "bk-b"],
                                "无 filter 时快路命中双书（filter 分支非空集证明）")
                let filtered = try service.matchingBooks("anchor", filter: SearchFilter(bookIDEquals: "bk-a"))
                try expectEqual(filtered.map(\.bookID), ["bk-a"],
                                "快路必须同常规路一样尊重 metadata filter")
            },
            // 同批：无 filter 时快路与常规路输出必须逐项一致——
            // 快路是性能捷径不是语义分叉。常规路先于灌大采集（blob 小＝
            // 谓词 nil＝常规路），灌大后同查询走快路，两次结果全等。
            TestDesc(suite: "MatchingBooksDeterminism", name: "fastPathEqualsRegularPathWithoutFilter") {
                let (store, service, dir) = try makeTwoBookFastPathLibrary()
                defer { Fixtures.cleanup(dir) }
                try expectNil(try store.candidateBookCountsViaFTS(term: "anchor"),
                              "夹具初始态必须处于常规路（blob 未灌大）")
                let regular = try service.matchingBooks("anchor")
                try expectEqual(Set(regular.map(\.bookID)), ["bk-a", "bk-b"])
                try inflateFastPathBlobs(store)
                try expectNotNil(try store.candidateBookCountsViaFTS(term: "anchor"),
                                 "灌大后必须真实处于快路")
                let fast = try service.matchingBooks("anchor")
                try expectEqual(fast, regular, "无 filter 时快路与常规路输出必须逐项一致")
            }
        ]
    }
}
