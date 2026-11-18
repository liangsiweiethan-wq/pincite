import Foundation
@testable import LiteratureCore

// 性能优化测试：perBookPageStats 的缓存与失效，外加「改写后的
// SQL 与改写前旧 SQL 逐字段等价」的对拍。旧 SQL 已不在产品代码里，故在此
// 原样保留一份作为对照基准——任何后续改写只要这里红了，就是语义漂移。
enum PagesStatsCacheTests {
    /// 改写前的原始 SQL（旧 perBookPageStats 实现，逐字保留作对照基准）。
    static let legacySQL = """
    SELECT b.id, b.status, COUNT(p.page_number),
           COALESCE(SUM(CASE WHEN TRIM(p.text_norm) = '' THEN 0 ELSE 1 END), 0)
    FROM books b LEFT JOIN pages p ON p.book_id = b.id
    GROUP BY b.id, b.status
    ORDER BY b.rel_path;
    """

    static func legacyStats(_ store: IndexStore) throws -> [BookPageStat] {
        let stmt = try store.db.prepare(legacySQL)
        var out: [BookPageStat] = []
        while try stmt.step() {
            out.append(BookPageStat(bookID: stmt.text(0), status: stmt.text(1),
                                    indexedPages: Int(stmt.int(2)), pagesWithText: Int(stmt.int(3))))
        }
        return out
    }

    static func makeStore() throws -> (IndexStore, URL) {
        let dir = Fixtures.makeTempDir("pages-stats")
        return (try Fixtures.openStore(in: dir), dir)
    }

