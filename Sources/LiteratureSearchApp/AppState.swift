import Foundation
import SwiftUI
import WidgetKit
import CryptoKit
import LiteratureCore
import LiteratureSearchUI

/// Central app state: indexing (explicit, cancellable, incremental, bounded),
/// search (all occurrences, filters, query-time policy re-check), AI
/// (HTTPS-only, confirmation-gated, per-snippet compare), metadata editing,
/// full coverage statistics and OCR pair import (explicit manifest + two roots).
@MainActor
final class AppState: ObservableObject {
    // Library
    let access = LibraryAccess()
    /// Query/open/AI-time policy re-checks use the same policy as indexing.
    let policy: ExclusionPolicy
    /// Fail-closed: malformed exclusions.json blocks indexing until fixed.
    @Published var policyConfigError: String?
    @Published var rootName: String?
    @Published var progress: IndexProgress?
    @Published var lastSummary: IndexRunSummary?
    @Published var indexing: Bool = false
    @Published var indexError: String?

    // Search
    @Published var query: String = ""
    @Published var hits: [SearchHit] = []
    @Published var searchError: String?
    @Published var searchedOnce: Bool = false
    @Published var isSearching: Bool = false
    @Published var truncatedNotice: String?
    @Published var zeroHitExplanation: ZeroHitExplanation?
    // Filters (positive filters never match unknown/nil metadata)
    @Published var filterAuthor: String = ""
    @Published var filterVersion: String = ""
    @Published var filterLanguage: String = ""
    /// Source-domain filter:  "" = 全部, "book" = 书籍, "paper" = 论文.
    /// 切档即生效——持久化 + query 非空时自动重搜当前检索；
    /// query 为空仅存档不触发检索。didSet 在 init 赋值期间不触发。
    @Published var filterDomain: String = "" {
        didSet {
            UserDefaults.standard.set(filterDomain, forKey: "filterDomain")
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            search()
        }
    }
    /// Client-side source filter over the returned hits (""=all, "native", "ocr").
    @Published var sourceFilter: String = ""
    /// Per-book COMPLETE hit lists (loaded on demand via the book-scoped
    /// search); keyed by bookID. Replaces the book's top-N slice in the list.
    @Published var bookFullHits: [String: [SearchHit]] = [:]
    /// Phase-one results: EVERY matching work (version-grouped — 异版/年版
    /// duplicates of one book collapse into a single `BookVersionGroup` whose
    /// `primary` is the best-text variant), each group carrying its hit-page
    /// count (fast aggregate — page rows are never materialized).
    @Published var bookResults: [BookVersionGroup] = []
    @Published var totalMatchingPages: Int = 0
    /// Citation style for display + copy (persisted).
    @Published var citationStyle: CitationStyle {
        didSet { UserDefaults.standard.set(citationStyle.rawValue, forKey: "citationStyle") }
    }
    /// Per-book hit-loading cap for 「本书全部」 (persisted; 0 = unlimited —
    /// bounded in practice by the book's own page count).
    @Published var bookHitsLimit: Int {
        didSet { UserDefaults.standard.set(bookHitsLimit, forKey: "bookHitsLimit") }
    }
    @Published var bookFullTotalPages: [String: Int] = [:]
    @Published var bookFullTruncated: Set<String> = []
    @Published var loadingBookID: String?

