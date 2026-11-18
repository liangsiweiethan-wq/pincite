import Foundation
@testable import LiteratureCore

// MARK: - 查询语法层测试（语法串→AST 快照表 / parity / 三档 /
// 引号短语 / 正则超时闸 / QueryFilter AND 组合 / 标签投影 / 引号内不解析）

enum QuerySyntaxSuite {
    /// 合成库（CoverageClassificationSuite.addBook 同款三本书；标签经 favorites 注入）。
    static func makeStore() throws -> IndexStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lit-qsyn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try IndexStore(path: dir.appendingPathComponent("index.db"))
        try addBook(store, id: "bA", name: "a.pdf", pages: [
            "样书一 第一章 权利与义务。Recht und Pflicht.",
            "自由与国家 第二章。natural rights 的边界。",
        ], author: "甲乙", title: "样书一", language: "zh", version: "第2版")
        try addBook(store, id: "bB", name: "b.pdf", pages: [
            "样书一 权利自由民主。",
            "Sovereignty and the state. Rechtsstaat tradition.",
        ], author: "丙丁", title: "样书一", language: "zh", version: "初版")
        try addBook(store, id: "bC", name: "c.pdf", pages: [
            "纯粹数学笔记 1+1=2。",
        ], author: "佚名", title: "数学笔记", language: "en", version: nil)
        return store
    }

    @discardableResult
    static func addBook(_ store: IndexStore, id: String, name: String, pages: [String],
                        author: String?, title: String?, language: String?, version: String?) throws -> IndexStore.BookRow {
        let book = IndexStore.BookRow(
            id: id, realPath: "/tmp/lit-tests/\(name)", rootPath: "/tmp/lit-tests",
            relPath: name, fileName: name,
            title: title, author: author, version: version, language: language, metaSource: nil,
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

    static var tests: [TestDesc] {
        [
            // 「语法串→AST」快照表（JabRef 模式：按「语法串→AST」组织）。
            TestDesc(suite: "QuerySyntax", name: "parseSnapshotTableMixedQuery") {
                let parsed = try QuerySyntax.parse("作者:丙丁 标签:法理 \"法律 概念\" 丙丁= 权利~Recht.*")
                try expectEqual(parsed.nodes.count, 6)
                guard case .field(let f1, .contains(let v1)) = parsed.nodes[0] else {
                    try failTest("node0 should be field contains")
                }
                try expectEqual(f1, .author); try expectEqual(v1, "丙丁")
                guard case .field(let f2, .contains(let v2)) = parsed.nodes[1] else {
                    try failTest("node1 should be field contains")
                }
                try expectEqual(f2, .tag); try expectEqual(v2, "法理")
                guard case .phrase(let p) = parsed.nodes[2] else { try failTest("node2 should be phrase") }
                try expectEqual(p, "法律 概念")
                guard case .exactTerm(let e) = parsed.nodes[3] else { try failTest("node3 should be exact") }
                try expectEqual(e, "丙丁")
                // `权利~Recht.*` = 词[权利] + 正则[Recht.*] 两节点。
                guard case .term(let t) = parsed.nodes[4] else { try failTest("node4 should be term") }
                try expectEqual(t, "权利")
                guard case .regex(let re) = parsed.nodes[5] else { try failTest("node5 should be regex") }
                try expectEqual(re, "Recht.*")
                try expectTrue(parsed.usedSyntax)
            },

            TestDesc(suite: "QuerySyntax", name: "parseFieldModifiersAndQuotedValues") {
                // 精确档字段：作者:丙丁=
                let p1 = try QuerySyntax.parse("作者:丙丁=")
                guard case .field(.author, .equals(let v)) = p1.nodes[0] else { try failTest("expect author equals") }
                try expectEqual(v, "丙丁")
                // 引号值 + 档位：作者:"林 某 甲"=
                let p2 = try QuerySyntax.parse("作者:\"林 某 甲\"=")
                guard case .field(.author, .equals(let v2)) = p2.nodes[0] else { try failTest("expect quoted equals") }
                try expectEqual(v2, "林 某 甲")
                // 引号值缺省档：作者:"林 某 甲"
                let p3 = try QuerySyntax.parse("作者:\"林 某 甲\"")
                guard case .field(.author, .contains(let v3)) = p3.nodes[0] else { try failTest("expect quoted contains") }
                try expectEqual(v3, "林 某 甲")
                // 字段正则档：书名:Recht~Re.*s
                let p4 = try QuerySyntax.parse("书名:Recht~Re.*s")
                guard case .field(.title, .regex(let re)) = p4.nodes[0] else { try failTest("expect title regex") }
                try expectEqual(re, "Re.*s")
                // 非字段 token（http://x 不误判——http 不在字段集）：
                let p5 = try QuerySyntax.parse("http://example.com")
                guard case .term(let t5) = p5.nodes[0] else { try failTest("expect plain term") }
                try expectTrue(t5.contains("http"))
                // `作者:` 无值 → 字面 term（不猜）。
                let p6 = try QuerySyntax.parse("作者:")
                guard case .term = p6.nodes[0] else { try failTest("expect literal term fallback") }
            },

            // 零漂移 parity：无语法查询 freeTerms 与 splitQueryTerms 逐项相等。
            TestDesc(suite: "QuerySyntax", name: "noSyntaxQueriesMatchSplitQueryTermsParity") {
                let samples = [
                    "法律", "法律 概念", "the idea of rules",
                    "法律  概念 ", "FalV recht", "国家 权力 民主",
                ]
                for q in samples {
                    let parsed = try QuerySyntax.parse(q)
                    try expectFalse(parsed.usedSyntax, "no-syntax query: \(q)")
                    try expectEqual(parsed.nodes, parsed.freeTerms.map { QueryNode.term($0) },
                                    "parse must be term-per-term: \(q)")
                    try expectEqual(parsed.freeTerms, splitQueryTerms(normalizeQuery(q)),
                                    "parity vs splitQueryTerms: \(q)")
                }
            },

            TestDesc(suite: "QuerySyntax", name: "quotesInsidePhraseAreNotFields") {
                // 引号内语法字符不解析："作者:xx" 是短语不是字段。
                let parsed = try QuerySyntax.parse("\"作者:xx\"")
                try expectEqual(parsed.nodes.count, 1)
                guard case .phrase(let p) = parsed.nodes[0] else { try failTest("expect phrase") }
                try expectEqual(p, "作者:xx")
                try expectNil(parsed.fieldNodes.first)
            },

            TestDesc(suite: "QuerySyntax", name: "fullWidthColonDoesNotTriggerSyntaxLayer") {
                // 全角冒号不是语法字符（归一化前判定）——不触发新层。
                try expectFalse(QuerySyntax.hasSyntaxCharacter("作者：丙丁"))
                try expectFalse(QuerySyntax.hasSyntaxCharacter("法律 概念"))
                try expectTrue(QuerySyntax.hasSyntaxCharacter("作者:丙丁"))
                try expectTrue(QuerySyntax.hasSyntaxCharacter("a=b"))
                try expectTrue(QuerySyntax.hasSyntaxCharacter("a~b"))
                try expectTrue(QuerySyntax.hasSyntaxCharacter("a\"b"))
            },

            // 三档各自命中/不命中（页级求值）。
            TestDesc(suite: "QuerySyntax", name: "threeModesHitAndMissOnSyntheticPages") {
                let store = try makeStore()
                let service = SearchService(store: store)
                // 缺省（子串）：「权利」命中 bA p1（权利与义务）与 bB p1。
                let r1 = try service.searchDetailed("权利")
                try expectEqual(r1.totalPageMatches, 2)
                // 精确档（全词边界）：「权」在两书页文本中都不是独立词——
                // 「权利」的子串命中不算精确。
                let r2 = try service.searchDetailed("权=")
                try expectEqual(r2.totalPageMatches, 0)
                // 精确档命中：Recht（bA p1 的「Recht und」前有边界、后是空格）。
                let r3 = try service.searchDetailed("Recht=")
                try expectEqual(r3.totalPageMatches, 1)
                try expectEqual(r3.hits.first?.bookID, "bA")
                // 正则档：Re.*t 命中 Recht（bA）与 Rechtsstaat（bB）。
                let r4 = try service.searchDetailed("~Re.*t")
                try expectEqual(r4.totalPageMatches, 2)
                // 正则档带字面前缀：权利~Re.*t（权利 AND 正则）——bA p1 同时
                // 有「权利」和 Recht。
                let r5 = try service.searchDetailed("权利~Re.*t")
                try expectEqual(r5.totalPageMatches, 1)
                try expectEqual(r5.hits.first?.bookID, "bA")
            },

            // 正则超时闸（慢正则 `(a+)+$` 对长串）：超时错误而非挂死。
            TestDesc(suite: "QuerySyntax", name: "regexTimeoutGateThrowsInsteadOfHanging") {
                let long = String(repeating: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", count: 40) + "b"
                let page = IndexStore.PageRow(
                    bookID: "bX", pageNumber: 1, label: nil, printedPage: nil,
                    textOriginal: long, textNorm: long, normStarts: [], normEnds: [])
                let regex = try NSRegularExpression(pattern: "(a+)+$")
                let bytes = Array(page.textNorm.utf8)
                let start = Date()
                try expectThrows(
                    try QueryMatcher.regexMatches(regex: regex, pattern: "(a+)+$", page: page))
                let elapsed = Date().timeIntervalSince(start)
                try expectTrue(elapsed < 5.0, "timeout gate must trip fast, took \(elapsed)s")
                _ = bytes
            },

            // 字段限定与 GUI 过滤条 AND 组合；QueryFilter 书级判定。
            TestDesc(suite: "QuerySyntax", name: "queryFilterCombinesWithGuiFilter") {
                let store = try makeStore()
                let service = SearchService(store: store)
                // 字段：语言:zh → bA + bB。
                let r1 = try service.matchingBooks("语言:zh")
                try expectEqual(Set(r1.map(\.bookID)), Set(["bA", "bB"]))
                // 字段 AND GUI 过滤条（authorContains=甲乙）：只剩 bA。
                let guiFilter = SearchFilter(authorContains: "甲乙")
                let r2 = try service.matchingBooks("语言:zh", filter: guiFilter)
                try expectEqual(r2.map(\.bookID), ["bA"])
                // 字段精确档：作者:丙丁= → bB；作者:韦=（精确）→ 无（作者非「韦」）。
                let r3 = try service.matchingBooks("作者:丙丁=")
                try expectEqual(r3.map(\.bookID), ["bB"])
                let r4 = try service.matchingBooks("作者:韦=")
                try expectTrue(r4.isEmpty)
                // 字段与自由词 AND：语言:zh 权利 → 候选含「权利」的书（bA、bB）。
                let r5 = try service.matchingBooks("语言:zh 权利")
                try expectEqual(Set(r5.map(\.bookID)), Set(["bA", "bB"]))
                // 页级：书名:法律 概念 → bA 内两段式；页级检索只回 bA。
                let r6 = try service.searchDetailed("书名:法律 概念")
                try expectTrue(r6.hits.allSatisfy { $0.bookID == "bA" })
            },

            // 标签投影：未收藏书恒不命中。
            TestDesc(suite: "QuerySyntax", name: "tagProjectionOnlyMatchesFavoritedBooks") {
                let store = try makeStore()
                let service = SearchService(store: store)
                // 未打标签：标签:法理 零命中。
                let r1 = try service.matchingBooks("标签:法理")
                try expectTrue(r1.isEmpty)
                // 收藏 bA 带 tags=[法理, 经典]。
                let favorites = FavoritesStore(indexStore: store)
                _ = try favorites.add(.book(bookID: "bA", fileName: "a.pdf", title: "样书一"),
                                      tags: ["法理", "经典"])
                let r2 = try service.matchingBooks("标签:法理")
                try expectEqual(r2.map(\.bookID), ["bA"])
                let r3 = try service.matchingBooks("标签:经典")
                try expectEqual(r3.map(\.bookID), ["bA"])
                // 未收藏的 bB 即使文本相关也不进标签结果。
                try expectFalse(r2.contains { $0.bookID == "bB" })
            },

            // 引号短语跨空格整体匹配。
            TestDesc(suite: "QuerySyntax", name: "quotedPhraseMatchesAcrossSpaceAsOneTerm") {
                let store = try makeStore()
                let service = SearchService(store: store)
                let pageNorm = normalizeForSearch("样书一 第一章 权利与义务。Recht und Pflicht.")
                let book = try expectNotNil(try store.book(byID: "bA"))
                _ = book
                // 短语「权利与义务」整体命中（等价于字面子串通道）。
                let r1 = try service.searchDetailed("\"权利与义务\"")
                try expectEqual(r1.totalPageMatches, 1)
                try expectEqual(r1.hits.first?.bookID, "bA")
                // 短语「与 义务」（跨空格）：规范化后「与 义务」含空格，页文本
                // 「权利与义务」无空格——不命中（与现行多词 AND 语义不同处，
                // 断言固定）。
                let r2 = try service.searchDetailed("\"与 义务\"")
                try expectEqual(r2.totalPageMatches, 0)
                _ = pageNorm
                // 混合：短语 + 自由词 AND。
                let r3 = try service.searchDetailed("\"权利与义务\" Recht")
                try expectEqual(r3.totalPageMatches, 1)
            },

            // 无效正则 fail-closed 报错（不静默零命中）。
            TestDesc(suite: "QuerySyntax", name: "invalidRegexFailsClosed") {
                try expectThrows(try QuerySyntax.parse("foo~([unclosed"))
                // 但普通引用词不抛。
                _ = try QuerySyntax.parse("法律 概念")
            },

            // 书目级正则节点参与求值（此前被静默忽略——两阶段
            // 基准一致：页级怎么算，书目级就怎么算）。
            TestDesc(suite: "QuerySyntax", name: "matchingBooksEvaluatesRegexNodes") {
                let store = try makeStore()
                let service = SearchService(store: store)
                // ~Re.*t 命中 Recht（bA p1）与 Rechtsstaat（bB p2）→ 两书。
                let r1 = try service.matchingBooks("~Re.*t")
                try expectEqual(Set(r1.map(\.bookID)), Set(["bA", "bB"]))
                try expectTrue(r1.allSatisfy { $0.matchingPages >= 1 },
                               "regex hit pages must count into matchingPages")
                let r2 = try service.matchingBooks("语言:zh ~Re.*t")
                try expectEqual(Set(r2.map(\.bookID)), Set(["bA", "bB"]))
                let r3 = try service.matchingBooks("~Zzzqqq")
                try expectTrue(r3.isEmpty)
                // 词项零候选时词 AND 正则＝零（不得退化成只看
                // 正则——「falv」不在任何页文本，候选空集即空全集）。
                let r4 = try service.matchingBooks("falv~Re.*t")
                try expectTrue(r4.isEmpty, "zero-candidate term AND regex must be empty")
                // 对照：页级同查询同为零（两阶段基准一致）。
                let r5 = try service.searchDetailed("falv~Re.*t")
                try expectEqual(r5.totalPageMatches, 0)
            },

            TestDesc(suite: "QuerySyntax", name: "unterminatedQuoteDegradesToLiteralTerm") {
                let parsed = try QuerySyntax.parse("\"未闭合")
                try expectFalse(parsed.nodes.isEmpty)
                try expectTrue(parsed.freeTerms.contains { !$0.isEmpty })
            },

            // 分派镜像：usedSyntax 与 hasSyntaxCharacter 一致。
            TestDesc(suite: "QuerySyntax", name: "usedSyntaxMirrorMatchesDispatchPredicate") {
                for q in ["法律", "作者:x", "a=b", "\"p\"", "a~b", "普通查询"] {
                    let parsed = try QuerySyntax.parse(q)
                    try expectEqual(parsed.usedSyntax, QuerySyntax.hasSyntaxCharacter(q))
                }
            },

            // 诊断数据：语法查询 AST 概要与正则超时标注。
            TestDesc(suite: "QuerySyntax", name: "diagnosticsCarrySyntaxSummaryAndTimeoutFlag") {
                let store = try makeStore()
                let service = SearchService(store: store)
                _ = try service.searchDetailed("作者:甲乙")
                let diag = try expectNotNil(service.lastQueryDiagnostics)
                try expectTrue(diag.syntaxSummary.contains("字段[作者"))
                try expectFalse(diag.regexTimedOut)
                // 无语法查询：概要为空。
                _ = try service.searchDetailed("权利")
                let diag2 = try expectNotNil(service.lastQueryDiagnostics)
                try expectEqual(diag2.syntaxSummary, "")
            },

            // 探针：探针激活时四相字段在位；开关不改变结果。
            TestDesc(suite: "QuerySyntax", name: "phaseTimingProbeRecordsWithoutChangingResults") {
                let store = try makeStore()
                let service = SearchService(store: store)
                SearchPhaseTiming.forced = false
                let r1 = try service.searchDetailed("权利")
                SearchPhaseTiming.forced = true
                defer { SearchPhaseTiming.forced = false }
                let r2 = try service.searchDetailed("权利")
                try expectEqual(r1, r2, "probe must not change results")
                let rec = try expectNotNil(SearchPhaseTiming.lastSearchRecord)
                try expectTrue(rec.queryMs >= 0)
                try expectTrue(rec.materializeMs >= 0)
                try expectTrue(rec.verifyMs >= 0)
                try expectTrue(rec.candidates > 0)
                try expectTrue(rec.pagesLoaded > 0)
                try expectEqual(rec.totalPageMatches, r2.totalPageMatches)
            },
        ]
    }
}
