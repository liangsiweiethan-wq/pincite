import Foundation
@testable import LiteratureCore

enum SearchDetailedParitySuite {
    static func makeStore() throws -> (IndexStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lit-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try IndexStore(path: dir.appendingPathComponent("index.db")), dir)
    }

    @discardableResult
    static func addBook(_ store: IndexStore, id: String, name: String,
                        pages: [String], author: String? = nil) throws -> IndexStore.BookRow {
        let book = IndexStore.BookRow(
            id: id, realPath: "/tmp/lit-parity/\(name)", rootPath: "/tmp/lit-parity",
            relPath: name, fileName: name,
            title: "标题-\(id)", author: author, version: "v1", language: "zh",
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

    /// 混合库：多书、中英混排、词项跨书分布不均、含空文本页（覆盖过滤项
    /// 与书缺失/策略排除等分支）。
    static func buildLibrary(_ store: IndexStore) throws {
        try addBook(store, id: "bA", name: "a.pdf", pages: [
            "法律与国家的示范理论", "The theory of law and the state begins here",
            "权利的概念 第一章", "graph theory of computation 权利",
            "国家与社会", "", "法律的权利与社会权利",
        ], author: "作者甲")
        try addBook(store, id: "bB", name: "b.pdf", pages: [
            "国家的权利结构", "law state and rights",
            "示例契约论", "权利 国家 社会", "",
        ], author: "作者乙")
        try addBook(store, id: "bC", name: "c.pdf", pages: [
            "", "", "法律", "state law graph", "国家",
            // 候选层过近似回归页：含 bigram la+aw（swallow/land）却无 "law"
            // 子串，含 "state" —— 多词查询下旧语义（∃term 命中）应计 1 页。
            "state swallow land",
        ], author: "作者甲")
    }

    // MARK: - 基线镜像（两阶段改造前的字面路径，仅测试对照用）

    static func baselineSearch(store: IndexStore, policy: ExclusionPolicy?,
                               rawQuery: String, options: SearchOptions) throws -> SearchResult {
        let normalizedQuery = normalizeQuery(rawQuery)
        let terms = splitQueryTerms(normalizedQuery)
        guard !terms.isEmpty else { throw TestFailure(message: "baseline: empty query") }
        var intersection: Set<String>? = nil
        for term in terms {
            let ids = try store.candidatePageIDs(term: term)
            if let current = intersection {
                intersection = current.intersection(ids)
            } else {
                intersection = Set(ids)
            }
            if intersection!.isEmpty { break }
        }
        guard var scoped = intersection, !scoped.isEmpty else {
            return SearchResult(hits: [], totalPageMatches: 0, truncated: false,
                                zeroHitExplanation: serviceExplain(store: store, policy: policy, terms: terms))
        }
        if let bookScope = options.filter?.bookIDEquals {
            let bookPages = try store.candidateRowIDs(bookID: bookScope)
            scoped = scoped.intersection(bookPages)
            if scoped.isEmpty {
                return SearchResult(hits: [], totalPageMatches: 0, truncated: false,
                                    zeroHitExplanation: serviceExplain(store: store, policy: policy, terms: terms))
            }
        }
        let orderedRowIDs = scoped.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
        let pages = try store.pages(rowIDs: orderedRowIDs)
        var hits: [SearchHit] = []
        var policyVerdicts: [String: Bool] = [:]
        let preparedTerms = terms.map { SearchService.PreparedSearchTerm(term: $0) }
        var bookCache: [String: IndexStore.BookRow] = [:]
        var pairingCache: [String: (sourced: Set<Int>, map: [Int: Int], path: String?, fp: String?)] = [:]
        func pairing(for book: IndexStore.BookRow) -> (sourced: Set<Int>, map: [Int: Int], path: String?, fp: String?) {
            if let cached = pairingCache[book.id] { return cached }
            guard let info = try? store.ocrPairing(bookID: book.id) else {
                let empty = (Set<Int>(), [Int: Int](), nil as String?, nil as String?)
                pairingCache[book.id] = empty
                return empty
            }
            let value = (info.ocrSourcedPages, info.ocrPages, info.ocrRealPath, info.ocrFingerprint)
            pairingCache[book.id] = value
            return value
        }
        for page in pages {
            guard let book: IndexStore.BookRow = {
                if let cached = bookCache[page.bookID] { return cached }
                let fetched = try? store.book(byID: page.bookID)
                bookCache[page.bookID] = fetched
                return fetched
            }() else { continue }
            if let policy {
                let allowed = policyVerdicts[book.id] ?? {
                    let ok = policy.allowsBook(realPath: book.realPath, rootPath: book.rootPath, bookID: book.id)
                    policyVerdicts[book.id] = ok
                    return ok
                }()
                guard allowed else { continue }
            }
            let ocr = pairing(for: book)
            let isOCR = ocr.sourced.contains(page.pageNumber)
            func hitSkeleton() -> SearchHit {
                SearchHit(bookID: page.bookID, filePath: book.realPath, fileName: book.fileName,
                          fingerprint: book.fingerprint, physicalPage: page.pageNumber,
                          pageLabel: page.label, printedPage: page.printedPage, pageCount: book.pageCount,
                          title: book.title, author: book.author, version: book.version, language: book.language,
                          matches: [], snippet: "",
                          source: isOCR ? "ocr" : "native",
                          ocrFilePath: isOCR ? ocr.path : nil,
                          ocrPage: isOCR ? ocr.map[page.pageNumber] : nil,
                          ocrFingerprint: isOCR ? ocr.fp : nil)
            }
            if let filter = options.filter, filter.isActive {
                let probe = hitSkeleton()
                guard filter.allows(probe) else { continue }
            }
            let pageNormBytes = Array(page.textNorm.utf8)
            let matches = SearchService.utf8Matches(page: page, pageNormBytes: pageNormBytes, preparedTerms: preparedTerms)
            guard !matches.isEmpty else { continue }
            hits.append(SearchHit(
                bookID: page.bookID, filePath: book.realPath, fileName: book.fileName,
                fingerprint: book.fingerprint, physicalPage: page.pageNumber,
                pageLabel: page.label, printedPage: page.printedPage, pageCount: book.pageCount,
                title: book.title, author: book.author, version: book.version, language: book.language,
                matches: matches,
                snippet: SearchService.snippet(in: page.textOriginal, around: matches.map(\.originalUTF16Range)),
                source: isOCR ? "ocr" : "native",
                ocrFilePath: isOCR ? ocr.path : nil,
                ocrPage: isOCR ? ocr.map[page.pageNumber] : nil,
                ocrFingerprint: isOCR ? ocr.fp : nil))
        }
        let total = hits.count
        let truncated = total > options.limit
        let slice: [SearchHit]
        if let quota = options.perBookLimit, quota > 0 {
            slice = SearchService.roundRobinByBook(hits, perBookLimit: quota, limit: options.limit)
        } else {
            slice = Array(hits.prefix(options.limit))
        }
        return SearchResult(hits: slice, totalPageMatches: total, truncated: truncated,
                            zeroHitExplanation: total == 0
                                ? serviceExplain(store: store, policy: policy, terms: terms) : nil)
    }

    /// 基线的零命中解释：直接用 service 的同一实现（分类逻辑与两阶段无关）。
    static func serviceExplain(store: IndexStore, policy: ExclusionPolicy?, terms: [String]) -> ZeroHitExplanation {
        // SearchService.explainZeroHit 是实例方法且依赖其私有 policy 存储；
        // 基线以同参重建一个等价 service 调用（policy 由测试显式传入同值）。
        let mirror = SearchService(store: store, policy: policy)
        return mirror.explainZeroHit(terms: terms)
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "SearchDetailedParity", name: "twoPhaseMatchesFullMaterializationBaseline") {
                let (store, _) = try makeStore()
                try buildLibrary(store)
                // 本套测试锁定「两阶段 ↔ 全量物化镜像」的 legacy 双轨
                // 实现等价性——置 wfts_dirty=1 令 ASCII 词项全部落子串路（路由
                // 优先级 4 降级），词路对旧路的子集等价性由 WordLevelIndexTests
                // 专断言，两套语义互不稀释。
                try store.setMetaValue("wfts_dirty", "1")
                let service = SearchService(store: store)
                let queries: [(String, SearchOptions)] = [
                    ("权利", SearchOptions(limit: 20)),
                    ("权利 国家", SearchOptions(limit: 20)),
                    ("法律 权利", SearchOptions(limit: 3, perBookLimit: 1)),
                    ("国家 社会", SearchOptions(limit: 20, perBookLimit: 2)),
                    ("graph 权利", SearchOptions(limit: 20)),
                    ("law state", SearchOptions(limit: 20)),
                    // 过近似假候选页必须保留（∃term 命中语义，见 buildLibrary 注）。
                    ("state law", SearchOptions(limit: 20)),
                    // 单 ASCII 词／拼音词：曾被英文短词快路劫持的形态（快路已
                    // 移除），必须与全量物化镜像走同一条页级路径且逐字节恒等。
                    ("state", SearchOptions(limit: 20)),
                    ("law", SearchOptions(limit: 3)),
                    ("falv", SearchOptions(limit: 20)),
                    ("法律 国家 社会 权利", SearchOptions(limit: 20, perBookLimit: 3)),
                    ("不存在的词组", SearchOptions(limit: 20)),
                ]
                for (q, opts) in queries {
                    let fast = try service.searchDetailed(q, options: opts)
                    let base = try baselineSearch(store: store, policy: nil, rawQuery: q, options: opts)
                    // 设计断言 1-5：计数、条数、逐项 bookID/physicalPage/snippet。
                    try expectEqual(fast.totalPageMatches, base.totalPageMatches, "[\(q)] totalPageMatches")
                    try expectEqual(fast.hits.count, base.hits.count, "[\(q)] hits.count")
                    for i in 0..<min(fast.hits.count, base.hits.count) {
                        try expectEqual(fast.hits[i].bookID, base.hits[i].bookID, "[\(q)] hit#\(i) bookID")
                        try expectEqual(fast.hits[i].physicalPage, base.hits[i].physicalPage, "[\(q)] hit#\(i) physicalPage")
                        try expectEqual(fast.hits[i].snippet, base.hits[i].snippet, "[\(q)] hit#\(i) snippet")
                        try expectEqual(fast.hits[i], base.hits[i], "[\(q)] hit#\(i) whole")
                    }
                    try expectEqual(fast, base, "[\(q)] whole SearchResult")
                    // 复跑一次（走持久化候选缓存）仍恒等。
                    let fastAgain = try service.searchDetailed(q, options: opts)
                    try expectEqual(fastAgain, fast, "[\(q)] repeat via candidate cache")
                }
            },

            TestDesc(suite: "SearchDetailedParity", name: "parityHoldsUnderPolicyAndMetadataFilter") {
                let (store, _) = try makeStore()
                try buildLibrary(store)
                // 策略排除 bB：两轨同用一策略。
                let policy = ExclusionPolicy(config: ExclusionConfig(excludedBookIDs: ["bB"]))
                let service = SearchService(store: store, policy: policy)
                let cases: [(String, SearchOptions, SearchFilter?)] = [
                    ("权利 国家", SearchOptions(limit: 20), nil),
                    ("法律 权利", SearchOptions(limit: 20, perBookLimit: 2),
                     SearchFilter(authorContains: "作者甲")),
                    ("国家 社会", SearchOptions(limit: 5), SearchFilter(versionContains: "v1")),
                    ("社会", SearchOptions(limit: 20), SearchFilter(languageEquals: "zh")),
                ]
                for (q, opts, filter) in cases {
                    var o = opts
                    o.filter = filter
                    let fast = try service.searchDetailed(q, options: o)
                    let base = try baselineSearch(store: store, policy: policy, rawQuery: q, options: o)
                    try expectEqual(fast.totalPageMatches, base.totalPageMatches, "[\(q)/\(String(describing: filter))] total")
                    try expectEqual(fast.hits, base.hits, "[\(q)/\(String(describing: filter))] hits")
                    try expectEqual(fast, base, "[\(q)/\(String(describing: filter))] whole")
                }
            },

            TestDesc(suite: "SearchDetailedParity", name: "parityHoldsWithBookScopeAndSnippetContent") {
                let (store, _) = try makeStore()
                try buildLibrary(store)
                let service = SearchService(store: store)
                // 书域收窄 + 片段断言（证据窗口必须含每个 term 的原文证据）。
                let scoped = try service.searchDetailed("权利", options: SearchOptions(limit: 20, filter: SearchFilter(bookIDEquals: "bA")))
                let base = try baselineSearch(store: store, policy: nil, rawQuery: "权利",
                                              options: SearchOptions(limit: 20, filter: SearchFilter(bookIDEquals: "bA")))
                try expectEqual(scoped, base, "book-scoped whole")
                try expectTrue(scoped.hits.allSatisfy { $0.bookID == "bA" })
                for hit in scoped.hits {
                    try expectFalse(hit.snippet.isEmpty)
                    for m in hit.matches {
                        try expectTrue(hit.snippet.contains(m.displayTerm) || hit.snippet.contains("…"),
                                       "snippet must carry the term evidence or an ellipsis window")
                    }
                }
            },

            // 快路双轨穷举断言：合成库达不到
            // 2MB bigram 门槛，快路在此前测试中从不激活——本测以 zeroblob
            // 灌大门槛（同 MatchingBooksDeterminism 夹具基准：只动门槛判定
            // 读的 length(rowids)，页/FTS 内容不动）真实激活 快路，
            // 与未优化基线镜像逐字节穷举比对。真/假候选混布：假候选含该词
            // 全部 bigram 却无词面子串，专打下推 vs Swift ∃term 校验的同构性。
            TestDesc(suite: "SearchDetailedParity", name: "fastPathPushdownByteParityFiveRepeatsAndEdges") {
                let (store, _) = try makeStore()
                // 快路/LIKE 下推现只服务子串轨——置 wfts_dirty=1
                // 锁定该轨（bidx_* 键不受影响，快路照常激活）；词路专断言见
                // WordLevelIndexTests。
                try store.setMetaValue("wfts_dirty", "1")
                try addBook(store, id: "bF", name: "f.pdf", pages: [
                    "state of the art", "start team at dawn", "the state again",
                    "statesman est atte", "state law rights", "atlas statue rooms",
                    "no law without equity", "raw layout plan", "flavor lawn salad",
                ], author: "作者甲")
                try addBook(store, id: "bG", name: "g.pdf", pages: [
                    "estate states", "taste starter", "state", "start at estate",
                    "lawyer statutes", "claw static theater",
                ], author: "作者乙")
                _ = try store.rebuildBigramInvertedIndex()
                let service = SearchService(store: store)

                func inflate(_ bigrams: [String]) throws {
                    let list = bigrams.map { "'\($0)'" }.joined(separator: ",")
                    try store.db.exec("UPDATE bigram_index SET rowids = zeroblob(600000) WHERE bigram IN (\(list));")
                }
                try inflate(["st", "ta", "at", "te"])
                try expectNotNil(try store.candidateRowIDsViaFTS(term: "state"),
                                 "夹具必须真实激活快路（state）")
                // "law"：第二个激活词（la/aw 两枚——单枚需 1.1MB 才过 2MB 门）。
                try store.db.exec("UPDATE bigram_index SET rowids = zeroblob(1100000) WHERE bigram IN ('la','aw');")
                try expectNotNil(try store.candidateRowIDsViaFTS(term: "law"),
                                 "夹具必须真实激活快路（law）")

                // 设计断言集：单 ASCII 词快路 vs 基线镜像逐字节恒等＋连续 5 次
                // 复跑（缓存命中/未命中两态交替扰动）结果恒定。
                for (q, opts) in [("state", SearchOptions(limit: 20)),
                                  ("law", SearchOptions(limit: 3)),
                                  ("state", SearchOptions(limit: 20, perBookLimit: 1))] {
                    let base = try baselineSearch(store: store, policy: nil, rawQuery: q, options: opts)
                    var first: SearchResult? = nil
                    for run in 0..<5 {
                        if run % 2 == 1 { try store.purgeQueryCaches() }   // 缓存两态扰动
                        let fast = try service.searchDetailed(q, options: opts)
                        try expectEqual(fast.totalPageMatches, base.totalPageMatches, "[\(q)] run\(run) total")
                        try expectEqual(fast.hits, base.hits, "[\(q)] run\(run) hits")
                        try expectEqual(fast, base, "[\(q)] run\(run) whole")
                        if let f = first { try expectEqual(fast, f, "[\(q)] run\(run) vs run0") }
                        else { first = fast }
                    }
                }
                // 边缘形态：单字母、空结果、含 % 的词面（LIKE
                // 转义面）、双词——这些形态不激活快路或走空候选，双轨仍须恒等。
                for q in ["a", "qqzzww", "100%", "c++", "state law"] {
                    let base = try baselineSearch(store: store, policy: nil, rawQuery: q,
                                                  options: SearchOptions(limit: 20))
                    let fast = try service.searchDetailed(q, options: SearchOptions(limit: 20))
                    try expectEqual(fast, base, "[edge \(q)] whole")
                }
            },
        ]
    }
}
