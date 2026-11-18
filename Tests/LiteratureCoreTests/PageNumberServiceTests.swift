import Foundation
@testable import LiteratureCore

// MARK: - 稳定页码套件（docs/PAGE-BASIS.md 语义的合同测试）
//
// 全合成：临时库 + 合成 pages 行，绝不触真实库；sidecar 一律内存 Data 注入。

enum PageNumberServiceSuite {
    static func makeStore(pageCount: Int = 10) throws -> (IndexStore, URL, String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lit-pagemap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try IndexStore(path: dir.appendingPathComponent("index.db"))
        let book = IndexStore.BookRow(
            id: "bp", realPath: "/tmp/lit-tests/p.pdf", rootPath: "/tmp/lit-tests",
            relPath: "p.pdf", fileName: "p.pdf",
            firstFingerprint: "fp-p", fingerprint: "fp-p", fileSize: 1, mtime: 0,
            pageCount: pageCount, status: "ok", indexedAt: 0)
        try store.upsertBook(book)
        return (store, dir, book.id)
    }

    static func writePages(_ store: IndexStore, bookID: String, count: Int,
                           printed: [Int: Int] = [:]) throws {
        var rows: [IndexStore.PageRow] = []
        for p in 1...max(count, 1) {
            let text = "page \(p) 内容"
            let n = normalizeForSearch(text)
            rows.append(IndexStore.PageRow(bookID: bookID, pageNumber: p, label: nil,
                                           printedPage: printed[p],
                                           textOriginal: text, textNorm: n.text,
                                           normStarts: n.starts, normEnds: n.ends))
        }
        try store.replacePages(bookID: bookID, rows)
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "PageNumberService", name: "serviceResolvesPageMapOverPagesColumn") {
                let (store, dir, bookID) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                try writePages(store, bookID: bookID, count: 10, printed: [3: 30])
                let service = PageNumberService.forStore(store)
                // 两路都无 → nil（未知，绝不猜）。
                try expectNil(service.printedPage(bookID: bookID, physical: 1))
                // pages 列有值（pages.printed_page）→ 第二路生效。
                try expectEqual(service.printedPage(bookID: bookID, physical: 3), 30)
                // page_map 声明优先于 pages 列。
                try store.upsertPageMap(bookID: bookID, physical: 3, printed: 33,
                                        sourceEdition: "测试版次")
                try expectEqual(service.printedPage(bookID: bookID, physical: 3), 33)
                try store.upsertPageMap(bookID: bookID, physical: 5, printed: 55,
                                        sourceEdition: "")
                try expectEqual(service.printedPage(bookID: bookID, physical: 5), 55)
            },

            TestDesc(suite: "PageNumberService", name: "offsetImportExpandsAndDropsNonPositivePrefix") {
                let (store, dir, bookID) = try makeStore(pageCount: 5)
                defer { Fixtures.cleanup(dir) }
                try writePages(store, bookID: bookID, count: 5)
                // 负偏移：前置罗马页场景——printed ≤ 0 的前置页拒收并计数，
                // 不中断整批。offset 模式必须带表头（从严判别防歧义）。
                let csv = "fileName,offset\np.pdf,-3,2001年第二版\n"
                let (entries, report) = try store.importPageMapSidecar(Data(csv.utf8))
                try expectEqual(entries, 1)
                try expectEqual(report.offsetBooks, ["p.pdf"])
                try expectEqual(report.acceptedRows, 2)          // (4,1) (5,2)
                try expectEqual(report.rejected.count, 1)
                try expectTrue(report.rejected[0].reason.contains("前置"),
                               "prefix drop must be reported")
                let service = PageNumberService.forStore(store)
                try expectNil(service.printedPage(bookID: bookID, physical: 1))
                try expectEqual(service.printedPage(bookID: bookID, physical: 4), 1)
                try expectEqual(service.printedPage(bookID: bookID, physical: 5), 2)
            },

