import Foundation
@testable import LiteratureCore

// MARK: - 批注聚合查询层套件（全部合成库）
//
// 断言固定：跨书分页（limit/offset 边界与稳定性）、created_at 闭开区间四组合、
// 软删/恢复对三类既有查询与聚合查询的同时生效、墓碑幂等语义、created_at
// 索引幂等（迁移 + .bak 重建两处）、分页+软删组合的 OFFSET 语义如实性。

enum HighlightAggregationSuite {

    static func makeStore() throws -> (HighlightStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lit-agg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let index = try IndexStore(path: dir.appendingPathComponent("index.db"))
        return (HighlightStore(indexStore: index), dir)
    }

    /// 受控 created_at 写入（insertRowLocked internal，调用方持锁的契约在
    /// 单线程测试内以显式 lock.lock 满足）。
    @discardableResult
    static func add(_ store: HighlightStore, book: String, page: Int = 1,
                    note: String = "", createdAt: Date = Date(),
                    viewSource: String = HighlightStore.viewSourceOCR,
                    style: String = "highlight", anchor: String = "锚文本") throws -> Int64 {
        let pending = HighlightStore.PendingHighlight(
            bookID: book, pageNumber: page, utf16Start: 0, utf16End: 10,
            color: .yellow, note: note, createdAt: createdAt.timeIntervalSince1970,
            anchorText: anchor, anchorVerified: anchor.isEmpty ? 0 : 1,
            style: style, viewSource: viewSource)
        store.lock.lock(); defer { store.lock.unlock() }
        return try store.insertRowLocked(pending)
    }

    /// 页级批注（(0,0) 占位 + 空锚）。
    @discardableResult
    static func addPageNote(_ store: HighlightStore, book: String, page: Int,
                            note: String, createdAt: Date = Date()) throws -> Int64 {
        let pending = HighlightStore.PendingHighlight(
            bookID: book, pageNumber: page, utf16Start: 0, utf16End: 0,
            color: .yellow, note: note, createdAt: createdAt.timeIntervalSince1970,
            anchorText: "", anchorVerified: 0, style: "highlight",
            viewSource: HighlightStore.viewSourceOCR)
        store.lock.lock(); defer { store.lock.unlock() }
        return try store.insertRowLocked(pending)
    }

    static func createdIndexCount(_ store: HighlightStore) throws -> Int {
        let stmt = try store.db.prepare("""
            SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_user_highlights_created';
            """)
        var count = 0
        if try stmt.step() { count = Int(stmt.int(0)) }
        return count
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "HighlightAggregation", name: "countExcludesSoftDeleted") {
                let (store, _) = try makeStore()
                try add(store, book: "bA")
                try add(store, book: "bA")
                try add(store, book: "bB")
                try expectEqual(try store.allHighlightsCount(), 3)
                try store.softDelete(id: 2)
                try expectEqual(try store.allHighlightsCount(), 2)
                try store.restore(id: 2)
                try expectEqual(try store.allHighlightsCount(), 3)
            },

            TestDesc(suite: "HighlightAggregation", name: "paginationWindowsAreStable") {
                let (store, _) = try makeStore()
                for i in 0..<7 {
                    try add(store, book: "bA", createdAt: Date(timeIntervalSince1970: 1000 + Double(i)))
                }
                // 全量取回 = 7；每页 3 → 3 页，末页 1 条。
                try expectEqual(try store.allHighlights(limit: 50, offset: 0).count, 7)
                try expectEqual(try store.allHighlights(limit: 3, offset: 0).count, 3)
                try expectEqual(try store.allHighlights(limit: 3, offset: 3).count, 3)
                try expectEqual(try store.allHighlights(limit: 3, offset: 6).count, 1)
                // 越界窗口 = 空页（如实，不报错）。
                try expectEqual(try store.allHighlights(limit: 3, offset: 9).count, 0)
                // 稳定序：created_at DESC（最新在前）。
                let first = try expectNotNil(try store.allHighlights(limit: 1, offset: 0).first)
                try expectEqual(first.id, Int64(7))
            },

            TestDesc(suite: "HighlightAggregation", name: "sameCreatedAtBreaksTieByIdDesc") {
                let (store, _) = try makeStore()
                let same = Date(timeIntervalSince1970: 42)
                let a = try add(store, book: "bA", createdAt: same)
                let b = try add(store, book: "bA", createdAt: same)
                let c = try add(store, book: "bA", createdAt: same)
                let ids = try store.allHighlights(limit: 10, offset: 0).map(\.id)
                try expectEqual(ids, [c, b, a], "same-second writes order by id DESC")
            },

