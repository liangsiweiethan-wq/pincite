import Foundation
@testable import LiteratureCore

enum ParallelMaterializeSuite {
    static let pageCount = 8_100   // > materializeParallelThreshold（8,000），确保走并行分支

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "ParallelMaterialize", name: "parallelShardsMatchSequentialFilter") {
                let dir = Fixtures.makeTempDir("parallel-materialize")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                try store.upsertBook(IndexStore.BookRow(
                    id: "bk-par", realPath: dir.appendingPathComponent("par.pdf").path,
                    rootPath: dir.path, relPath: "par.pdf", fileName: "par.pdf",
                    firstFingerprint: "fp-par", fingerprint: "fp-par",
                    fileSize: 1, mtime: 0, pageCount: pageCount, status: "ok", indexedAt: 0))

                var pages: [IndexStore.PageRow] = []
                pages.reserveCapacity(pageCount)
                for i in 1...pageCount {
// 每 997 页一命中，其余为不含目标串的填充文本。
                let text = (i % 997 == 0) ? "alpha targetword beta" : "alpha filler beta"
                    pages.append(IndexStore.PageRow(
                        bookID: "bk-par", pageNumber: i,
                        textOriginal: text, textNorm: text,
                        normStarts: [], normEnds: []))
                }
                try store.replacePages(bookID: "bk-par", pages)

                let light = try store.lightPages(rowIDs: (1...pageCount).map(String.init))
                try expectEqual(light.count, pageCount, "全部页行都应可取回")
                let expected = light
                    .filter { $0.textNorm.contains("targetword") }
                    .map { $0.rowID }
                try expectTrue(!expected.isEmpty, "夹具必须含命中页")
                try expectTrue(expected == expected.sorted(), "顺序过滤结果按 rowid 升序")

                let ids = light.map { $0.rowID }
                let parallel = try store.lightPagesFiltered(rowIDs: ids, term: "targetword")
                try expectEqual(parallel.map { $0.rowID }, expected,
                                "并行分片输出必须与顺序 LIKE 过滤逐字节一致（含升序）")
            },
            TestDesc(suite: "ParallelMaterialize", name: "singleTermSearchUsesSQLPrefilterAndKeepsHits") {
                let dir = Fixtures.makeTempDir("parallel-search")
                defer { Fixtures.cleanup(dir) }
                let pages: [SyntheticPDFPage] = (1...30).map { i in
                    let text = (i == 7 || i == 19) ? "这里讨论 法律 与规范" : "无关页面内容"
                    return .init(lines: [text])
                }
                _ = Fixtures.makePDF(pages: pages, in: dir, named: "search.pdf")
                let store = try Fixtures.openStore(in: dir)
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)

                let service = SearchService(store: store)
                let result = try service.searchDetailed("法律", options: SearchOptions(limit: 20))
                let hitPages = result.hits.map { $0.physicalPage }.sorted()
                try expectEqual(hitPages, [7, 19], "单词 CJK 查询仍应命中且仅命中含该词的页")
                try expectEqual(result.totalPageMatches, 2, "总命中数按页计")
            }
        ]
    }
}