            TestDesc(suite: "PageNumberService", name: "offsetImportPositiveOffsetCoversAllPages") {
                let (store, dir, bookID) = try makeStore(pageCount: 4)
                defer { Fixtures.cleanup(dir) }
                try writePages(store, bookID: bookID, count: 4)
                let csv = "fileName,offset\np.pdf,8\n"
                let (entries, report) = try store.importPageMapSidecar(Data(csv.utf8))
                try expectEqual(entries, 1)
                try expectEqual(report.acceptedRows, 4)
                try expectTrue(report.rejected.isEmpty)
                let rows = try store.pageMapRows(bookID: bookID)
                try expectEqual(rows.count, 4)
                try expectEqual(rows[0].printed, 9)
                try expectEqual(rows[3].printed, 12)
            },

            TestDesc(suite: "PageNumberService", name: "secondOffsetRowForSameBookRejected") {
                let (store, dir, bookID) = try makeStore(pageCount: 4)
                defer { Fixtures.cleanup(dir) }
                try writePages(store, bookID: bookID, count: 4)
                let csv = "fileName,offset\np.pdf,8\np.pdf,5\n"
                let (entries, report) = try store.importPageMapSidecar(Data(csv.utf8))
                try expectEqual(entries, 1, "only the first offset declaration survives")
                try expectEqual(report.acceptedRows, 4, "no double counting")
                try expectEqual(report.rejected.count, 1)
                try expectTrue(report.rejected[0].reason.contains("同书第二条 offset 行拒收"))
                let rows = try store.pageMapRows(bookID: bookID)
                try expectEqual(rows.count, 4)
                try expectEqual(rows[0].printed, 9, "first offset (+8) wins, second (+5) never lands")
            },

            TestDesc(suite: "PageNumberService", name: "explicitPairsEndToEndAndBackfill") {
                let (store, dir, bookID) = try makeStore(pageCount: 10)
                defer { Fixtures.cleanup(dir) }
                try writePages(store, bookID: bookID, count: 10)
                let csv = "fileName,physical,printed,source_edition\np.pdf,2,14,\np.pdf,7,19,第二版\n"
                let (entries, report) = try store.importPageMapSidecar(Data(csv.utf8))
                try expectEqual(entries, 1)
                try expectEqual(report.acceptedRows, 2)
                try expectTrue(report.rejected.isEmpty)
                let service = PageNumberService.forStore(store)
                try expectEqual(service.printedPage(bookID: bookID, physical: 2), 14)
                try expectEqual(service.printedPage(bookID: bookID, physical: 7), 19)
                // 回填：pages.printed_page 原 NULL 行被填（声明制落地到列轨）。
                try expectEqual(try store.printedPageColumn(bookID: bookID, physical: 2), 14)
            },

            TestDesc(suite: "PageNumberService", name: "sidecarRejectsBadRowsWithoutAborting") {
                let (store, dir, bookID) = try makeStore(pageCount: 5)
                defer { Fixtures.cleanup(dir) }
                try writePages(store, bookID: bookID, count: 5)
                let csv = """
                p.pdf,6,10
                p.pdf,x,10
                p.pdf,2,-4
                p.pdf,2,9
                p.pdf,2,8
                p.pdf,3
                other.pdf,1,1
                """
                let (_, report) = try store.importPageMapSidecar(Data(csv.utf8))
                // 逐行拒收原因：越界 / physical 非整数 / printed 负数 /
                // 同页重复（先到者胜，(2,9) 存活）/ 缺列 / 未匹配书。
                try expectEqual(report.acceptedRows, 1)          // 仅 (2,9) 存活
                try expectEqual(report.rejected.count, 5)
                try expectEqual(report.unmatchedBooks, ["other.pdf"])
                let service = PageNumberService.forStore(store)
                try expectEqual(service.printedPage(bookID: bookID, physical: 2), 9)
                try expectNil(service.printedPage(bookID: bookID, physical: 3))
            },

