import Foundation

// MARK: - Search over the index (never touches PDFs; bounds resolved lazily)

public struct SearchHit: Equatable, Hashable {
    public struct TermMatch: Equatable, Hashable {
        public var term: String                 // normalized term actually matched
        public var displayTerm: String          // the substring of the original text (verbatim)
        public var originalUTF16Range: Range<Int>

        public init(term: String, displayTerm: String, originalUTF16Range: Range<Int>) {
            self.term = term
            self.displayTerm = displayTerm
            self.originalUTF16Range = originalUTF16Range
        }
    }

    public var bookID: String
    public var filePath: String                 // real (resolved) path of the ORIGINAL pdf at index time
    public var fileName: String
    public var fingerprint: String              // content the page came from (ORIGINAL file)
    public var physicalPage: Int                // 1-based physical page of the ORIGINAL pdf
    public var pageLabel: String?               // nil = unknown
    public var printedPage: Int?                // nil = unknown (not guessed)
    public var pageCount: Int
    public var title: String?                   // nil = unknown
    public var author: String?                  // nil = unknown
    public var version: String?                 // nil = unknown
    public var language: String?                // nil = unknown
    public var matches: [TermMatch]             // ALL occurrences on the page
    public var snippet: String                  // from the page's stored text, verbatim
    public var source: String                   // "native" | "ocr"
    public var ocrFilePath: String?             // paired OCR pdf (nil = native hit)
    public var ocrPage: Int?                    // physical page inside the OCR pdf
    public var ocrFingerprint: String?          // OCR file content the text came from

    public init(bookID: String, filePath: String, fileName: String, fingerprint: String,
                physicalPage: Int, pageLabel: String?, printedPage: Int?, pageCount: Int,
                title: String?, author: String?, version: String?, language: String?,
                matches: [TermMatch], snippet: String,
                source: String = "native", ocrFilePath: String? = nil,
                ocrPage: Int? = nil, ocrFingerprint: String? = nil) {
        self.bookID = bookID
        self.filePath = filePath
        self.fileName = fileName
        self.fingerprint = fingerprint
        self.physicalPage = physicalPage
        self.pageLabel = pageLabel
        self.printedPage = printedPage
        self.pageCount = pageCount
        self.title = title
        self.author = author
        self.version = version
        self.language = language
        self.matches = matches
        self.snippet = snippet
        self.source = source
        self.ocrFilePath = ocrFilePath
        self.ocrPage = ocrPage
        self.ocrFingerprint = ocrFingerprint
    }
}

/// Metadata filters. Positive filters NEVER match unknown (nil) fields —
/// "unknown" is not silently treated as a match.
public struct SearchFilter: Equatable {
    public var authorContains: String?
    public var versionContains: String?
    public var languageEquals: String?
    /// Restricts the search to one book (used by "load all hits of this book").
    /// Positive filter: only exact bookID matches survive.
    public var bookIDEquals: String?
    /// Source-domain filter (selectable 论文/书籍):
    /// "book" keeps hits from the 书 library root, "paper" from the 论文 root.
    public var sourceDomain: String?
    /// 工具书开关：默认 false 不含工具书；不并入 isActive——纯放行开关，无字段过滤义。
    public var includeToolBooks: Bool = false

    public init(authorContains: String? = nil, versionContains: String? = nil,
                languageEquals: String? = nil, bookIDEquals: String? = nil,
                sourceDomain: String? = nil, includeToolBooks: Bool = false) {
        self.authorContains = authorContains
        self.versionContains = versionContains
        self.languageEquals = languageEquals
        self.bookIDEquals = bookIDEquals
        self.sourceDomain = sourceDomain
        self.includeToolBooks = includeToolBooks
    }

    public var isActive: Bool {
        authorContains != nil || versionContains != nil || languageEquals != nil || bookIDEquals != nil || sourceDomain != nil
    }

    public static func domain(ofPath path: String) -> String {
        let folders = ContentCategoryFolders.current
        if contentCategoryPathMatches(path, folders.papers) { return "paper" }
        return "book"
    }

    func allows(_ hit: SearchHit) -> Bool {
        if let needle = authorContains {
            guard let author = hit.author, author.localizedCaseInsensitiveContains(needle) else { return false }
        }
        if let needle = versionContains {
            guard let version = hit.version, version.localizedCaseInsensitiveContains(needle) else { return false }
        }
        if let lang = languageEquals {
            guard let hitLanguage = hit.language, hitLanguage.caseInsensitiveCompare(lang) == .orderedSame else { return false }
        }
        if let bookID = bookIDEquals {
            guard hit.bookID == bookID else { return false }
        }
        if let domain = sourceDomain {
            guard Self.domain(ofPath: hit.filePath) == domain else { return false }
        }
        return true
    }
}

/// 书级工具书过滤（probe 处调用；与 filter.allows 语义分立——
/// 本判定不依赖 isActive，纯类别放行开关）。
func toolbookExcluded(category: String, filter: SearchFilter?) -> Bool {
    category == ContentCategory.toolbook.rawValue && !(filter?.includeToolBooks ?? false)
}

public struct SearchOptions {
    public var limit: Int
    public var filter: SearchFilter?
    /// Per-book page quota for the returned slice. When set (e.g. 10), the
    /// slice is filled ROUND-ROBIN across books (page 1 of each book, then
    /// page 2 of each book, ...) so high-frequency terms surface many books
    /// instead of letting one book fill the whole window. `totalPageMatches`
    /// and `truncated` still describe the UNQUOTED total. nil = legacy flat
    /// top-N behavior.
    public var perBookLimit: Int?

    public init(limit: Int = 100, filter: SearchFilter? = nil, perBookLimit: Int? = nil) {
        self.limit = max(1, limit)
        self.filter = filter
        self.perBookLimit = perBookLimit
    }
}

public struct SearchResult: Equatable {
    public var hits: [SearchHit]
    /// Pages matching (after policy re-check + filter) before the limit cut.
    public var totalPageMatches: Int
    /// True when totalPageMatches exceeded options.limit.
    public var truncated: Bool
    /// Non-nil EXACTLY when zero pages matched: per-book honest reason
    /// (no text layer / term not matched / excluded by policy / not
    /// assessable). Never claims OCR has been performed.
    public var zeroHitExplanation: ZeroHitExplanation?
    public var countCaliber: CountCaliber

    public init(hits: [SearchHit], totalPageMatches: Int, truncated: Bool,
                zeroHitExplanation: ZeroHitExplanation? = nil,
                countCaliber: CountCaliber = .characterLevel) {
        self.hits = hits
        self.totalPageMatches = totalPageMatches
        self.truncated = truncated
        self.zeroHitExplanation = zeroHitExplanation
        self.countCaliber = countCaliber
    }
}

public enum CountCaliber: Equatable {
    case characterLevel
    case wordLevel
}


public enum SearchError: Error, Equatable, CustomStringConvertible {
    case emptyQuery
    case description(String)
    public var description: String {
        switch self {
        case .emptyQuery: return "empty query"
        case .description(let m): return m
        }
    }
    public static func == (a: SearchError, b: SearchError) -> Bool { "\(a)" == "\(b)" }
}

// MARK: - 分相计时探针（默认关；输出一律走 stderr，stdout 零改动）
public enum SearchPhaseTiming {
    /// CLI --phase-timing 进程内置位（环境变量等效；测试可直接控制）。
    public static var forced = false

    public static var isActive: Bool {
        forced || ProcessInfo.processInfo.environment["LITERATURESEARCH_PHASE_TIMING"] == "1"
    }

    /// 最后一次 searchDetailed 的四相记录（测试/调试面板读取；stderr 之外
    public struct Record: Equatable {
        public var queryMs: Double = 0
        public var materializeMs: Double = 0
        public var verifyMs: Double = 0
        public var candidates: Int = 0
        public var pagesLoaded: Int = 0
        public var totalPageMatches: Int = 0
        /// 两阶段物化探针：阶段一轻量扫描的候选行数（不再全量
        /// 物化；理论上＝候选数）。
        public var lightRowsScanned: Int = 0
        /// 性能门探针：全量物化页数。两阶段下恒＝结果切片长度
        /// ＝min(totalPageMatches, limit)（perBookLimit 提前耗尽轮次时更小），
        /// 不会扩大到全部候选集。
        public var pagesFullyMaterialized: Int = 0
        /// 第五相：零命中诊断（explainZeroHit：全书页统计＋逐书归类）。
        /// 零命中查询才走；有命中的查询恒 0（该相不在其路径上）。此相在
        /// 既有四相之后执行，旧探针看不到它——这正是部分慢查询中
        /// 「四相耗时之和明显小于墙钟时间」的原因。
        public var zeroHintMs: Double = 0
    }

    public private(set) static var lastSearchRecord: Record?

    static func emit(_ line: String) {
        guard isActive else { return }
        FileHandle.standardError.write(Data("[phase] \(line)\n".utf8))
    }

    /// 最近一次 emit 的那行：命中的查询在四相当场就 emit 并在第五相处
    /// 追加；零命中的查询要等 explainZeroHit 跑完才 emit 整行（否则第五相
    /// 在同一次调用里后到，找不到可增补的行）。每次 recordSearch 置位/清空，
    /// 跨调用不残留。
    private static var lastEmittedLine: String?

    static func recordSearch(_ record: Record) {
        lastSearchRecord = record
        if record.totalPageMatches == 0 {
            lastEmittedLine = nil
            return
        }
        let line = "search query=\(Self.ms(record.queryMs))ms materialize=\(Self.ms(record.materializeMs))ms " +
            "verify=\(Self.ms(record.verifyMs))ms candidates=\(record.candidates) " +
            "pages=\(record.pagesLoaded) hits=\(record.totalPageMatches)"
        lastEmittedLine = line
        emit(line)
    }

    /// 零命中诊断相收尾（由 zeroHitExplanation /
    /// recordZeroHintSkip 在拿到结果后调用）。本函数只补 zeroHintMs 字段并
    /// 追加同一行；其余字段不动。零命中的查询在 recordSearch 里没 emit，
    /// 故此处按记录重新排版整行（与 recordSearch 同为一行，只多尾部一相）。
    static func recordZeroHint(ms: Double) {
        guard var record = lastSearchRecord else { return }
        record.zeroHintMs = ms
        lastSearchRecord = record
        let line: String
        if let prior = lastEmittedLine {
            line = prior + " zero_hint=\(Self.ms(ms))ms"
        } else {
            line = "search query=\(Self.ms(record.queryMs))ms materialize=\(Self.ms(record.materializeMs))ms " +
                "verify=\(Self.ms(record.verifyMs))ms candidates=\(record.candidates) " +
                "pages=\(record.pagesLoaded) hits=\(record.totalPageMatches) zero_hint=\(Self.ms(ms))ms"
        }
        lastEmittedLine = line
        emit(line)
    }

    static func ms(_ v: Double) -> String { String(format: "%.1f", v) }
}

/// 检索调试面板的数据结构（SearchService 每次查询填 light 计数；
/// 语法查询的语法层再补充 term 级候选数与正则超时标注）。
public struct QueryDiagnostics: Equatable {
    public var normalizedQuery: String = ""
    public var terms: [String] = []
    /// 各 term 的候选页数（语法层填；现行路径只记交集总数）。
    public var termCandidates: [String: Int] = [:]
    /// 交集后候选页数。
    public var intersectionCount: Int = 0
    public var pagesLoaded: Int = 0
    public var totalPageMatches: Int = 0
    public var truncated: Bool = false
    /// 四相耗时（毫秒）。
    public var queryMs: Double = 0
    public var materializeMs: Double = 0
    public var verifyMs: Double = 0
    /// 语法层：正则超时发生过（调试面板如实标注）。
    public var regexTimedOut: Bool = false
    /// 语法层：AST 概要（无语法查询为空串）。
    public var syntaxSummary: String = ""
    /// 语法层：字段-only 且无正则（——页级计 0 如实基准的提示
    /// 判据；diag.terms 是原串分词恒非空，不能作判据）。
    public var fieldOnlyQuery: Bool = false
    public var countCaliber: CountCaliber = .characterLevel
    public var routedTerms: [String: String] = [:]

    public init() {}
}