    // Navigation (three-column shell). Selection persists across launches.
    // 新增 excerpts（批注区）。rawValue 持久化向后兼容——旧值
    // 照常解析，新增 case 只增不改。
    enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
        case search, history, coverage, library, favorites, quote, excerpts
        var id: String { rawValue }
    }
    @Published var sidebarSection: SidebarSection = .search {
        didSet { UserDefaults.standard.set(sidebarSection.rawValue, forKey: "sidebarSection") }
    }


    enum Column: String, CaseIterable {
        case sidebar, results, detail
    }

    /// 三栏可见性（收起 = false；默认全显，缺省键视为 true）。
    @Published var sidebarColumnVisible = AppState.storedVisible("sidebarColumnVisible") {
        didSet { UserDefaults.standard.set(sidebarColumnVisible, forKey: "sidebarColumnVisible") }
    }
    @Published var resultsColumnVisible = AppState.storedVisible("resultsColumnVisible") {
        didSet { UserDefaults.standard.set(resultsColumnVisible, forKey: "resultsColumnVisible") }
    }
    @Published var detailColumnVisible = AppState.storedVisible("detailColumnVisible") {
        didSet { UserDefaults.standard.set(detailColumnVisible, forKey: "detailColumnVisible") }
    }

    /// 三栏宽度：各自 min/ideal/max（侧栏 180–260、结果栏 440–560、原文栏
    /// 480–1400），两根分隔条各自只改相邻一列，互不联动。
    static let sidebarColumnMin: CGFloat = 180
    static let sidebarColumnMax: CGFloat = 260
    static let resultsColumnMin: CGFloat = 440
    static let resultsColumnMax: CGFloat = 560
    static let detailColumnMin: CGFloat = 480
    @Published var sidebarColumnWidth = AppState.storedWidth("sidebarColumnWidth", fallback: 200,
                                                             min: sidebarColumnMin, max: sidebarColumnMax) {
        didSet { UserDefaults.standard.set(Double(sidebarColumnWidth), forKey: "sidebarColumnWidth") }
    }
    @Published var resultsColumnWidth = AppState.storedWidth("resultsColumnWidth", fallback: 520,
                                                             min: resultsColumnMin, max: resultsColumnMax) {
        didSet { UserDefaults.standard.set(Double(resultsColumnWidth), forKey: "resultsColumnWidth") }
    }

    private static func storedVisible(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil
            ? true
            : UserDefaults.standard.bool(forKey: key)
    }

    private static func storedWidth(_ key: String, fallback: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        let stored = CGFloat(UserDefaults.standard.double(forKey: key))
        guard stored > 0 else { return fallback }
        return Swift.min(Swift.max(stored, lo), hi)
    }

    /// 动效门：AppState 非 View（无 SwiftUI 环境），读 AppKit
    /// 系统降动效设置；Reduce Motion 开启时三栏切换无动画直接落位。
    var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// 工具栏按钮 / ⌘1 ⌘2 ⌘3 共用的三栏显隐切换。
    func toggleColumn(_ column: Column) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: DS.Motion.duration)) {
            switch column {
            case .sidebar: sidebarColumnVisible.toggle()
            case .results: resultsColumnVisible.toggle()
            case .detail: detailColumnVisible.toggle()
            }
        }
    }
    /// Incremented by the 聚焦搜索 menu command (⌘F); SearchView observes it.
    @Published var focusSearchRequest = 0

    // 每日一句（widget slice）：启动后台挑选（池空才抽取），
    // 选中句写入 AppGroup 共享文件供 Widget 只读。
    @Published var todayQuote: Quote?
    /// 同池轮换备选（前 5 条，排除当日选中）。
    @Published var quoteAlternatives: [Quote] = []
    /// Quote 专用合成 hit（打开原书/AI 预览共用；发送时守卫查找池含它）。
    @Published var quoteHit: SearchHit?
    /// bookID → 书目信息（出处行显示书名/作者）。
    @Published var quoteBooks: [String: QuoteBookInfo] = [:]
    @Published var quoteLoading = false
    /// 每日一句打开被拒的就地原因（不污染检索流的 openBlockedReason）。
    @Published var quoteBlockedReason: String?

    struct QuoteBookInfo: Equatable {
        var title: String?
        var author: String?
    }
    @Published var focusReading = false
    @Published var palettePresented = false
    /// Book groups the user expanded (default: small groups open, large collapsed).
    @Published var expandedGroupIDs: Set<String> = []
    /// Recent searches mirrored from the shared store for the UI (refreshed
    /// after each search / import / on appear).
    @Published var historyEntries: [HistoryEntry] = []
    /// Per-book page stats backing the coverage page (populated together with
    /// the coverage classification on every coverage refresh).
    @Published var perBookStats: [BookPageStat] = []
    /// bookID → file name for honest per-book coverage rows.
    @Published var bookNames: [String: String] = [:]

    /// Client-side derivation for the grouped result list; the search service
    /// still returns the flat top-N (protocol and truncation semantics intact).
    /// Books whose COMPLETE hit list was loaded replace their top-N slice and
    /// are marked complete; an unloaded book that is absent from the top-N can
    /// still appear after a per-book load.
    var sourceFilteredHits: [SearchHit] {
        sourceFilter.isEmpty ? hits : hits.filter { $0.source == sourceFilter }
    }
    var groupedHits: [HitRouter.HitGroup] {
        // Phase-two groups: only books whose complete hit list has been loaded.
        var groups: [HitRouter.HitGroup] = []
        for (bid, full) in bookFullHits {
            let filtered = sourceFilter.isEmpty ? full : full.filter { $0.source == sourceFilter }
            guard let first = filtered.first else { continue }
            groups.append(HitRouter.HitGroup(bookID: bid, fileName: first.fileName,
                                             title: first.title, author: first.author,
                                             version: first.version, language: first.language,
                                             pageCount: first.pageCount, hits: filtered,
                                             isComplete: true))
        }
        groups.sort { lhs, rhs in
            if lhs.hits.count != rhs.hits.count { return lhs.hits.count > rhs.hits.count }
            let la = lhs.author ?? "", ra = rhs.author ?? ""
            if la != ra { return la < ra }
            return lhs.fileName < rhs.fileName
        }
        return groups
    }

    /// Loads the COMPLETE per-book hit list for the current query (book-scoped
    /// search, generous cap, honest truncation flag). Auto-expands the group.
    func loadAllHitsForBook(_ bookID: String) {
        let q = query
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty, loadingBookID == nil else { return }
        loadingBookID = bookID
        Task(priority: .userInitiated) {
            do {
                let s = try storeOrOpen()
                let service = SearchService(store: s, policy: policy)
                let filter = SearchFilter(authorContains: filterAuthor.isEmpty ? nil : filterAuthor,
                                          versionContains: filterVersion.isEmpty ? nil : filterVersion,
                                          languageEquals: filterLanguage.isEmpty ? nil : filterLanguage,
                                          bookIDEquals: bookID,
                                          includeToolBooks: UserDefaults.standard.bool(forKey: "includeToolBooks"))
                let effectiveLimit = bookHitsLimit == 0 ? Int.max : bookHitsLimit
                let result = try service.searchDetailed(q, options: SearchOptions(limit: effectiveLimit, filter: filter))
                bookFullHits[bookID] = result.hits
                bookFullTotalPages[bookID] = result.totalPageMatches
                if result.truncated { bookFullTruncated.insert(bookID) } else { bookFullTruncated.remove(bookID) }
                expandedGroupIDs.insert(bookID)
            } catch {
                searchError = String(describing: error)
            }
            loadingBookID = nil
        }
    }

    func refreshHistory() {
        historyEntries = history.history()
    }

    /// Clears the shared search-history store (the widget reads the same
    /// file), preserving the coverage snapshot. Additive accessor — the
    /// store exposes no mutating clear, and search logic is untouched.
    func clearHistory() {
        let url = history.fileURL
        if let data = try? Data(contentsOf: url),
           var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object["history"] = [Any]()
            if let out = try? JSONSerialization.data(withJSONObject: object) {
                try? out.write(to: url, options: .atomic)
            }
        }
        historyEntries = []
    }

    // Selection / PDF view
    @Published var selectedHit: SearchHit?
    /// 最近选中命中的 key（跨 closePDF 保留）与「同一命中重选」
    /// 标记——PDF 原文栏据此区分「重开恢复页码」与「新命中跳转」。
    private var lastSelectedHitKey: String?
    private(set) var reselectedSameHit = false
    /// 每书阅读位置（页码/缩放）持久化存储。
    let readingPositions = ReadingPositionStore()
    @Published var openBlockedReason: String?

    // Coverage (full categories: indexed / no-text awaiting-OCR / error / excluded / unsupported)
    @Published var coverageStats: IndexStore.CoverageStats?
    @Published var coverageClassification: CoverageClassification?
    @Published var lastRunRecord: IndexingEngine.RunRecord?

    // OCR pair import (explicit manifest + two explicitly chosen roots)
    @Published var ocrManifestName: String?
    @Published var ocrManifestEntryCount: Int?
    @Published var ocrManifestError: String?
    @Published var ocrOriginalRootName: String?
    @Published var ocrOCRRootName: String?
    @Published var ocrImporting: Bool = false
    @Published var ocrImportMessage: String?
    @Published var ocrImportSummary: OCRImportSummary?
    @Published var ocrVerifyMessage: String?

    // Metadata editing for the selected book (writes index only, never originals)
    @Published var metaEditTitle: String = ""
    @Published var metaEditAuthor: String = ""
    @Published var metaEditVersion: String = ""
    @Published var metaEditLanguage: String = ""
    @Published var metaEditMessage: String?

    // ── 检索增强批 ──
    //全库结果命中页预览（limit 上限 200＋perBookLimit 4 防刷屏）。
    struct PreviewRow: Identifiable {
        let id = UUID()
        let fileName: String
        let physicalPage: Int
        let isOCR: Bool
        let matchCount: Int
        let snippet: SnippetHighlighter.HighlightedSnippet
    }
    @Published var previewRows: [PreviewRow] = []
    @Published var previewLoading = false
    @Published var previewTruncatedNotice: String?
    //书内/全库两级分区：书内档（当前书 scope 的 searchDetailed）。
    @Published var bookScopeHits: [SearchHit] = []
    @Published var bookScopeBookID: String?
    @Published var bookScopeTotal = 0
    //命中行上下文（key=Self.key(for:)；命中句→页/节上下文）。
    @Published var hitContexts: [String: SearchService.PageContext] = [:]
    //相似文档推荐。
    @Published var similarBooks: [SimilarBook] = []
    @Published var similarBooksFor: String?
    @Published var similarLoading = false
    //引擎（进程内缓存；索引完成后 invalidate）。
    private var similarEngine: SimilarBooksEngine?
    //检索调试面板。
    @Published var showSearchDebug = false
    @Published var lastSearchDiagnostics: QueryDiagnostics?
    /// 一次性学习：当前查询的「上次选择」锚点（结果列表头部锚点
    /// 行数据源；applySearchResults 按当前查询读，无效/关闭态即 nil＝不显示）。
    @Published var lastSelectionAnchor: SearchSelectionAnchor?

    // Cross-device snapshot (export/import; whitelist-only payload)
    @Published var syncMessage: String = ""

    // WebDAV 同步（面板状态。网络一律后台队列，结果回主线程）
    @Published var webdavServerBase: String = ""
    @Published var webdavUsername: String = ""
    /// 内存态编辑副本；保存动作后只进本机钥匙串（SecretStore），不落盘。
    @Published var webdavPassword: String = ""
    @Published var webdavRemoteDir: String = WebDAVSettingsStore.defaultRemoteDir
    @Published var webdavBusy = false
    @Published var webdavStatus = ""
    @Published var webdavLocalRootName: String = WebDAVSettingsStore.defaultLocalFolder
    /// 面板配置持久化（AppSupport JSON，结构与 CLI --config 一致）。
    let webdavSettings = WebDAVSettingsStore()
    /// 密码只进本机钥匙串（独立 service；不进 JSON、不随快照同步）。
    let webdavSecrets: SecretStore = SecurityFrameworkKeyStorage(
        service: SecurityFrameworkKeyStorage.webdavService)

    // AI (default: unconfigured; HTTPS-only)
    @Published var aiServiceURLString: String = ""
    @Published var aiModel: String = ""
    @Published var aiAPIKey: String = ""
    @Published var aiConfigured: Bool = false
    @Published var aiQuestion: String = ""
    @Published var aiPreview: AIPreview?
    @Published var aiAnswer: String?
    @Published var aiDecisions: [ReferenceDecision] = []
    @Published var aiMessage: String = L10n.aiUnconfigured
    // AI 发送进行中标志 + 可取消句柄。「停止」按钮经
    // cancelAISend 取消传输层真中断；完成后句柄由 defer 自清。
    @Published var aiSending = false
    var aiSendTask: Task<Void, Never>?
    var aiCancellationToken: AICancellationToken?
    // AI 配置档案：多档案+按用途路由。legacy 单渠道保留为回退
    //（store 空=legacy 行为不变；有档案但解析失败=fail-closed 中止）。
    let aiProfiles = AIProfilesStore()
    @Published var showAIProfilesSettings = false
    @Published var aiActivePurpose: AIPurpose = .freeChat

    /// 按用途取路由配置。store 无档案 → nil（调用方走 legacy 单渠道）；
    /// 有档案但解析失败 → 抛错（调用方中止发送，不静默回退）。
    func aiRoutingConfiguration(for purpose: AIPurpose) throws -> AIConfiguration? {
        guard !aiProfiles.profiles.isEmpty else { return nil }
        switch aiProfiles.resolveConfiguration(for: purpose) {
        case .success(let cfg): return cfg
        case .failure(let e): throw e
        }
    }

    /// 发送/预览前按用途切换底层服务（路由接线）。store 有档案但解析
    /// 失败时抛错；空档案库不动现有配置。
    ///
    /// 分型扩展：经 OnDeviceRouter 分型——云端档案照旧（不探针，
    /// MarginNote 规则 2「不支持机型保留云端通路」：绝不把云端用户自动推
    /// 向端上）；端上档案先体检，不可用抛 AIProfileError.onDeviceUnavailable
    /// （类型化原因＋恢复指引，三处既有调用点的 catch 原样接住显示——
    /// 预览阶段就拦截，不构造确认、零发送）。界限写死：体检失败＝可降级
    /// 项（显式提示原因）；配置解析失败＝不可降级项（既有 fail-closed 语义
    /// 零变化）。
    func routeAIForPurpose(_ purpose: AIPurpose) throws {
        guard !aiProfiles.profiles.isEmpty else { return }
        let kind = aiProfiles.profile(for: purpose)?.kind
        let outcome: OnDeviceRouteOutcome
        switch aiProfiles.resolveConfiguration(for: purpose) {
        case .failure(let e):
            throw e   // 不可降级项（fail-closed 不变）
        case .success(let cfg):
            outcome = OnDeviceRouter.route(profileKind: kind, resolved: cfg,
                                           probe: onDeviceProbe)
        }
        switch outcome {
        case .cloud(let cfg):
            try ai.configure(cfg)
            aiRouteIsOnDevice = false
        case .onDevice(let cfg):
            try ai.configure(cfg)
            aiRouteIsOnDevice = true
        case .onDeviceUnavailable(let status):
            throw AIProfileError.onDeviceUnavailable(status)
        }
    }

    // AI chat transcript: append-only, IN MEMORY ONLY (never persisted).
    // aiAnswer stays as the latest-answer mirror for existing call sites/tests.
    @Published var aiTranscript: [AIChatTurn] = []

    public enum AIChatRole {
        case user, assistant
    }

    /// One citable (book file, physical page) pair. Derived ONLY from the sent
    /// preview's own selections / accepted reference decisions — never invented.
    public struct AICitation: Equatable {
        public let fileName: String
        public let page: Int
        public var isValid: Bool
        public var bookID: String?
        public var expectedFingerprint: String?

        public init(fileName: String, page: Int, isValid: Bool = true, bookID: String? = nil, expectedFingerprint: String? = nil) {
            self.fileName = fileName
            self.page = page
            self.isValid = isValid
            self.bookID = bookID
            self.expectedFingerprint = expectedFingerprint
        }
    }

    public struct AIChatTurn: Identifiable, Equatable {
        public let id: Int
        public let role: AIChatRole
        public let text: String
        public let citations: [AICitation]
    }

    // Multi-snippet compare: every snippet still gets its own preview + its own
    // explicit confirmation; responses resolve references against input IDs only.
    @Published var compareSelectionIDs: Set<String> = []
    @Published var compareQueue: [AIPreview] = []
    @Published var compareResults: [CompareResult] = []

    // MARK: AI 增强批注预览分型与结果态（全内存，不持久化）

    /// 当前预览所属流程（sendAIConfirmed 据此分派；.plain＝单发问答）。
    enum PreviewKind: Equatable {
        case plain, synthesis, rcs, speedRead, review
    }
    @Published var aiPreviewKind: PreviewKind = .plain
    var rcsPlan: RCSPlan?
    @Published var rcsOutcome: RCSOutcome?
    let rcsLedger = AICallLedger()
    @Published var speedReadCard: SpeedReadCard?
    @Published var speedReadDroppedChars = 0
    @Published var reviewOutcome: ReviewSelfCheckOutcome?
    let reviewLedger = AICallLedger()

    struct CompareResult: Identifiable, Equatable {
        var id: UUID { preview.id }
        var preview: AIPreview
        var answer: String
        var decisions: [ReferenceDecision]
    }

    private var coverageGeneration = 0
    private var indexTask: Task<Void, Never>?
    private var ocrTask: Task<Void, Never>?
    private var ocrManifest: OCRPairManifest?
    private var store: IndexStore?
    let ai = AIAssistantService() // internal：跨文件 extension（AppState+HybridEvidence）可达；最小放宽 最小放宽
    // transport 双档拆分。云端照旧；端上档 lazy 构建（探针可用
    // 才建，FoundationModels 专属类型不离开 Core 的工厂函数）。探针仅在
    // 预览/路由/降级判定时按需调用（无 Timer、无轮询）。
    private let cloudTransport = URLSessionAITransport()
    lazy private var onDeviceTransport: AITransport? = makeOnDeviceAITransport()
    lazy private var onDeviceProbe: OnDeviceModelProbe? = makeOnDeviceModelProbe()
    /// 当前路由选档（routeAIForPurpose 更新）：true＝端上。断网降级的
    /// 方向性判定依据（端上→云端自动重试路径不存在）。
    private var aiRouteIsOnDevice = false

    let dbURL: URL
    let history: SharedHistoryStore
    /// 一次性学习存储（App 私有；不入 AppGroup widget 共享面）。
    let searchMemory = SearchMemoryStore()
    // 根目录解析降级警告（AppSupportPaths.resolveBase；正常环境
    // 为 nil）。设置页「存储位置」展示。
    @Published var storageWarning: String?
    // 导出目录（UserDefaults 持久化；默认 AppSupport/exports）。
    // 索引库位置本期只读展示不做迁移——迁移涉及库重建，留 + 评估。
    static let exportDirectoryDefaultsKey = "exportDirectory"
    @Published var exportDirectoryPath: String = ""

    /// 导出目录 URL（exportSnapshot 等“导出动作”的初始落点）。
    var exportDirectoryURL: URL {
        URL(fileURLWithPath: exportDirectoryPath, isDirectory: true)
    }

    /// 「更改导出目录」：NSOpenPanel 选目录 → UserDefaults 持久化。
    @MainActor
    func chooseExportDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.storageChooseExportDir
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportDirectoryPath = url.path
        UserDefaults.standard.set(url.path, forKey: Self.exportDirectoryDefaultsKey)
    }

    // 阅读侧 stores：两个 store 共享同一 IndexStore 实例（索引库未开时
    // lazy 初始化为 nil，全部调用点 fail-closed）。
    lazy var highlightStore: HighlightStore? = {
        guard let s = try? storeOrOpen() else { return nil }
        return HighlightStore(indexStore: s)
    }()
    lazy var favoritesStore: FavoritesStore? = {
        guard let s = try? storeOrOpen() else { return nil }
        return FavoritesStore(indexStore: s)
    }()
    // marks／sessions 同一 storeOrOpen 连接（照 highlightStore 先例，
    // 索引库未开时 lazy 初始化为 nil，全部调用点 fail-closed）；marks 不进
    // user_highlights、sessions 不进既有任何表——均为自有新表。
    lazy var marksStore: MarksStore? = {
        guard let s = try? storeOrOpen() else { return nil }
        return MarksStore(indexStore: s)
    }()
    lazy var sessionStore: ReadingSessionStore? = {
        guard let s = try? storeOrOpen() else { return nil }
        return ReadingSessionStore(indexStore: s)
    }()
    /// 分类规则库句柄（照 favoritesStore lazy 同款；索引库未开时
    /// nil，调用点 fail-closed）。
    lazy var classificationStore: ClassificationRulesStore? = {
        guard let s = try? storeOrOpen() else { return nil }
        return ClassificationRulesStore(indexStore: s)
    }()
    /// 阅读统计句柄（reading_sessions / page_footprints 两表读写；
    /// 事件锚点为 store 内存态，随 App 进程存续——重启后首事件重记起点）。
    lazy var statsStore: ReadingStatsStore? = {
        guard let s = try? storeOrOpen() else { return nil }
        return ReadingStatsStore(indexStore: s)
    }()

    // MARK: 阅读统计喂点（事件驱动，无 Timer 无轮询）

    /// 每日卡统计镜像（主线程 Published；DailyQuoteView 数据源）。
    @Published var dailyReadingStats: ReadingStatsStore.DailyTotals?

    /// 翻页喂点（PDFDetailView currentPage onChange 唯一入口）：统计＋足迹
    /// 同一事件点不双记。写失败向 stderr 记录且不影响阅读（persistSession 先例）。
    func recordReadingPageTurn(bookID: String, page: Int) {
        assert(Thread.isMainThread, "reading stats feed must run on the main thread")
        guard let store = statsStore else { return }
        do {
            try store.recordPageTurn(bookID: bookID, page: page,
                                     now: Date().timeIntervalSince1970)
        } catch {
            Self.logReadingStatsFailure(error)
            return
        }
        refreshDailyReadingStats()
    }

    /// 阅读视图出现/消失喂点（DetailChromeView onAppear/onDisappear）：只
    /// 入账分钟差分，不动翻页计数与足迹。
    func recordReadingActive(bookID: String) {
        assert(Thread.isMainThread, "reading stats feed must run on the main thread")
        guard let store = statsStore else { return }
        do {
            try store.recordActiveEvent(bookID: bookID, now: Date().timeIntervalSince1970)
        } catch {
            Self.logReadingStatsFailure(error)
            return
        }
        refreshDailyReadingStats()
    }

    /// 概览九宫格足迹快照（PageOverviewView 徽标数据源；本视图保持无 store
    /// 依赖，弹窗打开时取一次集合）。读失败时把原因写入 stderr 日志后返回空集，
    /// 徽标面降级也不静默吞错——保持可观测，且与写路径共用同一日志通道。
    func readFootprints(bookID: String) -> Set<Int> {
        assert(Thread.isMainThread, "reading stats feed must run on the main thread")
        guard let store = statsStore else {
            return []
        }
        do {
            return Set(try store.footprints(bookID: bookID).map(\.pageNumber))
        } catch {
            Self.logReadingStatsFailure(error)
            return []
        }
    }

    /// 每日卡统计刷新（今日合计；nil = 当日无行 → UI 显式空态，不造数）。
    /// 读失败不再静默假空态——与写路径同通道向 stderr 记录后
    /// 维持 nil（UX 与既有基准一致，可观测性补齐，不假称无数据）。
    func refreshDailyReadingStats() {
        assert(Thread.isMainThread, "reading stats feed must run on the main thread")
        guard let store = statsStore else {
            dailyReadingStats = nil
            return
        }
        let day = ReadingStatsStore.dayKey(for: Date())
        do {
            dailyReadingStats = try store.dailyTotals(day: day)
        } catch {
            Self.logReadingStatsFailure(error)
            dailyReadingStats = nil
        }
    }

    private static func logReadingStatsFailure(_ error: Error) {
        FileHandle.standardError.write(Data("reading stats write failed: \(error)\n".utf8))
    }

    // MARK: 本机只读 API（服务随开关启停；默认关）

    /// 服务壳（App 层 LocalAPIServer：全仓唯一 import Network 宿主；监听/
    /// 路由/审计语义都在壳与 Core 路由内，AppState 只管生命周期）。
    let localAPIServer = LocalAPIServer()

    // MARK: 索引刷新控制台

    lazy var refreshConsole: RefreshConsoleStore = {
        let store = RefreshConsoleStore(dbURL: dbURL)
        store.exportDirectoryProvider = { [weak self] in
            guard let self, !self.exportDirectoryPath.isEmpty else { return nil }
            return URL(fileURLWithPath: self.exportDirectoryPath, isDirectory: true)
        }
        return store
    }()

    /// 设置页开关（UserDefaults 持久化；默认关——新装首启永不自启，Joplin
    /// clipper 先例：服务随开关启停，无守护进程无 LaunchAgent）。
    @Published var localAPIEnabled: Bool = {
        guard UserDefaults.standard.object(forKey: "localAPIEnabled") != nil else { return false }
        return UserDefaults.standard.bool(forKey: "localAPIEnabled")
    }() {
        didSet {
            guard oldValue != localAPIEnabled else { return }
            UserDefaults.standard.set(localAPIEnabled, forKey: "localAPIEnabled")
            applyLocalAPIEnabled()
        }
    }

    private func applyLocalAPIEnabled() {
        if localAPIEnabled {
            startLocalAPI()
        } else {
            localAPIServer.stop()
        }
    }

    /// 启动本机 API（主线程纪律照 snapshotController 同款）：索引库未就绪
    /// → 壳 fail-closed 显式报错回设置页，不静默不假称运行。
    func startLocalAPI() {
        assert(Thread.isMainThread, "local API start must run on the main thread")
        guard let s = try? storeOrOpen() else {
            localAPIServer.failStart(L10n.localAPIStoreUnavailable)
            return
        }
        // 检索面与 CLI search 同一条只读调用链（同 policy 装配）；句柄在
        // 主线程解析后交给壳（网络队列上零 lazy 初始化）。批注库
        // 句柄一并传入（/annotations 单书只读清单，note 经既有解密读路径）。
        let service = SearchService(store: s, policy: policy)
        guard let highlights = highlightStore else {
            localAPIServer.failStart(L10n.localAPIStoreUnavailable)
            return
        }
        localAPIServer.start(store: s, search: service, highlights: highlights)
    }

    // MARK: 快照托盘（会话内浮动窗；零落盘零写回）

    /// 快照窗管理器（窗口生命周期/托盘镜像见 SnapshotWindowController；
    /// NSWindow isReleasedWhenClosed=false＋delegate 出账的悬垂纪律在
    /// 控制器内建）。计数/标题经回调主线程发布。internal：PDFDetailView
    /// 选区操作条快照钮跨文件消费。
    lazy var snapshotController: SnapshotWindowController = {
        let controller = SnapshotWindowController()
        controller.onTrayChanged = { [weak self] count, titles in
            self?.snapshotCount = count
            self?.snapshotWindowTitles = titles
        }
        controller.onError = { [weak self] message in
            self?.postFavoriteNotice(message)
        }
        return controller
    }()
    /// 快照窗计数与标题镜像（主线程更新；ReadingChrome 托盘 popover 数据源）。
    @Published var snapshotCount: Int = 0
    @Published var snapshotWindowTitles: [String] = []

    /// 托盘行「前置」。
    func raiseSnapshot(at index: Int) {
        assert(Thread.isMainThread, "snapshot tray must run on the main thread")
        snapshotController.raise(at: index)
    }

    /// 托盘「全部前置」。
    func raiseAllSnapshots() {
        assert(Thread.isMainThread, "snapshot tray must run on the main thread")
        snapshotController.raiseAll()
    }

    /// 托盘「全部关闭」。
    func closeAllSnapshots() {
        assert(Thread.isMainThread, "snapshot tray must run on the main thread")
        snapshotController.closeAll()
    }

    // MARK: 会话账本（退出写一次＋启动还原一次；无 Timer
    // 无守护进程——位置本就按书连续落盘，账本只补「开着哪些＋谁是活动签」）

    /// 会话账本（SessionLedger 纯值；open/select/close/openWorkbench 各一行
    /// 记账，KOReader 关闭即存盘双保险的对应物）。
    private(set) var sessionLedger = SessionLedger()
    /// 还原一次性守卫（onAppear 深链让位判定共用）。
    private var sessionRestoreAttempted = false
    /// 对照台窗口槽位。
    private var workbenchWindowController: WorkbenchWindowController?

    /// 退出钩子入口（AppDelegate.applicationShouldTerminate 调用）：账本逐项
    /// 读 ReadingPositionStore 现值组行 → 整表替换落库。写失败不问题退出、
    /// 向 stderr 记录（诚实呈现；无常驻进程、无轮询）。
    func persistSession() {
        guard let store = sessionStore else { return }
        var positions: [String: Int] = [:]
        for entry in sessionLedger.entries where positions[entry.bookID] == nil {
            positions[entry.bookID] = readingPositions.position(for: entry.bookID)?.page ?? 1
        }
        let rows = sessionLedger.rows(positions: positions,
                                      updatedAt: Date().timeIntervalSince1970)
        do {
            try store.writeSession(rows)
        } catch {
            fputs("AppState.persistSession: 会话落库失败（不阻断退出）\(error)\n", stderr)
        }
    }

    /// 启动还原（WindowGroup onAppear 一次性守卫调用）。深链让位的唯一真
    func restoreSessionOnce() async {
        guard !sessionRestoreAttempted else { return }
        sessionRestoreAttempted = true
        guard selectedHit == nil else { return }
        guard let store = sessionStore else { return }
        let rows: [SessionRow]
        do {
            rows = try store.readSession()
        } catch {
            postFavoriteNotice(L10n.sessionRestoreUnavailable)
            return
        }
        guard !rows.isEmpty else { return }
        let active = rows.first { $0.isActive } ?? rows[0]
        switch active.tabType {
        case "pdf":
            await openBookPage(bookID: active.bookID, pageNumber: max(active.page, 1))
            if selectedHit == nil {
                // 目标书缺失（库已变化）→ 一次显式提示，不静默不崩。
                postFavoriteNotice(L10n.sessionRestoreUnavailable)
            }
        case "workbench":
            guard let secondary = active.secondaryBookID else {
                postFavoriteNotice(L10n.sessionRestoreUnavailable)
                return
            }
            await openWorkbench(primaryBookID: active.bookID, secondaryBookID: secondary)
        default:
            break
        }
    }

    /// 深链让位登记（onAppear 深链分支调用；还原一次性守卫照样烧掉——
    func skipSessionRestore() {
        sessionRestoreAttempted = true
    }

    // MARK: 双文档对照工作台（单窗口单工作台；异版对屏＋单向联动）

    /// 开对照台：主＝组当前选中版本、对照＝该行版本（SearchResultListView
    /// 版本行入口）；同书自对照拒绝（提示，不建窗）。两 hit 走既有合成管线
    /// （openGuard/双指纹守卫原样生效）。
    func openWorkbench(primaryBookID: String, secondaryBookID: String) async {
        assert(Thread.isMainThread, "workbench must run on the main thread")
        guard primaryBookID != secondaryBookID else {
            postFavoriteNotice(L10n.workbenchSelfCompareDenied)
            return
        }
        guard let primaryHit = synthesizedHit(bookID: primaryBookID, pageNumber: 1),
              let secondaryHit = synthesizedHit(bookID: secondaryBookID, pageNumber: 1) else {
            postFavoriteNotice(L10n.workbenchUnavailable)
            return
        }
        // (a)：openGuard 已 async——`??` 右侧是 @autoclosure 不容
        // async 调用，改为顺序短路判定（主 hit 先判，未拦再判对照 hit）。
        var workbenchBlocked = await openGuard(for: primaryHit)
        if workbenchBlocked == nil {
            workbenchBlocked = await openGuard(for: secondaryHit)
        }
        if let reason = workbenchBlocked {
            postFavoriteNotice(reason)
            return
        }
        // 单工作台顶替：旧窗先显式出账再 performClose。windowWillClose 异步落地时新 controller 已占槽位——
        // 旧窗 onClose 现携带闭窗身份（window 指针），非槽位窗（=旧窗）的
        // 关闭只走这里的显式出账，不再触碰槽位与新账（顶替双重出账一并
        // 消除：异步路径身份不符直接跳过）。
        if let existing = workbenchWindowController {
            sessionLedger.closed(existing.primaryBookID, tabType: "workbench")
            existing.window.performClose(nil)
            workbenchWindowController = nil
        }
        let controller = WorkbenchWindowController(
            primaryHit: primaryHit, secondaryHit: secondaryHit, state: self,
            onClose: { [weak self] closedWindow in
                guard let self else { return }
                guard self.workbenchWindowController?.window === closedWindow else { return }
                self.sessionLedger.closed(primaryBookID, tabType: "workbench")
                self.workbenchWindowController = nil
            })
        workbenchWindowController = controller
        sessionLedger.opened(primaryBookID, secondary: secondaryBookID,
                             tabType: "workbench")
        sessionLedger.activated(primaryBookID, tabType: "workbench")
        controller.show()
    }
    /// 收藏动作的瞬态回执（各入口共用；3 秒后自动清除）。
    @Published var lastFavoriteNotice: String?
    private var favoriteNoticeTask: Task<Void, Never>?
    @Published var highlightsVersion: UInt64 = 0

    // MARK: 批注删除撤销（5 秒 toast 窗口；软删语义见 AnnotationUndo）

    /// 当前待撤销的删除回执（nil = 无窗口）。同时只存在一条：新删除顶替
    /// 旧 notice（旧软删保持墓碑态，不随之恢复）；窗口过期只收 toast，
    /// **不做二次硬删**（墓碑永久保留）。
    @Published var annotationUndo: AnnotationUndoNotice?
    private var annotationUndoExpiryTask: Task<Void, Never>?

    /// 删除请求唯一入口（四个删除调用点全部上抛至此）：softDelete → 置
    /// notice → 5 秒到点清 nil。已删/不存在（changes==0 抛错）静默返回，
    /// 不重复上抛。
    @MainActor
    func requestAnnotationDelete(_ highlight: UserHighlight) {
        requestAnnotationDelete(id: highlight.id)
    }

    /// id 形态入口：PDF 选区操作条与标注菜单两条通道只有高亮 id（不重构
    /// 视图层级取整行），语义与整行入口完全一致。
    @MainActor
    func requestAnnotationDelete(id: Int64) {
        assert(Thread.isMainThread, "annotation deletes must run on the main thread")
        guard let store = highlightStore else { return }
        guard (try? store.softDelete(id: id)) != nil else { return }
        highlightsVersion &+= 1
        annotationUndoExpiryTask?.cancel()
        let notice = AnnotationUndo.makeNotice(highlightID: id, issuedAt: Date())
        annotationUndo = notice
        annotationUndoExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(AnnotationUndo.windowSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.expireAnnotationUndo(ifSameAs: notice)
        }
    }

    /// 撤销：窗口内点「撤销」→ restore（批注原样回来，墓碑清空）。
    @MainActor
    func undoAnnotationDelete() {
        assert(Thread.isMainThread, "annotation undo must run on the main thread")
        guard let notice = annotationUndo else { return }
        annotationUndoExpiryTask?.cancel()
        annotationUndo = nil
        guard let store = highlightStore else { return }
        // 恢复失败（行已被外部硬删等）不问题：toast 照收，版本号照 bump。
        _ = try? store.restore(id: notice.highlightID)
        highlightsVersion &+= 1
    }

    /// 到点清理：只收 toast，不做二次硬删（约束：墓碑永久保留）。
    @MainActor
    private func expireAnnotationUndo(ifSameAs notice: AnnotationUndoNotice) {
        if annotationUndo == notice { annotationUndo = nil }
    }

    // MARK: 批注区查询桥接（薄封装；主线程纪律照侧边面板先例）

    //跨书分页窗口（摘录板/总列表数据源； allHighlights 透传）。
    func excerptWindows(limit: Int, offset: Int) -> [UserHighlight] {
        assert(Thread.isMainThread, "annotation queries must run on the main thread")
        guard let store = highlightStore else { return [] }
        return (try? store.allHighlights(limit: limit, offset: offset, viewSource: nil)) ?? []
    }

    /// 跨书总数（分页「已加载/共 N」如实标注）。
    func annotationTotalCount() -> Int {
        assert(Thread.isMainThread, "annotation queries must run on the main thread")
        guard let store = highlightStore else { return 0 }
        return (try? store.allHighlightsCount()) ?? 0
    }

    /// 每书计数（摘录板分组头徽标；withNote = 带注行数）。
    func excerptBookCounts() -> [(bookID: String, total: Int, withNote: Int)] {
        assert(Thread.isMainThread, "annotation queries must run on the main thread")
        guard let store = highlightStore else { return [] }
        return (try? store.highlightsByBookCounts()) ?? []
    }

    /// created_at 区间窗口（每日回顾数据源；区间换算在视图侧纯函数）。
    func reviewWindows(from: Date?, to: Date?, limit: Int, offset: Int) -> [UserHighlight] {
        assert(Thread.isMainThread, "annotation queries must run on the main thread")
        guard let store = highlightStore else { return [] }
        return (try? store.highlightsCreated(from: from, to: to, limit: limit, offset: offset)) ?? []
    }

    /// created_at 区间总数（每日回顾「共 N 条」如实标注）。
    func reviewTotalCount(from: Date?, to: Date?) -> Int {
        assert(Thread.isMainThread, "annotation queries must run on the main thread")
        guard let store = highlightStore else { return 0 }
        return (try? store.highlightsCreatedCount(from: from, to: to)) ?? 0
    }

    // MARK: 批量导出（任务化前台管道；取消即停、同目录重跑续）

    /// 导出进行中的进度回执（AnnotationExportView 进度条）。
    @Published var annotationExportProgress: AnnotationExportProgress?
    /// 最近一次导出的汇总回执（sheet 完成面板/失败汇总）。
    @Published var annotationExportSummary: AnnotationExportPipeline.Summary?
    /// 最近一次导出的失败信息（未识别 state 拒跑等管道外错误）。
    @Published var annotationExportError: String?
    /// 管道在跑（取消/重跑按钮禁用依据）。
    @Published var annotationExportRunning = false
    private var annotationExportTask: Task<Void, Never>?

    /// 触发一次批量导出（后台 Task 跑管道；书间检查取消；进度/汇总回主线程）。
    /// 三条注入（三轨页码行/颜色名/文件名清洗）全部取既有 App 层实现；引注
    /// 数据在主线程先取好再进 detached（管道回调闭包非隔离可执行）。
    func runAnnotationExport(directory: URL, selection: AnnotationExportSelection) {
        guard annotationExportTask == nil else { return }
        guard let s = try? storeOrOpen(), let store = highlightStore else {
            annotationExportError = L10n.annotationExportStoreUnavailable
            return
        }
        let citationRows = citationExportRows()
        let citationsMD = citationsMarkdown()
        annotationExportError = nil
        annotationExportSummary = nil
        annotationExportRunning = true
        annotationExportProgress = AnnotationExportProgress(total: 0, done: 0, failed: 0, currentBook: nil)
        annotationExportTask = Task.detached(priority: .userInitiated) { [weak self] in
            let pipeline = AnnotationExportPipeline(highlightStore: store, indexStore: s)
            do {
                let summary = try pipeline.run(
                    directory: directory, selection: selection,
                    citations: citationRows,
                    citationsMarkdown: citationsMD,
                    pageTrackText: { bookID, page in
                        let line = AppState.pageTrackLine(store: s, bookID: bookID, pageNumber: page)
                        return line.isEmpty ? L10n.highlightsPageLabel(page) : line
                    },
                    colorName: { color in
                        AppState.exportColorName(color)
                    },
                    cleanName: { CitationFormatter.cleanFileName($0) },
                    shouldCancel: { Task.isCancelled },
                    progress: { value in
                        Task { @MainActor in self?.annotationExportProgress = value }
                    })
                await MainActor.run { [weak self] in
                    self?.annotationExportSummary = summary
                    if summary.allFailed {
                        self?.annotationExportError = L10n.annotationExportAllFailed
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.annotationExportError = String(describing: error)
                }
            }
            await MainActor.run { [weak self] in
                self?.annotationExportTask = nil
                self?.annotationExportRunning = false
            }
        }
    }

    /// 取消当前导出（书间生效；已写文件保留如实报告）。
    func cancelAnnotationExport() {
        annotationExportTask?.cancel()
    }

    /// 引注 CSV 行（books 全表投影；citation 串走 CitationFormatter 既有体例）。
    private func citationExportRows() -> [AnnotationExportCitationRow] {
        guard let s = try? storeOrOpen(), let books = try? s.allBooks() else { return [] }
        return books.map { book in
            AnnotationExportCitationRow(
                author: book.author ?? "", title: book.title ?? "",
                version: book.version ?? "", language: book.language ?? "",
                fileName: book.fileName,
                citation: CitationFormatter.bookCitation(fileName: book.fileName,
                                                         title: book.title))
        }
    }

    /// 引注 MD（bibliography 一行一书；books 全表）。
    private func citationsMarkdown() -> String {
        guard let s = try? storeOrOpen(), let books = try? s.allBooks() else { return "" }
        return CitationFormatter.bibliography(
            books.map { (fileName: $0.fileName, title: $0.title) },
            style: .faxueYinzhuShouce)
    }

    /// 三轨页码行（非隔离静态：detached 导出任务内可用；照 highlightsExport
    /// Markdown 同款组装——物理/标签/印刷页，印刷页经 PageNumberService）。
    /// `s` 由调用方传入（IndexStore 线程安全读），不触 MainActor 状态。
    nonisolated private static func pageTrackLine(store s: IndexStore,
                                                  bookID: String, pageNumber: Int) -> String {
        guard let book = try? s.book(byID: bookID) else { return "" }
        let page = try? s.page(bookID: bookID, pageNumber: pageNumber)
        let hit = SearchHit(bookID: book.id, filePath: book.realPath, fileName: book.fileName,
                            fingerprint: book.fingerprint, physicalPage: pageNumber,
                            pageLabel: page?.label, printedPage: nil,
                            pageCount: book.pageCount, title: book.title, author: book.author,
                            version: book.version, language: book.language,
                            matches: [], snippet: "", source: "native")
        return HitRouter.threeTrackPageText(
            for: hit,
            printed: PageNumberService.forStore(s).printedPage(bookID: bookID,
                                                               physical: pageNumber))
    }

    /// 键位注册表（启动加载 keybindings.json；坏文件 fail-closed
    /// 回默认表 + 告警）。经 RootView 环境注入，按钮侧 registeredShortcut
    @Published var keybindings: KeybindingRegistry = .builtin()

    init() {
        // 键位外置加载（AppSupportPaths 应用目录 keybindings.json，
        // 与 reader-preferences.json 同目录；文件不存在 = 未定制，用默认表）。
        keybindings = KeybindingRegistry.load(userURL: KeybindingRegistry.defaultUserURL())
        // 根目录推导收拢到 AppSupportPaths（消灭 first 强解包；
        // 异常环境降级到家目录降级处理并给出明确警告，落点语义不变）。
        let resolved = AppSupportPaths.resolveBase(
            from: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask))
        storageWarning = resolved.warning
        dbURL = AppSupportPaths.directory(under: resolved.url).appendingPathComponent("index.db")
        exportDirectoryPath = UserDefaults.standard.string(forKey: Self.exportDirectoryDefaultsKey)
            ?? AppSupportPaths.defaultExportDirectory(under: resolved.url).path
        history = SharedHistoryStore(fileURL: SharedHistoryStore.sharedFileURL())
        do {
            policy = ExclusionPolicy(config: try ExclusionConfig.loadForOperation(
                fileAt: dbURL.deletingLastPathComponent().appendingPathComponent("exclusions.json")))
        } catch {
            // Fail closed: baseline + forbidden defaults remain enforced; the
            // malformed file blocks indexing until the user fixes it.
            policy = ExclusionPolicy(config: ExclusionConfig.conservativeDefaults)
            policyConfigError = String(describing: error)
        }
        if let root = access.restoreRoot() {
            rootName = root.lastPathComponent
        }
        ocrOriginalRootName = access.restore(.originalRoot)?.lastPathComponent
        ocrOCRRootName = access.restore(.ocrRoot)?.lastPathComponent
        sidebarSection = SidebarSection(rawValue: UserDefaults.standard.string(forKey: "sidebarSection") ?? "") ?? .search
        citationStyle = CitationStyle(rawValue: UserDefaults.standard.string(forKey: "citationStyle") ?? "") ?? .faxueYinzhuShouce
        let storedLimit = UserDefaults.standard.integer(forKey: "bookHitsLimit")
        bookHitsLimit = storedLimit > 0 ? storedLimit : 2000
        filterDomain = UserDefaults.standard.string(forKey: "filterDomain") ?? ""
        loadWebDAVSettings()
        scheduleCoverageRefresh()
        scheduleDailyQuoteRefresh()
        refreshHistory()
        // 上次启动用户已开启的本机 API 随开关态恢复（服务随开关
        // 启停，无守护进程——只在本 App 进程内存活；storeOrOpen 主线程打开，
        // 与 quote/coverage 启动路径同款）。
        if localAPIEnabled {
            startLocalAPI()
        }
    }

    // MARK: WebDAV 同步（仿既有 Task.detached → MainActor.run 模式）

    /// 启动时装载：配置 JSON（坏档回默认）+ 钥匙串密码预填（仅内存）。
    private func loadWebDAVSettings() {
        if let config = webdavSettings.load() {
            webdavServerBase = config.serverBase
            webdavUsername = config.username
            webdavRemoteDir = config.rules.first?.remoteDir ?? WebDAVSettingsStore.defaultRemoteDir
            webdavLocalRootName = config.rules.first?.localRoot.lastPathComponent
                ?? WebDAVSettingsStore.defaultLocalFolder
        }
        webdavPassword = webdavSecrets.read(account: Self.webdavSecretAccount) ?? ""
    }

    /// 本机钥匙串 account（独立 service，见 webdavSecrets）。
    static let webdavSecretAccount = "webdav.password"

    /// 字段 → 配置（HTTPS 强制：Basic 凭据不得走明文）；非法置状态行返 nil。
    private func buildWebDAVConfig() -> WebDAVSyncConfig? {
        let base = webdavServerBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: base), url.scheme?.lowercased() == "https", url.host != nil else {
            webdavStatus = L10n.webdavInvalidURL
            return nil
        }
        let remoteDir = webdavRemoteDir.trimmingCharacters(in: .whitespacesAndNewlines)
        let rule = WebDAVSyncRule(remoteDir: remoteDir.isEmpty ? WebDAVSettingsStore.defaultRemoteDir : remoteDir,
                                  localRoot: AppSupportPaths.appDirectory(WebDAVSettingsStore.defaultLocalFolder))
        return WebDAVSyncConfig(serverBase: base,
                                username: webdavUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                                rules: [rule])
    }

    /// 动作前置：校验 + 先持久化（配置 JSON + 钥匙串密码）。失败置状态行。
    private func validatedWebDAVInputs() -> (config: WebDAVSyncConfig, password: String)? {
        guard let config = buildWebDAVConfig() else { return nil }
        let password = webdavPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !config.username.isEmpty, !password.isEmpty else {
            webdavStatus = L10n.webdavCredentialsMissing
            return nil
        }
        do {
            try webdavSecrets.save(password, account: Self.webdavSecretAccount)
            try webdavSettings.save(config)
            webdavLocalRootName = config.rules.first?.localRoot.lastPathComponent
                ?? WebDAVSettingsStore.defaultLocalFolder
        } catch {
            webdavStatus = "\(L10n.webdavSaveFailedPrefix)\(error)"
            return nil
        }
        return (config, password)
    }

    /// 连接测试：PROPFIND depth1 只验可达+鉴权，状态行显示远端条目数。
    func testWebDAVConnection() {
        guard let inputs = validatedWebDAVInputs() else { return }
        webdavBusy = true
        webdavStatus = L10n.webdavWorking
        let config = inputs.config
        let password = inputs.password
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<Int, Error>
            do {
                // 安全约束：serverBase 代码级强制（HTTPS/无 userinfo），
                // 非法=明确报错（假 URL 降级处理已废除）。
                let base = try WebDAVClient.validatedBase(config.serverBase)
                let client = WebDAVClient(serverBase: base, username: config.username, password: password)
                let entries = try await client.list(directory: config.rules.first?.remoteDir ?? "/")
                result = .success(entries.count)
            } catch {
                result = .failure(error)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.webdavBusy = false
                switch result {
                case .success(let count):
                    self.webdavStatus = L10n.webdavConfigSaved + L10n.webdavTestOK(count)
                case .failure(let error):
                    self.webdavStatus = "\(L10n.webdavTestFailedPrefix)\(error)"
                }
            }
        }
    }

    /// 预览同步（dry-run）：远端清单 vs 本地账本，显示将下载文件数与总大小。
    func previewWebDAVSync() {
        guard let inputs = validatedWebDAVInputs() else { return }
        webdavBusy = true
        webdavStatus = L10n.webdavWorking
        let config = inputs.config
        let password = inputs.password
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<WebDAVSyncOutcome, Error>
            do {
                var merged = WebDAVSyncOutcome()
                for rule in config.rules {
                    let outcome = try await WebDAVSyncEngine.sync(rule: rule, config: config,
                                                                  password: password, dryRun: true)
                    merged.skipped += outcome.skipped
                    merged.pendingDownloads += outcome.pendingDownloads
                    merged.failed += outcome.failed
                }
                result = .success(merged)
            } catch {
                result = .failure(error)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.webdavBusy = false
                switch result {
                case .success(let outcome):
                    let bytes = outcome.pendingDownloads.reduce(Int64(0)) { $0 + $1.size }
                    self.webdavStatus = L10n.webdavConfigSaved
                        + L10n.webdavPreviewOK(outcome.pendingDownloads.count,
                                               ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    if let firstFailure = outcome.failed.first {
                        self.webdavStatus += "\n\(L10n.webdavPreviewFailedPrefix)\(firstFailure)"
                    }
                case .failure(let error):
                    self.webdavStatus = "\(L10n.webdavPreviewFailedPrefix)\(error)"
                }
            }
        }
    }

    /// 立即同步：真跑 sync，状态行显示新增/跳过/失败计数（失败附前两条明细）。
    func syncWebDAVNow() {
        guard let inputs = validatedWebDAVInputs() else { return }
        webdavBusy = true
        webdavStatus = L10n.webdavWorking
        let config = inputs.config
        let password = inputs.password
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<WebDAVSyncOutcome, Error>
            do {
                var merged = WebDAVSyncOutcome()
                for rule in config.rules {
                    let outcome = try await WebDAVSyncEngine.sync(rule: rule, config: config,
                                                                  password: password)
                    merged.downloaded += outcome.downloaded
                    merged.skipped += outcome.skipped
                    merged.failed += outcome.failed
                }
                result = .success(merged)
            } catch {
                result = .failure(error)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.webdavBusy = false
                switch result {
                case .success(let outcome):
                    var line = L10n.webdavConfigSaved
                        + L10n.webdavSyncOK(outcome.downloaded.count, outcome.skipped, outcome.failed.count)
                    if !outcome.failed.isEmpty {
                        let detail = outcome.failed.prefix(2).joined(separator: "；")
                        line += "（\(detail)\(outcome.failed.count > 2 ? " …" : "")）"
                    }
                    self.webdavStatus = line
                case .failure(let error):
                    self.webdavStatus = "\(L10n.webdavSyncFailedPrefix)\(error)"
                }
            }
        }
    }

    // MARK: WebDAV 索引上传（方案一：VACUUM INTO 快照 → 白名单 PUT → manifest 提交点）

    /// 审计存储（环形 5 条；测试注入临时目录，生产默认 AppSupport）。
    let webdavUploadAuditStore = WebDAVUploadAuditStore()
    @Published var webdavUploadBusy = false
    @Published var webdavUploadStatus = ""
    @Published var webdavUploadAudit: [WebDAVUploadAuditEntry] = []

    /// 快照工作目录（VACUUM INTO 落点；上传后即清）。
    /// 时需同量级临时磁盘与分钟级耗时——设置页状态行已注明。
    static var indexUploadDirectory: URL {
        AppSupportPaths.appDirectory("webdav-upload-work", ensure: true)
    }


    // MARK: 手机分享拉取（PROPFIND inbox → 白名单 → 幂等落盘）

    @Published var webdavInboxBusy = false
    @Published var webdavInboxStatus = ""

    func pullShareInbox() {
        guard !webdavInboxBusy else { return }
        guard let inputs = validatedWebDAVInputs() else { return }
        webdavInboxBusy = true
        webdavInboxStatus = L10n.iosInboxPulling
        let config = inputs.config
        let password = inputs.password
        Task.detached(priority: .userInitiated) { [weak self] in
            let line: String
            do {
                let base = try WebDAVClient.validatedBase(config.serverBase)
                let client = WebDAVClient(serverBase: base, username: config.username, password: password)
                let puller = ShareInboxPuller(loader: WebDAVShareInboxLoader(client: client),
                                              into: AppSupportPaths.appDirectory("inbox", ensure: true))
                let outcome = try await puller.pull()
                line = L10n.iosInboxPulled(outcome.downloaded.count,
                                           outcome.skippedExisting.count,
                                           outcome.skippedOversize.count + outcome.foreignSkipped)
            } catch {
                line = L10n.iosInboxPullFailed(String(describing: error))
            }
            await MainActor.run { [weak self] in
                self?.webdavInboxBusy = false
                self?.webdavInboxStatus = line
            }
        }
    }

    func reloadWebDAVUploadAudit() {
        webdavUploadAudit = webdavUploadAuditStore.entries()
    }

    /// 「上传索引到 WebDAV」（手动）：先走既有凭据门（未配置→状态行
    /// 明确报错不静默），再只读 PROPFIND 连接测试，通过后
    /// 快照+上传。网络与磁盘重活全部在后台，状态回主线程。
    func uploadIndexToWebDAV() {
        guard !webdavUploadBusy else { return }
        guard let inputs = validatedWebDAVInputs() else { return }   // 未配置凭据：明确报错
        webdavUploadBusy = true
        webdavUploadStatus = L10n.webdavUploadInProgress
        let config = inputs.config
        let password = inputs.password
        let dbPath = dbURL
        let workDir = Self.indexUploadDirectory
        let auditStore = webdavUploadAuditStore
        let cleanupEnabled = WebDAVUploadOptions.cleanupEnabled(UserDefaults.standard)
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "dev"
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<WebDAVUploadOutcome, Error>
            do {
                let base = try WebDAVClient.validatedBase(config.serverBase)
                let client = WebDAVClient(serverBase: base, username: config.username, password: password)
                // 连接测试只读先行：PROPFIND 上传前缀（未配置凭据/网络
                // 不通在这里显式失败，不产生任何写动作）。
                _ = try await client.list(directory: WebDAVIndexPaths.uploadPrefixDirectory)
                defer { try? FileManager.default.removeItem(at: workDir) }
                let snapshot = try WebDAVIndexUploader.buildSnapshot(
                    dbPath: dbPath, workDir: workDir, appVersion: appVersion)
                let outcome = try await WebDAVIndexUploader.uploadAll(
                    client: client, snapshot: snapshot,
                    cleanupEnabled: cleanupEnabled, audit: auditStore)
                result = .success(outcome)
            } catch {
                auditStore.append(kind: "upload", result: "failed", detail: String(describing: error))
                result = .failure(error)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.webdavUploadBusy = false
                self.reloadWebDAVUploadAudit()
                switch result {
                case .success(let outcome):
                    var line = L10n.webdavUploadOK(outcome.volumesTotal, outcome.volumesSkipped,
                                                   ByteCountFormatter.string(fromByteCount: outcome.totalBytes,
                                                                             countStyle: .file),
                                                   L10n.webdavUploadDurationSeconds(outcome.durationSeconds))
                    if let cleanupError = outcome.cleanupError {
                        line += L10n.webdavUploadCleanupFailedPrefix + cleanupError
                            + L10n.webdavUploadCleanupFailedSuffix
                    }
                    self.webdavUploadStatus = line
                case .failure(let error):
                    self.webdavUploadStatus = "\(L10n.webdavUploadFailedPrefix)\(error)"
                }
            }
        }
    }

    func triggerAutoIndexUploadIfEnabled() {
        guard WebDAVUploadOptions.autoUploadEnabled(UserDefaults.standard) else { return }
        uploadIndexToWebDAV()
    }

    /// Launch path (external-research slice; Apple launch guidance:
    /// keep heavy work off the first frame). Coverage statistics touch every
    private func scheduleCoverageRefresh() {
        coverageGeneration += 1
        let generation = coverageGeneration
        guard let s = try? storeOrOpen() else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let stats = try? s.coverageStats()
            let perBook = try? s.perBookPageStats()
            let books = (try? s.allBooks()) ?? []
            let recordJSON = try? s.metaValue("last_run_summary")
            let record = recordJSON.flatMap { try? JSONDecoder().decode(IndexingEngine.RunRecord.self, from: Data($0.utf8)) }
            await MainActor.run { [weak self] in
                self?.applyCoverage(stats: stats, perBook: perBook, books: books, record: record, generation: generation)
            }
        }
    }

    /// Main-actor application of fetched coverage data (also writes the shared
    /// Widget snapshot — same values as before, just off the launch path).
    private func applyCoverage(stats: IndexStore.CoverageStats?, perBook: [BookPageStat]?,
                               books: [IndexStore.BookRow], record: IndexingEngine.RunRecord?,
                               generation: Int) {
        guard generation == coverageGeneration else { return }
        if let stats { coverageStats = stats }
        if let perBook {
            coverageClassification = CoverageClassification(stats: perBook)
            self.perBookStats = perBook
        }
        if let record { lastRunRecord = record }
        let roots = Set(books.map(\.rootPath))
        bookNames = Dictionary(books.map { ($0.id, $0.fileName) },
                               uniquingKeysWith: { first, _ in first })
        libraryBooks = books.sorted { sortKey($0) < sortKey($1) }
        var pageCount = 0
        for book in books { pageCount += book.pageCount }
        history.update(coverage: CoverageSnapshot(
            bookCount: books.count,
            pageCount: pageCount,
            lastIndexedAt: lastRunRecord?.at,
            rootName: roots.count == 1 ? books.first.map { URL(fileURLWithPath: $0.rootPath).lastPathComponent } : nil,
            rootCount: roots.count,
            pagesWithoutText: coverageStats?.pagesWithoutText,
            errorBooks: coverageStats?.booksError,
            lastRunExcluded: lastRunRecord?.excluded,
            lastRunUnsupported: lastRunRecord?.unsupported,
            lastRunFailed: lastRunRecord?.failed
        ))
    }

    func storeOrOpen() throws -> IndexStore {
        if let store { return store }
        let s = try IndexStore(path: dbURL)
        store = s
        return s
    }

    // MARK: 稳定页码（docs/PAGE-BASIS.md）

    /// 统一取页服务入口：printed 页码两路合成（page_map 表 > pages 列）。
    /// 消费面（引句绑定/命中行引注/详情页轨文本/高亮导出）一律经此取页，
    /// nil = 未知，绝不回退猜测。存储基准恒为物理页（位置记忆契约零改动）。
    func printedPage(bookID: String, physical: Int) -> Int? {
        guard let s = try? storeOrOpen() else { return nil }
        return PageNumberService.forStore(s).printedPage(bookID: bookID, physical: physical)
    }

    // MARK: 元数据在线补全（手动唯一；总开关默认关）

    /// 详情页粘贴的查询标识（只作查询输入，不持久化入库——隐私契约）。
    @Published var fetchDOIInput = ""
    @Published var fetchArxivInput = ""
    @Published var fetchMessage: String?
    @Published var fetchRunning = false

    static let metadataFetchEnabledKey = "metadataFetchEnabled"
    static let metadataFetchSourceKeyPrefix = "metadataFetchSource."

    /// 总开关（UserDefaults，默认关）。关闭时详情页按钮禁用 + 零请求。
    var metadataFetchEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.metadataFetchEnabledKey)
    }

    func setMetadataFetchEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.metadataFetchEnabledKey)
        objectWillChange.send()
    }

    func metadataFetchSourceEnabled(_ source: MetadataSource) -> Bool {
        UserDefaults.standard.bool(forKey: Self.metadataFetchSourceKeyPrefix + source.rawValue)
    }

    func setMetadataFetchSource(_ source: MetadataSource, enabled: Bool) {
        UserDefaults.standard.set(enabled,
                                  forKey: Self.metadataFetchSourceKeyPrefix + source.rawValue)
        objectWillChange.send()
    }

    var metadataFetchEnabledSources: Set<MetadataSource> {
        Set(MetadataSource.allCases.filter { metadataFetchSourceEnabled($0) })
    }

    /// 手动触发（详情页按钮）：链序每源至多一次、零重试、超时 15s；
    /// 只填 nil 字段；报告落 AppSupportPaths 下 fetch-report.json（环形 10）。
    func fetchMetadataForBookDetail() {
        guard let book = bookDetail else { return }
        guard metadataFetchEnabled else {
            fetchMessage = L10n.metadataFetchMasterOff
            return
        }
        guard !fetchRunning else { return }
        guard let store = try? storeOrOpen() else { return }
        fetchRunning = true
        fetchMessage = nil
        let service = MetadataFetchService(loader: URLSessionMetadataLoader())
        let reportURL = AppSupportPaths.appDirectory(ensure: true)
            .appendingPathComponent("fetch-report.json", isDirectory: false)
        let enabled = metadataFetchEnabledSources
        let doi = fetchDOIInput.trimmingCharacters(in: .whitespaces)
        let arxiv = fetchArxivInput.trimmingCharacters(in: .whitespaces)
        let bookID = book.id
        let fileName = book.fileName
        let title = book.title ?? (book.fileName as NSString).deletingPathExtension
        let author = book.author
        Task { @MainActor in
            let report = await service.fetch(bookID: bookID, fileName: fileName,
                                             doi: doi.isEmpty ? nil : doi,
                                             arxivID: arxiv.isEmpty ? nil : arxiv,
                                             title: title, author: author,
                                             store: store,
                                             enabled: enabled,
                                             reportURL: reportURL)
            let requestedSources = report.outcomes.filter(\.requested).count
            fetchMessage = L10n.metadataFetchDone(report.appliedFields.count, requestedSources)
            fetchRunning = false
            reloadBookDetailFields()
            if !query.trimmingCharacters(in: .whitespaces).isEmpty { search() }
        }
    }

    /// 页码映射 sidecar 手动导入回执（booksSection 入口；NSOpenPanel 同款，
    /// 无任何自动/定时触发）。
    @Published var pageMapImportMessage: String?

    func importPageMapSidecar() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.prompt = L10n.pageMapImportPrompt
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let s = try storeOrOpen()
            let data = try Data(contentsOf: url)
            let (books, report) = try s.importPageMapSidecar(data)
            pageMapImportMessage = L10n.pageMapImportDone(books, report.acceptedRows,
                                                          report.rejected.count,
                                                          report.unmatchedBooks.count)
            search() // 命中行轨文本/引注按新映射刷新
        } catch {
            pageMapImportMessage = L10n.pageMapImportFailurePrefix + "\(error)"
        }
    }

    /// 自动目录回退：只读索引库 auto_toc 表（生成由索引批末
    /// rebuildAutoTOCAll 负责，这里只读）；库未开/无目录返回空数组。
    /// UI 层经 autoTOCProvider 闭包调用，Coordinator 不持 IndexStore。
    func autoTOC(for bookID: String) -> [AutoTOCEntry] {
        (try? storeOrOpen().autoTOC(for: bookID)) ?? []
    }

    // MARK: 每日一句（后台抽取 + Widget 共享面）
    //
    // Launch path mirrors scheduleCoverageRefresh: the store opens on the main
    // thread (sub-millisecond), the pool extraction runs detached and ONLY when
    // the pool is empty (full-library scan, seconds — never on the first frame),
    // and the cheap per-day pick + shared-file write land back on the main actor.

    private func scheduleDailyQuoteRefresh() {
        quoteLoading = true
        guard let s = try? storeOrOpen() else { quoteLoading = false; return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let picked: Quote?
            do {
                if QuoteExtractor.today(store: s) == nil {
                    // 池空才全库抽取（幂等：DELETE 当日 + INSERT 事务）。
                    _ = try QuoteExtractor.extract(from: s)
                }
                picked = QuoteExtractor.today(store: s)
            } catch {
                await MainActor.run { [weak self] in
                    self?.quoteLoading = false
                }
                return
            }
            guard let picked else {
                await MainActor.run { [weak self] in
                    self?.quoteLoading = false
                }
                return
            }
            let pool = (try? s.allDailyQuotes()) ?? []
            var books: [String: QuoteBookInfo] = [:]
            for q in [picked] + pool {
                guard books[q.bookID] == nil, let row = try? s.book(byID: q.bookID) else { continue }
                books[q.bookID] = QuoteBookInfo(title: row.title, author: row.author)
            }
            let snapshotBooks = books
            await MainActor.run { [weak self] in
                self?.applyDailyQuote(picked: picked, pool: pool, books: snapshotBooks)
            }
        }
    }

    /// Main-actor application of the picked quote: state, shared file, widget reload.
    private func applyDailyQuote(picked: Quote, pool: [Quote], books: [String: QuoteBookInfo]) {
        todayQuote = picked
        quoteAlternatives = Array(pool.filter { $0.id != picked.id }.prefix(5))
        quoteBooks = books
        quoteLoading = false
        let shared = SharedQuoteStore(fileURL: SharedQuoteStore.quoteFileURL())
        shared.save(SharedQuoteState(sentence: picked.sentence, bookFileName: picked.fileName,
                                    physicalPage: picked.pageNumber, date: Self.quoteDateString()))
        // App Group 文件已变化：立刻刷新 Widget 时间线（另有过夜 .daily 刷新）。
        WidgetCenter.shared.reloadTimelines(ofKind: "DailyQuoteWidget")
    }

    static func quoteDateString(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar.current
        return formatter.string(from: date)
    }

    /// Widget 深链入口：跳到每日一句分区；数据缺失时触发一次后台刷新。
    func openTodayQuote() {
        sidebarSection = .quote
        if todayQuote == nil && !quoteLoading {
            scheduleDailyQuoteRefresh()
        }
    }

    /// Quote → 完全忠实的 SearchHit：在页文本内定位句子的 UTF-16 区间作
    /// 高亮（定位失败则不高亮，页码/指纹不受影响）；OCR 来源页带齐配对，
    /// 坐标留在 OCR 文件，绝不映射回原书（HitRouter 不变式）。
    func hit(for quote: Quote) -> SearchHit? {
        guard let s = try? storeOrOpen() else { return nil }
        guard let book = try? s.book(byID: quote.bookID),
              let page = try? s.page(bookID: quote.bookID, pageNumber: quote.pageNumber) else {
            return nil
        }
        let pairing = try? s.ocrPairing(bookID: quote.bookID)
        let isOCR = pairing?.ocrSourcedPages.contains(quote.pageNumber) ?? false
        let range = Self.quoteRange(of: quote.sentence, in: page.textOriginal)
        let match = range.map { SearchHit.TermMatch(term: "", displayTerm: quote.sentence,
                                                    originalUTF16Range: $0) }
        return SearchHit(
            bookID: book.id, filePath: book.realPath, fileName: book.fileName,
            fingerprint: book.fingerprint, physicalPage: quote.pageNumber,
            pageLabel: page.label, printedPage: page.printedPage, pageCount: book.pageCount,
            title: book.title, author: book.author, version: book.version, language: book.language,
            matches: match.map { [$0] } ?? [], snippet: quote.sentence,
            source: isOCR ? "ocr" : "native",
            ocrFilePath: isOCR ? pairing?.ocrRealPath : nil,
            ocrPage: isOCR ? pairing?.ocrPages[quote.pageNumber] : nil,
            ocrFingerprint: isOCR ? pairing?.ocrFingerprint : nil)
    }

    /// 在页文本中定位摘录句的 UTF-16 区间：精确匹配优先，去首尾空白回退。
    static func quoteRange(of sentence: String, in text: String) -> Range<Int>? {
        if let r = text.range(of: sentence) {
            return r.lowerBound.utf16Offset(in: text)..<r.upperBound.utf16Offset(in: text)
        }
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let r = text.range(of: trimmed) {
            return r.lowerBound.utf16Offset(in: text)..<r.upperBound.utf16Offset(in: text)
        }
        return nil
    }

    /// 「打开原书此页」：合成 hit 走既有 select/openGuard 管线，
    /// 双指纹守卫自动生效（OCR 句：显示在 OCR 文件页，可在阅读条切原件视图）。
    func openQuoteInBook(_ quote: Quote) async {
        guard let hit = hit(for: quote) else {
            quoteBlockedReason = L10n.quoteBookMissing
            return
        }
        quoteHit = hit
        quoteBlockedReason = nil
        await select(hit: hit)
        if let reason = openBlockedReason {
            quoteBlockedReason = reason
        }
    }

    /// 每日一句 AI 三按钮模式：翻译 / 解释 / 语法拆解，
    /// 仅决定预填 prompt，确认门与发送管线完全一致。
    enum QuoteAIMode: Equatable {
        case translate, explain, grammar

        var prompt: String {
            switch self {
            case .translate: return L10n.quoteAITranslatePrompt
            case .explain: return L10n.quoteAIExplainPrompt
            case .grammar: return L10n.quoteAIGrammarPrompt
            }
        }
    }

    /// 「翻译 / 解释 / 语法拆解」：按模式预填 prompt 后走既有 AI 确认门
    /// （openGuard → 零 I/O 预览 → 逐次确认发送，未确认前零请求）。
    func makeQuoteAIPreview(_ quote: Quote, mode: QuoteAIMode = .translate) async {
        guard aiConfigured else { return }
        guard let hit = hit(for: quote) else {
            aiMessage = L10n.quoteBookMissing
            return
        }
        quoteHit = hit
        aiQuestion = mode.prompt
        await makeAIPreview(for: hit)
    }

    // MARK: - 高亮与收藏（阅读侧视图层支撑）

    func postFavoriteNotice(_ text: String) {
        lastFavoriteNotice = text
        favoriteNoticeTask?.cancel()
        favoriteNoticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.lastFavoriteNotice = nil
        }
    }

    func favoriteBook(bookID: String, fileName: String, title: String?) {
        guard let store = favoritesStore else { postFavoriteNotice(L10n.favoriteAddFailed); return }
        do {
            _ = try store.add(.book(bookID: bookID, fileName: fileName, title: title))
            postFavoriteNotice(L10n.favoriteAddedBook)
        } catch { postFavoriteNotice(L10n.favoriteAddFailed) }
    }

    func favoritePage(_ hit: SearchHit) {
        guard let store = favoritesStore else { postFavoriteNotice(L10n.favoriteAddFailed); return }
        let range = hit.matches.first?.originalUTF16Range
        do {
            _ = try store.add(.page(bookID: hit.bookID, fileName: hit.fileName,
                                    pageNumber: hit.physicalPage, snippet: hit.snippet,
                                    utf16Start: range?.lowerBound, utf16End: range?.upperBound))
            postFavoriteNotice(L10n.favoriteAddedPage)
        } catch { postFavoriteNotice(L10n.favoriteAddFailed) }
    }

    func favoriteQuote() {
        guard let store = favoritesStore, let quote = todayQuote else {
            postFavoriteNotice(L10n.favoriteAddFailed); return
        }
        do {
            _ = try store.add(.quote(bookID: quote.bookID, fileName: quote.fileName,
                                     pageNumber: quote.pageNumber, sentence: quote.sentence))
            postFavoriteNotice(L10n.favoriteAddedQuote)
        } catch { postFavoriteNotice(L10n.favoriteAddFailed) }
    }

    func favoriteCurrentSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard let store = favoritesStore, !q.isEmpty else {
            postFavoriteNotice(L10n.favoriteAddFailed); return
        }
        do {
            _ = try store.add(.search(query: q))
            postFavoriteNotice(L10n.favoriteAddedSearch)
        } catch { postFavoriteNotice(L10n.favoriteAddFailed) }
    }

    /// 存为智能集合——query＋过滤四件（:37-43 @Published）整体
    /// 入库（集合存条件本身，FavoritesView 打开时经 state.search 现算，
    /// 零快照）。filter 组装照 search 内既有基准；四件全空存 nil（等价
    /// 无条件）。旧 favoriteCurrentSearch 入口原样保留。
    func saveCurrentSearchAsSmartCollection() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard let store = favoritesStore, !q.isEmpty else {
            postFavoriteNotice(L10n.favoriteAddFailed); return
        }
        let filter = SearchFilter(
            authorContains: filterAuthor.isEmpty ? nil : filterAuthor,
            versionContains: filterVersion.isEmpty ? nil : filterVersion,
            languageEquals: filterLanguage.isEmpty ? nil : filterLanguage,
            sourceDomain: filterDomain.isEmpty ? nil : filterDomain)
        do {
            _ = try store.add(.smartSearch(query: q, filter: filter.isActive ? filter : nil))
            postFavoriteNotice(L10n.favoriteAddedSmartSearch)
        } catch { postFavoriteNotice(L10n.favoriteAddFailed) }
    }

    /// 设置页「立即归类」（两处显式时机之一——无
    /// Timer 无常驻）。主线程只取库句柄（storeOrOpen 纪律），求值落后台。
    func runClassificationNow() {
        guard let store = classificationStore else {
            classificationMessage = L10n.classificationFailed
            return
        }
        // 主线程落地走 let 常量闭包（detached 内不捕 var self——不新增
        // Sendable 捕获 warning；求值仍全程后台，主线程零阻塞）。
        let finish: @MainActor (String) -> Void = { [weak self] message in
            self?.classificationMessage = message
        }
        Task.detached(priority: .userInitiated) {
            do {
                let report = try store.classifyAll()
                let skipped = report.disabledSkipped + report.invalidSkipped
                await finish(L10n.classificationResult(
                    report.classified, report.unclassified, skipped))
            } catch {
                await finish(L10n.classificationFailed)
            }
        }
    }

    // MARK: 深链定位（open / collection；handleDeepLink 分派）

    /// collection 深链的行焦点（FavoritesView onChange 接住置选中）。
    @Published var favoriteFocusID: Int64?
    /// 设置页归类状态行（「立即归类」结果回执）。
    @Published var classificationMessage: String = ""

    /// open 动词：书在库中才动作；书缺 → 显式 toast 不静默。page=nil 走
    /// 既有书级打开（openBookDetail，不开页）；page 非 nil 走 openBookPage
    ///（synthesizedHit→select，openGuard 双指纹自动生效），页不在也显式报。
    func deepLinkOpen(doc: String, page: Int?, highlight: Int64?) async {
        guard let s = try? storeOrOpen(), (try? s.book(byID: doc)) != nil else {
            postFavoriteNotice(L10n.deepLinkBookMissing)
            return
        }
        if let highlight {
            let rows = (try? highlightStore?.highlightsForBook(doc, viewSource: nil)) ?? nil
            guard let pageFromRow = rows.flatMap({ DeepLink.highlightPage(in: $0, id: highlight) }) else {
                postFavoriteNotice(L10n.deepLinkHighlightMissing)
                return
            }
            await openBookPage(bookID: doc, pageNumber: pageFromRow)
            return
        }
        guard let page else {
            openBookDetail(bookID: doc)
            return
        }
        guard synthesizedHit(bookID: doc, pageNumber: page) != nil else {
            postFavoriteNotice(L10n.deepLinkPageMissing)
            return
        }
        await openBookPage(bookID: doc, pageNumber: page)
    }

    /// collection 动词：行在库中才动作（缺行显式 toast）；命中则切收藏页
    /// 并把行 ID 交给视图选中。
    func deepLinkCollection(id: Int64) {
        guard let store = favoritesStore,
              let all = try? store.all(), all.contains(where: { $0.id == id }) else {
            postFavoriteNotice(L10n.deepLinkCollectionMissing)
            return
        }
        sidebarSection = .favorites
        favoriteFocusID = id
    }

    /// 「跳原文」通用入口（高亮列表 / 收藏列表共用）：合成无命中 hit 走既有
    /// select/openGuard 管线（双指纹自动生效；OCR 页自动落到 OCR 文件视图，
    /// 坐标纪律不变：坐标留在相应文件，绝不跨文件映射）。
    /// 成功路径记会话账本（opened＋activated）。
    func openBookPage(bookID: String, pageNumber: Int) async {
        guard let hit = synthesizedHit(bookID: bookID, pageNumber: pageNumber) else { return }
        await select(hit: hit)
    }

    /// 无命中 hit 合成（自 openBookPage 抽出供对照台复用；行为逐字
    /// 不变——bookID/page 不可得返回 nil，不猜）。
    func synthesizedHit(bookID: String, pageNumber: Int) -> SearchHit? {
        guard let s = try? storeOrOpen(),
              let book = try? s.book(byID: bookID),
              let page = try? s.page(bookID: bookID, pageNumber: pageNumber) else { return nil }
        let pairing = try? s.ocrPairing(bookID: bookID)
        let isOCR = pairing?.ocrSourcedPages.contains(pageNumber) ?? false
        return SearchHit(
            bookID: book.id, filePath: book.realPath, fileName: book.fileName,
            fingerprint: book.fingerprint, physicalPage: pageNumber,
            pageLabel: page.label, printedPage: page.printedPage, pageCount: book.pageCount,
            title: book.title, author: book.author, version: book.version, language: book.language,
            matches: [], snippet: "", source: isOCR ? "ocr" : "native",
            ocrFilePath: isOCR ? pairing?.ocrRealPath : nil,
            ocrPage: isOCR ? pairing?.ocrPages[pageNumber] : nil,
            ocrFingerprint: isOCR ? pairing?.ocrFingerprint : nil)
    }

    /// Smart Jump 外链引文跳转：调既有 resolveCitation
    /// 跨库解析（同名书 → 同作者+年份 → 全库检索回退，检索匹配语义零改动），
    /// 命中走 openBookPage 既有管线（select/openGuard/双指纹守卫原样生效）；
    /// 未命中打 3 秒瞬态回执。解析是 SQLite 只读，放后台线程，回主线程落地。
    func smartJumpCitation(_ target: CitationTargetKind) {
        guard let s = try? storeOrOpen() else {
            postFavoriteNotice(L10n.citationNotFound)
            return
        }
        let service = SearchService(store: s, policy: policy)
        let currentBookID = selectedHit?.bookID
        Task.detached(priority: .userInitiated) {
            let resolved = try? service.resolveCitation(target: target, currentBookID: currentBookID)
                await MainActor.run {
                    guard let resolved else {
                        self.postFavoriteNotice(L10n.citationNotFound)
                        return
                    }
                    Task { await self.openBookPage(bookID: resolved.bookID, pageNumber: resolved.pageNumber) }
                }
        }
    }

    /// 高亮列表预览：从索引页原文按 utf16 区间切片（页缺失/越界返回 nil，不猜）。
    func highlightSnippet(bookID: String, pageNumber: Int, range: Range<Int>) -> String? {
        guard let s = try? storeOrOpen(),
              let page = try? s.page(bookID: bookID, pageNumber: pageNumber) else { return nil }
        let utf16 = page.textOriginal.utf16
        guard range.lowerBound >= 0, range.upperBound <= utf16.count,
              range.lowerBound < range.upperBound else { return nil }
        let start = utf16.index(utf16.startIndex, offsetBy: range.lowerBound)
        let end = utf16.index(utf16.startIndex, offsetBy: range.upperBound)
        return String(decoding: utf16[start..<end], as: UTF16.self)
    }

    /// 整页原文（TTS 朗读用；只读索引库 text_original，原书 PDF 不碰）。
    func pageOriginalText(bookID: String, pageNumber: Int) -> String? {
        guard let s = try? storeOrOpen(),
              let page = try? s.page(bookID: bookID, pageNumber: pageNumber) else { return nil }
        return page.textOriginal
    }

    /// 高亮导出 Markdown：三轨页码行复用 HitRouter.threeTrackPageText；
    /// user_highlights 锚定原书物理页，source 恒 native（绝不带 OCR 轨）。
    /// 缺书/缺库/无有效条目返回 nil；切片失效回退 anchorText，不猜。
    /// 返回 (书名, Markdown)——书名为 books.title（未知回退 fileName），供
    /// NSSavePanel 默认文件名与 `# ` 标题行共用同一来源。
    func highlightsExportMarkdown(bookID: String) -> (title: String, markdown: String)? {
        guard let s = try? storeOrOpen(),
              let book = try? s.book(byID: bookID),
              let store = highlightStore else { return nil }
        let highlights = (try? store.verifiedHighlightsForBook(bookID)) ?? []
        guard !highlights.isEmpty else { return nil }
        var entries: [HighlightExportEntry] = []
        var trackCache: [Int: String] = [:]
        for h in highlights {
            let text: String
            if h.anchorVerified == 1,
               let slice = highlightSnippet(bookID: h.bookID, pageNumber: h.pageNumber,
                                            range: h.utf16Start..<h.utf16End), !slice.isEmpty {
                text = slice
            } else if !h.anchorText.isEmpty {
                text = h.anchorText
            } else {
                continue
            }
            let track: String
            if let cached = trackCache[h.pageNumber] {
                track = cached
            } else {
                let page = try? s.page(bookID: bookID, pageNumber: h.pageNumber)
                let hit = SearchHit(bookID: book.id, filePath: book.realPath, fileName: book.fileName,
                                    fingerprint: book.fingerprint, physicalPage: h.pageNumber,
                                    pageLabel: page?.label, printedPage: nil,
                                    pageCount: book.pageCount, title: book.title, author: book.author,
                                    version: book.version, language: book.language,
                                    matches: [], snippet: "", source: "native")
                track = HitRouter.threeTrackPageText(
                    for: hit, printed: printedPage(bookID: bookID, physical: h.pageNumber))
                trackCache[h.pageNumber] = track
            }
            entries.append(HighlightExportEntry(pageNumber: h.pageNumber, pageTrackText: track,
                                                text: text, note: h.note,
                                                colorName: Self.exportColorName(h.color)))
        }
        guard !entries.isEmpty else { return nil }
        let title = book.title ?? book.fileName
        return (title, HighlightExport.markdown(bookTitle: title, entries: entries))
    }

    /// 非隔离静态（detached 导出任务的 colorName 注入也在用；
    /// 纯查表无状态，主线程既有调用不受影响）。
    nonisolated private static func exportColorName(_ color: HighlightColor) -> String {
        switch color {
        case .yellow: return L10n.menuHighlightYellow
        case .green: return L10n.menuHighlightGreen
        case .blue: return L10n.menuHighlightBlue
        case .red: return L10n.menuHighlightRed
        }
    }

    // MARK: Folder

    func chooseFolder() {
        if let url = access.pickFolder() {
            rootName = url.lastPathComponent
        }
    }

    func chooseOriginalRoot() {
        if let url = access.pickFolder(role: .originalRoot, prompt: "选择原件根目录") {
            ocrOriginalRootName = url.lastPathComponent
        }
    }

    func chooseOCRRoot() {
        if let url = access.pickFolder(role: .ocrRoot, prompt: "选择 OCR 根目录") {
            ocrOCRRootName = url.lastPathComponent
        }
    }

    // MARK: OCR manifest (explicit pick + strict parse; nothing auto-detected)

    func pickOCRManifest() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        panel.prompt = "选择 OCR 配对清单 (JSON)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let manifest = try OCRPairManifest.parse(try Data(contentsOf: url))
            ocrManifest = manifest
            ocrManifestName = url.lastPathComponent
            ocrManifestEntryCount = manifest.entries.count
            ocrManifestError = nil
        } catch {
            ocrManifest = nil
            ocrManifestName = nil
            ocrManifestEntryCount = nil
            ocrManifestError = String(describing: error)
        }
    }

    // MARK: OCR pair import / verification (background, cancellable at run boundary)

    func startOCRImport() {
        guard !ocrImporting else { return }
        guard let manifest = ocrManifest else {
            ocrImportMessage = "尚未选择/解析 OCR 配对清单"
            return
        }
        guard let originalRoot = access.restore(.originalRoot), let ocrRoot = access.restore(.ocrRoot) else {
            ocrImportMessage = "需要先显式选择原件根目录与 OCR 根目录（不会读取未选择的目录）"
            return
        }
        if policyConfigError != nil {
            ocrImportMessage = "排除配置无效（fail-closed）：请修复 exclusions.json 后重试"
            return
        }
        runOCREngine({ engine in
            engine.importManifest(manifest, originalRoot: originalRoot, ocrRoot: ocrRoot)
        }, completion: { summary in
            Self.ocrSummaryText(summary) + (Task.isCancelled ? "（收到取消请求：引擎为单次同步调用，本次运行已完整结束）" : "")
        })
    }

    func cancelOCRImport() {
        ocrTask?.cancel()
        ocrImportMessage = "取消请求已发出（引擎为单次同步调用，当前运行结束后停止）"
    }

    func verifyOCRPairs() {
        guard !ocrImporting else { return }
        if policyConfigError != nil {
            ocrVerifyMessage = "排除配置无效（fail-closed）：请修复 exclusions.json 后重试"
            return
        }
        runOCREngine({ $0.verifyRegisteredPairs() }, completion: { summary in
            "复查完成：验证 \(summary.pairsVerified) 对；失效清除 \(summary.pairsStalePurged) 对" +
            "（文件指纹变化或策略翻转的配对已清除，陈旧引用随之失效）"
        })
    }

    /// Runs one OCR-engine pass off the main thread. Security-scoped access is
    /// held for both roots for the duration (import AND verification read both).
    private func runOCREngine(_ op: @escaping (OCRIndexingEngine) -> OCRImportSummary,
                              completion: @escaping (OCRImportSummary) -> String) {
        guard !ocrImporting else { return }
        do { _ = try storeOrOpen() } catch {
            ocrImportMessage = "索引库打开失败: \(error)"
            return
        }
        guard let store = store else { return }
        let enginePolicy = policy
        ocrImporting = true
        ocrImportMessage = nil
        ocrTask = Task { [weak self] in
            accessStart()
            let summary = await Task.detached(priority: .userInitiated) {
                op(OCRIndexingEngine(store: store, policy: enginePolicy))
            }.value
            // OCR imports replace page content — keep the inverted index fresh.
            // 复查路径只清失效配对（pairsImported==0、
            // pairsStalePurged>0）同样把 OCR 页翻回 native，索引与 native 计数须
            // 同刷；只看导入数会漏掉这条 purge-only 路径（CLI 侧同型修复）。
            if summary.pairsImported > 0 || summary.pairsStalePurged > 0 {
                _ = try? store.ensureBigramIndexFresh()
                _ = try? store.refreshBookNativeCounts()
                _ = try? store.backfillPinyinIfNeeded()
                _ = try? store.ensureWftsReady()   // 词级索引续跑/结算（幂等，ready 即 no-op）
            }
            accessStop()
            guard let self else { return }
            if summary.pairsImported > 0 || summary.pairsStalePurged > 0 {
                self.triggerAutoIndexUploadIfEnabled()
            }
            self.ocrImporting = false
            self.ocrImportSummary = summary
            self.ocrImportMessage = completion(summary)
            self.refreshCoverageFromStore()
        }
        func accessStart() { self.access.startAccess([.originalRoot, .ocrRoot]) }
        func accessStop() { self.access.stopAllAccess() }
    }

    static func ocrSummaryText(_ s: OCRImportSummary) -> String {
        "配对 共\(s.pairsTotal)：导入 \(s.pairsImported) · 未变化 \(s.pairsSkippedUnchanged) · 拒绝 \(s.pairsRejected) · " +
        "失败 \(s.pairsFailed) · 失效清除 \(s.pairsStalePurged)；页：并入 \(s.pagesImported) · 保持原生 \(s.pagesKeptNative) · 无文字 \(s.pagesTextless)"
    }

    // MARK: Indexing (never automatic)

    func startIndexing() {
        guard !indexing else { return }
        if policyConfigError != nil {
            indexError = "排除配置无效（fail-closed）：请修复 exclusions.json 后重试；基线排除仍生效"
            return
        }
        indexing = true
        indexError = nil
        indexTask = Task { [weak self] in
            guard let self else { return }
            defer { self.indexing = false }
            guard let root = self.access.startAccess() else {
                self.indexing = false
                return
            }
            defer { self.access.stopAccess() }
            do {
                let s = try self.storeOrOpen()
                let engine = IndexingEngine(store: s, policy: self.policy,
                                            progress: { [weak self] progress in
                    Task { @MainActor in
                        self?.progress = progress
                    }
                })
                let summary = try await engine.run(rootURL: root)
                self.lastSummary = summary
                let queueEngine = IndexingEngine(store: s, policy: policy)
                _ = try? await queueEngine.runQueued(timeBudget: 2.0)
                // Post-batch maintenance: page content changed, so rebuild the
                // bigram inverted index once (seconds) to keep cold queries on
                // the millisecond inverted-intersection path.
                _ = try? s.ensureBigramIndexFresh()
                _ = try? s.refreshBookNativeCounts()
                _ = try? s.backfillPinyinIfNeeded()
                _ = try? s.ensureWftsReady()   // 词级索引续跑/结算（幂等，ready 即 no-op）
                _ = try? s.rebuildAutoTOCAll()
                // 相似推荐缓存随批失效（下次查询全量重算）。
                self.similarEngine?.invalidate()
                refreshCoverageFromStore()
                triggerAutoIndexUploadIfEnabled()   // 方案一 重建完成且队列结算、新索引就绪后（上传最后）
            } catch {
                self.indexError = "索引失败: \(error)"
            }
        }
    }

    func cancelIndexing() {
        indexTask?.cancel()
    }

    // MARK: - 扫描工具书目录（设置页显式触发，无 Timer 无常驻）
    /// 对书域根（既有 library 授权根）全量 index 扫描一遍：skip-unchanged
    @Published var isScanningToolbooks: Bool = false
    @Published var toolbookScanMessage: String = ""
    private var toolbookScanTask: Task<Void, Never>?

    func scanToolbookDirectory() {
        guard !isScanningToolbooks else { return }
        if policyConfigError != nil {
            toolbookScanMessage = "排除配置无效（fail-closed）：请修复 exclusions.json 后重试；基线排除仍生效"
            return
        }
        isScanningToolbooks = true
        toolbookScanMessage = L10n.scanToolbookRunning
        toolbookScanTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isScanningToolbooks = false }
            guard let root = self.access.startAccess() else {
                self.toolbookScanMessage = L10n.scanToolbookNoRoot
                return
            }
            defer { self.access.stopAccess() }
            do {
                let s = try self.storeOrOpen()
                let engine = IndexingEngine(store: s, policy: self.policy,
                                            progress: { [weak self] progress in
                    Task { @MainActor in
                        guard let self else { return }
                        self.toolbookScanMessage = "\(L10n.scanToolbookRunning) \(progress.filesDone)/\(max(progress.filesTotal, progress.filesDone))"
                    }
                })
                let summary = try await engine.run(rootURL: root)
                // 收尾维护照抄 startIndexing 顺序（队列→倒排→计数→拼音→词级→TOC）。
                let queueEngine = IndexingEngine(store: s, policy: policy)
                _ = try? await queueEngine.runQueued(timeBudget: 2.0)
                _ = try? s.ensureBigramIndexFresh()
                _ = try? s.refreshBookNativeCounts()
                _ = try? s.backfillPinyinIfNeeded()
                _ = try? s.ensureWftsReady()
                _ = try? s.rebuildAutoTOCAll()
                self.similarEngine?.invalidate()
                refreshCoverageFromStore()
                self.toolbookScanMessage = L10n.scanToolbookDone(
                    added: summary.indexedNew, updated: summary.updated,
                    skipped: summary.skippedUnchanged)
            } catch {
                self.toolbookScanMessage = "\(L10n.scanToolbookFailed): \(error)"
            }
        }
    }

    /// Coverage over ALL roots, with explicit categories. rootName is only set
    /// when a single root is indexed — an aggregate is never mislabelled.
    func refreshCoverageFromStore() {
        coverageGeneration += 1
        let generation = coverageGeneration
        guard let s = try? storeOrOpen() else { return }
        let stats = try? s.coverageStats()
        let perBook = try? s.perBookPageStats()
        let recordJSON = try? s.metaValue("last_run_summary")
        let record = recordJSON.flatMap { try? JSONDecoder().decode(IndexingEngine.RunRecord.self, from: Data($0.utf8)) }
        let books = (try? s.allBooks()) ?? []
        applyCoverage(stats: stats, perBook: perBook, books: books, record: record, generation: generation)
    }

    // MARK: Search

    /// 检索代次（detached 化后旧查询可能晚于新查询完成——
    /// 乱序回写守卫，模式照 coverageGeneration）＋在途检索句柄（新搜取消旧搜）。
    var searchGeneration = 0
    private var searchTask: Task<Void, Never>?

    func search() {
        let q = query
        searchedOnce = true
        isSearching = true
        searchTask?.cancel()   // 新搜取消旧搜（旧任务回写另由代次守卫挡）
        searchGeneration += 1
        let generation = searchGeneration
        searchTask = Task { @MainActor in
            guard let s = try? storeOrOpen() else {
                self.isSearching = false
                self.searchError = "库打开失败"
                return
            }
            let policy = self.policy
            // 工具书开关从设置页键透传（默认 false=不含）。
            let includeToolBooks = UserDefaults.standard.bool(forKey: "includeToolBooks")
            let filter = SearchFilter(
                authorContains: self.filterAuthor.isEmpty ? nil : self.filterAuthor,
                versionContains: self.filterVersion.isEmpty ? nil : self.filterVersion,
                languageEquals: self.filterLanguage.isEmpty ? nil : self.filterLanguage,
                sourceDomain: self.filterDomain.isEmpty ? nil : self.filterDomain,
                includeToolBooks: includeToolBooks
            )
            let openBookID = self.selectedHit?.bookID
            await Task.detached(priority: .userInitiated) { [generation] in
                do {
                    // 主检索入口经引擎注册表解析（偏好缺失/未知值
                    // fail-closed 回 fts5-default＝现引擎，检索语义零变化）。
                    let service = SearchEngineRegistry.resolve(UserDefaults.standard.string(forKey: SearchEngineRegistry.preferenceKey))
                        .init(store: s, policy: policy) // query-time policy re-check
                    // 两段式：阶段一只做书目级聚合（不物化任何页面行，快）；
                    // 阶段二（点开某本）按需加载该书全部命中。
                    let summaries = try service.matchingBooks(q, filter: filter)
                    let zeroHit = summaries.isEmpty ? try service.explainZeroHit(q) : nil
                    // 诊断面只在默认引擎上存在。
                    let diagnostics = (service as? SearchService)?.lastQueryDiagnostics
                    await MainActor.run {
                        self.applySearchResults(generation: generation,
                                                summaries: summaries, zeroHit: zeroHit,
                                                diagnostics: diagnostics, query: q,
                                                openBookID: openBookID)
                    }
                } catch {
                    await MainActor.run { [generation] in
                        guard generation == self.searchGeneration else { return }   // 乱序守卫
                        self.isSearching = false
                        self.hits = []
                        self.bookResults = []
                        self.totalMatchingPages = 0
                        self.truncatedNotice = nil
                        self.zeroHitExplanation = nil
                        self.searchError = String(describing: error)
                    }
                }
            }.value
        }
    }

    /// 检索结果回写与联动刷新（主线程；search 的 detached 完成侧）。
    /// 乱序守卫：两次连发时旧查询可能后完成——代次不匹配
    private func applySearchResults(generation: Int, summaries: [SearchService.BookHitSummary],
                                    zeroHit: ZeroHitExplanation?,
                                    diagnostics: QueryDiagnostics?, query: String,
                                    openBookID: String?) {
        guard generation == searchGeneration else { return }
        defer { isSearching = false }
        let groups = aggregateVersionGroups(summaries)
        self.bookResults = groups
        // Each work counts once: the group's total is its PRIMARY's
        // matching-page count (other versions never double-counted).
        self.totalMatchingPages = totalMatchingPagesAcrossGroups(groups)
        self.hits = []
        self.zeroHitExplanation = zeroHit
        self.truncatedNotice = nil
        self.searchError = nil
        self.sourceFilter = ""
        // New query invalidates per-book complete lists.
        bookFullHits = [:]
        bookFullTotalPages = [:]
        bookFullTruncated = []
        expandedGroupIDs = []
        // 最近一次查询分相诊断（调试面板读）。
        self.lastSearchDiagnostics = diagnostics
        // 当前查询的「上次选择」锚点（锚点行数据源；无记录/学习
        // 关闭即 nil＝不显示。展示层再校验 bookID 在当前结果内且页码有效）。
        self.lastSelectionAnchor = searchMemory.anchor(for: query)
        // 预览与书内分区数据随新查询失效。
        self.previewRows = []
        self.previewTruncatedNotice = nil
        // 书内分区：当前有打开书时并行跑该书 scope（独立
        // Task；行数与全库档该书记数走既有「双标」诚实呈现）。
        if let openBookID {
            self.loadBookScopeHits(query, bookID: openBookID)
        } else {
            self.bookScopeHits = []
            self.bookScopeBookID = nil
            self.bookScopeTotal = 0
        }
        // Zero-hit: the detail pane must not keep showing the previous
        // search's PDF next to a "no results" list (misleading).
        if summaries.isEmpty { self.closePDF() }
        history.record(query: query, hitCount: self.totalMatchingPages)
        self.refreshHistory()
    }

    // MARK: Policy re-check on open (not only at index time)

    func policyAllows(_ hit: SearchHit) -> String? {
        guard policy.evaluateBookID(hit.bookID) == .allowed else {
            return "该书目 ID 命中当前排除策略（查询/打开时复查）"
        }
        let allowed = policy.allowsBook(realPath: hit.filePath,
                                        rootPath: URL(fileURLWithPath: hit.filePath).deletingLastPathComponent().path,
                                        bookID: hit.bookID)
        if !allowed { return "该文件命中当前排除策略（查询/打开时复查）" }
        return nil
    }

    /// Pre-open/pre-send re-check: policy + BOTH fingerprints (original, and
    /// for OCR hits the OCR file). Any drift refuses open/send, fail closed.
    /// 结构债 (a)：全量 sha256 经
    /// sha256HexOffMain 出主线程（原同步实现 GB 级书首触哈希卡 UI 数秒）；
    /// 守卫语义逐字节不变（同一三重判定＋fail-closed），仅哈希执行线程变化。
    func openGuard(for hit: SearchHit) async -> String? {
        if let reason = policyAllows(hit) { return reason }
        let isOCR = hit.source == "ocr"
        let origMatches = await Fingerprint.sha256HexOffMain(ofFileAt: URL(fileURLWithPath: hit.filePath)) == hit.fingerprint
        var ocrMatches: Bool? = nil
        if isOCR {
            if let p = hit.ocrFilePath, let fp = await Fingerprint.sha256HexOffMain(ofFileAt: URL(fileURLWithPath: p)) {
                ocrMatches = (fp == hit.ocrFingerprint)
            } else {
                ocrMatches = false
            }
        }
        return HitRouter.fingerprintGuard(isOCR: isOCR, originalMatches: origMatches, ocrMatches: ocrMatches)
    }

    func select(hit: SearchHit) async {
        // 是否为「同一命中重选」（关闭后再点同一命中、或重复点同
        // 一条结果）——原文栏据此恢复上次阅读页码；选中不同命中仍为命中页
        // 跳转（检索语义零改动）。
        reselectedSameHit = (Self.key(for: hit) == lastSelectedHitKey)
        lastSelectedHitKey = Self.key(for: hit)
        if let reason = await openGuard(for: hit) {
            openBlockedReason = reason
            access.stopAllAccess()
            selectedHit = nil
            return
        }
        // Hold security-scoped access while the selection is displayed
        // (covers reading the ORIGINAL and, for OCR hits, the OCR file).
        var roles: [LibraryAccess.Role] = [.library]
        if hit.source == "ocr" { roles.append(contentsOf: [.originalRoot, .ocrRoot]) }
        access.startAccess(roles)
        openBlockedReason = nil
        selectedHit = hit
        // 一次性学习——记录本查询的选中（同查询下次检索置顶显示
        // 锚点行；store 内部按开关门与空查询门自守，检索排序零参与）。
        searchMemory.recordSelection(query: query, bookID: hit.bookID, page: hit.physicalPage)
        sessionLedger.opened(hit.bookID, tabType: "pdf")
        sessionLedger.activated(hit.bookID, tabType: "pdf")
        // Load current metadata into the edit sheet (unknown stays empty).
        metaEditTitle = hit.title ?? ""
        metaEditAuthor = hit.author ?? ""
        metaEditVersion = hit.version ?? ""
        metaEditLanguage = hit.language ?? ""
        metaEditMessage = nil
    }

    /// 锚点行跳转——合成 hit 走既有 select/openGuard 管线
    ///（openQuoteInBook 同款；书不在库/非 ok/页越界如实处理，守卫自动生效）。
    func select(anchor: SearchSelectionAnchor) async {
        guard let s = try? storeOrOpen(), let b = try? s.book(byID: anchor.bookID), b.status == "ok" else { return }
        let page = min(max(1, anchor.page), max(1, b.pageCount))
        await select(hit: SearchHit(bookID: b.id, filePath: b.realPath, fileName: b.fileName,
                                    fingerprint: b.fingerprint, physicalPage: page, pageLabel: nil,
                                    printedPage: nil, pageCount: b.pageCount, title: b.title,
                                    author: b.author, version: b.version, language: b.language,
                                    matches: [], snippet: ""))
    }

    func closePDF() {
        if let closing = selectedHit {
            sessionLedger.closed(closing.bookID, tabType: "pdf")
        }
        selectedHit = nil
        openBlockedReason = nil
        access.stopAllAccess()
        //书关闭即隐藏书内分区（不显示空壳）＋ 上下文失效。
        bookScopeHits = []
        bookScopeBookID = nil
        bookScopeTotal = 0
        hitContexts = [:]
    }

    // MARK: Metadata editing / sidecar import (index-only; originals untouched)

    func saveMetadataEdits() {
        guard let hit = selectedHit else { return }
        do {
            let s = try storeOrOpen()
            let ok = try s.updateMetadata(
                bookID: hit.bookID,
                title: metaEditTitle.isEmpty ? nil : metaEditTitle,
                author: metaEditAuthor.isEmpty ? nil : metaEditAuthor,
                version: metaEditVersion.isEmpty ? nil : metaEditVersion,
                language: metaEditLanguage.isEmpty ? nil : metaEditLanguage,
                source: "manual"
            )
            metaEditMessage = ok ? L10n.metaWriteSuccess : L10n.metaWriteMissingBook
            search() // refresh visible metadata
        } catch {
            metaEditMessage = L10n.metaWriteFailurePrefix + "\(error)"
        }
    }

    func importSidecar() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json, .commaSeparatedText, .data]
        panel.prompt = "选择书目 sidecar（JSON/CSV）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let s = try storeOrOpen()
            let data = try Data(contentsOf: url)
            let records: [MetadataRecord]
            switch url.pathExtension.lowercased() {
            case "json": records = try MetadataImporter.parseJSON(data)
            case "csv": records = try MetadataImporter.parseCSV(data)
            default:
                records = try (try? MetadataImporter.parseJSON(data)) ?? MetadataImporter.parseCSV(data)
            }
            let report = MetadataImporter.apply(records, store: s)
            metaEditMessage = "导入完成：应用 \(report.applied)，跳过 \(report.skipped.count)（未匹配的书目不猜测）"
            search()
        } catch {
            metaEditMessage = "导入失败: \(error)"
        }
    }

    // MARK: 书目详情（引用升级切片；只读索引 + 仅索引内编辑）

    /// All indexed books backing the library page list (sorted, refreshed with
    /// coverage). `libraryBookFilter` narrows client-side; nothing auto-scans.
    @Published var libraryBooks: [IndexStore.BookRow] = []
    @Published var libraryBookFilter: String = ""
    var filteredLibraryBooks: [IndexStore.BookRow] {
        guard !libraryBookFilter.isEmpty else { return libraryBooks }
        let f = libraryBookFilter.lowercased()
        return libraryBooks.filter {
            $0.fileName.lowercased().contains(f)
                || ($0.title?.lowercased().contains(f) ?? false)
                || ($0.author?.lowercased().contains(f) ?? false)
        }
    }

    @Published var bookDetail: IndexStore.BookRow?
    @Published var bookDetailStat: BookPageStat?
    @Published var bookDetailMetaEdit: (title: String, author: String, version: String, language: String) = ("", "", "", "")
    @Published var bookDetailMessage: String?

    func sortKey(_ b: IndexStore.BookRow) -> String {
        (b.title ?? b.fileName).lowercased()
    }

    func openBookDetail(bookID: String) {
        guard let s = try? storeOrOpen() else { return }
        bookDetail = try? s.book(byID: bookID)
        bookDetailStat = (try? s.perBookPageStats())?.first { $0.bookID == bookID }
        if let b = bookDetail {
            bookDetailMetaEdit = (b.title ?? "", b.author ?? "", b.version ?? "", b.language ?? "")
        }
        bookDetailMessage = nil
    }

    func closeBookDetail() {
        bookDetail = nil
        bookDetailStat = nil
        bookDetailMessage = nil
    }

    func saveBookDetailMetadata() {
        guard let book = bookDetail else { return }
        do {
            let s = try storeOrOpen()
            let e = bookDetailMetaEdit
            let ok = try s.updateMetadata(
                bookID: book.id,
                title: e.title.isEmpty ? nil : e.title,
                author: e.author.isEmpty ? nil : e.author,
                version: e.version.isEmpty ? nil : e.version,
                language: e.language.isEmpty ? nil : e.language,
                source: "manual"
            )
            bookDetailMessage = ok ? L10n.metaWriteSuccess : L10n.metaWriteMissingBook
            reloadBookDetailFields()
            if !query.trimmingCharacters(in: .whitespaces).isEmpty { search() }
        } catch {
            bookDetailMessage = L10n.metaWriteFailurePrefix + "\(error)"
        }
    }

    private func reloadBookDetailFields() {
        guard let book = bookDetail, let s = try? storeOrOpen(),
              let fresh = try? s.book(byID: book.id) else { return }
        bookDetail = fresh
        bookDetailMetaEdit = (fresh.title ?? "", fresh.author ?? "", fresh.version ?? "", fresh.language ?? "")
    }

    // MARK: 批量引用（书目引注 / BibTeX — 全部来自索引元数据，未知不猜）

    typealias CitationSource = (fileName: String, title: String?, author: String?, language: String?)

    func copyBookCitations(_ books: [CitationSource]) {
        let text = CitationFormatter.bibliography(
            books.map { (fileName: $0.fileName, title: $0.title) },
            style: citationStyle)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyBooksBibtex(_ books: [CitationSource]) {
        // 批量导出走 bibtexBatch：同批键冲突自动 -2/-3 消解，导出的 .bib 键唯一
        let text = CitationFormatter.bibtexBatch(books.map {
            ($0.fileName, $0.title, $0.author, $0.language)
        })
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyString(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: AI (HTTPS-only, confirmation-gated, policy re-checked)

    func configureAI() {
        guard let url = URL(string: aiServiceURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            aiMessage = "服务地址无效"
            return
        }
        let config = AIConfiguration(serviceURL: url,
                                     model: aiModel.trimmingCharacters(in: .whitespacesAndNewlines),
                                     apiKey: aiAPIKey.isEmpty ? nil : aiAPIKey)
        do {
            try ai.configure(config) // core enforces HTTPS + explicit model
            aiConfigured = true
            aiMessage = "已配置：\(url.absoluteString) / \(config.model)。发送前仍需逐次确认。"
        } catch {
            aiConfigured = false
            aiMessage = "配置被拒绝: \(error)"
        }
    }

    func makeAIPreview(for hit: SearchHit) async {
        if let reason = await openGuard(for: hit) { // policy + both fingerprints before ANY preview/send
            aiMessage = reason
            return
        }
        do { try routeAIForPurpose(aiActivePurpose) } catch {
            aiMessage = "AI 路由解析失败：\(error)"
            return
        }
        do {
            aiPreview = try ai.makePreview(question: aiQuestion.isEmpty ? "解释选中片段" : aiQuestion,
                                           selection: HitRouter.previewSelection(for: hit))
            aiPreviewKind = .plain
            aiAnswer = nil
            aiDecisions = []
        } catch {
            aiMessage = String(describing: error)
            aiPreview = nil
        }
    }

    func cancelAIPreview() {
        aiPreview = nil
    }

    // MARK: — AI 发送可取消
    //
    // 所有 AI 发送经 startAISend 统一入口：保存 Task 句柄与取消令牌、
    // 管理 aiSending。「停止」（cancelAISend）经令牌回调取消底层
    // URLSessionTask 真中断；取消后状态干净——aiSending 复位、不追加
    // 半截答案，preview 保留（重新点「确认发送」即可重试）。

    /// 「停止」按钮动作：取消进行中的 AI 请求并复位到可重新发送。
    func cancelAISend() {
        aiCancellationToken?.cancel()
        aiSendTask?.cancel()
        aiSendTask = nil
        aiCancellationToken = nil
        aiSending = false
        aiMessage = L10n.aiSendCancelled
    }

    /// 发送统一入口。`allowed` 由调用方按既有 send-time 复检规则备好；
    /// onSuccess 在主线程回调（Task 继承 AppState 的 @MainActor）。
    ///
    /// 按当前路由选档取 transport（cloudTransport/onDeviceTransport）；
    /// 断网降级（方向性写死）：仅「云端→端上」自动重发一次且必须
    /// 披露（OnDeviceDegrade.shouldRetryOnOnDevice 判定）；「端上→云端」自动
    /// 重试路径不存在——端上失败显式报错，上云必须用户显式改绑云端档案并
    /// 重新过预览确认。
    /// 段级降级处理归因：证据段集合非空（混合检索路径）→
    /// resolveWithParagraphs（para 必须落在请求证据段集合内）；nil/空＝
    /// 页级现状语义逐字节不变。
    private static func decideReferences(_ references: [AIReference], allowed: [AllowedSource],
                                         evidenceParagraphs: Set<SemanticAnchor>?) -> [ReferenceDecision] {
        guard let evidenceParagraphs, !evidenceParagraphs.isEmpty else {
            return ReferenceResolver.resolve(references, allowedSources: allowed)
        }
        return ReferenceResolver.resolveWithParagraphs(references, allowedSources: allowed,
                                                       evidenceParagraphs: evidenceParagraphs)
    }

    private func startAISend(preview: AIPreview, allowed: [AllowedSource],
                             evidenceParagraphs: Set<SemanticAnchor>? = nil,
                             onSuccess: @escaping (AIParsedResponse, [ReferenceDecision]) -> Void) {
        guard !aiSending else {
            aiMessage = L10n.aiAlreadySending
            return
        }
        guard let confirmation = AIConfirmation(explicit: true, previewID: preview.id) else {
            aiMessage = "确认无效"
            return
        }
        let routeIsOnDevice = aiRouteIsOnDevice
        let transport: AITransport = (routeIsOnDevice ? (onDeviceTransport ?? cloudTransport) : cloudTransport)
        let token = AICancellationToken()
        aiCancellationToken = token
        aiSending = true
        aiSendTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.aiSending = false
                if self.aiCancellationToken === token { self.aiCancellationToken = nil }
            }
            do {
                let response = try await self.ai.send(preview: preview, confirmation: confirmation,
                                                      transport: transport, cancellation: token)
                let decisions = Self.decideReferences(response.references, allowed: allowed,
                                                      evidenceParagraphs: evidenceParagraphs)
                onSuccess(response, decisions)
            } catch AIAssistantError.cancelled {
                self.aiMessage = L10n.aiSendCancelled
            } catch is CancellationError {
                self.aiMessage = L10n.aiSendCancelled
            } catch {
                // 云端原错误保留绑定，端上重发失败时并置呈现。
                let cloudError = error
                // 断网降级：云端路由＋连接类错误＋探针可用 → 端上重发一次＋披露。
                let probeStatus = self.onDeviceProbe?.status()
                if let onDeviceTransport = self.onDeviceTransport,
                   OnDeviceDegrade.shouldRetryOnOnDevice(currentRouteIsOnDevice: routeIsOnDevice,
                                                         error: error, probeStatus: probeStatus) {
                    do {
                        let retry = try await self.ai.send(preview: preview, confirmation: confirmation,
                                                           transport: onDeviceTransport, cancellation: token)
                        let decisions = Self.decideReferences(retry.references, allowed: allowed,
                                                              evidenceParagraphs: evidenceParagraphs)
                        // 低2：降级生效后同步选档标记（下次
                        // 发送仍会经 routeAIForPurpose 重置，此处消除残留）。
                        self.aiRouteIsOnDevice = true
                        self.aiMessage = L10n.aiDegradeNotice(String(describing: error))
                        onSuccess(retry, decisions)
                    } catch {
                        // 结构债 (e)：重发途中用户取消＝
                        // 已停止语义，按取消文案呈现，不与云端错误并置成「失败」。
                        if error is CancellationError || (error as? AIAssistantError) == .cancelled {
                            self.aiMessage = L10n.aiSendCancelled
                        } else {
                            // 重发失败时两错并置——
                            // 原云端错误（cloudError）不得被重发错误遮蔽丢弃。
                            self.aiMessage = "AI 请求失败: \(error)；云端原错误：\(cloudError)"
                        }
                    }
                } else {
                    self.aiMessage = "AI 请求失败: \(error)"
                }
            }
        }
    }

    func sendAIConfirmed() async {
        guard let preview = aiPreview else { return }
        do { try routeAIForPurpose(aiActivePurpose) } catch {
            aiMessage = "AI 路由解析失败：\(error)"
            return
        }
        if !preview.selections.isEmpty {
            // 按预览分型分派（RCS/速读/综述各自流程；综合照旧）。
            switch aiPreviewKind {
            case .rcs:
                await runRCSConfirmed()
                return
            case .speedRead:
                await sendSpeedReadConfirmed()
                return
            case .review:
                await sendReviewConfirmed()
                return
            case .plain, .synthesis:
                break
            }
            await sendSynthesisConfirmed()
            return
        }
        await sendPreview(preview) { [weak self] response, decisions in
            self?.aiAnswer = response.answerText
            self?.aiDecisions = decisions
            self?.aiPreview = nil
            self?.appendAIChatTurns(preview: preview, answer: response.answerText, decisions: decisions)
        }
    }

    // MARK: Multi-snippet compare (each snippet: its own preview + explicit confirmation)

    func buildComparePreviews() async {
        compareQueue = []
        compareResults = []
        for hit in hits where compareSelectionIDs.contains(Self.key(for: hit)) {
            if await openGuard(for: hit) != nil { continue } // policy + both fingerprints per snippet
            do {
                compareQueue.append(try ai.makePreview(question: aiQuestion.isEmpty ? "解释选中片段" : aiQuestion,
                                                       selection: HitRouter.previewSelection(for: hit)))
            } catch {
                aiMessage = String(describing: error)
                return
            }
        }
    }

    func sendComparePreview(_ preview: AIPreview) async {
        await sendPreview(preview) { [weak self] response, decisions in
            self?.compareResults.append(CompareResult(preview: preview, answer: response.answerText, decisions: decisions))
            self?.compareQueue.removeAll { $0.id == preview.id }
        }
    }

    // MARK: Multi-evidence synthesis (PaperQA2-style, per approved upgrade)
    //
    // One confirmed request over ALL selected passages; the answer must cite
    // (bookID, page) pairs from those passages only. Every passage passes the
    // open guard at preview time AND at send time; references resolve against
    // exactly the sent sources.

    func buildSynthesisPreview() async {
        guard aiConfigured else { return }
        let selected = hits.filter { compareSelectionIDs.contains(Self.key(for: $0)) }
        guard !selected.isEmpty else {
            aiMessage = "综合需要至少一条证据：请在结果上右键「加入综合证据」"
            return
        }
        var selections: [AIPreview.Selection] = []
        for hit in selected {
            if await openGuard(for: hit) != nil { continue } // policy + both fingerprints per passage
            selections.append(HitRouter.previewSelection(for: hit))
        }
        do {
            let question = aiQuestion.isEmpty ? "综合以上文献片段回答问题，并逐条标注引用来源" : aiQuestion
            aiPreview = try ai.makeSynthesisPreview(question: question, selections: selections)
            aiPreviewKind = .synthesis
            aiAnswer = nil
            aiDecisions = []
        } catch {
            aiMessage = String(describing: error)
        }
    }

    func sendSynthesisConfirmed() async {
        guard let preview = aiPreview, !preview.selections.isEmpty else { return }
        do { try routeAIForPurpose(aiActivePurpose) } catch {
            aiMessage = "AI 路由解析失败：\(error)"
            return
        }
        // Send-time re-check: EVERY passage must still pass policy + fingerprints.
        for sel in preview.selections {
            if let hit = hits.first(where: { $0.bookID == sel.bookID && $0.physicalPage == sel.physicalPage }),
               let reason = await openGuard(for: hit) {
                aiMessage = reason
                return
            }
        }
        let allowed: [AllowedSource] = preview.selections.map { sel in
            AllowedSource(bookID: sel.bookID,
                          pageCount: hits.first(where: { $0.bookID == sel.bookID })?.pageCount ?? 1,
                          fingerprint: sel.fingerprint)
        }
        //selections 携带段号（仅混合检索路径）→ 生成后段级
        // 降级处理归因；既有页级路径集合为空 → 页级判定语义逐字节不变。
        let evidenceParagraphs = Set(preview.selections.compactMap { sel in
            sel.para.map { SemanticAnchor(bookID: sel.bookID, page: sel.physicalPage, paraIndex: $0) }
        })
        // Task 句柄与取消令牌由 startAISend 统一保存。
        startAISend(preview: preview, allowed: allowed, evidenceParagraphs: evidenceParagraphs) { [weak self] response, decisions in
            self?.aiAnswer = response.answerText
            self?.aiDecisions = decisions
            self?.aiPreview = nil
            self?.appendAIChatTurns(preview: preview, answer: response.answerText, decisions: decisions)
        }
    }

    // MARK: — RCS 逐块评分摘要（先打分压缩、后入最终上下文）
    //
    // 入口复用综合证据的选择机制（compareSelectionIDs＋openGuard 逐块）；
    // 计划预览（makeRCSPlanPreview）披露「将发 N+1 次请求」，确认经既有
    // previewCard → sendAIConfirmed → runRCSConfirmed，确认门绑定 previewID
    // （RCSPipeline 入口再验一次，零确认/绑错＝零 transport 调用）。

    /// 页码标签换算（声明制）：printed 页码优先，未知显式 nil（绝不猜）。
    /// 速读卡锚点显示亦复用（AIPreviewPanel.speedReadAnchorText）。
    func rcsPageLabelText(bookID: String, physicalPage: Int) -> String? {
        guard let s = try? storeOrOpen() else { return nil }
        let printed = PageNumberService.forStore(s).printedPage(bookID: bookID, physical: physicalPage)
        guard let printed else { return nil }
        return "印刷页 \(printed)"
    }

    func buildRCSPreview() async {
        guard aiConfigured else { return }
        do { try routeAIForPurpose(aiActivePurpose) } catch {
            aiMessage = "AI 路由解析失败：\(error)"
            return
        }
        let selected = hits.filter { compareSelectionIDs.contains(Self.key(for: $0)) }
        guard !selected.isEmpty else {
            aiMessage = L10n.rcsNeedsSelection
            return
        }
        var selections: [AIPreview.Selection] = []
        for hit in selected {
            if await openGuard(for: hit) != nil { continue }
            selections.append(HitRouter.previewSelection(for: hit))
        }
        do {
            let question = aiQuestion.isEmpty ? "综合以上文献片段回答问题，并逐条标注引用来源" : aiQuestion
            let preview = try ai.makeRCSPlanPreview(question: question, selections: selections)
            // 页码标签主线程预计算（@Sendable 闭包内不触 MainActor 隔离面）；
            // 键 "bookID#page"，缺项＝未知，计划层显式「页码未知」。
            var labels: [String: String] = [:]
            for sel in preview.selections {
                if let label = rcsPageLabelText(bookID: sel.bookID, physicalPage: sel.physicalPage) {
                    labels["\(sel.bookID)#\(sel.physicalPage)"] = label
                }
            }
            // 计划块与预览同源同量；previewID 绑定整条流程（单确认绑整计划）。
            let snapshotLabels = labels
            let built = try RCSContextBuilder.makePlan(
                question: question, selections: preview.selections,
                pageLabel: { bookID, page in snapshotLabels["\(bookID)#\(page)"] })
            rcsPlan = RCSPlan(previewID: preview.id, question: built.question, blocks: built.blocks)
            aiPreview = preview
            aiPreviewKind = .rcs
            aiAnswer = nil
            aiDecisions = []
            rcsOutcome = nil
        } catch {
            aiMessage = String(describing: error)
        }
    }

    private func runRCSConfirmed() async {
        guard let preview = aiPreview, let plan = rcsPlan, plan.previewID == preview.id else { return }
        // Send-time re-check: EVERY passage must still pass policy + fingerprints.
        for sel in preview.selections {
            if let hit = hits.first(where: { $0.bookID == sel.bookID && $0.physicalPage == sel.physicalPage }),
               let reason = await openGuard(for: hit) {
                aiMessage = reason
                return
            }
        }
        guard let configuration = ai.configuration else {
            aiMessage = "AI 路由解析失败：无可用配置"
            return
        }
        guard let confirmation = AIConfirmation(explicit: true, previewID: preview.id) else {
            aiMessage = "确认无效"
            return
        }
        let allowed: [AllowedSource] = preview.selections.map { sel in
            AllowedSource(bookID: sel.bookID,
                          pageCount: hits.first(where: { $0.bookID == sel.bookID })?.pageCount ?? 1,
                          fingerprint: sel.fingerprint)
        }
        let transport: AITransport = (aiRouteIsOnDevice ? (onDeviceTransport ?? cloudTransport) : cloudTransport)
        let token = AICancellationToken()
        aiCancellationToken = token
        aiSending = true
        rcsLedger.reset()
        aiSendTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.aiSending = false
                if self.aiCancellationToken === token { self.aiCancellationToken = nil }
            }
            do {
                let outcome = try await RCSPipeline.run(plan: plan, configuration: configuration,
                                                        confirmation: confirmation, transport: transport,
                                                        cancellation: token, ledger: self.rcsLedger)
                self.rcsOutcome = outcome
                if let answer = outcome.answer {
                    let decisions = ReferenceResolver.resolve(answer.references, allowedSources: allowed)
                    self.aiAnswer = answer.answerText
                    self.aiDecisions = decisions
                    self.appendAIChatTurns(preview: preview, answer: answer.answerText, decisions: decisions)
                } else {
                    self.aiAnswer = nil
                    self.aiMessage = L10n.rcsAllFilteredNote
                }
                self.aiPreview = nil
            } catch AIAssistantError.cancelled {
                self.aiMessage = L10n.aiSendCancelled
            } catch is CancellationError {
                self.aiMessage = L10n.aiSendCancelled
            } catch {
                self.aiMessage = "AI 请求失败: \(error)"
            }
        }
    }

    // MARK: — 四段式速读（综合通道＋预设问题模板，零新门）
    //
    // 预览 question 即四问全文（用户看到的就是将发送的）；发送复用综合
    // 通道全链（openGuard 逐块＋send-time 复检＋startAISend 确认门）；结果
    // 解析成速读卡，解析失败整卡降级为普通 answer 显示（不崩不编造）。

    func buildSpeedReadPreview() async {
        guard aiConfigured else { return }
        do { try routeAIForPurpose(aiActivePurpose) } catch {
            aiMessage = "AI 路由解析失败：\(error)"
            return
        }
        let selected = hits.filter { compareSelectionIDs.contains(Self.key(for: $0)) }
        guard !selected.isEmpty else {
            aiMessage = L10n.speedReadNeedsSelection
            return
        }
        var selections: [AIPreview.Selection] = []
        for hit in selected {
            if await openGuard(for: hit) != nil { continue }
            selections.append(HitRouter.previewSelection(for: hit))
        }
        // 预算裁剪（纯函数，未确认零副作用）；丢弃计数如实显示。
        let budget = SpeedReadBudget.trim(selections: selections)
        speedReadDroppedChars = budget.droppedCharCount
        do {
            let question = SpeedReadQuestionBuilder.build(selections: budget.selections, question: aiQuestion)
            aiPreview = try ai.makeSynthesisPreview(question: question, selections: budget.selections)
            aiPreviewKind = .speedRead
            aiAnswer = nil
            aiDecisions = []
            speedReadCard = nil
        } catch {
            aiMessage = String(describing: error)
        }
    }

    private func sendSpeedReadConfirmed() async {
        guard let preview = aiPreview, !preview.selections.isEmpty else { return }
        for sel in preview.selections {
            if let hit = hits.first(where: { $0.bookID == sel.bookID && $0.physicalPage == sel.physicalPage }),
               let reason = await openGuard(for: hit) {
                aiMessage = reason
                return
            }
        }
        let allowed: [AllowedSource] = preview.selections.map { sel in
            AllowedSource(bookID: sel.bookID,
                          pageCount: hits.first(where: { $0.bookID == sel.bookID })?.pageCount ?? 1,
                          fingerprint: sel.fingerprint)
        }
        startAISend(preview: preview, allowed: allowed) { [weak self] response, decisions in
            guard let self else { return }
            self.aiAnswer = response.answerText
            self.aiDecisions = decisions
            // 解析失败=整卡降级为普通 answer（aiAnswer 已设，卡为 nil）。
            self.speedReadCard = SpeedReadCardParser.parse(answerText: response.answerText)
            self.aiPreview = nil
            self.appendAIChatTurns(preview: preview, answer: response.answerText, decisions: decisions)
        }
    }

    // MARK: — 综述自检反馈循环（单确认绑整计划）
    //
    // 草稿＝综合通道（综述指令：结构化长文＋每断言带 [n] 引用号＋只准引用
    // 所给 passages）；确认后同一 confirmation 绑定自检 runner（逐 leg 再验
    // previewID）。补块检索走 SearchService.searchDetailed 只读（零检索路径
    // 改动）；「采用」只写内存 transcript 与剪贴板，不自动写批注库。

    static let reviewInstruction = "请基于以下证据块写一篇结构化综述：背景、分论点与结论分段展开；每条断言句末带 [n] 引用号标注所依据的证据块编号；只准引用所给 passages；证据不含的内容不要写。"

    func buildReviewPreview() async {
        guard aiConfigured else { return }
        do { try routeAIForPurpose(aiActivePurpose) } catch {
            aiMessage = "AI 路由解析失败：\(error)"
            return
        }
        let selected = hits.filter { compareSelectionIDs.contains(Self.key(for: $0)) }
        guard !selected.isEmpty else {
            aiMessage = L10n.reviewNeedsSelection
            return
        }
        var selections: [AIPreview.Selection] = []
        for hit in selected {
            if await openGuard(for: hit) != nil { continue }
            selections.append(HitRouter.previewSelection(for: hit))
        }
        do {
            let question = aiQuestion.isEmpty ? Self.reviewInstruction : aiQuestion
            aiPreview = try ai.makeReviewPreview(question: question, selections: selections)
            aiPreviewKind = .review
            aiAnswer = nil
            aiDecisions = []
            reviewOutcome = nil
        } catch {
            aiMessage = String(describing: error)
        }
    }

    /// 本地检索闭包（自检补块用；只读公共 API，零检索路径改动）。
    private func retrieveForReview(_ query: String) -> [SearchHit] {
        guard let s = try? storeOrOpen() else { return [] }
        let service = SearchService(store: s, policy: policy)
        return (try? service.searchDetailed(query).hits) ?? []
    }

    /// 补块入证据集前的双指纹复检（=openGuard
    /// 查询/打开时复查政策＋原文件 sha256＋OCR 指纹；对原文件内容漂移、
    /// 排除策略命中、OCR 配对缺失一律 fail-closed 拒绝）。
    @MainActor
    func verifySupplementHit(_ hit: SearchHit) async -> Bool {
        await openGuard(for: hit) == nil
    }

    private func sendReviewConfirmed() async {
        guard let preview = aiPreview, !preview.selections.isEmpty else { return }
        for sel in preview.selections {
            if let hit = hits.first(where: { $0.bookID == sel.bookID && $0.physicalPage == sel.physicalPage }),
               let reason = await openGuard(for: hit) {
                aiMessage = reason
                return
            }
        }
        guard let configuration = ai.configuration else {
            aiMessage = "AI 路由解析失败：无可用配置"
            return
        }
        guard let confirmation = AIConfirmation(explicit: true, previewID: preview.id) else {
            aiMessage = "确认无效"
            return
        }
        let allowed: [AllowedSource] = preview.selections.map { sel in
            AllowedSource(bookID: sel.bookID,
                          pageCount: hits.first(where: { $0.bookID == sel.bookID })?.pageCount ?? 1,
                          fingerprint: sel.fingerprint)
        }
        let transport: AITransport = (aiRouteIsOnDevice ? (onDeviceTransport ?? cloudTransport) : cloudTransport)
        let evidence = preview.selections.map { AIRequestPayload.SelectionPayload($0) }
        let token = AICancellationToken()
        aiCancellationToken = token
        aiSending = true
        reviewLedger.reset()
        aiSendTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.aiSending = false
                if self.aiCancellationToken === token { self.aiCancellationToken = nil }
            }
            do {
                // leg 1：草稿（综合通道全链；确认绑定同一 previewID）。
                // 低3：草稿 leg 同样入账本（账本基准完整；
                // 字节按同形综合载荷计）。
                if !evidence.isEmpty {
                    // 载荷构造收在 Core（AIRequestPayload memberwise init
                    // internal），App 层只取字节基准。
                    self.reviewLedger.record(name: "草稿",
                                             requestBytes: AIRequestMetrics.synthesisPayloadBytes(
                                                model: configuration.model,
                                                question: preview.question,
                                                evidence: evidence,
                                                citationNote: AIAssistantService.synthesisCitationNote),
                                             ok: true)
                }
                let draft = try await self.ai.send(preview: preview, confirmation: confirmation,
                                                   transport: transport, cancellation: token)
                // legs 2+：自检循环（逐断言→补块/删句→改写→防坍缩门）。
                let outcome = try await ReviewSelfCheckRunner.run(
                    draft: draft.answerText, planPreviewID: preview.id,
                    configuration: configuration, confirmation: confirmation,
                    transport: transport, cancellation: token, ledger: self.reviewLedger,
                    evidence: evidence,
                    retrieve: { [weak self] query in
                        // SearchService 挂主线程隔离面：跨 actor await 取数。
                        guard let self else { return [] }
                        return await self.retrieveForReview(query)
                    },
                    // 生产 verify 显式接线——
                    // openGuard 真·双指纹复检（政策＋原文件 sha256＋OCR 指纹；
                    // 注意 SearchService.verifyCitation 只比索引存量指纹，
                    // 对补块恒过＝空转，不作生产实现）。openGuard 挂
                    // @MainActor，故闭包为 async 跨 actor 调用。
                    verify: { [weak self] hit in
                        guard let self else { return false }
                        return await self.verifySupplementHit(hit)
                    })
                self.reviewOutcome = outcome
                self.aiAnswer = outcome.finalDraft
                self.aiDecisions = ReferenceResolver.resolve(draft.references, allowedSources: allowed)
                self.aiPreview = nil
                self.appendAIChatTurns(preview: preview, answer: outcome.finalDraft,
                                       decisions: self.aiDecisions)
            } catch AIAssistantError.cancelled {
                self.aiMessage = L10n.aiSendCancelled
            } catch is CancellationError {
                self.aiMessage = L10n.aiSendCancelled
            } catch {
                self.aiMessage = "AI 请求失败: \(error)"
            }
        }
    }

    //「采用」：只写内存 transcript 与剪贴板，不自动写批注库；
    /// 存为批注留后续。
    func adoptReviewOutcome() {
        guard let outcome = reviewOutcome else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(outcome.finalDraft, forType: .string)
        aiMessage = L10n.reviewAdoptedNote
    }

    func discardReviewOutcome() {
        reviewOutcome = nil
        aiMessage = L10n.reviewDiscardedNote
    }

    /// transcript helper: appends the user turn (the confirmed question)
    /// and the assistant turn (the answer + derived citations). Called only on
    /// the success path after aiAnswer/aiDecisions are published; a total
    /// failure (throw before any answer text) appends nothing.
    private func appendAIChatTurns(preview: AIPreview, answer: String, decisions: [ReferenceDecision]) {
        let nextID = (aiTranscript.last?.id ?? 0) + 1
        aiTranscript.append(AIChatTurn(id: nextID, role: .user, text: preview.question, citations: []))
        aiTranscript.append(AIChatTurn(id: nextID + 1, role: .assistant, text: answer,
                                       citations: aiCitations(for: preview, decisions: decisions)))
    }

    /// citation derivation (transcript level only — the core service is
    /// untouched). Accepted decisions contribute (bookID, page) → fileName via
    /// the bookNames table (`@Published var bookNames`, filled from
    /// IndexStore.BookRow.id → fileName in applyCoverage). A selection whose
    /// book has NO accepted decision still cites what was actually sent: its
    /// own provenance (book fileName + physical page). Rejected decisions
    /// never produce a citation.
    /// 回答展示前对每条引用执行校验：bookID 仍在库且状态 ok + 页码 ≤ 页数 + 指纹未漂移。
    private func aiCitations(for preview: AIPreview, decisions: [ReferenceDecision]) -> [AICitation] {
        var out: [AICitation] = []
        var seen = Set<String>()
        let passages = preview.selections.isEmpty ? [preview.selection] : preview.selections
        let fingerprintByBook = Dictionary(passages.map { ($0.bookID, $0.fingerprint) }, uniquingKeysWith: { a, _ in a })

        for decision in decisions {
            if case .accepted(let bookID, let page) = decision {
                let fileName = bookNames[bookID] ?? bookID
                if seen.insert("\(fileName)#\(page)").inserted {
                    let fp = fingerprintByBook[bookID] ?? ""
                    let valid = isCitationValid(bookID: bookID, page: page, expectedFingerprint: fp)
                    out.append(AICitation(fileName: fileName, page: page, isValid: valid, bookID: bookID, expectedFingerprint: fp))
                }
            }
        }
        for sel in passages where !decisions.contains(where: { decision in
            if case .accepted(let bookID, let page) = decision {
                return bookID == sel.bookID && page == sel.physicalPage
            }
            return false
        }) {
            let fileName = bookNames[sel.bookID] ?? sel.bookID
            if seen.insert("\(fileName)#\(sel.physicalPage)").inserted {
                let valid = isCitationValid(bookID: sel.bookID, page: sel.physicalPage, expectedFingerprint: sel.fingerprint)
                out.append(AICitation(fileName: fileName, page: sel.physicalPage, isValid: valid, bookID: sel.bookID, expectedFingerprint: sel.fingerprint))
            }
        }
        return out
    }

    /// 校验出处页在当前索引中仍有效：bookID 仍在库且状态 ok + 页码 ≤ 页数 + 指纹未漂移
    func isCitationValid(bookID: String, page: Int, expectedFingerprint: String) -> Bool {
        guard let s = try? storeOrOpen() else { return false }
        let searchService = SearchService(store: s, policy: policy)
        return (try? searchService.verifyCitation(bookID: bookID, page: page, expectedFingerprint: expectedFingerprint)) ?? false
    }

    func isCitationValid(_ citation: AICitation) -> Bool {
        guard let bookID = citation.bookID, let fp = citation.expectedFingerprint else {
            return citation.isValid
        }
        return isCitationValid(bookID: bookID, page: citation.page, expectedFingerprint: fp)
    }

    public func clearAIChat() {
        aiTranscript.removeAll()
    }

    private func sendPreview(_ preview: AIPreview, completion: @escaping (AIParsedResponse, [ReferenceDecision]) -> Void) async {
        // Re-check policy + BOTH fingerprints at SEND time; drift refuses the send.
        // The lookup pool includes the quote-synthesized hit (每日一句) so the
        // send-time guard is not weakened for quote-sourced previews.
        if let hit = (hits + [quoteHit].compactMap { $0 })
            .first(where: { $0.bookID == preview.selection.bookID && $0.physicalPage == preview.selection.physicalPage }),
           let reason = await openGuard(for: hit) {
            aiMessage = reason
            return
        }
        let allowed: [AllowedSource] = [AllowedSource(
            bookID: preview.selection.bookID,
            pageCount: hits.first(where: { $0.bookID == preview.selection.bookID })?.pageCount ?? 1,
            fingerprint: preview.selection.fingerprint
        )]
        // Task 句柄与取消令牌由 startAISend 统一保存。
        startAISend(preview: preview, allowed: allowed) { [weak self] response, decisions in
            completion(response, decisions)
            self?.appendAIChatTurns(preview: preview, answer: response.answerText, decisions: decisions)
        }
    }

    // MARK: Cross-device snapshot (whitelist-only export / history-only import)
    //
    // Export: builds the versioned SyncSnapshot from the index. The payload is
    // whitelist-only by construction (no paths, no fingerprints, no full text,
    // no AI configuration) — see SyncModels.
    // Import: applies ONLY the query history (and shows the book count). The
    // index itself is never rewritten from another device's metadata: without
    // the original files, paths/pages cannot exist on this machine anyway.
    // Cloud transport stays unconfigured (personal team) — nothing uploads.

    func exportSnapshot() {
        do {
            let s = try storeOrOpen()
            let snapshot = try SyncSnapshotBuilder.build(store: s, history: history.history())
            let data = try SyncSnapshotCodec.encode(snapshot)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "literature-sync-v\(snapshot.schemaVersion).json"
            panel.allowedContentTypes = [.json]
            panel.prompt = L10n.syncExport
            // 导出动作走用户配置的导出目录（设置页可改，默认
            // AppSupport/exports）；目录缺失时先建（atomic 写需要）。
            try FileManager.default.createDirectory(at: exportDirectoryURL,
                                                    withIntermediateDirectories: true)
            panel.directoryURL = exportDirectoryURL
            guard panel.runModal() == .OK, let url = panel.url else {
                syncMessage = L10n.syncCancelled
                return
            }
            try data.write(to: url, options: .atomic)
            syncMessage = "\(L10n.syncExportedOK)：书目 \(snapshot.books.count)，历史 \(snapshot.history.count) 条（仅白名单字段）"
        } catch {
            syncMessage = "\(L10n.syncExportFailed)\(error)"
        }
    }

    func importSnapshot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.prompt = L10n.syncImport
        guard panel.runModal() == .OK, let url = panel.url else {
            syncMessage = L10n.syncCancelled
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let snapshot = try SyncSnapshotCodec.decode(data)
            // record dedups by query and keeps the original timestamps.
            for entry in snapshot.history {
                history.record(query: entry.query, hitCount: entry.hitCount, now: entry.at)
            }
            syncMessage = "\(L10n.syncImportedOK)：v\(snapshot.schemaVersion)，书目 \(snapshot.books.count)（只读展示），历史合并 \(snapshot.history.count) 条"
        } catch {
            syncMessage = "\(L10n.syncImportFailed)\(error)"
        }
    }

    static func key(for hit: SearchHit) -> String {
        "\(hit.bookID)#\(hit.physicalPage)"
    }

    // MARK: - 检索增强批（App 侧组装）

    /// 档该书记数（候选基准）并存——两数走既有「双标」诚实呈现。
    func loadBookScopeHits(_ query: String, bookID: String) {
        Task(priority: .userInitiated) {
            do {
                let s = try storeOrOpen()
                let service = SearchService(store: s, policy: policy)
                var filter = SearchFilter()
                filter.bookIDEquals = bookID
                // 工具书开关透传（书内档与全库档同则）。
                filter.includeToolBooks = UserDefaults.standard.bool(forKey: "includeToolBooks")
                let result = try service.searchDetailed(
                    query, options: SearchOptions(limit: AppState.bookHitsLimitDefault, filter: filter))
                guard self.query == query, self.selectedHit?.bookID == bookID else { return }
                self.bookScopeHits = result.hits
                self.bookScopeBookID = bookID
                self.bookScopeTotal = result.totalPageMatches
            } catch {
                // 书内档失败不遮蔽全库档（如实空分区，不假称）。
                self.bookScopeHits = []
                self.bookScopeBookID = nil
                self.bookScopeTotal = 0
            }
        }
    }

    private static let bookHitsLimitDefault = 50

    //命中页预览：当前查询跑 searchDetailed（200/4 上限），逐条读命中
    /// 页行全文并经 SnippetHighlighter 组装高亮段（渲染层零猜测）。
    /// 重活在 Task.detached 后台线程跑（Task{} 会继承主 actor
    /// 把全库级检索压进 UI 线程），UI 状态写经 MainActor.run 回主线程。
    func loadPreviewHits() {
        guard !previewLoading else { return }
        previewLoading = true
        previewTruncatedNotice = nil
        let q = query
        Task.detached(priority: .userInitiated) {
            defer { Task { @MainActor in self.previewLoading = false } }
            do {
                // 主 actor 句柄/策略先取（storeOrOpen 属主线程纪律），重活在本 detached 线程。
                let s = try await MainActor.run { try self.storeOrOpen() }
                let policy = await MainActor.run { self.policy }
                let service = SearchService(store: s, policy: policy)
                var options = SearchOptions(limit: 200)
                options.perBookLimit = 4
                let result = try service.searchDetailed(q, options: options)
                var rows: [PreviewRow] = []
                for hit in result.hits {
                    // 命中页行全文（该来源页文本——OCR 命中即 OCR 页文本，
                    // 高亮坐标同源；零猜测：读不到行即跳过该条）。
                    guard let page = try s.page(bookID: hit.bookID, pageNumber: hit.physicalPage) else { continue }
                    let assembled = SnippetHighlighter.assemble(
                        fullText: page.textOriginal, ranges: hit.matches.map(\.originalUTF16Range))
                    rows.append(PreviewRow(fileName: hit.fileName, physicalPage: hit.physicalPage,
                                           isOCR: hit.source == "ocr", matchCount: hit.matches.count,
                                           snippet: assembled))
                }
                let rowsFinal = rows
                let hitCount = result.hits.count
                let total = result.totalPageMatches
                let truncated = result.truncated
                await MainActor.run {
                    self.previewRows = rowsFinal
                    if truncated {
                        self.previewTruncatedNotice = L10n.previewTruncated(hitCount, total)
                    }
                }
            } catch {
                await MainActor.run {
                    self.previewRows = []
                    self.previewTruncatedNotice = String(describing: error)
                }
            }
        }
    }

    /// 展开代次：迟到的后台回写不得复活已收起的展开区。
    private var contextGenerations: [String: UUID] = [:]

    //命中行上下文展开/收起（查询期零写库；无目录如实 nil）。
    func toggleContext(for hit: SearchHit) {
        let key = Self.key(for: hit)
        if hitContexts[key] != nil {
            hitContexts[key] = nil
            contextGenerations[key] = nil
            return
        }
        let gen = UUID()
        contextGenerations[key] = gen
        Task.detached(priority: .userInitiated) {
            do {
                let s = try await MainActor.run { try self.storeOrOpen() }
                let policy = await MainActor.run { self.policy }
                let service = SearchService(store: s, policy: policy)
                let context = try service.contextExpansion(bookID: hit.bookID, page: hit.physicalPage)
                await MainActor.run {
                    if self.contextGenerations[key] == gen {   // 期间未被收起/重开才回写
                        self.hitContexts[key] = context
                    }
                }
            } catch {
                // 上下文读取失败：不写假数据，如实留空（展开区显示无上下文）。
            }
        }
    }

    //相似文档（进程内缓存；未建倒排/单词书如实空列表）。
    /// /计算走后台线程（Task{} 会继承主 actor 把全库级
    /// 相似计算压进 UI 线程）；引擎带排除策略（策略排除书不进推荐）。
    func loadSimilarBooks(bookID: String) {
        if similarBooksFor == bookID { return }
        similarBooksFor = bookID
        similarLoading = true
        Task.detached(priority: .userInitiated) {
            defer { Task { @MainActor in self.similarLoading = false } }
            do {
                let s = try await MainActor.run { try self.storeOrOpen() }
                let engine: SimilarBooksEngine = await MainActor.run {
                    if let e = self.similarEngine { return e }
                    let e = SimilarBooksEngine(store: s, policy: self.policy)
                    self.similarEngine = e
                    return e
                }
                let result = try engine.similar(to: bookID)
                await MainActor.run {
                    if self.similarBooksFor == bookID {
                        self.similarBooks = result
                    }
                }
            } catch {
                await MainActor.run { self.similarBooks = [] }   // 失败如实空，不假称
            }
        }
    }

}