            TestDesc(suite: "HighlightAggregation", name: "invalidWindowThrows") {
                let (store, _) = try makeStore()
                try expectThrows(try store.allHighlights(limit: 0, offset: 0))
                try expectThrows(try store.allHighlights(limit: -1, offset: 0))
                try expectThrows(try store.allHighlights(limit: 5, offset: -1))
                try expectThrows(try store.highlightsCreated(from: nil, to: nil, limit: 0, offset: 0))
                try expectThrows(try store.highlightsCreated(from: nil, to: nil, limit: 5, offset: -2))
            },

            TestDesc(suite: "HighlightAggregation", name: "viewSourceFilterOnAggregation") {
                let (store, _) = try makeStore()
                try add(store, book: "bA", viewSource: HighlightStore.viewSourceOCR)
                try add(store, book: "bA", viewSource: HighlightStore.viewSourceOriginal)
                try expectEqual(try store.allHighlights(limit: 10, offset: 0, viewSource: HighlightStore.viewSourceOCR).count, 1)
                try expectEqual(try store.allHighlights(limit: 10, offset: 0, viewSource: HighlightStore.viewSourceOriginal).count, 1)
                try expectEqual(try store.allHighlights(limit: 10, offset: 0, viewSource: nil).count, 2)
            },

            TestDesc(suite: "HighlightAggregation", name: "bookCountsSplitTotalAndWithNote") {
                let (store, _) = try makeStore()
                try add(store, book: "bA", note: "有注")
                try add(store, book: "bA")
                try add(store, book: "bA", note: "又有注")
                try add(store, book: "bB")
                let counts = try store.highlightsByBookCounts()
                let byID = Dictionary(uniqueKeysWithValues: counts.map { ($0.bookID, $0) })
                try expectEqual(byID["bA"]?.total, 3)
                try expectEqual(byID["bA"]?.withNote, 2)
                try expectEqual(byID["bB"]?.total, 1)
                try expectEqual(byID["bB"]?.withNote, 0)
                // 软删行不进分组。
                try store.softDelete(id: 1)
                let after = try store.highlightsByBookCounts()
                let aAfter = after.first { $0.bookID == "bA" }
                try expectEqual(aAfter?.total, 2)
                try expectEqual(aAfter?.withNote, 1)
            },

            TestDesc(suite: "HighlightAggregation", name: "createdRangeClosedOpenFourCombos") {
                let (store, _) = try makeStore()
                try add(store, book: "bA", createdAt: Date(timeIntervalSince1970: 100))
                try add(store, book: "bA", createdAt: Date(timeIntervalSince1970: 200))
                try add(store, book: "bA", createdAt: Date(timeIntervalSince1970: 300))
                let from = Date(timeIntervalSince1970: 200)
                let to = Date(timeIntervalSince1970: 300)
                // [200, 300)：含 200 不含 300 → 1 条。
                try expectEqual(try store.highlightsCreated(from: from, to: to, limit: 10, offset: 0).count, 1)
                // [200, ∞)：2 条。
                try expectEqual(try store.highlightsCreated(from: from, to: nil, limit: 10, offset: 0).count, 2)
                // (-∞, 300)：2 条。
                try expectEqual(try store.highlightsCreated(from: nil, to: to, limit: 10, offset: 0).count, 2)
                // 全不设限：3 条。
                try expectEqual(try store.highlightsCreated(from: nil, to: nil, limit: 10, offset: 0).count, 3)
                // 计数与列表一致。
                try expectEqual(try store.highlightsCreatedCount(from: from, to: to), 1)
                try expectEqual(try store.highlightsCreatedCount(from: nil, to: nil), 3)
            },

            TestDesc(suite: "HighlightAggregation", name: "softDeleteHidesFromExistingAndAggregationQueries") {
                let (store, _) = try makeStore()
                let id = try add(store, book: "bA", page: 3)
                try add(store, book: "bA", page: 3, note: "留存")
                // 三类既有查询（按书/按页/verified 汇总）批前都可见。
                try expectEqual(try store.highlightsForBook("bA", viewSource: nil).count, 2)
                try expectEqual(try store.highlightsForPage(bookID: "bA", pageNumber: 3, viewSource: nil).count, 2)
                try expectEqual(try store.verifiedHighlightsForBook("bA", viewSource: nil).count, 2)
                try store.softDelete(id: id)
                // 软删后：既有查询与聚合查询同步不可见（deleted_at IS NULL 过滤已在位）。
                try expectEqual(try store.highlightsForBook("bA", viewSource: nil).count, 1)
                try expectEqual(try store.highlightsForPage(bookID: "bA", pageNumber: 3, viewSource: nil).count, 1)
                try expectEqual(try store.verifiedHighlightsForBook("bA", viewSource: nil).count, 1)
                try expectEqual(try store.allHighlights(limit: 10, offset: 0).count, 1)
                try expectEqual(try store.highlightsCreated(from: nil, to: nil, limit: 10, offset: 0).count, 1)
                // restore 后原样回来。
                try store.restore(id: id)
                try expectEqual(try store.highlightsForBook("bA", viewSource: nil).count, 2)
            },