public final class SearchService {
    private let store: IndexStore
    /// Optional policy re-check at QUERY time (not only at index time):
    /// hits whose book would now be excluded disappear from results.
    private let policy: ExclusionPolicy?
    /// verify 阶段的页文本源配置（侧车源经 SearchServiceConfig.sidecar 显式注入才生效）。
    let searchConfig: SearchServiceConfig

    /// 最近一次查询的诊断数据（App 内调试面板读取）。
    public private(set) var lastQueryDiagnostics: QueryDiagnostics?

    public init(store: IndexStore, policy: ExclusionPolicy? = nil,
                searchConfig: SearchServiceConfig = SearchServiceConfig()) {
        self.store = store
        self.policy = policy
        self.searchConfig = searchConfig
    }

    /// SearchEngine 协议 init 需求的精确形见证（Swift 对 init 见证要求参数
    /// 列表精确匹配——默认参不满足 init 需求，与方法的默认参规则不同）。
    /// 与指定构造器同体（缺省 config＝现路径）；既有两参调用点行为零变化。
    public convenience init(store: IndexStore, policy: ExclusionPolicy?) {
        self.init(store: store, policy: policy, searchConfig: SearchServiceConfig())
    }

    /// verify 相统一取页口（三路 verify 的唯一缝合点）：配置注入了文本源
    /// 走之，否则直通 `store.pages(rowIDs:)`＝现路径（逐字节同源）。
    var resolvedTextSource: PageTextSource {
        searchConfig.textSource ?? SQLitePageTextSource(store: store)
    }

    /// Convenience wrapper: hits only.
    public func search(_ rawQuery: String, options: SearchOptions = SearchOptions()) throws -> [SearchHit] {
        try searchDetailed(rawQuery, options: options).hits
    }

    /// Public zero-hit explainer (CLI/App): classify WHY a query matched
    /// nothing, per book. Honest categories only; OCR is never claimed.
    public func explainZeroHit(_ rawQuery: String) throws -> ZeroHitExplanation {
        let terms = splitQueryTerms(normalizeQuery(rawQuery))
        guard !terms.isEmpty else { throw SearchError.emptyQuery }
        return explainZeroHit(terms: terms)
    }

    /// Book-level search phase (fast): per-book matching-page counts with book
    /// metadata, policy re-check and metadata filter applied — WITHOUT
    /// materializing page rows. Phase one of the two-phase flow: the overview
    /// lists EVERY matching book; phase two (book-scoped searchDetailed) loads
    /// one book's full hits on demand.
    public struct BookHitSummary: Equatable {
        public let bookID: String
        public let fileName: String
        public let title: String?
        public let author: String?
        public let version: String?
        public let language: String?
        public let pageCount: Int
        public let matchingPages: Int
        /// Pages with a native (original-pdf) text layer — the quality signal
        public let nativeTextPages: Int

        public init(bookID: String, fileName: String, title: String?, author: String?,
                    version: String?, language: String?, pageCount: Int, matchingPages: Int,
                    nativeTextPages: Int) {
            self.bookID = bookID
            self.fileName = fileName
            self.title = title
            self.author = author
            self.version = version
            self.language = language
            self.pageCount = pageCount
            self.matchingPages = matchingPages
            self.nativeTextPages = nativeTextPages
        }
    }

    public func matchingBooks(_ rawQuery: String, filter: SearchFilter? = nil) throws -> [BookHitSummary] {
        // 分派：同 searchDetailed——语法字符才进语法层（零漂移）。
        if QuerySyntax.hasSyntaxCharacter(rawQuery) {
            var diag: QueryDiagnostics? = QueryDiagnostics()
            diag?.normalizedQuery = normalizeQuery(rawQuery)
            let normQ = diag?.normalizedQuery ?? ""
            diag?.terms = splitQueryTerms(normQ)
            diag?.syntaxSummary = (try? QuerySyntax.parse(rawQuery).summary) ?? ""
            if let parsed = try? QuerySyntax.parse(rawQuery) {
                diag?.fieldOnlyQuery = parsed.freeTerms.isEmpty && !parsed.hasRegex
            }
            let result = try matchingBooksSyntax(rawQuery, filter: filter, diagnostics: &diag)
            lastQueryDiagnostics = diag
            return result
        }
        var diagnostics = QueryDiagnostics()
        diagnostics.normalizedQuery = normalizeQuery(rawQuery)
        diagnostics.terms = splitQueryTerms(diagnostics.normalizedQuery)
        defer { lastQueryDiagnostics = diagnostics }

        let normalizedQuery = normalizeQuery(rawQuery)
        let terms = splitQueryTerms(normalizedQuery)
        guard !terms.isEmpty else { throw SearchError.emptyQuery }
        // 英文短词快路：单 ASCII 词且 bigram 候选超阈值
        // 时一次 SQL 出计数，避免将全部候选写入临时表。
        if terms.count == 1, let fastCounts = try store.candidateBookCountsViaFTS(term: terms[0]) {
            var out: [BookHitSummary] = []
            let nativeCounts = (try? store.nativeTextPageCountsByBook()) ?? [:]
            let allBooksMap = (try? store.allBooksCached()) ?? [:]
            for (bid, pages) in fastCounts {
                guard let book = try allBooksMap[bid] ?? store.book(byID: bid) else { continue }
                if let policy {
                    guard policy.allowsBook(realPath: book.realPath, rootPath: book.rootPath, bookID: book.id) else { continue }
                }
                // metadata filter 补检。快路
                // 此前只做 policy 检查，而 GUI 两段式阶段一真实传 filter
                //（AppState matchingBooks 调用），单 ASCII 词激活快路时
                // authorContains/bookIDEquals 等元数据过滤整体失效。补与常规
                // 路径（下方主循环）逐字节同款的 probe+allows 段。
                let probe = SearchHit(bookID: bid, filePath: book.realPath, fileName: book.fileName,
                                      fingerprint: book.fingerprint, physicalPage: 1, pageLabel: nil,
                                      printedPage: nil, pageCount: book.pageCount, title: book.title,
                                      author: book.author, version: book.version, language: book.language,
                                      matches: [], snippet: "", source: "native",
                                      ocrFilePath: nil, ocrPage: nil, ocrFingerprint: nil)
                if toolbookExcluded(category: book.contentCategory, filter: filter) { continue }
                if let filter, filter.isActive {
                    guard filter.allows(probe) else { continue }
                }
                out.append(BookHitSummary(bookID: bid, fileName: book.fileName, title: book.title,
                                          author: book.author, version: book.version,
                                          language: book.language, pageCount: book.pageCount,
                                          matchingPages: pages,
                                          nativeTextPages: nativeCounts[bid] ?? 0))
            }
            // 全序决胜排序。此前的 count-only 排序
            // 在 fastCounts 字典随机迭代序上并列时输出逐进程漂移（同款缺陷曾
            // 致 searchDetailed 输出失稳，见 searchDetailed 内注）；书目级输出
            // 也必须确定为 DB 状态的纯函数。决胜键与 matchingBooksSyntax 一致
            // （fileName），再以 bookID 结算保证严格全序。
            out.sort {
                if $0.matchingPages != $1.matchingPages { return $0.matchingPages > $1.matchingPages }
                if $0.fileName != $1.fileName { return $0.fileName < $1.fileName }
                return $0.bookID < $1.bookID
            }
            // 拼音书目命中段与置前——快路此前提前
            // return，拼音层永远执行不到（falv 在书目级只余 Vexley 碎片
            // 页，倒挂根因之一）。与常规路径共用同段同序，快路形态下拼音
            // 命中书同样直中书名排前；非拼音查询 pinned 为空，零扰动。
            let pinnedFast = try appendPinyinBookHits(to: &out, terms: terms, filter: filter)
            sortBookHitsPinyinPrimary(&out, pinned: pinnedFast)
            return out
        }
        var intersection: Set<String>? = nil
        for term in terms {
            let ids = try store.candidatePageIDs(term: term)
            intersection = intersection.map { $0.intersection(ids) } ?? Set(ids)
            if intersection!.isEmpty { break }   // 页面无命中仍可能拼音命中书，不提前返回
        }
        var out: [BookHitSummary] = []
        if let rowIDs = intersection, !rowIDs.isEmpty {
            let counts = try store.matchingPageCounts(rowIDs: Array(rowIDs))
            // One in-memory aggregation pass instead of per-book COUNT or temp table
            let nativeCounts = (try? store.nativeTextPageCountsByBook()) ?? [:]
            let allBooksMap = (try? store.allBooksCached()) ?? [:]
            for (bid, pages) in counts {
                guard let book = try allBooksMap[bid] ?? store.book(byID: bid) else { continue }
                if let policy {
                    guard policy.allowsBook(realPath: book.realPath, rootPath: book.rootPath, bookID: book.id) else { continue }
                }
                let probe = SearchHit(bookID: bid, filePath: book.realPath, fileName: book.fileName,
                                      fingerprint: book.fingerprint, physicalPage: 1, pageLabel: nil,
                                      printedPage: nil, pageCount: book.pageCount, title: book.title,
                                      author: book.author, version: book.version, language: book.language,
                                      matches: [], snippet: "", source: "native",
                                      ocrFilePath: nil, ocrPage: nil, ocrFingerprint: nil)
                if toolbookExcluded(category: book.contentCategory, filter: filter) { continue }
                if let filter, filter.isActive {
                    guard filter.allows(probe) else { continue }
                }
                out.append(BookHitSummary(bookID: bid, fileName: book.fileName, title: book.title,
                                          author: book.author, version: book.version,
                                          language: book.language, pageCount: book.pageCount,
                                          matchingPages: pages,
                                          nativeTextPages: nativeCounts[bid] ?? 0))
            }
        }
        // 全序决胜排序（同 fast-path 处注：counts
        // 字典迭代序逐进程随机，count-only 排序在并列时不确定）。
        out.sort {
            if $0.matchingPages != $1.matchingPages { return $0.matchingPages > $1.matchingPages }
            if $0.fileName != $1.fileName { return $0.fileName < $1.fileName }
            return $0.bookID < $1.bookID
        }
        // 拼音书目检索：ASCII 字母查询词额外做书名/作者/
        // 文件名的拼音包含匹配（yangshu → 样书一）。命中书若不在页面
        // 命中集合，以 matchingPages=0 追加；store 未建投影（老库未迁移完）
        // 时静默跳过。：段体原样提取为
        // appendPinyinBookHits 与英文快路共用，并按拼音命中置前（Primary
        // Hit）——书名直中书排位于仅含 bigram 字母碎片的页级伪候选之前，
        // 页面命中集合与 policy/filter 语义零改动。
        let pinned = try appendPinyinBookHits(to: &out, terms: terms, filter: filter)
        sortBookHitsPinyinPrimary(&out, pinned: pinned)
        if ProcessInfo.processInfo.environment["LITERATURESEARCH_SEARCH_TRACE"] == "1" {
            FileHandle.standardError.write(Data("[matchingBooks] terms=\(terms) books=\(out.count) topCounts=\(out.prefix(3).map { "\($0.fileName.prefix(12))=\($0.matchingPages)" })\n".utf8))
        }
        return out
    }

    // MARK: - 拼音书目命中段（提取，常规路/英文快路共用）

    /// 拼音书目命中段（原常规路径尾段逐字提取）：ASCII 字母查询词做书名/
    /// 作者/文件名拼音包含匹配，命中书若不在页面命中集合以 matchingPages=0
    /// 追加；policy/filter/nativeTextPages 语义零改动；投影未建静默跳过。
    /// 返回全部拼音命中 bookID（含已在页面命中集合中的书），供置前排序。
    private func appendPinyinBookHits(to out: inout [BookHitSummary], terms: [String], filter: SearchFilter?) throws -> Set<String> {
        var pinned = Set<String>()
        for term in terms where PinyinNorm.isPinyinQuery(term) {
            guard let ids = try? store.bookIDsMatchingPinyin(term), !ids.isEmpty else { continue }
            pinned.formUnion(ids)
            let known = Set(out.map(\.bookID))
            let allBooksMap = (try? store.allBooksCached()) ?? [:]
            var extra: [BookHitSummary] = []
            for id in ids where !known.contains(id) {
                guard let book = try allBooksMap[id] ?? store.book(byID: id) else { continue }
                if let policy {
                    guard policy.allowsBook(realPath: book.realPath, rootPath: book.rootPath, bookID: book.id) else { continue }
                }
                let probe = SearchHit(bookID: id, filePath: book.realPath, fileName: book.fileName,
                                      fingerprint: book.fingerprint, physicalPage: 1, pageLabel: nil,
                                      printedPage: nil, pageCount: book.pageCount, title: book.title,
                                      author: book.author, version: book.version, language: book.language,
                                      matches: [], snippet: "", source: "native",
                                      ocrFilePath: nil, ocrPage: nil, ocrFingerprint: nil)
                if toolbookExcluded(category: book.contentCategory, filter: filter) { continue }
                if let filter, filter.isActive {
                    guard filter.allows(probe) else { continue }
                }
                extra.append(BookHitSummary(bookID: id, fileName: book.fileName, title: book.title,
                                            author: book.author, version: book.version,
                                            language: book.language, pageCount: book.pageCount,
                                            matchingPages: 0,
                                            nativeTextPages: (try? store.nativeTextPageCount(bookID: id)) ?? 0))
            }
            out.append(contentsOf: extra)
        }
        return pinned
    }