extension ExclusionConfig {
    /// Loads user exclusion rules from `<db-dir>/exclusions.json` when present.
    static func loadOrDefault(at dbURL: URL) -> ExclusionConfig {
        let url = dbURL.deletingLastPathComponent().appendingPathComponent("exclusions.json")
        if FileManager.default.fileExists(atPath: url.path) {
            return ExclusionConfig.load(from: url)
        }
        return ExclusionConfig.conservativeDefaults
    }
}

// MARK: - 前置页屏蔽（extension 追加块）

extension AppState {
    /// 书级正文起始物理页（nil = 未设置/库未开——不屏蔽，默认关）。
    /// storeOrOpen 主线程开库惯例（AppState.search 同款）。
    func frontMatterBodyStart(bookID: String) -> Int? {
        guard let s = try? storeOrOpen() else { return nil }
        return FrontMatterFilter.readBodyStartPage(store: s, bookID: bookID)
    }

    /// 手动校正写入（书详情面板；nil = 清除）。只写书级 meta 键，检索
    /// 链路零接触；写后既有查询结果重渲染即生效（视图层过滤每次重算）。
    func frontMatterWriteBodyStart(bookID: String, page: Int?) throws {
        guard let s = try? storeOrOpen() else {
            throw FrontMatterError("库未打开，无法保存正文起始页")
        }
        try FrontMatterFilter.writeBodyStartPage(page, store: s, bookID: bookID)
    }
}
