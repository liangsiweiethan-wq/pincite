import Foundation
@testable import LiteratureCore

// MARK: - 智能收藏套件（.smartSearch 动态集合）

enum SmartCollectionsSuite {

    static func makeBook(_ id: String, title: String?, author: String?,
                         realPath: String? = nil) -> IndexStore.BookRow {
        IndexStore.BookRow(
            id: id, realPath: realPath ?? "/tmp/\(id).pdf", rootPath: "/tmp",
            relPath: "\(id).pdf", fileName: "\(id).pdf",
            title: title, author: author, version: nil, language: nil, metaSource: nil,
            firstFingerprint: "fp-\(id)", fingerprint: "fp-\(id)", fileSize: 100, mtime: 0,
            pageCount: 3, status: "ok", error: nil, indexedAt: 0)
    }

    static var tests: [TestDesc] {
        [
            // ── 往返：add → all 解码还原，filter 五字段逐一相等 ──
            TestDesc(suite: "SmartCollections", name: "roundTripSmartSearchWithFilter") {
                let dir = Fixtures.makeTempDir("smart-roundtrip")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let favorites = FavoritesStore(indexStore: store)
                let filter = SearchFilter(authorContains: "林克尔",
                                          versionContains: "第二版",
                                          languageEquals: "zh",
                                          bookIDEquals: "bX",
                                          sourceDomain: "paper")
                let id = try favorites.add(.smartSearch(query: "泛函分析", filter: filter))
                let all = try favorites.all()
                try expectEqual(all.count, 1)
                try expectEqual(all[0].kind, FavoriteKind.smartSearch)
                guard case .smartSearch(let q, let f?) = all[0].target else {
                    throw TestFailure(message: "expected smartSearch target")
                }
                try expectEqual(q, "泛函分析")
                try expectEqual(f, filter)
                _ = id
            },

            // ── filter=nil 往返（等价旧语义但独立 case）──
            TestDesc(suite: "SmartCollections", name: "roundTripSmartSearchNilFilter") {
                let dir = Fixtures.makeTempDir("smart-nilfilter")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let favorites = FavoritesStore(indexStore: store)
                _ = try favorites.add(.smartSearch(query: "拓扑", filter: nil))
                let all = try favorites.all()
                guard case .smartSearch(let q, let f) = all[0].target else {
                    throw TestFailure(message: "expected smartSearch target")
                }
                try expectEqual(q, "拓扑")
                try expectNil(f)
            },

            // ── 旧 JSON 兼容：前形态 .search 行解出不变；smartSearch
            //    无 filter 键解出 nil ──
            TestDesc(suite: "SmartCollections", name: "legacySearchJSONDecodesUnchanged") {
                let legacy = #"{"kind":"search","query":"normierung"}"#
                let target = try JSONDecoder().decode(FavoriteTarget.self,
                                                      from: Data(legacy.utf8))
                try expectEqual(target, FavoriteTarget.search(query: "normierung"))
                // smartSearch 形态但缺 filter 键（理论上本库不产，防御兼容）
                let noFilter = #"{"kind":"smartSearch","query":"泛函"}"#
                let t2 = try JSONDecoder().decode(FavoriteTarget.self,
                                                  from: Data(noFilter.utf8))
                guard case .smartSearch(let q2, let f2) = t2 else {
                    throw TestFailure(message: "expected smartSearch")
                }
                try expectEqual(q2, "泛函")
                try expectNil(f2)
                // 未知 kind 仍 fail-closed（既有契约不被新 case 放松）
                let unknown = #"{"kind":"teleport","query":"x"}"#
                try expectThrows(try JSONDecoder().decode(FavoriteTarget.self,
                                                          from: Data(unknown.utf8)))
            },

            // ── 动态性：同一收藏行不改，库加书后现算结果变多（非快照）──
            TestDesc(suite: "SmartCollections", name: "dynamicReevaluationPicksUpNewBooks") {
                let dir = Fixtures.makeTempDir("smart-dynamic")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir,
                                                   options: .init(forceFallbackSearch: true))
                let favorites = FavoritesStore(indexStore: store)
                try store.upsertBook(makeBook("b1", title: "计算理论导论", author: "西格玛"))
                try store.replacePages(bookID: "b1", [
                    IndexStore.PageRow(bookID: "b1", pageNumber: 1, label: nil,
                                       printedPage: nil,
                                       textOriginal: "计算理论导论 第一章",
                                       textNorm: "计算理论导论 第一章",
                                       normStarts: [0],
                                       normEnds: [Int32("计算理论导论 第一章".count)]),
                ])
                let filter = SearchFilter(authorContains: "西格玛")
                _ = try favorites.add(.smartSearch(query: "计算", filter: filter))
                let first = try SmartCollections.evaluate(query: "计算", filter: filter, store: store)
                try expectEqual(first.count, 1)
                try store.upsertBook(makeBook("b2", title: "可计算性与逻辑", author: "西格玛"))
                try store.replacePages(bookID: "b2", [
                    IndexStore.PageRow(bookID: "b2", pageNumber: 1, label: nil,
                                       printedPage: nil,
                                       textOriginal: "可计算性与逻辑 绪论",
                                       textNorm: "可计算性与逻辑 绪论",
                                       normStarts: [0],
                                       normEnds: [Int32("可计算性与逻辑 绪论".count)]),
                ])
                let second = try SmartCollections.evaluate(query: "计算", filter: filter, store: store)
                try expectEqual(second.count, 2)
                try expectTrue(second.contains { $0.bookID == "b2" })
            },

            // ── unknown 不命中：author NULL 不被 contains 过滤命中（正向谓词）──
            TestDesc(suite: "SmartCollections", name: "unknownAuthorNeverMatches") {
                let dir = Fixtures.makeTempDir("smart-unknown")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir,
                                                   options: .init(forceFallbackSearch: true))
                try store.upsertBook(makeBook("b-nil", title: "计算几何", author: nil))
                try store.replacePages(bookID: "b-nil", [
                    IndexStore.PageRow(bookID: "b-nil", pageNumber: 1, label: nil,
                                       printedPage: nil,
                                       textOriginal: "计算几何 第一章",
                                       textNorm: "计算几何 第一章",
                                       normStarts: [0],
                                       normEnds: [Int32("计算几何 第一章".count)]),
                ])
                let filter = SearchFilter(authorContains: "任何人")
                let hits = try SmartCollections.evaluate(query: "计算", filter: filter, store: store)
                try expectTrue(hits.isEmpty)
                // 同书去过滤 → 命中（证明空结果是过滤谓词而非检索失败）
                let unfiltered = try SmartCollections.evaluate(query: "计算", filter: nil, store: store)
                try expectEqual(unfiltered.count, 1)
            },