    /// 置前排序：拼音命中书（Primary Hit）排位于仅含 bigram 字母碎片
    private func sortBookHitsPinyinPrimary(_ out: inout [BookHitSummary], pinned: Set<String>) {
        out.sort {
            let aPrimary = pinned.contains($0.bookID)
            let bPrimary = pinned.contains($1.bookID)
            if aPrimary != bPrimary { return aPrimary }
            if $0.matchingPages != $1.matchingPages { return $0.matchingPages > $1.matchingPages }
            if $0.fileName != $1.fileName { return $0.fileName < $1.fileName }
            return $0.bookID < $1.bookID
        }
    }

    func routeTerm(_ term: String) -> TermRoute {
        QuerySyntax.syntaxRoute(term: term, wftsReady: store.wftsReadyForWordPath())
    }

    /// Literal multi-term search: every whitespace-separated term must appear on
    /// the page; ALL occurrences per page are returned. Matching is literal
    /// (no regex, no FTS query syntax), after identical normalization on both sides.
    public func searchDetailed(_ rawQuery: String, options: SearchOptions = SearchOptions()) throws -> SearchResult {
        // 分派：查询串含任一语法字符才进语法层；
        // 其余查询走现行路径——本行以下代码对无语法查询逐字节不变。
        if QuerySyntax.hasSyntaxCharacter(rawQuery) {
            var diag: QueryDiagnostics? = QueryDiagnostics()
            diag?.normalizedQuery = normalizeQuery(rawQuery)
            let normQ = diag?.normalizedQuery ?? ""
            diag?.terms = splitQueryTerms(normQ)
            diag?.syntaxSummary = (try? QuerySyntax.parse(rawQuery).summary) ?? ""
            if let parsed = try? QuerySyntax.parse(rawQuery) {
                diag?.fieldOnlyQuery = parsed.freeTerms.isEmpty && !parsed.hasRegex
            }
            let result = try searchDetailedSyntax(rawQuery, options: options, diagnostics: &diag)
            diag?.totalPageMatches = result.totalPageMatches
            diag?.truncated = result.truncated
            lastQueryDiagnostics = diag
            return result
        }
        var diagnostics = QueryDiagnostics()
        diagnostics.normalizedQuery = normalizeQuery(rawQuery)
        diagnostics.terms = splitQueryTerms(diagnostics.normalizedQuery)
        defer { lastQueryDiagnostics = diagnostics }

        let normalizedQuery = normalizeQuery(rawQuery)
        let terms = splitQueryTerms(normalizedQuery)
        guard !terms.isEmpty else { throw SearchError.emptyQuery }

        let termRoutes = terms.map { routeTerm($0) }
        for (t, r) in zip(terms, termRoutes) { diagnostics.routedTerms[t] = r.routeName() }
        if termRoutes.allSatisfy({ $0 == .latinWordPath }) {
            return try searchDetailedWordPath(terms: terms, options: options, diagnostics: &diagnostics)
        }

        let candidate = try selectSearchCandidates(terms: terms, normalizedQuery: normalizedQuery, diagnostics: &diagnostics)
        guard let narrowed = try narrowSearchCandidates(candidate, options: options, diagnostics: &diagnostics) else {
            return SearchResult(hits: [], totalPageMatches: 0, truncated: false,
                                zeroHitExplanation: zeroHitExplanation(terms: terms))
        }
        let stage1 = try scanSearchStage1(narrowed: narrowed, terms: terms, options: options)
        return try materializeSearchStage2(stage1: stage1, terms: terms, options: options,
                                           candidateCount: candidate.count, diagnostics: &diagnostics)
    }

    private struct SearchCandidateSelection {
        let isFastPath: Bool
        let fastOrderedRowIDs: [Int64]
        let rowIDs: Set<String>?
        let count: Int
    }

    private struct NarrowedSearchCandidates {
        let isFastPath: Bool
        let fastOrderedRowIDs: [Int64]
        let regularOrderedRowIDs: [String]
    }

    private struct SearchStage1Scan {
        let stage1: [Stage1Hit]
        let lightRows: [IndexStore.LightPageRow]
        let preparedTerms: [PreparedSearchTerm]
        let startedAt: Date
    }

    /// 候选选择三轨（fast path / 缓存 / 交集）——原 searchDetailed 主体段逐字随迁；
    /// queryMs 计时段（__tQuery）覆盖本函数全部逻辑，queryMs 与 intersectionCount
    private func selectSearchCandidates(terms: [String], normalizedQuery: String,
                                        diagnostics: inout QueryDiagnostics) throws -> SearchCandidateSelection {
        // Candidate page row-ids per term (AND semantics via intersection).
        // The store returns complete candidate sets — no silent truncation here.
        // Repeated queries reuse the persisted candidate cache (a 2-char CJK
        // term's LIKE fallback scans the whole pages btree); any write purges it.
        //
        // 页级契约（不变式）：searchDetailed 返回页级命中，书目级快查只允许
        // 走 matchingBooks。书目级 FTS 计数会破坏三件事：
        // 1) total 语义：FTS 计数和 ≠ 页级校验命中数；
        // 2) hits 结构：书目级全量无 limit，缺页级 top-20，拼音命中断言失效；
        // 3) 确定性：fastCounts 字典迭代序逐进程随机 + unstable sort，
        // 并列书序每次运行不同，两次运行无法逐字节一致。
        // 确定性快路与下推流水线
        // 快路仅在单 ASCII 词、长度≥2、bigram 倒排规模超 2MB 且索引健康时激活。
        // 【与既有 CLI 输出逐字节等价·双轨分派契约】：
        // 1. 若激活：直出有序 [Int64]，并在 Stage1 直接通过 SQLite C 层 LIKE 谓词下推，
        //    减少假候选物化开销；
        // 2. 若未激活：回落常规两阶段物化，逐字节执行路径与既有实现恒等；
        // 3. 两轨产出的 Stage1 命中序列均严格保持 rowid ASC，为后置仲裁与切片提供一致的同构输入流。
        // 【确定性宣称基准（措辞收敛，项目组）】：以上全部
        // 确定性保证均在**单进程顺序语义**下成立；并发写入下的快照一致性
            // 并发场景由 (bookID, page_number) 主键确定配对。

        // 精确配对兜「不错配」之底（消失行跳过），不宣称快照集完整。
        var isFastPath = false
        var fastOrderedRowIDs: [Int64] = []
        var rowIDs: Set<String>? = nil
        let __tQuery = Date()

        if terms.count == 1,
           let fastIDs = try store.candidateRowIDsViaFTS(term: terms[0]) {
            isFastPath = true
            fastOrderedRowIDs = fastIDs
        } else if let cached = try? store.cachedCandidateRowIDs(normalizedQuery: normalizedQuery) {
            rowIDs = Set(cached)
        } else {
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
            if let intersection {
                rowIDs = intersection
                // 空集绝不缓存：重建/导入进行中的空库查询若写入空集，会持续
                // 遮蔽后续已导入数据的真实命中（毒缓存）。
                if !intersection.isEmpty {
                    try? store.storeCandidateRowIDsCache(normalizedQuery: normalizedQuery, rowIDs: Array(intersection))
                }
            }
        }

        let candidateCount = isFastPath ? fastOrderedRowIDs.count : (rowIDs?.count ?? 0)
        diagnostics.intersectionCount = candidateCount
        diagnostics.queryMs = Date().timeIntervalSince(__tQuery) * 1000
        return SearchCandidateSelection(isFastPath: isFastPath, fastOrderedRowIDs: fastOrderedRowIDs, rowIDs: rowIDs, count: candidateCount)

    }

    /// 书域收窄与排序（原 searchDetailed 主体段逐字随迁）：含三个 zero-hit 早退
    /// 分支；早退时由本体统一构造 SearchResult 返回（defer 语义不变）。
    private func narrowSearchCandidates(_ candidate: SearchCandidateSelection, options: SearchOptions,
                                        diagnostics: inout QueryDiagnostics) throws -> NarrowedSearchCandidates? {
        let isFastPath = candidate.isFastPath
        var fastOrderedRowIDs = candidate.fastOrderedRowIDs
        let rowIDs = candidate.rowIDs
        var regularOrderedRowIDs: [String] = []

        if isFastPath {
            guard !fastOrderedRowIDs.isEmpty else {
                diagnostics.totalPageMatches = 0
                return nil
            }
            // 书域过滤（保留 rowid ASC 全序）
            if let bookScope = options.filter?.bookIDEquals {
                let bookPages = try store.candidateRowIDs(bookID: bookScope)
                let bookPageIDs = Set(bookPages.compactMap(Int64.init))
                // 【为何与既有 CLI 输出逐字节等价·全序保全】：
                // Array.filter 依序保留元素，使得 fastOrderedRowIDs 依然严格保持 rowid ASC 单调递增。
                fastOrderedRowIDs = fastOrderedRowIDs.filter { bookPageIDs.contains($0) }
                if fastOrderedRowIDs.isEmpty {
                    diagnostics.totalPageMatches = 0
                    return nil
                }
            }
        } else {
            guard let rawIDs = rowIDs, !rawIDs.isEmpty else {
                diagnostics.totalPageMatches = 0
                return nil
            }
            // Book-scoped searches never need the whole library's page rows:
            // narrow candidates to the book BEFORE materializing anything.
            var scopedRowIDs = rawIDs
            if let bookScope = options.filter?.bookIDEquals {
                let bookPages = try store.candidateRowIDs(bookID: bookScope)
                scopedRowIDs = rawIDs.intersection(bookPages)
                if scopedRowIDs.isEmpty {
                    diagnostics.totalPageMatches = 0
                    return nil
                }
            }
            regularOrderedRowIDs = scopedRowIDs.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
        }

        return NarrowedSearchCandidates(isFastPath: isFastPath, fastOrderedRowIDs: fastOrderedRowIDs, regularOrderedRowIDs: regularOrderedRowIDs)
    }

