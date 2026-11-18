import Foundation
@testable import LiteratureCore

// MARK: -：sessions 表 + SessionLedger 套件
//
// 契约：round-trip 保序；active 唯一；'pdf'/'workbench' 双类型
// 行读回分派正确；整表替换幂等；空表读=空数组；未知 tab_type 行跳过；
// SessionLedger 纯函数（opened 去重后移／closed／activated／rows 组行）各一
// 例以上；坏页值（0/负数）如实落库不崩。

enum ReadingSessionStoreSuite {
    static func makeStore(_ tag: String) throws -> ReadingSessionStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sessions-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: dir.appendingPathComponent("annotations.db").path)
        return ReadingSessionStore(db: db)
    }

    static func row(tab: Int, type: String = "pdf", book: String = "bA",
                    secondary: String? = nil, page: Int = 1,
                    active: Bool = false, updated: Double = 100) -> SessionRow {
        SessionRow(tabIndex: tab, tabType: type, bookID: book,
                   secondaryBookID: secondary, page: page,
                   isActive: active, updatedAt: updated)
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "ReadingSessionStore", name: "ddlIdempotentAndSubschemaVersioned") {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("sessions-ddl-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let db = try SQLiteDatabase(path: dir.appendingPathComponent("annotations.db").path)
                _ = ReadingSessionStore(db: db)
                _ = ReadingSessionStore(db: db)
                let probe = ReadingSessionStore(db: db)
                try expectEqual(probe.storedSubschemaVersion, 1)
                try expectTrue(try probe.readSession().isEmpty)
            },

            TestDesc(suite: "ReadingSessionStore", name: "roundTripPreservesOrder") {
                let store = try makeStore("rt")
                try store.writeSession([
                    row(tab: 0, book: "bA", page: 3, active: true),
                    row(tab: 1, book: "bB", page: 7),
                    row(tab: 2, book: "bC", page: 2),
                ])
                let rows = try store.readSession()
                try expectEqual(rows.map(\.bookID), ["bA", "bB", "bC"])
                try expectEqual(rows.map(\.page), [3, 7, 2])
                try expectEqual(rows.first?.isActive, true)
                try expectEqual(rows.last?.isActive, false)
            },

            TestDesc(suite: "ReadingSessionStore", name: "writeReplacesWholeTable") {
                let store = try makeStore("repl")
                try store.writeSession([row(tab: 0, book: "bA"), row(tab: 1, book: "bB")])
                try store.writeSession([row(tab: 0, book: "bC", active: true)])
                let rows = try store.readSession()
                try expectEqual(rows.map(\.bookID), ["bC"], "旧行全部清除（整表替换）")
                try expectEqual(rows.first?.isActive, true)
            },

            TestDesc(suite: "ReadingSessionStore", name: "pdfAndTabRowsRoundTrip") {
                let store = try makeStore("types")
                try store.writeSession([
                    row(tab: 0, book: "bA", page: 5, active: true),
                    row(tab: 1, type: "workbench", book: "bA", secondary: "bB", page: 1),
                ])
                let rows = try store.readSession()
                try expectEqual(rows.count, 2)
                try expectEqual(rows[0].tabType, "pdf")
                try expectNil(rows[0].secondaryBookID)
                try expectEqual(rows[1].tabType, "workbench")
                try expectEqual(rows[1].secondaryBookID, "bB")
                try expectEqual(rows[1].bookID, "bA", "workbench 行 book_id＝主文档")
                // 活动分派目标＝active 行（此处 pdf 行）。
                let active = rows.first { $0.isActive }
                try expectEqual(active?.tabType, "pdf")
            },

            TestDesc(suite: "ReadingSessionStore", name: "emptyAndClearReadAsEmpty") {
                let store = try makeStore("empty")
                try expectTrue(try store.readSession().isEmpty)
                try store.writeSession([row(tab: 0)])
                try store.clear()
                try expectTrue(try store.readSession().isEmpty)
            },

            TestDesc(suite: "ReadingSessionStore", name: "unknownTabTypeRowsSkipped") {
                let store = try makeStore("unknown")
                try store.writeSession([
                    row(tab: 0, book: "bA", active: true),
                    row(tab: 1, type: "future-widget", book: "bX"),
                ])
                let rows = try store.readSession()
                try expectEqual(rows.count, 1)
                try expectEqual(rows.first?.bookID, "bA")
            },

            TestDesc(suite: "ReadingSessionStore", name: "badPageValuesStoredAsIs") {
                let store = try makeStore("badpage")
                try store.writeSession([row(tab: 0, book: "bA", page: 0),
                                        row(tab: 1, book: "bB", page: -3)])
                let rows = try store.readSession()
                try expectEqual(rows.map(\.page), [0, -3], "坏值不崩、不静默改写")
            },

            TestDesc(suite: "ReadingSessionStore", name: "ledgerOpenedDedupesAndMovesToEnd") {
                var ledger = SessionLedger()
                ledger.opened("bA")
                ledger.opened("bB")
                ledger.opened("bA")
                try expectEqual(ledger.entries.map(\.bookID), ["bB", "bA"],
                                "同书重开移到末尾，不重复")
                try expectEqual(ledger.entries.count, 2)
            },

            TestDesc(suite: "ReadingSessionStore", name: "ledgerClosedRemovesPrimary") {
                var ledger = SessionLedger()
                ledger.opened("bA")
                ledger.opened("bB", secondary: "bC", tabType: "workbench")
                ledger.closed("bB")   // 默认 pdf：不应动 workbench 行
                try expectEqual(ledger.entries.count, 2,
                                "关 PDF 不连带清同书 workbench 行（互不覆写）")
                ledger.closed("bB", tabType: "workbench")
                try expectEqual(ledger.entries.map(\.bookID), ["bA"],
                                "workbench 行按自身 tabType 出账")
                ledger.closed("missing", tabType: "pdf")
                try expectEqual(ledger.entries.count, 1, "关不存在书零副作用")
            },

            TestDesc(suite: "ReadingSessionStore", name: "ledgerActivatedMatchesTabType") {
                var ledger = SessionLedger()
                ledger.opened("bA", secondary: "bX", tabType: "workbench")
                ledger.opened("bA")
                ledger.activated("bA")   // 默认 pdf
                try expectEqual(ledger.entries.first { $0.tabType == "workbench" }?.isActive,
                                false, "激活 PDF 不点亮同书 workbench 行")
                try expectEqual(ledger.entries.last { $0.tabType == "pdf" }?.isActive,
                                true, "pdf 行被点亮（workbench 先入账不命中错行）")
                ledger.activated("bA", tabType: "workbench")
                try expectEqual(ledger.entries.first { $0.tabType == "workbench" }?.isActive,
                                true, "显式 workbench 激活命中")
                try expectEqual(ledger.entries.last { $0.tabType == "pdf" }?.isActive,
                                false, "active 唯一跨 tabType 仍然成立")
            },

            TestDesc(suite: "ReadingSessionStore", name: "ledgerActivatedIsUnique") {
                var ledger = SessionLedger()
                ledger.opened("bA")
                ledger.opened("bB")
                ledger.activated("bA")
                try expectEqual(ledger.entries.first { $0.bookID == "bA" }?.isActive, true)
                try expectEqual(ledger.entries.first { $0.bookID == "bB" }?.isActive, false)
                ledger.activated("bB")
                try expectEqual(ledger.entries.first { $0.bookID == "bA" }?.isActive, false,
                                "旧 active 清零")
                try expectEqual(ledger.entries.first { $0.bookID == "bB" }?.isActive, true)
                ledger.activated("missing")
                try expectTrue(ledger.entries.allSatisfy { !$0.isActive },
                                "无匹配条目零变化（不隐式开账）")
            },

            TestDesc(suite: "ReadingSessionStore", name: "ledgerRowsComposeSessionRows") {
                var ledger = SessionLedger()
                ledger.opened("bA")
                ledger.opened("bB", secondary: "bC", tabType: "workbench")
                ledger.activated("bB", tabType: "workbench")
                let rows = ledger.rows(positions: ["bA": 9], updatedAt: 555)
                try expectEqual(rows.count, 2)
                try expectEqual(rows[0].tabIndex, 0)
                try expectEqual(rows[0].page, 9)
                try expectEqual(rows[0].isActive, false)
                try expectEqual(rows[1].tabType, "workbench")
                try expectEqual(rows[1].secondaryBookID, "bC")
                try expectEqual(rows[1].page, 1, "位置缺失回 1（不猜）")
                try expectEqual(rows[1].isActive, true)
                try expectEqual(rows[1].updatedAt, 555)
                // 纯函数：同输入同输出。
                let again = ledger.rows(positions: ["bA": 9], updatedAt: 555)
                try expectEqual(rows, again)
            },

            TestDesc(suite: "ReadingSessionStore", name: "ledgerToStoreRoundTrip") {
                let store = try makeStore("e2e")
                var ledger = SessionLedger()
                ledger.opened("bA")
                ledger.opened("bB", secondary: "bC", tabType: "workbench")
                ledger.activated("bA")
                try store.writeSession(ledger.rows(positions: ["bA": 4, "bB": 8],
                                                   updatedAt: 77))
                let rows = try store.readSession()
                try expectEqual(rows.count, 2)
                try expectEqual(rows.first { $0.isActive }?.bookID, "bA")
                try expectEqual(rows.first { $0.tabType == "workbench" }?.secondaryBookID, "bC")
                try expectEqual(rows.map(\.page), [4, 8])
            },
        ]
    }
}