            TestDesc(suite: "HighlightAggregation", name: "tombstoneSemanticsRejectDoubleTransitions") {
                let (store, _) = try makeStore()
                let id = try add(store, book: "bA")
                try expectThrows(try store.restore(id: id), "未删行不可恢复")
                try store.softDelete(id: id)
                try expectThrows(try store.softDelete(id: id), "已删行不可二次软删")
                try store.restore(id: id)
                try expectThrows(try store.softDelete(id: 999), "不存在的行抛错")
            },

            TestDesc(suite: "HighlightAggregation", name: "createdAtIndexIdempotentAcrossReopenAndRestore") {
                let (store, dir) = try makeStore()
                try add(store, book: "bA")
                try expectEqual(try createdIndexCount(store), 1)
                // 重开库：迁移幂等，无重复索引。
                let index = try IndexStore(path: dir.appendingPathComponent("index.db"))
                let reopened = HighlightStore(indexStore: index)
                try expectEqual(try createdIndexCount(reopened), 1)
                // 真实损坏→.bak 回退路径（init 先 verifyIntegrity 回退、后迁移
                // 补列）：DROP 表制造损坏后重开新 store——重建 DDL 必须补回
                // created_at 索引，迁移再补齐 三列。
                try add(reopened, book: "bA", note: "second")
                reopened.lock.withLock {
                    reopened.writeBackupSnapshotLocked()
                    _ = reopened.db.tryExec("DROP TABLE user_highlights;")
                }
                let afterCrash = HighlightStore(indexStore: index)
                try expectEqual(try createdIndexCount(afterCrash), 1,
                                ".bak 重建 DDL 补回 created_at 索引")
                try expectEqual(try afterCrash.allHighlightsCount(), 2, "重建后行数不丢")
            },

            TestDesc(suite: "HighlightAggregation", name: "paginationWithSoftDeleteOffsetShiftsHonestly") {
                let (store, _) = try makeStore()
                // 5 条按 created_at 升序写入（id 1..5，列表序为 5,4,3,2,1）。
                for i in 1...5 {
                    try add(store, book: "bA", createdAt: Date(timeIntervalSince1970: Double(i)))
                }
                let window1 = try store.allHighlights(limit: 2, offset: 0).map(\.id)
                try expectEqual(window1, [5, 4])
                // 删掉列表第 2 行（id=4）后，同 offset=0 窗口前移（OFFSET 分页
                // 在删除发生时的固有语义——如实断言并在视图层如实标注已加载/
                // 总数，不做游标分页）。
                try store.softDelete(id: 4)
                let window1After = try store.allHighlights(limit: 2, offset: 0).map(\.id)
                try expectEqual(window1After, [5, 3])
            },

            TestDesc(suite: "HighlightAggregation", name: "subSchemaVersionStaysAt8") {
                let (store, _) = try makeStore()
                try expectEqual(store.userHighlightsSubSchemaVersion(), 8,
                                "本次零列变化：子 schema 维持 8 不 bump")
            },

            TestDesc(suite: "HighlightAggregation", name: "grouperKeepsOrderAndUnknownBucket") {
                let base = Date(timeIntervalSince1970: 10)
                let mk: (String, Int64) -> UserHighlight = { book, id in
                    UserHighlight(id: id, bookID: book, pageNumber: 1, utf16Start: 0,
                                  utf16End: 5, color: .yellow, note: "", createdAt: base)
                }
                let items = [mk("bA", 1), mk("bB", 2), mk("bA", 3), mk("未知书", 4)]
                let grouped = UserHighlightGrouper.group(items, knownBookIDs: ["bA", "bB"])
                // 组间序 = 首现序；未知 bookID 归保留组不丢行。
                try expectEqual(grouped.map(\.bookID), ["bA", "bB", ""])
                try expectEqual(grouped[0].items.map(\.id), [1, 3])
                try expectEqual(grouped[2].items.map(\.id), [4])
                try expectEqual(grouped.flatMap(\.items).count, 4, "分组绝不丢行")
                // 无册时全按 bookID 分组。
                let plain = UserHighlightGrouper.group(items)
                try expectEqual(plain.map(\.bookID), ["bA", "bB", "未知书"])
            },

            TestDesc(suite: "HighlightAggregation", name: "hardDeleteAPIPreservedUntouched") {
                let (store, _) = try makeStore()
                let id = try add(store, book: "bA")
                // 硬删 API 保留（既有测试与外部语义不动）；软删行走墓碑路径。
                try store.delete(id: id)
                try expectEqual(try store.allHighlightsCount(), 0)
                try expectThrows(try store.restore(id: id), "硬删后无墓碑可恢复")
            },
        ]
    }
}