    private func scanSearchStage1(narrowed: NarrowedSearchCandidates, terms: [String],
                                  options: SearchOptions) throws -> SearchStage1Scan {
        let isFastPath = narrowed.isFastPath
        let fastOrderedRowIDs = narrowed.fastOrderedRowIDs
        let regularOrderedRowIDs = narrowed.regularOrderedRowIDs

        // 复用同一 round-robin 函数（只消费 bookID，骨架序＝旧 hits 序）。
        var stage1: [Stage1Hit] = []
        let __t0 = Date()
        let lightRows: [IndexStore.LightPageRow]
        let useSQLPrefilter = terms.count == 1
        if useSQLPrefilter {
            let prefilterIDs: [Int64] = isFastPath
                ? fastOrderedRowIDs
                : regularOrderedRowIDs.compactMap(Int64.init)
            lightRows = try store.lightPagesFiltered(rowIDs: prefilterIDs, term: terms[0])
        } else {
            lightRows = try store.lightPages(rowIDs: regularOrderedRowIDs)
        }

        var policyVerdicts: [String: Bool] = [:]
        let preparedTerms = terms.map { PreparedSearchTerm(term: $0) }
        var bookCache: [String: IndexStore.BookRow] = [:]
        // OCR pairing per book, fetched lazily and cached for the run.
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

        for page in lightRows {
            guard let book: IndexStore.BookRow = {
                if let cached = bookCache[page.bookID] { return cached }
                let fetched = try? store.book(byID: page.bookID)
                bookCache[page.bookID] = fetched
                return fetched
            }() else { continue }

            // Query-time policy re-check (path/ID based; no file content is read).
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

            // Metadata filter: positive filters never match unknown fields.
            // (probe 字段全部来自轻量行＋书行，两阶段与全量路径同值)
            if toolbookExcluded(category: book.contentCategory, filter: options.filter) { continue }
            if let filter = options.filter, filter.isActive {
                let probe = SearchHit(bookID: page.bookID, filePath: book.realPath, fileName: book.fileName,
                                      fingerprint: book.fingerprint, physicalPage: page.pageNumber,
                                      pageLabel: page.label, printedPage: page.printedPage, pageCount: book.pageCount,
                                      title: book.title, author: book.author, version: book.version, language: book.language,
                                      matches: [], snippet: "",
                                      source: isOCR ? "ocr" : "native",
                                      ocrFilePath: isOCR ? ocr.path : nil,
                                      ocrPage: isOCR ? ocr.map[page.pageNumber] : nil,
                                      ocrFingerprint: isOCR ? ocr.fp : nil)
                guard filter.allows(probe) else { continue }
            }

            // Stage-one term validation keeps SQL and in-memory substring checks equivalent.
            // useSQLPrefilter 下，p.text_norm LIKE '%term%' 已在 SQLite 内部按字节
            // 精确判定通过（快路与常规单词路径同一判据）；
            // 多词常规路径仍由 Swift 内存 Array(page.textNorm.utf8) + firstRange 进行 ∃ 校验。
            // 两者对规范化单词项「text_norm 子串存在性」的判定同构；但阶段一通过只是
            // 阶段二收录的必要非充分条件：阶段二 utf8Matches 还需 normalizedOriginalRange
             // （norm blob 覆盖）映射成功，短损页会计入 total 而不入 hits。
             // 中文词级查询保留明确的分词结果，短语查询不作猜测。
            // 词路计数走 FTS5 词级索引后，此边界仅余 CJK/拼音/子串路（本文件词路分派处）。
            if !useSQLPrefilter {
                let pageNormBytes = Array(page.textNorm.utf8)
                var anyTermMatched = false
                for prepared in preparedTerms {
                    guard !prepared.utf8Bytes.isEmpty else { continue }
                    if Self.firstRange(pageNormBytes, prepared.utf8Bytes, from: 0) != nil {
                        anyTermMatched = true
                        break
                    }
                }
                guard anyTermMatched else { continue }
            }

            stage1.append(Stage1Hit(rowID: page.rowID, book: book, page: page,
                                    isOCR: isOCR, ocrPath: ocr.path,
                                    ocrPage: ocr.map[page.pageNumber], ocrFingerprint: ocr.fp))
        }

        return SearchStage1Scan(stage1: stage1, lightRows: lightRows, preparedTerms: preparedTerms, startedAt: __t0)
    }

    /// 阶段二仲裁与物化（原 searchDetailed 主体段逐字随迁）：round-robin →
    /// 骨架构建 → pairStage2Rows → hits 组装 → diagnostics 收尾 →
    /// SearchPhaseTiming.recordSearch → 返回 SearchResult。
    private func materializeSearchStage2(stage1 stage1Scan: SearchStage1Scan, terms: [String],
                                         options: SearchOptions, candidateCount: Int,
                                         diagnostics: inout QueryDiagnostics) throws -> SearchResult {
        let stage1 = stage1Scan.stage1
        let lightRows = stage1Scan.lightRows
        let preparedTerms = stage1Scan.preparedTerms
        let __t0 = stage1Scan.startedAt
        let total = stage1.count
        // 阶段二仲裁：与旧路径同一 round-robin 函数跑在同一顺序的骨架行上
        // 【为何与既有 CLI 输出逐字节等价·round-robin 语义恒等】：
        // 骨架序列严格按 rowid ASC 注入，各书首次露面顺序（bookOrder）、书内各页升序排布
        // 以及逐轮出队配额仲裁，与基线全量路径严格一致。
        let skeletons: [SearchHit] = stage1.map { h in
            SearchHit(bookID: h.book.id, filePath: h.book.realPath, fileName: h.book.fileName,
                      fingerprint: h.book.fingerprint, physicalPage: h.page.pageNumber,
                      pageLabel: h.page.label, printedPage: h.page.printedPage, pageCount: h.book.pageCount,
                      title: h.book.title, author: h.book.author, version: h.book.version, language: h.book.language,
                      matches: [], snippet: "",
                      source: h.isOCR ? "ocr" : "native",
                      ocrFilePath: h.isOCR ? h.ocrPath : nil,
                      ocrPage: h.isOCR ? h.ocrPage : nil,
                      ocrFingerprint: h.isOCR ? h.ocrFingerprint : nil)
        }
        let sliceSkeletons: [SearchHit]
        if let quota = options.perBookLimit, quota > 0 {
            sliceSkeletons = Self.roundRobinByBook(skeletons, perBookLimit: quota, limit: options.limit)
        } else {
            sliceSkeletons = Array(skeletons.prefix(options.limit))
        }
        // 骨架 → stage1 回查：骨架由 stage1 行全字段派生，且 (book,page) 在
        // 候选集内唯一（rowid 唯一，一行一 (book,page)），可作精确键。
        var skeletonIndex: [SearchHit: Int] = [:]
        for (i, sk) in skeletons.enumerated() { skeletonIndex[sk] = i }
        let selected = sliceSkeletons.compactMap { sk in skeletonIndex[sk].map { stage1[$0] } }
        let fullRows = try resolvedTextSource.pages(rowIDs: selected.map { String($0.rowID) })
        diagnostics.materializeMs = Date().timeIntervalSince(__t0) * 1000
        diagnostics.pagesLoaded = fullRows.count
        if ProcessInfo.processInfo.environment["LITERATURESEARCH_SEARCH_TRACE"] == "1" {
            FileHandle.standardError.write(Data("[searchDetailed] candidates=\(candidateCount) lightScanned=\(lightRows.count) pagesFullyMaterialized=\(fullRows.count) totalMatches=\(total) limit=\(options.limit) bookScope=\(options.filter?.bookIDEquals ?? "-") cost=\(Date().timeIntervalSince(__t0))s\n".utf8))
        }
        let __tVerify = Date()
        var hits: [SearchHit] = []
        hits.reserveCapacity(fullRows.count)
        // 【为何与既有 CLI 输出逐字节等价·Top-20 逐字节恒等】：
        // 选出 Top-K 后，Stage2 调用未作修改的 store.pages，完全复用 utf8Matches 与 snippet，
        // 结果输出的所有字段（rank, bookID, physicalPage, fileName, snippet, matches）与基线 100% 逐字节吻合。
        // Stage1→Stage2 间隙若遇并发写（页行删除），
        // pages 保序但短数组，zip 会把 selected[i] 配给 found[j≠i]（张冠李戴：
        // 骨架的书/页元数据配到别的页文本上）。改按页主键 (bookID, physicalPage)
        // 精确配对——无并发场景与 zip 逐字节一致（输出零漂移），并发场景只跳过
        // 真正消失的页行，绝不错配；计数不齐时向 stderr 输出记录。
        if fullRows.count != selected.count {
            FileHandle.standardError.write(Data("[searchDetailed] concurrent-write guard: stage2 rows \(fullRows.count) != selected \(selected.count); paired by (bookID,page)\n".utf8))
        }
        for (sk, page) in Self.pairStage2Rows(skeletons: sliceSkeletons, fullRows: fullRows) {
            guard let idx = skeletonIndex[sk], idx < stage1.count else { continue }
            let s1 = stage1[idx]
            // Locate ALL occurrences of every term on this page via UTF-8 byte search.
            let pageNormBytes = Array(page.textNorm.utf8)
            let matches = Self.utf8Matches(page: page, pageNormBytes: pageNormBytes, preparedTerms: preparedTerms)
            guard !matches.isEmpty else { continue }

            hits.append(SearchHit(
                bookID: s1.book.id,
                filePath: s1.book.realPath,
                fileName: s1.book.fileName,
                fingerprint: s1.book.fingerprint,
                physicalPage: page.pageNumber,
                pageLabel: page.label,
                printedPage: page.printedPage,
                pageCount: s1.book.pageCount,
                title: s1.book.title,
                author: s1.book.author,
                version: s1.book.version,
                language: s1.book.language,
                matches: matches,
                snippet: Self.snippet(in: page.textOriginal, around: matches.map(\.originalUTF16Range)),
                source: s1.isOCR ? "ocr" : "native",
                ocrFilePath: s1.isOCR ? s1.ocrPath : nil,
                ocrPage: s1.isOCR ? s1.ocrPage : nil,
                ocrFingerprint: s1.isOCR ? s1.ocrFingerprint : nil))
        }
        diagnostics.verifyMs = Date().timeIntervalSince(__tVerify) * 1000
        let truncated = total > options.limit
        diagnostics.totalPageMatches = total
        diagnostics.truncated = truncated
        SearchPhaseTiming.recordSearch(.init(
            queryMs: diagnostics.queryMs,
            materializeMs: diagnostics.materializeMs,
            verifyMs: diagnostics.verifyMs,
            candidates: candidateCount,
            pagesLoaded: fullRows.count,
            totalPageMatches: total,
            lightRowsScanned: lightRows.count,
            pagesFullyMaterialized: fullRows.count))
        return SearchResult(
            hits: hits,
            totalPageMatches: total,
            truncated: truncated,
            // Every candidate filtered away (policy/filter) is also a zero-hit
            // case the user is entitled to see explained.
            zeroHitExplanation: total == 0 ? zeroHitExplanation(terms: terms) : recordZeroHintSkip()
        )
    }