            TestDesc(suite: "PageNumberService", name: "backfillNeverOverwritesNonNilColumn") {
                let (store, dir, bookID) = try makeStore(pageCount: 3)
                defer { Fixtures.cleanup(dir) }
                // 物理页 2 已有列值 7（既有非空），物理页 1/3 为 NULL。
                try writePages(store, bookID: bookID, count: 3, printed: [2: 7])
                let csv = "p.pdf,1,10\np.pdf,2,20\np.pdf,3,30\n"
                let backfilled = try store.backfillPrintedPages(bookID: bookID, pairs: [
                    (physical: 1, printed: 10), (physical: 2, printed: 20),
                    (physical: 3, printed: 30)])
                try expectEqual(backfilled, 2, "only NULL rows count as backfilled")
                try expectEqual(try store.printedPageColumn(bookID: bookID, physical: 2), 7,
                                "existing non-nil value must never be overwritten")
                try expectEqual(try store.printedPageColumn(bookID: bookID, physical: 1), 10)
                try expectEqual(try store.printedPageColumn(bookID: bookID, physical: 3), 30)
            },

            TestDesc(suite: "PageNumberService", name: "schemaV6MigrationIsIdempotentOnReopen") {
                let (store, dir, bookID) = try makeStore(pageCount: 3)
                defer { Fixtures.cleanup(dir) }
                try writePages(store, bookID: bookID, count: 3)
                try store.upsertPageMap(bookID: bookID, physical: 1, printed: 11,
                                        sourceEdition: "幂等版次")
                // 重开：迁移链重跑（幂等）→ 表不重建、行保留、版本随常量。
                let path = dir.appendingPathComponent("index.db")
                let reopened = try IndexStore(path: path)
                try expectEqual(try reopened.metaValue("schema_version"),
                                String(IndexStore.currentSchemaVersion))
                try expectTrue(IndexStore.currentSchemaVersion >= 11)
                let rows = try reopened.pageMapRows(bookID: bookID)
                try expectEqual(rows.count, 1)
                try expectEqual(rows[0].printed, 11)
                try expectEqual(rows[0].edition, "幂等版次")
                // 幂等：对同一库再次全量迁移（importPageMap 重复 upsert 同页）。
                try reopened.upsertPageMap(bookID: bookID, physical: 1, printed: 12,
                                           sourceEdition: "幂等版次")
                try expectEqual(try reopened.pageMapRows(bookID: bookID).count, 1)
                try expectEqual(try reopened.pageMapPrinted(bookID: bookID, physical: 1), 12)
            },

            TestDesc(suite: "PageNumberService", name: "headerSniffingAndTwoTrackSynthesis") {
                let (store, dir, bookID) = try makeStore(pageCount: 3)
                defer { Fixtures.cleanup(dir) }
                try writePages(store, bookID: bookID, count: 3)
                let service = PageNumberService.forStore(store)
                // 导入前两路皆无 → nil（未知照实）。
                try expectNil(service.printedPage(bookID: bookID, physical: 1))
                // 表头判别（offset 模式必须带表头）+ 空行跳过 + 引号包裹文件名。
                let csv = "fileName,offset\n\"p.pdf\",5\n\n"
                let (entries, report) = try store.importPageMapSidecar(Data(csv.utf8))
                try expectEqual(entries, 1)
                try expectEqual(report.acceptedRows, 3)
                try expectEqual(service.printedPage(bookID: bookID, physical: 1), 6)
                // 删除 page_map（显式 API）→ 回填过的 pages 列声明仍在
                // （两路合成的正确语义：第二路接住）。
                try store.deletePageMap(bookID: bookID)
                try expectEqual(service.printedPage(bookID: bookID, physical: 1), 6)
                // 无表头的 offset 形态不识别（从严判别）→ 按显式对缺列拒收。
                let ambiguous = "p.pdf,5\n"
                let (_, report2) = try store.importPageMapSidecar(Data(ambiguous.utf8))
                try expectEqual(report2.acceptedRows, 0)
                try expectTrue(report2.rejected.contains { $0.reason.contains("显式对需") })
            },
        ]
    }
}
