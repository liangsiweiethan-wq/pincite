import Foundation
@testable import LiteratureCore

// MARK: - 引擎接口层测试

enum SearchEngineSuite {
    /// 合成两册库（与 IndexSearchSuite.buildLibrary 同源文本）。
    static func buildLibrary(_ dir: URL) {
        Fixtures.makePDF(pages: [
            .init(lines: ["第一章 导论", "这是中文测试页面。", "The theory of computation begins here."]),
            .init(lines: ["第二章 方法", "Chapter two mentions 计算理论 clearly. Graph theory rocks."]),
        ], in: dir, named: "bookA.pdf")
        Fixtures.makePDF(pages: [
            .init(lines: ["Catalogue of Sample Works", "English only volume."]),
        ], in: dir, named: "bookB.pdf")
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "SearchEngine", name: "protocolCallsParityWithDirectService") {
                let dir = Fixtures.makeTempDir("engine-parity")
                defer { Fixtures.cleanup(dir) }
                buildLibrary(dir)
                let store = try Fixtures.openStore(in: dir)
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)

                let engine = SearchEngineRegistry.resolve("fts5-default")
                    .init(store: store, policy: nil)
                let direct = SearchService(store: store, policy: nil)

                let engineBooks = try engine.matchingBooks("计算理论", filter: nil)
                let directBooks = try direct.matchingBooks("计算理论", filter: nil)
                try expectEqual(engineBooks, directBooks, "book-level results must be equal")
                try expectTrue(!engineBooks.isEmpty, "fixture library must match")

                let engineDetailed = try engine.searchDetailed("计算理论", options: SearchOptions())
                let directDetailed = try direct.searchDetailed("计算理论", options: SearchOptions())
                try expectEqual(engineDetailed, directDetailed, "page-level results must be equal")
                try expectEqual(engineDetailed.hits.first?.physicalPage, 2)

                let engineZero = try engine.explainZeroHit("不存在的词组xyzq")
                let directZero = try direct.explainZeroHit("不存在的词组xyzq")
                try expectEqual(engineZero.summary, directZero.summary,
                                "zero-hit explanations must agree")
                try expectTrue(!engineZero.books.isEmpty)
            },

            TestDesc(suite: "SearchEngine", name: "unknownPreferenceFailsClosedToDefault") {
                for preference in [nil as String?, "", "fts5-default", "bogus-engine", "FTS5-DEFAULT"] {
                    let resolved = SearchEngineRegistry.resolve(preference)
                    try expectTrue(resolved == SearchService.self as SearchEngine.Type,
                                   "preference \(preference ?? "nil") must resolve to fts5-default")
                    try expectEqual(SearchEngineRegistry.engineName(for: preference),
                                    SearchEngineRegistry.defaultEngineName)
                }
                try expectEqual(SearchEngineRegistry.defaultEngineName, "fts5-default")
            },
        ]
    }
}