    /// 词路分支：候选+计数一体（FTS5 MATCH doclist 单趟）→ policy/filter/
    /// 书域在线校验 → round-robin Top-K → 仅 Top-K 物化＋wordMatches 词边界
    /// 验证。与常规路径的语义分界：
    ///   · 计数=拉丁词级（token 语义，CountCaliber.wordLevel 如实透传）；
    ///   · 候选≈真值（无 bigram 假候选税，不经 2MB 门槛/无 LIKE 下推必要）；
    private func searchDetailedWordPath(terms: [String], options: SearchOptions,
                                        diagnostics: inout QueryDiagnostics) throws -> SearchResult {
        diagnostics.countCaliber = .wordLevel
        let preparedTerms = terms.map { PreparedSearchTerm(term: $0) }
        // 多词项：quoteForFTS 包裹后按 FTS5 隐式 AND 连接（与现行
        // AND-of-terms 契约同形）。词路词项恒纯 [a-z0-9]+（路由保证），
        // 引号内即单 token 字符串，FTS5 词组语义=整 token 序列恰配。
        let wordQuery = terms.map { quoteForFTS($0) }.joined(separator: " ")
        let __tQuery = Date()
        let candidateRowIDs = try store.wordPathCandidateRowIDs(match: wordQuery)
        diagnostics.intersectionCount = candidateRowIDs.count
        diagnostics.queryMs = Date().timeIntervalSince(__tQuery) * 1000

        // 计数+骨架同一单趟（rowid ASC）：book_id 取自常驻 rowidToBookIDCache
        // （零 DB 读）；per-book policy 判定缓存 policyVerdicts；filter probe
        // 用 allBooksCache。ocr.sourced 不参与计数（与常规路径同则——sourcing
        // 只标注来源，不过滤页；展示行的 OCR 标注在下方 pairingCache 段）。
        let __t0 = Date()
        let mapping = try store.rowidToBookIDMappingCached()
        let allBooksMap = (try? store.allBooksCached()) ?? [:]
        var policyVerdicts: [String: Bool] = [:]
        var accepted: [Int64] = []
        accepted.reserveCapacity(min(candidateRowIDs.count, 65536))
        let bookScope = options.filter?.bookIDEquals
        for rowid in candidateRowIDs {
            guard let bid = mapping[rowid] else { continue }
            if let bookScope, bid != bookScope { continue }   // 书域在流内收窄
            guard let book = allBooksMap[bid] else { continue }
            if let policy {
                let allowed = policyVerdicts[bid] ?? {
                    let ok = policy.allowsBook(realPath: book.realPath, rootPath: book.rootPath, bookID: book.id)
                    policyVerdicts[bid] = ok
                    return ok
                }()
                guard allowed else { continue }
            }
            if toolbookExcluded(category: book.contentCategory, filter: options.filter) { continue }
            if let filter = options.filter, filter.isActive {
                // probe 字段全部来自书行。allows 只读 author/version/language/
                // bookID/filePath（＋sourceDomain）——页级字段（physicalPage/
                // label/printedPage/source）恒不被读取，与常规路径逐字段同值。
                let probe = SearchHit(bookID: bid, filePath: book.realPath, fileName: book.fileName,
                                      fingerprint: book.fingerprint, physicalPage: 1, pageLabel: nil,
                                      printedPage: nil, pageCount: book.pageCount, title: book.title,
                                      author: book.author, version: book.version, language: book.language,
                                      matches: [], snippet: "", source: "native",
                                      ocrFilePath: nil, ocrPage: nil, ocrFingerprint: nil)
                guard filter.allows(probe) else { continue }
            }
            accepted.append(rowid)
        }
        let total = accepted.count
        if ProcessInfo.processInfo.environment["LITERATURESEARCH_SEARCH_TRACE"] == "1" {
            FileHandle.standardError.write(Data(
                "[searchDetailed-word] terms=\(terms) candidates=\(candidateRowIDs.count) accepted=\(total) queryMs=\(diagnostics.queryMs)\n".utf8))
        }
        guard total > 0 else {
            diagnostics.totalPageMatches = 0
            diagnostics.materializeMs = Date().timeIntervalSince(__t0) * 1000
            return SearchResult(hits: [], totalPageMatches: 0, truncated: false,
                                zeroHitExplanation: zeroHitExplanation(terms: terms, countCaliber: .wordLevel),
                                countCaliber: .wordLevel)
        }

        // Top-K 切片：roundRobinByBook 复用既有函数（书首现序/书内升序/
        // 每书配额轮转语义零改动）。骨架是选择脚手架：轮转只读 bookID；
        // physicalPage 以接受序占位（下标+1 双射，供 scaffold→rowid 回查），
        // 绝不进入输出——展示行字段全部来自下方 lightPages＋pages 全量物化。
        var scaffolds: [SearchHit] = []
        scaffolds.reserveCapacity(accepted.count)
        for (i, rowid) in accepted.enumerated() {
            guard let bid = mapping[rowid], let book = allBooksMap[bid] else { continue }
            scaffolds.append(SearchHit(bookID: bid, filePath: book.realPath, fileName: book.fileName,
                                       fingerprint: book.fingerprint, physicalPage: i + 1, pageLabel: nil,
                                       printedPage: nil, pageCount: book.pageCount, title: book.title,
                                       author: book.author, version: book.version, language: book.language,
                                       matches: [], snippet: "", source: "native",
                                       ocrFilePath: nil, ocrPage: nil, ocrFingerprint: nil))
        }
        let sliceScaffolds: [SearchHit]
        if let quota = options.perBookLimit, quota > 0 {
            sliceScaffolds = Self.roundRobinByBook(scaffolds, perBookLimit: quota, limit: options.limit)
        } else {
            sliceScaffolds = Array(scaffolds.prefix(options.limit))
        }
        // 保持 round-robin 输出序（与常规路径 hits 序语义一致：书首现序×
        // 每书配额轮转）；scaffold.physicalPage=接受序下标+1 的双射供回查。
        let selectedRowIDs = sliceScaffolds.map { accepted[$0.physicalPage - 1] }
        // 分界线以下只对 Top-K 展示行做字符级工作：真实轻元数据（页码/标签/
        // 印刷页码）→ 全量物化 → wordMatches 词边界验证与 matches 定位。
        let selectedIDStrings = selectedRowIDs.map { String($0) }
        let lightRows = try store.lightPages(rowIDs: selectedIDStrings)
        let fullRows = try resolvedTextSource.pages(rowIDs: selectedIDStrings)
        diagnostics.materializeMs = Date().timeIntervalSince(__t0) * 1000
        diagnostics.pagesLoaded = fullRows.count

        let __tVerify = Date()
        // 展示骨架（真实元数据）＋Stage2 精确配对：与常规路径同构
        //（book 缓存＋pairing 缓存＋pairStage2Rows 按 (bookID,page) 主键配对，
            // 并发写入时按稳定主键配对。

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
        var displaySkeletons: [SearchHit] = []
        displaySkeletons.reserveCapacity(lightRows.count)
        for page in lightRows {
            guard let book: IndexStore.BookRow = {
                if let cached = bookCache[page.bookID] { return cached }
                let fetched = try? store.book(byID: page.bookID)
                bookCache[page.bookID] = fetched
                return fetched
            }() else { continue }
            let ocr = pairing(for: book)
            let isOCR = ocr.sourced.contains(page.pageNumber)
            displaySkeletons.append(SearchHit(
                bookID: page.bookID, filePath: book.realPath, fileName: book.fileName,
                fingerprint: book.fingerprint, physicalPage: page.pageNumber,
                pageLabel: page.label, printedPage: page.printedPage, pageCount: book.pageCount,
                title: book.title, author: book.author, version: book.version, language: book.language,
                matches: [], snippet: "",
                source: isOCR ? "ocr" : "native",
                ocrFilePath: isOCR ? ocr.path : nil,
                ocrPage: isOCR ? ocr.map[page.pageNumber] : nil,
                ocrFingerprint: isOCR ? ocr.fp : nil))
        }
        var hits: [SearchHit] = []
        hits.reserveCapacity(fullRows.count)
        for (sk, page) in Self.pairStage2Rows(skeletons: displaySkeletons, fullRows: fullRows) {
            let pageNormBytes = Array(page.textNorm.utf8)
            // 词边界验证与 matches 定位（替代 firstRange 全页扫描的判定层；
            // 每词项全量报告，与 utf8Matches 同一坐标映射链）。
            var matches: [SearchHit.TermMatch] = []
            for prepared in preparedTerms {
                matches.append(contentsOf: Self.wordMatches(page: page, pageNormBytes: pageNormBytes,
                                                            preparedTerm: prepared))
            }
            guard !matches.isEmpty else { continue }
            hits.append(SearchHit(
                bookID: sk.bookID,
                filePath: sk.filePath,
                fileName: sk.fileName,
                fingerprint: sk.fingerprint,
                physicalPage: page.pageNumber,
                pageLabel: page.label,
                printedPage: page.printedPage,
                pageCount: sk.pageCount,
                title: sk.title,
                author: sk.author,
                version: sk.version,
                language: sk.language,
                matches: matches,
                snippet: Self.snippet(in: page.textOriginal, around: matches.map(\.originalUTF16Range)),
                source: sk.source,
                ocrFilePath: sk.ocrFilePath,
                ocrPage: sk.ocrPage,
                ocrFingerprint: sk.ocrFingerprint))
        }
        diagnostics.verifyMs = Date().timeIntervalSince(__tVerify) * 1000
        let truncated = total > options.limit
        diagnostics.totalPageMatches = total
        diagnostics.truncated = truncated
        SearchPhaseTiming.recordSearch(.init(
            queryMs: diagnostics.queryMs,
            materializeMs: diagnostics.materializeMs,
            verifyMs: diagnostics.verifyMs,
            candidates: candidateRowIDs.count,
            pagesLoaded: fullRows.count,
            totalPageMatches: total,
            lightRowsScanned: lightRows.count,
            pagesFullyMaterialized: fullRows.count))
        return SearchResult(
            hits: hits,
            totalPageMatches: total,
            truncated: truncated,
            zeroHitExplanation: total == 0
                ? zeroHitExplanation(terms: terms, countCaliber: .wordLevel) : recordZeroHintSkip(),
            countCaliber: .wordLevel)
    }

    /// 阶段一轻量命中记录：足够驱动 round-robin 仲裁与最终
    /// SearchHit 组装（书行＋页轻行＋OCR 配对），不携带重文本与坐标 blob。
    private struct Stage1Hit {
        let rowID: Int64
        let book: IndexStore.BookRow
        let page: IndexStore.LightPageRow
        let isOCR: Bool
        let ocrPath: String?
        let ocrPage: Int?
        let ocrFingerprint: String?
    }

    /// Stage1 骨架 ↔ Stage2 全量行精确配对。
    /// pages(rowIDs:) 输出保序但可能因并发删页短数组，位置 zip 会错配
    /// （selected[i] ↔ found[j≠i]）。此助手以页主键 (bookID, physicalPage)
    /// 建字典精确配对：无并发场景与 zip 逐字节同结果；并发场景只丢弃真正
    /// 消失的页行，绝不错配。internal 供测试直接验证（IndexingRegression 套件）。
    /// 唯一性依据（补证）：pages 表
    /// PRIMARY KEY(book_id, page_number)（IndexStore.swift schema 头注）——
    /// 同书同物理页至多一行，byKey 字典键为单射（一键永不被两行覆盖），
    /// 配对即按页主键的精确一一映射；输入行序的保序由上游契约保证
    /// （pages 保序＋lightPagesFiltered／candidateRowIDsViaFTS 有序注）。
    static func pairStage2Rows(skeletons: [SearchHit],
                               fullRows: [IndexStore.PageRow]) -> [(skeleton: SearchHit, row: IndexStore.PageRow)] {
        var byKey: [String: IndexStore.PageRow] = [:]
        byKey.reserveCapacity(fullRows.count)
        for row in fullRows { byKey["\(row.bookID)\u{1F}#\(row.pageNumber)"] = row }
        var out: [(skeleton: SearchHit, row: IndexStore.PageRow)] = []
        out.reserveCapacity(skeletons.count)
        for sk in skeletons {
            if let row = byKey["\(sk.bookID)\u{1F}#\(sk.physicalPage)"] {
                out.append((skeleton: sk, row: row))
            }
        }
        return out
    }

    /// Round-robin interleave: page 1 of each book (in first-match order),
    /// then page 2 of each book, ... up to `perBookLimit` pages per book and
    /// `limit` hits overall. Guarantees breadth for high-frequency terms.
    static func roundRobinByBook(_ hits: [SearchHit], perBookLimit: Int, limit: Int) -> [SearchHit] {
        var queues: [String: [SearchHit]] = [:]
        var bookOrder: [String] = []
        for hit in hits {
            if queues[hit.bookID] == nil { bookOrder.append(hit.bookID) }
            queues[hit.bookID, default: []].append(hit)
        }
        var out: [SearchHit] = []
        out.reserveCapacity(limit)
        for round in 0..<perBookLimit {
            for book in bookOrder {
                let queue = queues[book]!
                if round < queue.count {
                    out.append(queue[round])
                    if out.count == limit { return out }
                }
            }
        }
        return out
    }

    /// Builds a ±context snippet from the original page text (verbatim, with
    /// ellipses marking truncation). Offsets are UTF-16 based.
    public static func snippet(in original: String, around ranges: [Range<Int>], context: Int = 40) -> String {
        guard let window = snippetWindow(in: original, around: ranges, context: context) else { return "" }
        let sliceStart = String.Index(utf16Offset: window.window.lowerBound, in: original)
        let sliceEnd = String.Index(utf16Offset: window.window.upperBound, in: original)
        return (window.ellipsisPrefix ? "…" : "") + String(original[sliceStart..<sliceEnd])
            + (window.ellipsisSuffix ? "…" : "")
    }

    /// snippet 窗口计算与 `snippet(in:around:)` 解耦的纯函数版
    /// （高亮组装需要「原文坐标＋窗口＋省略号位」三元组，供 UI 层把
    /// matches[].originalUTF16Range 平移进 snippet 坐标系着色——渲染层
    /// 零猜测）。窗口/省略号逻辑与 snippet 逐字节同源（snippet 即改由
    /// 本函数派生，单一事实路径）。匹配整页原文之外的 range 一律返回 nil
    /// （调用方降级为无高亮纯文本）。
    public static func snippetWindow(in original: String, around ranges: [Range<Int>],
                                     context: Int = 40) -> (window: Range<Int>, ellipsisPrefix: Bool, ellipsisSuffix: Bool)? {
        guard let first = ranges.min(by: { $0.lowerBound < $1.lowerBound }),
              let last = ranges.max(by: { $0.upperBound < $1.upperBound }) else { return nil }
        let total = original.utf16.count
        guard total > 0,
              first.lowerBound >= 0, last.upperBound <= total, first.lowerBound <= last.upperBound else { return nil }
        let start = max(0, first.lowerBound - context)
        let end = min(total, last.upperBound + context)
        return (start..<end, start > 0, end < total)
    }