            // ── 定义变更即重算：同一集合行改存不同 filter 后结果不同 ──
            TestDesc(suite: "SmartCollections", name: "definitionChangeRecomputes") {
                let dir = Fixtures.makeTempDir("smart-recompute")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir,
                                                   options: .init(forceFallbackSearch: true))
                let favorites = FavoritesStore(indexStore: store)
                try store.upsertBook(makeBook("b1", title: "计算理论导论", author: "西格玛"))
                try store.upsertBook(makeBook("b2", title: "计算几何", author: "欧米茄"))
                for b in ["b1", "b2"] {
                    try store.replacePages(bookID: b, [
                        IndexStore.PageRow(bookID: b, pageNumber: 1, label: nil,
                                           printedPage: nil,
                                           textOriginal: "计算 相关文本",
                                           textNorm: "计算 相关文本",
                                           normStarts: [0],
                                           normEnds: [Int32("计算 相关文本".count)]),
                    ])
                }
                let rowID = try favorites.add(.smartSearch(query: "计算",
                                                           filter: SearchFilter(authorContains: "西格玛")))
                let filterA = SearchFilter(authorContains: "西格玛")
                let withA = try SmartCollections.evaluate(query: "计算", filter: filterA, store: store)
                try expectEqual(withA.count, 1)
                // 同一行 UPDATE target_json 换定义 → 求值立即跟随（无缓存）。
                let filterB = SearchFilter(authorContains: "欧米茄")
                let newJSON = String(decoding: try JSONEncoder().encode(
                    FavoriteTarget.smartSearch(query: "计算", filter: filterB)), as: UTF8.self)
                let stmt = try store.db.prepare("UPDATE favorites SET target_json = ? WHERE id = ?;")
                defer { stmt.reset() }
                try stmt.bindText(1, newJSON)
                try stmt.bindInt(2, rowID)
                try stmt.run()
                let all = try favorites.all()
                guard case .smartSearch(_, let stored) = all[0].target else {
                    throw TestFailure(message: "expected smartSearch")
                }
                let withB = try SmartCollections.evaluate(query: "计算", filter: stored, store: store)
                try expectEqual(withB.count, 1)
                try expectEqual(withB.first?.bookID, "b2")
            },

            // ── evaluate limit 截断 ──
            TestDesc(suite: "SmartCollections", name: "evaluateLimitTruncates") {
                let dir = Fixtures.makeTempDir("smart-limit")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir,
                                                   options: .init(forceFallbackSearch: true))
                for i in 1...3 {
                    try store.upsertBook(makeBook("b\(i)", title: "计算书\(i)", author: "甲"))
                    try store.replacePages(bookID: "b\(i)", [
                        IndexStore.PageRow(bookID: "b\(i)", pageNumber: 1, label: nil,
                                           printedPage: nil,
                                           textOriginal: "计算 文本",
                                           textNorm: "计算 文本",
                                           normStarts: [0],
                                           normEnds: [Int32("计算 文本".count)]),
                    ])
                }
                let hits = try SmartCollections.evaluate(query: "计算", filter: nil, store: store, limit: 2)
                try expectEqual(hits.count, 2)
            },
        ]
    }
}
