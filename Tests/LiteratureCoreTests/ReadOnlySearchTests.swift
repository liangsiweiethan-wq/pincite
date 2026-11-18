import Foundation
@testable import LiteratureCore

// MARK: -：检索只读通道（IndexStore 只读形态 + 门禁特化）
//
// 核心用例 = 双开一致性：同一合成库正常开
// 与只读开，检索结果全等。只读纪律断言：meta 写 no-op（库文件 sha 不变）、
// 高/低版本门禁 fail-closed、低版本库只读开零迁移。

enum ReadOnlySearchSuite {
    /// 合成库（两本书多页；正常开一次完成迁移与倒排，供只读形态复用）。
    static func makeLibrary(tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ro-search-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("index.db")
        let store = try IndexStore(path: url)
        try CoverageClassificationSuite.addBook(store, id: "bA", name: "a.pdf",
                                         pages: ["norm appears here", "second page plain", "norm again deeper"])
        try CoverageClassificationSuite.addBook(store, id: "bB", name: "b.pdf",
                                         pages: ["other text entirely", "norm on page two"])
        try store.setNormalizationVersion()
        return url
    }

    static func sha(of url: URL) -> String {
        (try? Fingerprint.sha256Hex(ofFileAt: url)) ?? "<sha-failed>"
    }

    /// 直接开 RW 连接改 meta（模拟高/低版本库；多连接写入，不碰 IndexStore API）。
    static func setSchemaVersion(_ v: Int, at url: URL) throws {
        let db = try SQLiteDatabase(path: url.path)
        defer { _ = try? db.exec("PRAGMA wal_checkpoint(TRUNCATE);") }
        let stmt = try db.prepare(
            "INSERT INTO meta(key, value) VALUES('index_schema_version', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;")
        try stmt.bindText(1, String(v))
        try stmt.run()
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "ReadOnlySearch", name: "readOnlyOpenMatchesNormalOpenResultsExactly") {
                let url = try makeLibrary(tag: "dual")
                let normal = try IndexStore(path: url)
                let normalService = SearchService(store: normal)
                let ro = try IndexStore(path: url, options: .init(readOnlyReplica: true))
                let roService = SearchService(store: ro)

                let nBooks = try normalService.matchingBooks("norm")
                let rBooks = try roService.matchingBooks("norm")
                try expectEqual(rBooks, nBooks, "书目级聚合必须全等")
                try expectEqual(nBooks.count, 2)

                let nDetailed = try normalService.searchDetailed("norm")
                let rDetailed = try roService.searchDetailed("norm")
                try expectEqual(rDetailed.hits, nDetailed.hits, "页级命中必须全等")
                try expectEqual(rDetailed.totalPageMatches, nDetailed.totalPageMatches)
                try expectEqual(rDetailed.truncated, nDetailed.truncated)
                // 多词查询同样全等（含 LIKE/倒排候选路径）。
                try expectEqual(try roService.searchDetailed("norm here").hits,
                                try normalService.searchDetailed("norm here").hits)
            },

            TestDesc(suite: "ReadOnlySearch", name: "higherSchemaReplicaRejectedAskingUpgrade") {
                let url = try makeLibrary(tag: "high")
                try setSchemaVersion(IndexStore.currentSchemaVersion + 1, at: url)
                var thrown: Error?
                do {
                    _ = try IndexStore(path: url, options: .init(readOnlyReplica: true))
                } catch { thrown = error }
                let err = try expectNotNil(thrown, "高版本副本必须拒开")
                let text = String(describing: err)
                try expectTrue(text.contains("升级"), "错误消息必须含「升级」: \(text)")
            },

            TestDesc(suite: "ReadOnlySearch", name: "lowerSchemaReplicaRejectedWithoutMigration") {
                let url = try makeLibrary(tag: "low")
                try setSchemaVersion(IndexStore.currentSchemaVersion - 1, at: url)
                let before = sha(of: url)
                var thrown: Error?
                do {
                    _ = try IndexStore(path: url, options: .init(readOnlyReplica: true))
                } catch { thrown = error }
                let err = try expectNotNil(thrown, "低版本副本必须拒开")
                let text = String(describing: err)
                try expectTrue(text.contains("迁移") || text.contains("Mac"), "消息须指回 Mac 重建: \(text)")
                try expectEqual(sha(of: url), before, "拒开 = 库文件字节零变化（零迁移）")
            },

            TestDesc(suite: "ReadOnlySearch", name: "setMetaValueIsNoOpAndSearchStillWorks") {
                let url = try makeLibrary(tag: "noop")
                let ro = try IndexStore(path: url, options: .init(readOnlyReplica: true))
                let before = sha(of: url)
                // qt:/qc: 查询级缓存写走 setMetaValueLocked 卫语句——必须 no-op 不抛。
                try expectNoThrow(try ro.setMetaValue("qc:norm", "[]"))
                try expectNoThrow(try ro.setMetaValue("search_mode", "like-fallback"))
                try expectEqual(sha(of: url), before, "meta 写必须零落盘（no-op）")
                // 检索正常出结果（缓存写被放弃不影响结果）。
                let service = SearchService(store: ro)
                let result = try service.searchDetailed("norm")
                try expectFalse(result.hits.isEmpty)
                // 再读一次 meta 确认值未被写入。
                try expectNil(try ro.metaValue("qc:norm"), "qc 键不得落库")
            },

            TestDesc(suite: "ReadOnlySearch", name: "readOnlyHandleSurvivesModeProbesAndMacDefaultUnchanged") {
                let url = try makeLibrary(tag: "pragma")
                let ro = try IndexStore(path: url, options: .init(readOnlyReplica: true))
                // searchMode 由本机能力决定（与写入侧一致），只读分支不写
                // search_mode meta，查询走倒排/FTS/LIKE 均零写。
                try expectFalse(try ro.candidatePageIDs(term: "norm").isEmpty)
                // macOS 默认路径：Options 默认 readOnlyReplica=false，生产
                // 路径零改动（同库再正常开一次，行为照旧）。
                let normal = try IndexStore(path: url)
                try expectNoThrow(try normal.setMetaValue("search_mode", normal.searchMode.rawValue))
            },
        ]
    }
}