    // MARK: 父子块检索：命中句 → 页/节上下文扩展（只读加法）

    /// 上下文扩展返回结构。prevPage/nextPage nil＝书边界（首页无 prev、
    /// 末页无 next）；sectionLabel nil＝auto_toc 无该书记录（如实「无目录」，
    /// 不猜）。
    public struct PageContext: Equatable {
        public struct PageText: Equatable {
            public let bookID: String
            public let pageNumber: Int            // 1-based physical
            public let label: String?             // nil = unknown
            public let printedPage: Int?          // nil = unknown
            public let text: String               // original（verbatim；不回写任何文件）
            public init(bookID: String, pageNumber: Int, label: String?, printedPage: Int?, text: String) {
                self.bookID = bookID
                self.pageNumber = pageNumber
                self.label = label
                self.printedPage = printedPage
                self.text = text
            }
        }
        public let prevPage: PageText?
        public let page: PageText
        public let nextPage: PageText?
        /// 命中页所在节（auto_toc 中 page ≤ 命中页的最后一个 entry 的
        /// label/level）；无记录为 nil。
        public let sectionLabel: String?
        public let sectionLevel: Int?
    }

    /// 命中句 → 页/节上下文扩展（sioyek「命中→上下文」动线形态启发，
    /// 零代码采用）。查询期零写库；页行只读。页不存在返回 nil。
    public func contextExpansion(bookID: String, page: Int) throws -> PageContext? {
        guard page >= 1, let center = try store.page(bookID: bookID, pageNumber: page) else { return nil }
        func pageText(_ row: IndexStore.PageRow) -> PageContext.PageText {
            .init(bookID: row.bookID, pageNumber: row.pageNumber,
                  label: row.label, printedPage: row.printedPage, text: row.textOriginal)
        }
        let prev: PageContext.PageText? = page >= 2 ? (try store.page(bookID: bookID, pageNumber: page - 1)).map(pageText) : nil
        let next: PageContext.PageText? = (try store.page(bookID: bookID, pageNumber: page + 1)).map(pageText)
        // auto_toc：命中页所在节 = page ≤ 命中页的最后一个 entry。表未建
        // （老库/未重建目录）或该书无记录 → nil，如实显示「无目录」。
        let entries = (try? store.autoTOC(for: bookID)) ?? []
        let section = entries.last { $0.page <= page }
        return PageContext(prevPage: prev, page: pageText(center), nextPage: next,
                           sectionLabel: section?.label, sectionLevel: section?.level)
    }

    // MARK: Zero-hit explanation (internal workhorse)

    /// 零命中诊断＋第五相计时：searchDetailed 的字符级／词路／语法层三条
    /// 零命中出口统一走这里，语义＝直接调 explainZeroHit，只多做一次 Date
    /// 打点并把差值交给 SearchPhaseTiming.recordZeroHint（探针只在激活时写
    /// stderr，stdout 零改动——不改变既有输出）。
    func zeroHitExplanation(terms: [String],
                            countCaliber: CountCaliber = .characterLevel) -> ZeroHitExplanation {
        let t0 = Date()
        let explanation = explainZeroHit(terms: terms, countCaliber: countCaliber)
        SearchPhaseTiming.recordZeroHint(ms: Date().timeIntervalSince(t0) * 1000)
        return explanation
    }

    /// 非零命中出口：该查询没走第五相，如实记 0.0（进程内计数，零写库；
    /// 见 recordZeroHint 注释）。返回恒 nil，供
    /// `total == 0 ? zeroHitExplanation(…): recordZeroHintSkip` 直接使用。
    @discardableResult
    private func recordZeroHintSkip() -> ZeroHitExplanation? {
        SearchPhaseTiming.recordZeroHint(ms: 0)
        return nil
    }

    /// Classifies every indexed book against a zero-hit outcome. Categories:
    ///   - noTextLayer: every indexed page of the book is textless — search
    ///     cannot reach this book at all; this tool performs no OCR, so the
    ///     honest statement is "不可检索（无文字层，未OCR）", never "OCR 完成".
    ///     (After a stale pairing is purged the book lands back here.)
    ///   - termNotMatched: the book has text pages and the terms simply do not
    ///     occur on any of them.
    ///   - excludedByPolicy: query-time policy excludes the book entirely.
    ///   - notAssessable: error book or no page rows.
    func explainZeroHit(terms: [String], countCaliber: CountCaliber = .characterLevel) -> ZeroHitExplanation {
        var explanations: [ZeroHitExplanation.BookExplanation] = []
        let stats = (try? store.perBookPageStats()) ?? []
        let statByID = Dictionary(stats.map { ($0.bookID, $0) }, uniquingKeysWith: { a, _ in a })
        let books = (try? store.allBooks()) ?? []

        for book in books {
            let stat = statByID[book.id]
            let indexedPages = stat?.indexedPages ?? 0
            let pagesWithText = stat?.pagesWithText ?? 0
            let reason: ZeroHitExplanation.BookReason
            if book.status != "ok" || indexedPages == 0 {
                reason = .notAssessable
            } else if let policy,
                      !policy.allowsBook(realPath: book.realPath, rootPath: book.rootPath, bookID: book.id) {
                reason = .excludedByPolicy
            } else if pagesWithText == 0 {
                reason = .noTextLayer
            } else {
                reason = .termNotMatched
            }
            explanations.append(ZeroHitExplanation.BookExplanation(
                bookID: book.id, fileName: book.fileName,
                indexedPages: indexedPages, pagesWithText: pagesWithText, reason: reason))
        }

        let noText = explanations.filter { $0.reason == .noTextLayer }.count
        let missed = explanations.filter { $0.reason == .termNotMatched }.count
        let excluded = explanations.filter { $0.reason == .excludedByPolicy }.count
        var parts: [String] = []
        if noText > 0 { parts.append("\(noText) 本无文字层（未OCR，不可检索）") }
        if missed > 0 { parts.append("\(missed) 本有文字层但词未命中") }
        if excluded > 0 { parts.append("\(excluded) 本被排除策略过滤") }
        if parts.isEmpty { parts.append("索引中无可评估书目") }
        var summary = "0 命中：" + parts.joined(separator: "；")
        if countCaliber == .wordLevel {
            summary += "；词级基准：整词匹配，词内片段（如 copyrights 中的 rights）不计入，" +
                "零命中可能因变位/复数形式，可用语法层通配"
        }
        return ZeroHitExplanation(books: explanations, summary: summary)
    }


    struct PreparedSearchTerm {
        let term: String
        let normalizedText: String
        let utf8Bytes: [UInt8]

        init(term: String) {
            self.term = term
            let norm = normalizeForSearch(term)
            self.normalizedText = norm.text
            self.utf8Bytes = Array(norm.text.utf8)
        }
    }

