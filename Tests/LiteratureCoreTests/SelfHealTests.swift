import Foundation
@testable import LiteratureCore

// MARK: -：索引自愈 + schema 版本门禁 suite
//
// 覆盖：倒排表缺失/被清空 → 重开自愈重建（meta 记录、检索恢复）；
// 版本门禁两分支（高版本拒开、低版本放行迁移写回现行值）。

enum SelfHealSuite {
    static func makeStore(in dir: URL) throws -> IndexStore {
        // 自愈是显式维护操作；本 suite 专门验证它，所以 opt in。
        try IndexStore(path: dir.appendingPathComponent("index.db"),
                       options: .init(performExpensiveSelfHeal: true))
    }

    @discardableResult
    static func addBook(_ store: IndexStore, id: String, pages: [String]) throws -> IndexStore.BookRow {
        let book = IndexStore.BookRow(
            id: id, realPath: "/tmp/lit-tests/\(id).pdf", rootPath: "/tmp/lit-tests",
            relPath: "\(id).pdf", fileName: "\(id).pdf",
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

    /// 建库 + 写页 + 建成倒排表（built 且 dirty=0 的健康标记态）。
    static func makeHealthyStore(dir: URL, term: String, hitText: String) throws -> IndexStore {
        let store = try makeStore(in: dir)
        try addBook(store, id: "bH", pages: [hitText, "unrelated filler text", "more filler"])
        try expectTrue(try store.ensureBigramIndexFresh(), "首次必须实际重建倒排表")
        let viaIndex = try store.candidatePageIDsViaInvertedIndex(bigrams: [term])
        try expectTrue(viaIndex?.isEmpty == false, "健康态倒排表必须能命中测试词")
        return store
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "SelfHeal", name: "droppedInvertedIndexTableSelfHealsOnReopen") {
                let dir = Fixtures.makeTempDir("selfheal-drop")
                defer { Fixtures.cleanup(dir) }
                let store = try makeHealthyStore(dir: dir, term: "样书", hitText: "样书一与效力")
                // 模拟损坏：直接 DROP 倒排表（含健康标记仍在）。
                try expectTrue(store.db.tryExec("DROP TABLE bigram_index;"), "测试前置 DROP 必须成功")
                // 重开：自检发现表缺失 → 自动 DROP+DDL 重建+全量重填。
                let reopened = try makeStore(in: dir)
                try expectEqual(try reopened.metaValue("last_selfheal_ok"), "1")
                let reason = try expectNotNil(try reopened.metaValue("last_selfheal_reason"))
                // migrate 的 CREATE IF NOT EXISTS 会先把缺失表补成空表，
                // 故自检原因可能落在"表缺失"或"空表"分支，两者都算自愈到位。
                try expectTrue(reason.contains("缺失") || reason.contains("为空"),
                               "留痕原因应指出异常: \(reason)")
                try expectNotNil(try reopened.metaValue("last_selfheal_at"))
                // 重建后检索恢复：倒排查询命中。
                let after = try reopened.candidatePageIDsViaInvertedIndex(bigrams: ["样书"])
                try expectTrue(after?.isEmpty == false, "自愈后倒排表必须重新可命中")
                try expectEqual(try reopened.metaValue("bidx_dirty"), "0")
            },

            TestDesc(suite: "SelfHeal", name: "emptiedInvertedIndexWithHealthyMarkerSelfHeals") {
                let dir = Fixtures.makeTempDir("selfheal-empty")
                defer { Fixtures.cleanup(dir) }
                let store = try makeHealthyStore(dir: dir, term: "权利", hitText: "权利能力与行为能力")
                try expectTrue(store.db.tryExec("DELETE FROM bigram_index;"), "测试前置清空必须成功")
                // 表还在但空，且 bidx_built_at 存在、bidx_dirty=0 —— 行数比例
                // sanity 必须判为异常并自愈（静默零命中故障类）。
                let reopened = try makeStore(in: dir)
                try expectEqual(try reopened.metaValue("last_selfheal_ok"), "1")
                let reason = try expectNotNil(try reopened.metaValue("last_selfheal_reason"))
                try expectTrue(reason.contains("为空"), "留痕原因应指出空表: \(reason)")
                let after = try reopened.candidatePageIDsViaInvertedIndex(bigrams: ["权利"])
                try expectTrue(after?.isEmpty == false, "自愈后倒排表必须重新可命中")
            },

            TestDesc(suite: "SelfHeal", name: "healthyQuickCheckWithinThrottleLeavesNoHealTrace") {
                let dir = Fixtures.makeTempDir("selfheal-healthy")
                defer { Fixtures.cleanup(dir) }
                _ = try makeHealthyStore(dir: dir, term: "正义", hitText: "作为公平的正义")
                let reopened = try makeStore(in: dir)
                try expectNil(try reopened.metaValue("last_selfheal_ok"), "健康库不得触发自愈")
                try expectNil(try reopened.metaValue("last_selfheal_reason"))
                // 首次 quick_check 成功后必须记录时间戳（节流标记）。
                try expectNotNil(try reopened.metaValue("quickcheck_ok_at"))
            },

            TestDesc(suite: "SelfHeal", name: "newerSchemaVersionIsRejectedFailClosed") {
                let dir = Fixtures.makeTempDir("selfheal-gate-high")
                defer { Fixtures.cleanup(dir) }
                _ = try makeStore(in: dir)   // 建库并写入现行版本
                // 模拟"未来版本应用"写下的更高版本号。
                let raw = try SQLiteDatabase(path: dir.appendingPathComponent("index.db").path)
                try raw.exec("UPDATE meta SET value='999' WHERE key='index_schema_version';")
                try expectThrows(try makeStore(in: dir),
                                 "库版本高于应用已知版本必须拒绝打开（不静默降级）")
            },

            TestDesc(suite: "SelfHeal", name: "olderSchemaVersionOpensAndMigratesToCurrent") {
                let dir = Fixtures.makeTempDir("selfheal-gate-low")
                defer { Fixtures.cleanup(dir) }
                _ = try makeStore(in: dir)
                let raw = try SQLiteDatabase(path: dir.appendingPathComponent("index.db").path)
                try raw.exec("UPDATE meta SET value='4' WHERE key='index_schema_version';")
                let reopened = try makeStore(in: dir)
                // 低于现行版本 → 正常打开，迁移链把版本写回现行值。
                try expectEqual(try reopened.metaValue(IndexStore.indexSchemaVersionMetaKey),
                                String(IndexStore.currentSchemaVersion))
                // schema_version 写值随 currentSchemaVersion 常量走。
                try expectEqual(try reopened.metaValue("schema_version"),
                                String(IndexStore.currentSchemaVersion))
            },

            TestDesc(suite: "SelfHeal", name: "freshDatabaseRecordsCurrentSchemaVersion") {
                let dir = Fixtures.makeTempDir("selfheal-fresh")
                defer { Fixtures.cleanup(dir) }
                let store = try makeStore(in: dir)
                try expectEqual(try store.metaValue(IndexStore.indexSchemaVersionMetaKey),
                                String(IndexStore.currentSchemaVersion))
                // 现行版本 = 6（page_map 表）。断言住常量防误降。
                try expectTrue(IndexStore.currentSchemaVersion >= 11)
            },
        ]
    }
}