    @discardableResult
    static func addBook(_ store: IndexStore, id: String, name: String,
                        pages: [String], status: String = "ok") throws -> IndexStore.BookRow {
        let book = IndexStore.BookRow(
            id: id, realPath: "/tmp/pages-tests/\(name)", rootPath: "/tmp/pages-tests",
            relPath: name, fileName: name,
            firstFingerprint: "fp-\(id)", fingerprint: "fp-\(id)", fileSize: 1, mtime: 0,
            pageCount: pages.count, status: status, indexedAt: 0)
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

    static func stat(_ store: IndexStore, _ id: String) throws -> BookPageStat? {
        try store.perBookPageStats().first { $0.bookID == id }
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "PagesStatsCache", name: "unmodifiedAggregateMatches") {
                let (store, dir) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                try addBook(store, id: "bA", name: "a.pdf", pages: ["alpha one", "alpha two"])
                try addBook(store, id: "bB", name: "b.pdf", pages: ["", "beta", "   "])
                try addBook(store, id: "bC", name: "c.pdf", pages: ["", ""])
                try addBook(store, id: "bE", name: "e.pdf", pages: [], status: "error")
                try addBook(store, id: "bZ", name: "z.pdf", pages: ["gamma"])
                let legacy = try legacyStats(store)
                let current = try store.perBookPageStats()
                try expectEqual(legacy.count, 5, "旧 SQL 应出 5 行（每书一行）")
                // 有页行的书：两式逐字段相同（改写不改变这些书的结果）。
                for id in ["bA", "bB", "bC", "bZ"] {
                    try expectEqual(current.first { $0.bookID == id }, legacy.first { $0.bookID == id },
                                    "有页行的书 \(id) 必须逐字段一致")
                }
                // 无页行书（error 书）：旧式在 SQLite 3.51 上 SUM 得 1（见
                // PagesStatsCache/pagelessBookLegacyQuirk），改写后 COALESCE
                // 得 0——这是刻意的语义修正，不是漂移。
                let legacyE = try expectNotNil(legacy.first { $0.bookID == "bE" })
                try expectEqual(legacyE.indexedPages, 0)
                try expectEqual(legacyE.pagesWithText, 1, "旧式对无页书给 pagesWithText=1（既有异常，断言住供比对）")
                let e = try expectNotNil(current.first { $0.bookID == "bE" })
                try expectEqual(e.indexedPages, 0)
                try expectEqual(e.pagesWithText, 0, "改写后无页书为 (0,0)：无页即无文本页")
                // 空白页按无文本计（旧 TRIM 与 normalizeForSearch 的结算一致）。
                let b = try expectNotNil(current.first { $0.bookID == "bB" })
                try expectEqual(b.indexedPages, 3)
                try expectEqual(b.pagesWithText, 1)
            },

            TestDesc(suite: "PagesStatsCache", name: "hitReturnsCachedValueUntilInvalidated") {
                let (store, dir) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                try addBook(store, id: "bA", name: "a.pdf", pages: ["one", "two"])
                let first = try stat(store, "bA")
                try expectEqual(first?.indexedPages, 2)
                // 绕过所有写入口直接插页行：缓存若真的生效，第二次读仍是 2。
                try store.db.exec("""
                INSERT INTO pages(book_id, page_number, text_original, text_norm, norm_starts, norm_ends, text_latin)
                VALUES('bA', 99, 'three', 'three', X'', X'', 'three');
                """)
                try expectEqual(try stat(store, "bA")?.indexedPages, 2, "缓存命中：不应看到绕过写入口的改动")
                try store.purgeQueryCaches()
                try expectEqual(try stat(store, "bA")?.indexedPages, 3, "失效后重算：应看到新行")
            },

            TestDesc(suite: "PagesStatsCache", name: "returnedValueIsCopy") {
                let (store, dir) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                try addBook(store, id: "bA", name: "a.pdf", pages: ["one"])
                var first = try store.perBookPageStats()
                try expectEqual(first.count, 1)
                first[0].indexedPages = 999
                try expectEqual(try stat(store, "bA")?.indexedPages, 1, "调用方改动不得回写缓存")
            },

            TestDesc(suite: "PagesStatsCache", name: "invalidationCoversEveryWriteEntry") {
                let (store, dir) = try makeStore()
                defer { Fixtures.cleanup(dir) }

                // 入口 1：upsertBook（含 status 变化）＋ replacePages
                try addBook(store, id: "bA", name: "a.pdf", pages: ["one", "two", ""])
                try expectEqual(try stat(store, "bA")?.indexedPages, 3)
                try expectEqual(try stat(store, "bA")?.pagesWithText, 2)

                // 入口 2：replacePages 重写同一本书（页数变 2）
                try addBook(store, id: "bA", name: "a.pdf", pages: ["one", "two"])
                try expectEqual(try stat(store, "bA")?.indexedPages, 2, "replacePages 后页数应更新")
                try expectEqual(try stat(store, "bA")?.pagesWithText, 2)

                // 入口 3：updateMetadata 的 status 改动（books 写点）
                _ = try store.updateMetadata(bookID: "bA", title: "新标题", author: nil, version: nil,
                                             language: nil, source: "manual")
                try expectEqual(try stat(store, "bA")?.bookID, "bA")

                // 入口 4：deleteBook（books＋pages 双删）
                try addBook(store, id: "bB", name: "b.pdf", pages: ["x"])
                try expectTrue(try store.perBookPageStats().contains { $0.bookID == "bB" })
                try store.deleteBook(id: "bB")
                try expectNil(try store.perBookPageStats().first { $0.bookID == "bB" },
                              "deleteBook 后该书行必须消失")

                // 入口 5：applyOCRPages（pages 的 UPDATE 写点）
                try addBook(store, id: "bS", name: "s.pdf", pages: ["", ""])
                try expectEqual(try stat(store, "bS")?.pagesWithText, 0)
                try store.applyOCRPages(
                    bookID: "bS",
                    ocrBook: .init(bookID: "bS", ocrRealPath: "/tmp/pages-tests/s-ocr.pdf",
                                   ocrFingerprint: "ocr-fp", mappingKind: "same-page-verified",
                                   createdAt: 0),
                    mapping: [.init(originalPage: 1, ocrPage: 1)],
                    updates: [.init(originalPage: 1, ocrPage: 1, textOriginal: "敦煌文献",
                                    textNorm: "敦煌文献", normStarts: [0, 1, 2, 3], normEnds: [1, 2, 3, 4])])
                try expectEqual(try stat(store, "bS")?.pagesWithText, 1, "applyOCRPages 后文本页数应更新")

                // 入口 6：purgeOCR（pages 的 UPDATE 写点，文本清空）
                try store.purgeOCR(bookID: "bS")
                try expectEqual(try stat(store, "bS")?.pagesWithText, 0, "purgeOCR 后文本页数应归零")
            },

            TestDesc(suite: "PagesStatsCache", name: "zeroHitExplanationSeesFreshStats") {
                let (store, dir) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                try addBook(store, id: "bA", name: "a.pdf", pages: ["alpha"])
                let service = SearchService(store: store)
                let first = try service.searchDetailed("qqzzww")
                try expectEqual(first.zeroHitExplanation?.books.count, 1)
                // 先读一次（缓存落位），再导入第二本书，再零命中一次。
                _ = try store.perBookPageStats()
                try addBook(store, id: "bB", name: "b.pdf", pages: ["beta"])
                let second = try service.searchDetailed("qqzzww")
                let books = try expectNotNil(second.zeroHitExplanation?.books)
                try expectEqual(books.count, 2, "缓存在写入口之后必须失效，零命中解释才看得到新书")
                try expectEqual(books.first { $0.bookID == "bA" }?.reason, .termNotMatched)
            },

            TestDesc(suite: "PagesStatsCache", name: "zeroHintPhaseRecorded") {
                let (store, dir) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                try addBook(store, id: "bA", name: "a.pdf", pages: ["alpha one"])
                let service = SearchService(store: store)
                let hit = try service.searchDetailed("alpha")
                try expectEqual(hit.totalPageMatches, 1)
                let hitRec = try expectNotNil(SearchPhaseTiming.lastSearchRecord)
                try expectEqual(hitRec.zeroHintMs, 0, "有命中的查询没走第五相，应记 0")
                let miss = try service.searchDetailed("qqzzww")
                try expectEqual(miss.totalPageMatches, 0)
                let missRec = try expectNotNil(SearchPhaseTiming.lastSearchRecord)
                try expectTrue(missRec.zeroHintMs > 0, "零命中查询必须记下第五相耗时")
                try expectNotNil(miss.zeroHitExplanation)
            },

            TestDesc(suite: "PagesStatsCache", name: "statsIndexGatedByOption") {
                let dirDefault = Fixtures.makeTempDir("pages-stats-default")
                defer { Fixtures.cleanup(dirDefault) }
                let plain = try Fixtures.openStore(in: dirDefault)
                try addBook(plain, id: "bA", name: "a.pdf", pages: ["one"])
                try expectFalse(try plain.hasSqliteObjectLocked(type: "index", name: "idx_pages_stats"),
                                "默认选项（App 路径）不得建页统计索引")

                let dirOptIn = Fixtures.makeTempDir("pages-stats-optin")
                defer { Fixtures.cleanup(dirOptIn) }
                let opted = try IndexStore(path: dirOptIn.appendingPathComponent("index.db"),
                                           options: IndexStore.Options(allowPageStatsStatsIndex: true))
                try addBook(opted, id: "bA", name: "a.pdf", pages: ["one", ""])
                try expectTrue(try opted.hasSqliteObjectLocked(type: "index", name: "idx_pages_stats"),
                               "显式允许时应建 idx_pages_stats")
                let plan = try opted.db.prepare("""
                EXPLAIN QUERY PLAN
                SELECT b.id, b.status, COALESCE(pg.n, 0), COALESCE(tx.m, 0)
                FROM books b
                LEFT JOIN (SELECT book_id, COUNT(page_number) AS n FROM pages GROUP BY book_id) pg ON pg.book_id = b.id
                LEFT JOIN (SELECT book_id,
                                  COALESCE(SUM(CASE WHEN TRIM(text_norm) = '' THEN 0 ELSE 1 END), 0) AS m
                             FROM pages GROUP BY book_id) tx ON tx.book_id = b.id
                ORDER BY b.rel_path;
                """)
                var lines: [String] = []
                while try plan.step() { lines.append(plan.text(3)) }
                try expectTrue(lines.contains { $0.contains("idx_pages_stats") && $0.contains("COVERING") },
                               "改写后的查询必须用 idx_pages_stats 覆盖索引，实际计划：\(lines)")
                // 门控开启后统计值仍与旧 SQL 一致。
                try expectEqual(try opted.perBookPageStats(), try legacyStats(opted))
            },
        ]
    }
}