    /// Fast byte-level search: returns first index of needle in haystack starting from `from`.
    static func firstRange(_ haystack: [UInt8], _ needle: [UInt8], from: Int) -> Int? {
        if needle.isEmpty || haystack.count < needle.count { return nil }
        var i = max(from, 0)
        let last = haystack.count - needle.count
        let first = needle[0]
        while i <= last {
            if haystack[i] == first {
                var j = 1
                while j < needle.count && haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }

    /// Safe rollback to UTF-8 code point boundary if pointing at a continuation byte (b & 0xC0 == 0x80).
    static func utf8CodePointBoundary(in bytes: [UInt8], at offset: Int) -> Int {
        var i = min(max(offset, 0), bytes.count)
        while i > 0 && i < bytes.count && (bytes[i] & 0xC0) == 0x80 {
            i -= 1
        }
        return i
    }

    /// Legacy match implementation using String.range(of:), kept for parity assertion testing.
    static func legacyMatches(page: IndexStore.PageRow, terms: [String]) -> [SearchHit.TermMatch] {
        let preparedTerms = terms.map { normalizeForSearch($0) }
        var matches: [SearchHit.TermMatch] = []
        for (term, termNormalized) in zip(terms, preparedTerms) {
            var searchStart = page.textNorm.startIndex
            while searchStart < page.textNorm.endIndex,
                  let range = page.textNorm.range(of: termNormalized.text, range: searchStart..<page.textNorm.endIndex) {
                guard let originalRange = page.normalizedOriginalRange(normalizedRange: range) else { break }
                let originalCount = page.textOriginal.utf16.count
                guard originalRange.lowerBound >= 0, originalRange.upperBound <= originalCount else { break }
                let startIdx = String.Index(utf16Offset: originalRange.lowerBound, in: page.textOriginal)
                let endIdx = String.Index(utf16Offset: originalRange.upperBound, in: page.textOriginal)
                let displayTerm = String(page.textOriginal[startIdx..<endIdx])
                matches.append(SearchHit.TermMatch(term: term, displayTerm: displayTerm, originalUTF16Range: originalRange))
                searchStart = range.upperBound
            }
        }
        return matches
    }

    /// UTF-8 byte-level match implementation for a single page row.
    static func utf8Matches(page: IndexStore.PageRow, pageNormBytes: [UInt8], preparedTerms: [PreparedSearchTerm]) -> [SearchHit.TermMatch] {
        var matches: [SearchHit.TermMatch] = []
        let u8View = page.textNorm.utf8

        for prepared in preparedTerms {
            guard !prepared.utf8Bytes.isEmpty else { continue }
            var from = 0
            var lastU8Offset = 0
            var lastU8Index = u8View.startIndex

            while let s = firstRange(pageNormBytes, prepared.utf8Bytes, from: from) {
                let e = s + prepared.utf8Bytes.count
                let safeS = utf8CodePointBoundary(in: pageNormBytes, at: s)
                let safeE = utf8CodePointBoundary(in: pageNormBytes, at: e)

                let u8Start: String.UTF8View.Index
                if safeS >= lastU8Offset {
                    u8Start = u8View.index(lastU8Index, offsetBy: safeS - lastU8Offset)
                } else {
                    u8Start = u8View.index(u8View.startIndex, offsetBy: safeS)
                }
                lastU8Offset = safeS
                lastU8Index = u8Start

                let u8End: String.UTF8View.Index
                if safeE >= lastU8Offset {
                    u8End = u8View.index(lastU8Index, offsetBy: safeE - lastU8Offset)
                } else {
                    u8End = u8View.index(u8View.startIndex, offsetBy: safeE)
                }
                lastU8Offset = safeE
                lastU8Index = u8End

                guard let strStart = String.Index(u8Start, within: page.textNorm),
                      let strEnd = String.Index(u8End, within: page.textNorm),
                      strStart < strEnd else {
                    from = e
                    continue
                }

                guard let originalRange = page.normalizedOriginalRange(normalizedRange: strStart..<strEnd) else {
                    break
                }
                let originalCount = page.textOriginal.utf16.count
                guard originalRange.lowerBound >= 0, originalRange.upperBound <= originalCount else {
                    break
                }
                let startIdx = String.Index(utf16Offset: originalRange.lowerBound, in: page.textOriginal)
                let endIdx = String.Index(utf16Offset: originalRange.upperBound, in: page.textOriginal)
                let displayTerm = String(page.textOriginal[startIdx..<endIdx])
                matches.append(SearchHit.TermMatch(term: prepared.term, displayTerm: displayTerm, originalUTF16Range: originalRange))
                from = e
            }
        }
        return matches
    }

    /// Convenience wrapper for testing / ad-hoc matching.
    static func utf8Matches(page: IndexStore.PageRow, terms: [String]) -> [SearchHit.TermMatch] {
        let prepared = terms.map { PreparedSearchTerm(term: $0) }
        let pageBytes = Array(page.textNorm.utf8)
        return utf8Matches(page: page, pageNormBytes: pageBytes, preparedTerms: prepared)
    }

    // MARK: - 词边界验证

    /// 词路 matches 的域类型（TermMatch，含 term、displayTerm、originalUTF16Range 三元组）。
    typealias MatchRange = SearchHit.TermMatch

    /// ASCII [a-z0-9] 字节判定（词边界与投影共用基准；大写不属之——
    /// text_norm 契约已小写，若上游违约则按分隔符处理，fail-closed 不产假命中）。
    private static func isLatinTokenByte(_ b: UInt8) -> Bool {
        (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39)
    }

    /// 词边界验证：子串出现处左右邻字节均非 [a-z0-9]（含首尾、CJK、标点）
    /// 才算词命中。与「text_latin 投影 + unicode61」的 token 语义同构：
    /// token 集 = text_norm 中极大 [a-z0-9]+ 串；needle 纯 [a-z0-9] 时
    /// 「needle 恰为极大串」⟺「出现处左右邻非 [a-z0-9]」。UTF-8 安全性：
    /// 非 ASCII 字节（CJK/变音符残留）恒 ≥0x80，与 [a-z0-9] 字节域无交集，
    /// 逐字节判定不裂码位。返回该页该词项的全部词命中（左→右全量报告，
    /// 纯函数；坐标映射与 utf8Matches 同一链路）。
    static func wordMatches(page: IndexStore.PageRow, pageNormBytes: [UInt8],
                            preparedTerm: PreparedSearchTerm) -> [MatchRange] {
        var matches: [MatchRange] = []
        let needle = preparedTerm.utf8Bytes
        guard !needle.isEmpty, pageNormBytes.count >= needle.count else { return matches }
        let u8 = page.textNorm.utf8
        var from = 0
        let last = pageNormBytes.count - needle.count
        while let s = firstRange(pageNormBytes, needle, from: from), s <= last {
            from = s + needle.count
            let e = s + needle.count
            let leftOK = s == 0 || !isLatinTokenByte(pageNormBytes[s - 1])
            let rightOK = e >= pageNormBytes.count || !isLatinTokenByte(pageNormBytes[e])
            guard leftOK, rightOK else { continue }
            // 出现处为纯 ASCII 字节 ⇒ 恒在码位边界（防御性回退与 utf8Matches 同款）。
            let safeS = utf8CodePointBoundary(in: pageNormBytes, at: s)
            let safeE = utf8CodePointBoundary(in: pageNormBytes, at: e)
            guard let strStart = String.Index(u8.index(u8.startIndex, offsetBy: safeS), within: page.textNorm),
                  let strEnd = String.Index(u8.index(u8.startIndex, offsetBy: safeE), within: page.textNorm),
                  strStart < strEnd else { continue }
            guard let originalRange = page.normalizedOriginalRange(normalizedRange: strStart..<strEnd) else { continue }
            let originalCount = page.textOriginal.utf16.count
            guard originalRange.lowerBound >= 0, originalRange.upperBound <= originalCount else { continue }
            let startIdx = String.Index(utf16Offset: originalRange.lowerBound, in: page.textOriginal)
            let endIdx = String.Index(utf16Offset: originalRange.upperBound, in: page.textOriginal)
            let displayTerm = String(page.textOriginal[startIdx..<endIdx])
            matches.append(SearchHit.TermMatch(term: preparedTerm.term, displayTerm: displayTerm,
                                               originalUTF16Range: originalRange))
        }
        return matches
    }

    // MARK: - Citation Validation (AI response provenance verification)

    /// Verifies that a citation target remains valid in the current live index:
    /// 1. bookID 仍在库且状态 ok (book exists in store and book.status == "ok")
    /// 2. 页码 ≤ 页数 (1 <= page <= book.pageCount)
    /// 3. 指纹未漂移 (expectedFingerprint.isEmpty || book.fingerprint == expectedFingerprint)
    public func verifyCitation(bookID: String, page: Int, expectedFingerprint: String) throws -> Bool {
        guard let book = try store.book(byID: bookID) else { return false }
        guard book.status == "ok" else { return false }
        guard page >= 1 && page <= book.pageCount else { return false }
        guard expectedFingerprint.isEmpty || book.fingerprint == expectedFingerprint else { return false }
        return true
    }

    // MARK: - Smart Jump Citation Resolution

    /// Resolves a smart jump citation target across the library.
    /// For same-book jumps, returns the target page in currentBookID.
    /// For external citations, matches against allBooks (by title, author, year)
    /// and falls back to whole-library search for the best matching hit.
    public func resolveCitation(target: CitationTargetKind, currentBookID: String? = nil) throws -> CitationResolvedTarget? {
        switch target {
        case .sameBookPage(let page):
            guard let currentBookID, let book = try store.book(byID: currentBookID) else { return nil }
            let targetPage = min(max(1, page), max(1, book.pageCount))
            return CitationResolvedTarget(bookID: book.id, filePath: book.realPath, fileName: book.fileName,
                                          pageNumber: targetPage, title: book.title, author: book.author, snippet: "")
        case .externalCitation(let author, let title, let year, let page, let rawText):
            let allBooks = try store.allBooks()

            // 1. Exact or substring title match if title is given
            if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let normTitle = normalizeQuery(title)
                for book in allBooks {
                    let bookTitleNorm = normalizeQuery(book.title ?? book.fileName)
                    if bookTitleNorm.contains(normTitle) || normTitle.contains(bookTitleNorm) {
                        let p = page ?? 1
                        let targetPage = min(max(1, p), max(1, book.pageCount))
                        return CitationResolvedTarget(bookID: book.id, filePath: book.realPath, fileName: book.fileName,
                                                      pageNumber: targetPage, title: book.title, author: book.author, snippet: "")
                    }
                }
                // Fallback: search title in library
                if let hits = try? search(title, options: SearchOptions(limit: 5)), let top = hits.first {
                    let targetPage = page ?? top.physicalPage
                    return CitationResolvedTarget(bookID: top.bookID, filePath: top.filePath, fileName: top.fileName,
                                                  pageNumber: targetPage, title: top.title, author: top.author, snippet: top.snippet)
                }
            }

            // 2. Author match if author is given
            if let author, !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let normAuthor = normalizeQuery(author)
                var authorCandidates: [IndexStore.BookRow] = []
                for book in allBooks {
                    let bookAuthorNorm = normalizeQuery(book.author ?? book.fileName)
                    if bookAuthorNorm.contains(normAuthor) {
                        authorCandidates.append(book)
                    }
                }
                if !authorCandidates.isEmpty {
                    if let year {
                        let yearStr = String(year)
                        if let exact = authorCandidates.first(where: {
                            ($0.version ?? "").contains(yearStr) ||
                            ($0.title ?? "").contains(yearStr) ||
                            $0.fileName.contains(yearStr)
                        }) {
                            let p = page ?? 1
                            let targetPage = min(max(1, p), max(1, exact.pageCount))
                            return CitationResolvedTarget(bookID: exact.id, filePath: exact.realPath, fileName: exact.fileName,
                                                          pageNumber: targetPage, title: exact.title, author: exact.author, snippet: "")
                        }
                    }
                    let first = authorCandidates[0]
                    let p = page ?? 1
                    let targetPage = min(max(1, p), max(1, first.pageCount))
                    return CitationResolvedTarget(bookID: first.id, filePath: first.realPath, fileName: first.fileName,
                                                  pageNumber: targetPage, title: first.title, author: first.author, snippet: "")
                }
                // Fallback: search author + year across library
                let query = year != nil ? "\(author) \(year!)" : author
                if let hits = try? search(query, options: SearchOptions(limit: 5)), let top = hits.first {
                    let targetPage = page ?? top.physicalPage
                    return CitationResolvedTarget(bookID: top.bookID, filePath: top.filePath, fileName: top.fileName,
                                                  pageNumber: targetPage, title: top.title, author: top.author, snippet: top.snippet)
                }
            }

            // 3. Fallback: search rawText
            if !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let hits = try? search(rawText, options: SearchOptions(limit: 5)), let top = hits.first {
                    let targetPage = page ?? top.physicalPage
                    return CitationResolvedTarget(bookID: top.bookID, filePath: top.filePath, fileName: top.fileName,
                                                  pageNumber: targetPage, title: top.title, author: top.author, snippet: top.snippet)
                }
            }
            return nil
        }
    }
}

public struct CitationResolvedTarget: Equatable, Sendable {
    public let bookID: String
    public let filePath: String
    public let fileName: String
    public let pageNumber: Int
    public let title: String?
    public let author: String?
    public let snippet: String

    public init(bookID: String, filePath: String, fileName: String, pageNumber: Int,
                title: String?, author: String?, snippet: String) {
        self.bookID = bookID
        self.filePath = filePath
        self.fileName = fileName
        self.pageNumber = pageNumber
        self.title = title
        self.author = author
        self.snippet = snippet
    }
}

extension IndexStore.PageRow {
    /// Maps a normalized-text range back to a UTF-16 range in the original text
    /// using the stored offset maps.
    func normalizedOriginalRange(normalizedRange: Range<String.Index>) -> Range<Int>? {
        let chars = textNorm
        guard normalizedRange.lowerBound >= chars.startIndex, normalizedRange.upperBound <= chars.endIndex else { return nil }
        let lowerDistance = chars.distance(from: chars.startIndex, to: normalizedRange.lowerBound)
        let upperDistance = chars.distance(from: chars.startIndex, to: normalizedRange.upperBound)
        guard lowerDistance < normStarts.count else { return nil }
        let upperIdx = min(max(upperDistance - 1, 0), normEnds.count - 1)
        return Int(normStarts[lowerDistance])..<Int(normEnds[upperIdx])
    }
}

// MARK: - SearchService 语法分支（同文件置于 SearchService.swift 以访问其
// private 存储；只在查询串含语法字符时被调用——现行路径一个字节不变）

extension SearchService {
    struct SyntaxQueryPlan {
        let parsed: ParsedQuery
        let queryFilter: QueryFilter
        /// 按 pattern 索引的预编译正则（页循环外编译一次）。
        let compiledRegexes: [String: NSRegularExpression]
        /// 查询级正则熔断预算；实例随计划传递，无静态共享态。
        let budget = RegexBudget()
    }

    /// 组装语法查询计划（parse + 正则预编译；无效正则 fail-closed 抛错）。
    /// 正则档大小写不敏感编译：正则在规范化文本（含大小写折叠）上匹配，
    /// 大小写敏感 pattern 对折叠后文本永不命中（与子串档同基准）。
    static func plan(_ rawQuery: String) throws -> SyntaxQueryPlan {
        let parsed = try QuerySyntax.parse(rawQuery)
        var regexes: [String: NSRegularExpression] = [:]
        for node in parsed.nodes {
            if case .regex(let pattern) = node, regexes[pattern] == nil {
                regexes[pattern] = try NSRegularExpression(pattern: pattern,
                                                           options: [.caseInsensitive])
            }
        }
        return SyntaxQueryPlan(parsed: parsed,
                               queryFilter: QueryFilter.from(parsed.fieldNodes),
                               compiledRegexes: regexes)
    }

    /// 语法版页级检索：字段限定→QueryFilter（与 options.filter AND 组合）；
    func searchDetailedSyntax(_ rawQuery: String, options: SearchOptions,
                              diagnostics: inout QueryDiagnostics?) throws -> SearchResult {
        let plan = try Self.plan(rawQuery)
        let parsed = plan.parsed
        let freeTerms = parsed.freeTerms

        let queryStart = Date()
        var rowIDs: Set<String>? = nil
        if !freeTerms.isEmpty {
            var intersection: Set<String>? = nil
            for term in freeTerms {
                let ids = try store.candidatePageIDs(term: term)
                diagnostics?.termCandidates[term] = ids.count
                intersection = intersection.map { $0.intersection(ids) } ?? Set(ids)
                if intersection!.isEmpty { break }
            }
            rowIDs = intersection
        } else {
            rowIDs = try store.allPageRowIDs()
        }
        guard var scoped = rowIDs, !scoped.isEmpty else {
            return SearchResult(hits: [], totalPageMatches: 0, truncated: false,
                                zeroHitExplanation: zeroHitExplanation(terms: parsed.freeTerms))
        }
        diagnostics?.intersectionCount = scoped.count
        diagnostics?.queryMs = Date().timeIntervalSince(queryStart) * 1000

        // 书级字段过滤（QueryFilter）＋既有 GUI 过滤条 AND 组合：字段书集
        // 与书域都在**物化前**与候选页取交集；字段+正则查询不再
        // 物化被字段排除的书页），页循环里另有一行防御判定。
        var allowedBooks: Set<String>? = nil
        if plan.queryFilter.isActive {
            var bookTagIndex: [String: Set<String>] = [:]
            if plan.queryFilter.predicates[.tag] != nil {
                bookTagIndex = try Self.bookTagIndex(store: store)
            }
            var allowed = Set<String>()
            for book in try store.allBooks() {
                if let policy,
                   !policy.allowsBook(realPath: book.realPath, rootPath: book.rootPath, bookID: book.id) {
                    continue
                }
                if plan.queryFilter.allows(book: book, bookTags: bookTagIndex[book.id] ?? []) {
                    allowed.insert(book.id)
                }
            }
            if allowed.isEmpty {
                return SearchResult(hits: [], totalPageMatches: 0, truncated: false,
                                    zeroHitExplanation: zeroHitExplanation(terms: parsed.freeTerms))
            }
            allowedBooks = allowed
        }
        if parsed.freeTerms.isEmpty && !parsed.hasRegex {
            diagnostics?.totalPageMatches = 0
            return SearchResult(hits: [], totalPageMatches: 0, truncated: false,
                                zeroHitExplanation: zeroHitExplanation(terms: []))
        }
        if let bookScope = options.filter?.bookIDEquals {
            let bookPages = try store.candidateRowIDs(bookID: bookScope)
            scoped = scoped.intersection(bookPages)
        }
        if let allowedBooks {
            var allowedPages = Set<String>()
            for bid in allowedBooks {
                allowedPages.formUnion(try store.candidateRowIDs(bookID: bid))
            }
            scoped = scoped.intersection(allowedPages)
            if scoped.isEmpty {
                diagnostics?.totalPageMatches = 0
                return SearchResult(hits: [], totalPageMatches: 0, truncated: false,
                                    zeroHitExplanation: zeroHitExplanation(terms: parsed.freeTerms))
            }
        }

        let materializeStart = Date()
        let orderedRowIDs = scoped.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
        //
        // （matchingBooksSyntax 的正则书目级聚合仍走 store.pages——书目级
        // 聚合不在 verify 阶段物化。
        let pages = try resolvedTextSource.pages(rowIDs: orderedRowIDs)
        diagnostics?.materializeMs = Date().timeIntervalSince(materializeStart) * 1000
        diagnostics?.pagesLoaded = pages.count

        let verifyStart = Date()
        var hits: [SearchHit] = []
        var policyVerdicts: [String: Bool] = [:]
        var bookCache: [String: IndexStore.BookRow] = [:]
        var pairingCache: [String: (sourced: Set<Int>, map: [Int: Int], path: String?, fp: String?)] = [:]
        var timedOut = false
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
            if let allowedBooks, !allowedBooks.contains(book.id) { continue }
            let ocr = pairing(for: book)
            let isOCR = ocr.sourced.contains(page.pageNumber)
            func hitSkeleton() -> SearchHit {
                SearchHit(bookID: page.bookID, filePath: book.realPath, fileName: book.fileName,
                          fingerprint: book.fingerprint, physicalPage: page.pageNumber,
                          pageLabel: page.label, printedPage: page.printedPage, pageCount: book.pageCount,
                          title: book.title, author: book.author, version: book.version, language: book.language,
                          matches: [], snippet: "", source: isOCR ? "ocr" : "native",
                          ocrFilePath: isOCR ? ocr.path : nil,
                          ocrPage: isOCR ? ocr.map[page.pageNumber] : nil,
                          ocrFingerprint: isOCR ? ocr.fp : nil)
            }
            if toolbookExcluded(category: book.contentCategory, filter: options.filter) { continue }
            if let filter = options.filter, filter.isActive {
                guard filter.allows(hitSkeleton()) else { continue }
            }
            let pageNormBytes = Array(page.textNorm.utf8)
            var matches: [SearchHit.TermMatch] = []
            var pageOK = true
            nodeLoop: for node in parsed.nodes {
                switch node {
                case .field:
                    continue   // 书级已过滤
                case .regex(let pattern):
                    // 熔断已触发：余下页的正则整体按超时不命中（如实标注）。
                    if plan.budget.tripped { timedOut = true; pageOK = false; break nodeLoop }
                    do {
                        let m = try QueryMatcher.matches(node: node, page: page,
                                                         pageNormBytes: pageNormBytes,
                                                         regex: plan.compiledRegexes[pattern],
                                                         budget: plan.budget)
                        if m.isEmpty { pageOK = false }
                        matches.append(contentsOf: m)
                    } catch {
                        // 超时按该子句不命中处理，并如实标注。
                        timedOut = true
                        pageOK = false
                    }
                case .term, .exactTerm, .phrase:
                    let m = try QueryMatcher.matches(node: node, page: page, pageNormBytes: pageNormBytes)
                    if m.isEmpty { pageOK = false }
                    matches.append(contentsOf: m)
                }
                if !pageOK { break nodeLoop }
            }
            guard pageOK, !matches.isEmpty else { continue }
            hits.append(SearchHit(
                bookID: page.bookID, filePath: book.realPath, fileName: book.fileName,
                fingerprint: book.fingerprint, physicalPage: page.pageNumber,
                pageLabel: page.label, printedPage: page.printedPage, pageCount: book.pageCount,
                title: book.title, author: book.author, version: book.version, language: book.language,
                matches: matches,
                snippet: Self.snippet(in: page.textOriginal, around: matches.map(\.originalUTF16Range)),
                source: isOCR ? "ocr" : "native",
                ocrFilePath: isOCR ? ocr.path : nil,
                ocrPage: isOCR ? ocr.map[page.pageNumber] : nil,
                ocrFingerprint: isOCR ? ocr.fp : nil))
        }
        diagnostics?.verifyMs = Date().timeIntervalSince(verifyStart) * 1000
        diagnostics?.regexTimedOut = timedOut
        diagnostics?.totalPageMatches = hits.count

        let total = hits.count
        let truncated = total > options.limit
        let slice: [SearchHit]
        if let quota = options.perBookLimit, quota > 0 {
            slice = Self.roundRobinByBook(hits, perBookLimit: quota, limit: options.limit)
        } else {
            slice = Array(hits.prefix(options.limit))
        }
        return SearchResult(
            hits: slice,
            totalPageMatches: total,
            truncated: truncated,
            zeroHitExplanation: total == 0 ? zeroHitExplanation(terms: parsed.freeTerms) : recordZeroHintSkip())
    }

    /// 语法版书目级聚合：词项/正则/短语节点都须命中（页级求值，与
    /// searchDetailedSyntax 同 matcher/同超时语义）；字段限定→QueryFilter
    /// 书级过滤（AND 组合）。字段-only 查询 matchingPages=0（无页级词命中
    func matchingBooksSyntax(_ rawQuery: String, filter: SearchFilter?,
                             diagnostics: inout QueryDiagnostics?) throws -> [BookHitSummary] {
        let plan = try Self.plan(rawQuery)
        let parsed = plan.parsed
        let freeTerms = parsed.freeTerms
        let queryStart = Date()
        var intersection: Set<String>? = nil
        for term in freeTerms {
            let ids = try store.candidatePageIDs(term: term)
            diagnostics?.termCandidates[term] = ids.count
            intersection = intersection.map { $0.intersection(ids) } ?? Set(ids)
            if intersection!.isEmpty { break }
        }
        diagnostics?.intersectionCount = intersection?.count ?? 0
        diagnostics?.queryMs = Date().timeIntervalSince(queryStart) * 1000

        var countsByBook: [String: Int] = [:]
        if let rowIDs = intersection, !rowIDs.isEmpty {
            countsByBook = try store.matchingPageCounts(rowIDs: Array(rowIDs))
        }
        let regexNodes = parsed.nodes.compactMap { node -> String? in
            if case .regex(let p) = node { return p }
            return nil
        }
        var bookTagIndex: [String: Set<String>] = [:]
        var preAllowedBooks: Set<String>? = nil
        if policy != nil || plan.queryFilter.isActive {
            if plan.queryFilter.predicates[.tag] != nil {
                bookTagIndex = try Self.bookTagIndex(store: store)
            }
            var allowed = Set<String>()
            for book in try store.allBooks() {
                if let policy,
                   !policy.allowsBook(realPath: book.realPath, rootPath: book.rootPath, bookID: book.id) {
                    continue
                }
                if plan.queryFilter.isActive,
                   !plan.queryFilter.allows(book: book, bookTags: bookTagIndex[book.id] ?? []) {
                    continue
                }
                allowed.insert(book.id)
            }
            preAllowedBooks = allowed
        }
        if !regexNodes.isEmpty {
            let universe: [String]
            if freeTerms.isEmpty {
                universe = Array(try store.allPageRowIDs())
            } else {
                universe = Array(intersection ?? [])
            }
            var perBook: [String: Int] = [:]
            if !universe.isEmpty, preAllowedBooks?.isEmpty != true {
                let ordered = universe.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
                for page in try store.pages(rowIDs: ordered) {
                    if let preAllowedBooks, !preAllowedBooks.contains(page.bookID) { continue }
                    if plan.budget.tripped {
                        diagnostics?.regexTimedOut = true   // 熔断：余下页如实计入超时
                        break
                    }
                    var pageOK = true
                    let normBytes = Array(page.textNorm.utf8)
                    nodeLoop: for pattern in regexNodes {
                        do {
                            let m = try QueryMatcher.matches(node: .regex(pattern: pattern), page: page,
                                                             pageNormBytes: normBytes,
                                                             regex: plan.compiledRegexes[pattern],
                                                             budget: plan.budget)
                            if m.isEmpty { pageOK = false; break nodeLoop }
                        } catch {
                            diagnostics?.regexTimedOut = true
                            pageOK = false; break nodeLoop
                        }
                    }
                    if pageOK { perBook[page.bookID, default: 0] += 1 }
                }
            }
            // AND 语义：正则求值全集已含词项候选约束（或为字段-only 全库）。
            countsByBook = perBook
        }
        // 候选书集＝词命中书；字段-only（无词项）时＝全部书，由字段过滤收敛。
        var candidateBooks: [IndexStore.BookRow] = []
        if freeTerms.isEmpty && regexNodes.isEmpty {
            candidateBooks = (try? store.allBooks()) ?? []
        } else {
            for bid in countsByBook.keys {
                if let b = try store.book(byID: bid) { candidateBooks.append(b) }
            }
        }
        let nativeCounts = (try? store.nativeTextPageCountsByBook()) ?? [:]
        var out: [BookHitSummary] = []
        for book in candidateBooks {
            if let policy {
                guard policy.allowsBook(realPath: book.realPath, rootPath: book.rootPath, bookID: book.id) else { continue }
            }
            if plan.queryFilter.isActive {
                guard plan.queryFilter.allows(book: book, bookTags: bookTagIndex[book.id] ?? []) else { continue }
            }
            let probe = SearchHit(bookID: book.id, filePath: book.realPath, fileName: book.fileName,
                                  fingerprint: book.fingerprint, physicalPage: 1, pageLabel: nil,
                                  printedPage: nil, pageCount: book.pageCount, title: book.title,
                                  author: book.author, version: book.version, language: book.language,
                                  matches: [], snippet: "", source: "native")
            if toolbookExcluded(category: book.contentCategory, filter: filter) { continue }
            if let filter, filter.isActive {
                guard filter.allows(probe) else { continue }
            }
            out.append(BookHitSummary(bookID: book.id, fileName: book.fileName, title: book.title,
                                      author: book.author, version: book.version,
                                      language: book.language, pageCount: book.pageCount,
                                      matchingPages: countsByBook[book.id] ?? 0,
                                      nativeTextPages: nativeCounts[book.id] ?? 0))
        }
        // 补第三决胜键 bookID 结算——fileName 同名
        // 书（不同目录同名文件）在同级计数下原比较器返回 false 双向（非严格
        // 全序），输出依赖不稳定的迭代序。与 matchingBooks 两路全序决胜一致：
        // matchingPages 降序 → fileName 升序 → bookID 升序。
        out.sort {
            if $0.matchingPages != $1.matchingPages { return $0.matchingPages > $1.matchingPages }
            if $0.fileName != $1.fileName { return $0.fileName < $1.fileName }
            return $0.bookID < $1.bookID   // 字段-only 全 0 时亦严格全序
        }
        diagnostics?.totalPageMatches = out.reduce(0) { $0 + $1.matchingPages }
        return out
    }

    /// 标签投影（favorites kind=book 行的 tags；未收藏书恒不命中——
    /// 既有基准，帮助文案写明）。纯读，零写库。
    static func bookTagIndex(store: IndexStore) throws -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        let rows = try FavoritesStore(indexStore: store).favorites(kind: .book)
        for fav in rows {
            if case .book(let bookID, _, _) = fav.target {
                out[bookID, default: []].formUnion(Set(fav.tags))
            }
        }
        return out
    }
}
