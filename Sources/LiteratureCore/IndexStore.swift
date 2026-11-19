import Foundation

/// SQLite-backed index store.
public final class IndexStore {
    public static let expectedNormalizationVersion = 4
    /// Authoritative compile-time constant for FTS tokenizer version (bigram unicode61 = 2).
    /// Rejects databases with outdated or missing tokenizer version fail-closed.
    public static let expectedFTSTokenizerVersion = 2
    /// 现行索引 schema 迁移版本（与 migrate 末尾写入的
    /// `schema_version` / `index_schema_version` 对齐）。新增迁移时递增。
    public static let currentSchemaVersion = 13
    /// fulltext.db 自有格式版本
    /// （对齐 currentSchemaVersion 惯例）。全文索引库为可再生派生物——
    /// 版本不符/损坏 → 整库删除重建＋全量重排队（补齐缺口），绝不
    /// fail-closed 卡死用户（与 main 库版本门禁的用户数据保护语义相反）。
    public static let currentFulltextFormatVersion = 1
    /// 版本门禁 meta 键。写入现行迁移版本；读侧规则即向前兼容
    /// 语义：库版本 **低于** 应用已知版本 → 正常走既有逐版本迁移（旧索引
    /// 永远可读）；库版本 **高于** 应用已知版本 → 打开即报错提示升级应用
    /// （fail-closed，绝不静默降级读写——未知的新版本列/表语义被误读可能
    /// 损坏数据）。
    static let indexSchemaVersionMetaKey = "index_schema_version"
    /// quick_check 节流间隔。quick_check 对多 GB 库非平凡（遵循
    /// fts_probe_ok_v1 的成本先例：贵检查不每次启动跑）；成功一次记录
    /// 时间戳，超间隔才重跑。表存在性/行数比例 sanity 每次启动都跑。
    static let quickCheckInterval: TimeInterval = 24 * 3600

    public enum StoreError: Error, CustomStringConvertible {
        case description(String)
        public var description: String {
            switch self {
            case .description(let m): return m
            }
        }
        init(_ m: String) { self = .description(m) }
    }

    /// Test hook: force the LIKE fallback even when FTS5 exists.
    public struct Options {
        public var forceFallbackSearch: Bool
        /// 只读副本形态（iOS 端 WebDAV 下载的索引副本专用）。
        /// 打开走 SQLITE_OPEN_READONLY（SQLiteDatabase.readOnlyFlags 既有），
        /// 跳过 WAL/迁移/自愈/meta 写；schema 门禁特化为「读出版本 ==
        /// currentSchemaVersion 才放行」。默认 false = macOS 现行为逐字节
        /// 不变（生产 macOS 路径从不传 true）。
        public var readOnlyReplica: Bool
        /// Full FTS/quick_check and repair are maintenance operations. They are
        /// deliberately opt-in so opening a multi-GB library never blocks the
        /// SwiftUI main thread on a first launch.
        public var performExpensiveSelfHeal: Bool
        /// 允许开库期内建「全书页统计」覆盖索引
        /// `ft.idx_pages_stats`（migrate 链尾一次，索引已在不重建）。默认
        /// false＝App 路径逐字节不变（不让日常启动多一次整表扫描）；显式
        /// 打开时首次建索引需要一次性扫描，后续每次开库 O(1)
        /// 判别。CLI `search` 默认打开＝true（每进程只查一次，见 main 调用
        /// 点）；基准/长测进程可关。理由与范围见 migrateSchemaV14。
        public var allowPageStatsStatsIndex: Bool
        public init(forceFallbackSearch: Bool = false,
                    readOnlyReplica: Bool = false,
                    performExpensiveSelfHeal: Bool = false,
                    allowPageStatsStatsIndex: Bool = false) {
            self.forceFallbackSearch = forceFallbackSearch
            self.readOnlyReplica = readOnlyReplica
            self.performExpensiveSelfHeal = performExpensiveSelfHeal
            self.allowPageStatsStatsIndex = allowPageStatsStatsIndex
        }
    }

    public enum SearchMode: String {
        case fts5Bigram = "fts5-bigram"
        case fts5Trigram = "fts5-trigram"
        case likeFallback = "like-fallback"
    }

    public struct BookRow {
        public var id: String
        public var realPath: String
        public var rootPath: String
        public var relPath: String
        public var fileName: String
        public var title: String?      // nil = unknown
        public var author: String?     // nil = unknown
        public var version: String?    // nil = unknown
        public var language: String?   // nil = unknown (never detected/guessed)
        public var metaSource: String? // nil | "manual" | "sidecar"
        public var firstFingerprint: String
        public var fingerprint: String
        public var fileSize: Int64
        public var mtime: Double
        public var pageCount: Int
        public var status: String      // "ok" | "error"
        public var error: String?
        public var indexedAt: Double
        /// memberwise 默认值保既有调用点（init 末位带默认值，不破坏现有构造调用）
        public var contentCategory: String = ""
    }

    final class LazyOffsets: @unchecked Sendable {
        let startsBlob: Data
        let endsBlob: Data
        private var cachedStarts: [Int32]?
        private var cachedEnds: [Int32]?

        init(startsBlob: Data, endsBlob: Data) {
            self.startsBlob = startsBlob
            self.endsBlob = endsBlob
        }

        func starts() -> [Int32] {
            if let c = cachedStarts { return c }
            let arr = Self.int32Array(from: startsBlob)
            cachedStarts = arr
            return arr
        }

        func ends() -> [Int32] {
            if let c = cachedEnds { return c }
            let arr = Self.int32Array(from: endsBlob)
            cachedEnds = arr
            return arr
        }

        private static func int32Array(from data: Data) -> [Int32] {
            guard data.count % 4 == 0 else { return [] }
            var out: [Int32] = []
            out.reserveCapacity(data.count / 4)
            data.withUnsafeBytes { raw in
                for i in stride(from: 0, to: raw.count, by: 4) {
                    out.append(raw.loadUnaligned(fromByteOffset: i, as: Int32.self).littleEndian)
                }
            }
            return out
        }
    }

    public struct PageRow {
        public var bookID: String
        public var pageNumber: Int          // 1-based physical
        public var label: String?           // nil = unknown (not guessed)
        public var printedPage: Int?        // nil = unknown (not guessed)
        public var textOriginal: String
        public var textNorm: String
        private var lazyOffsets: LazyOffsets?
        private var _explicitStarts: [Int32]?
        private var _explicitEnds: [Int32]?

        public var normStarts: [Int32] {
            get {
                if let s = _explicitStarts { return s }
                if let lazy = lazyOffsets { return lazy.starts() }
                return []
            }
            set {
                _explicitStarts = newValue
                lazyOffsets = nil
            }
        }

        public var normEnds: [Int32] {
            get {
                if let e = _explicitEnds { return e }
                if let lazy = lazyOffsets { return lazy.ends() }
                return []
            }
            set {
                _explicitEnds = newValue
                lazyOffsets = nil
            }
        }

        public init(bookID: String, pageNumber: Int, label: String? = nil, printedPage: Int? = nil,
                    textOriginal: String, textNorm: String,
                    normStarts: [Int32], normEnds: [Int32]) {
            self.bookID = bookID
            self.pageNumber = pageNumber
            self.label = label
            self.printedPage = printedPage
            self.textOriginal = textOriginal
            self.textNorm = textNorm
            self._explicitStarts = normStarts
            self._explicitEnds = normEnds
            self.lazyOffsets = nil
        }

        public init(bookID: String, pageNumber: Int, label: String? = nil, printedPage: Int? = nil,
                    textOriginal: String, textNorm: String,
                    normStartsBlob: Data, normEndsBlob: Data) {
            self.bookID = bookID
            self.pageNumber = pageNumber
            self.label = label
            self.printedPage = printedPage
            self.textOriginal = textOriginal
            self.textNorm = textNorm
            self._explicitStarts = nil
            self._explicitEnds = nil
            self.lazyOffsets = LazyOffsets(startsBlob: normStartsBlob, endsBlob: normEndsBlob)
        }
    }

    public struct OCRBookRow: Equatable, Sendable {
        public var bookID: String
        public var ocrRealPath: String
        public var ocrFingerprint: String
        public var mappingKind: String   // "same-page-verified" | "explicit"
        public var createdAt: Double

        public init(bookID: String, ocrRealPath: String, ocrFingerprint: String,
                    mappingKind: String, createdAt: Double) {
            self.bookID = bookID
            self.ocrRealPath = ocrRealPath
            self.ocrFingerprint = ocrFingerprint
            self.mappingKind = mappingKind
            self.createdAt = createdAt
        }
    }

    /// One page's OCR text, already mapped to the ORIGINAL physical page.
    public struct OCRPageTextUpdate: Equatable, Sendable {
        public var originalPage: Int
        public var ocrPage: Int
        public var textOriginal: String
        public var textNorm: String
        public var normStarts: [Int32]
        public var normEnds: [Int32]

        public init(originalPage: Int, ocrPage: Int, textOriginal: String, textNorm: String,
                    normStarts: [Int32], normEnds: [Int32]) {
            self.originalPage = originalPage
            self.ocrPage = ocrPage
            self.textOriginal = textOriginal
            self.textNorm = textNorm
            self.normStarts = normStarts
            self.normEnds = normEnds
        }
    }

    /// Everything search/UI needs to know about a book's OCR pairing.
    public struct OCRPairingInfo: Equatable, Sendable {
        public var ocrRealPath: String
        public var ocrFingerprint: String
        public var mappingKind: String
        public var ocrPages: [Int: Int]       // original physical page -> ocr physical page
        public var ocrSourcedPages: Set<Int>  // original pages whose stored text is OCR-derived
    }

    public private(set) var capabilities: FTS5Capabilities
    public internal(set) var searchMode: SearchMode

    internal let db: SQLiteDatabase
    /// 模内可见（PinyinBookIndex 扩展的同层封装需要）；仍不对模外暴露。
    let lock = NSLock()

    // MARK: - 两库分离
    //
    // 元数据库 index.db（随快照/备份走、含用户数据、损坏不可再生）与全文
    // 索引库 fulltext.db（可再生派生物、不参与快照/备份、损坏可整库重建）
    // 物理分离。单连接 + ATTACH 形态（最小爆炸半径）：ATTACH 后同连接跨库
    // JOIN/SQL 文本基本不变（books 在 main、pages 在 ft，未限定名照常解析；
    // 本实现 sqlite3 实证：未限定 SELECT 解析 ft、未限定 CREATE 落 main——
    // 故 ft 侧懒建表全部显式 ft. 限定）。跨库事务不保证原子（main 为 WAL），
    // 沿用 persist 写序纪律，不引入跨库事务假设。
    /// ft 侧限定前缀（split="" 的 legacy 与 "ft." 的分离形态二态）。
    /// 模内可见（migrations/queue 扩展同层使用）。
    var ftQual: String { fulltextAttached ? "ft." : "" }
    /// fulltext.db 当前是否已 ATTACH（split 形态 true；legacy 单库 false）。
    /// setter internal：migrations 扩展的搬迁函数需跨文件置位（同层封装先例）。
    var fulltextAttached = false
    /// fulltext.db 落点（init 推导或显式注入；快照/备份天然不含）。
    public private(set) var fulltextURL: URL?

    // MARK: Lifecycle

    /// 只读副本形态标记（setMetaValueLocked 卫语句读它）。
    private let readOnlyReplica: Bool
    private let performExpensiveSelfHeal: Bool
    /// migrateSchemaV14 是否可建页统计覆盖索引（见 Options 注释）。
    /// 改为 var——**唯一**写点是 `ensurePageStatsIndex`
    /// （锁内临时置真、调完还原），供刷新批收尾复用同一条 DDL 通道；开库
    /// 迁移仍按 Options 原值判定，App 日常启动行为逐字节不变。
    var allowPageStatsStatsIndex: Bool
    /// 只读守卫：队列消费循环据此直接返回空队列（消费白做不发起；
    /// 队列写本身已在 IndexStore+IndexQueue.swift 逐函数卫语句 no-op）。
    var isReadOnlyReplica: Bool { readOnlyReplica }

    /// fulltextURL 传 nil 时由 init 内推导（index.db 同目录 fulltext.db）
    public init(path: URL, options: Options = Options(), fulltextURL: URL? = nil) throws {
        let __tOpen = Date()
        var __handleMs = 0.0, __migrateMs = 0.0, __selfhealMs = 0.0, __metaMs = 0.0
        if path.pathComponents.count > 1 {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        // fulltext 落点推导——默认 index.db 同目录 fulltext.db，
        // AppState 等既有调用点零改动。legacy 单库形态下仅作记录不 ATTACH。
        self.fulltextURL = fulltextURL
            ?? path.deletingLastPathComponent().appendingPathComponent("fulltext.db")
        // 只读分支：副本文件走 SQLITE_OPEN_READONLY 在句柄层保证
        // 拿不到写权限（SQLiteDatabase.readOnlyFlags 既有， 快照源库
        // 同款——「绝不回退读写打开」契约互引）；默认路径 convenience 逐字
        // 不变（RW|CREATE|FULLMUTEX）。
        readOnlyReplica = options.readOnlyReplica
        performExpensiveSelfHeal = options.performExpensiveSelfHeal
        allowPageStatsStatsIndex = options.allowPageStatsStatsIndex
        if options.readOnlyReplica {
            db = try SQLiteDatabase(path: path.path, flags: SQLiteDatabase.readOnlyFlags)
        } else {
            db = try SQLiteDatabase(path: path.path)
        }
        __handleMs = Date().timeIntervalSince(__tOpen) * 1000
        let caps = FTS5Probe.probeOrDefault()
        capabilities = caps
        searchMode = (caps.fts5 && caps.trigramTokenizer && !options.forceFallbackSearch) ? .fts5Trigram : .likeFallback

        lock.lock()
        defer { lock.unlock() }
        if options.readOnlyReplica {
            try db.exec("PRAGMA foreign_keys=ON;")
            try db.exec("PRAGMA mmap_size=1073741824;")
            try db.exec("PRAGMA cache_size=-65536;")
            // schema 门禁（只读特化）：读出版本必须 == currentSchemaVersion
            // 才放行。高于 → 提示升级 App；低于/缺失 → 提示回 Mac 重建上传。
            // 只读端不做任何迁移（副本文件对句柄层只读，迁移本就不可行）。
            let stored = try? metaValueLocked(Self.indexSchemaVersionMetaKey)
            guard let stored, let v = Int(stored) else {
                throw StoreError.description(
                    "只读副本缺少 schema 版本标记（index_schema_version），无法确认版本兼容。" +
                    "请回 Mac 端重建索引并重新上传副本。")
            }
            guard v == Self.currentSchemaVersion else {
                throw StoreError.description(
                    v > Self.currentSchemaVersion
                        ? "索引副本 schema 版本 v\(v) 高于本应用支持的最高版本 v\(Self.currentSchemaVersion)，" +
                          "请升级 App 后再打开（fail-closed，不静默降级）。"
                        : "索引副本 schema 版本 v\(v) 低于本应用支持的版本 v\(Self.currentSchemaVersion)，" +
                          "请回 Mac 端重建索引并重新上传（只读端不做任何迁移）。")
            }
            if let storedVer = try metaValueLocked("normalization_version") {
                if let v = Int(storedVer), v != Self.expectedNormalizationVersion {
                    FileHandle.standardError.write(Data("[IndexStore] Warning: normalization version mismatch (found '\(storedVer)', expected '\(Self.expectedNormalizationVersion)'). Queries will be rejected until index is rebuilt.\n".utf8))
                }
            }
            try attachFulltextForReplicaLocked()
            __metaMs = Date().timeIntervalSince(__tOpen) * 1000 - __handleMs
            SearchPhaseTiming.emit("open total=\(SearchPhaseTiming.ms(Date().timeIntervalSince(__tOpen) * 1000))ms " +
                                   "handle=\(SearchPhaseTiming.ms(__handleMs))ms meta=\(SearchPhaseTiming.ms(__metaMs))ms readonly=true")
            return
        }
        try db.exec("PRAGMA journal_mode=WAL;")
        try db.exec("PRAGMA foreign_keys=ON;")
        // Query-latency tuning:  multi-GB libraries scan large btree
        // ranges for 2-char CJK LIKE fallbacks; mmap avoids per-page memcpy and
        // a bigger page cache keeps the hot range resident across queries.
        try db.exec("PRAGMA mmap_size=1073741824;")
        try db.exec("PRAGMA cache_size=-65536;")
        // 版本门禁（先于迁移）：库版本高于应用已知版本 → 明确报错
        // 提示升级应用，不做任何写操作；低于 → 正常走既有逐版本迁移。
        try enforceSchemaVersionGateLocked()
        // 双库装配：legacy 判定 / ATTACH / 格式门禁 / 损坏整库重建。
        // 必须先于 migrate——迁移的 baseline DDL 与全文 DDL 路由依赖
        // fulltextAttached 态。
        try setupFulltextLocked()
        let __tMigrate = Date()
        try migrate()
        __migrateMs = Date().timeIntervalSince(__tMigrate) * 1000
        // 启动自检：倒排表 sanity（表存在 + 行数比例 + 节流
        // quick_check），异常自动重建并把原因记入 meta。
        let __tHeal = Date()
        // Expensive FTS integrity scans and repair are maintenance-only. The
        // normal app path performs schema/version checks and O(1) probes during
        // open, then remains responsive; callers doing maintenance must opt in
        // explicitly with Options(performExpensiveSelfHeal: true).
        if performExpensiveSelfHeal {
            try selfHealIfNeededLocked()
        }
        __selfhealMs = Date().timeIntervalSince(__tHeal) * 1000
        let storedMode = try metaValueLocked("search_mode")
        if storedMode != nil && storedMode != searchMode.rawValue {
            // Mode is decided by the machine's SQLite + Options at creation time;
            // keep it stable afterwards so index contents stay interpretable.
            searchMode = SearchMode(rawValue: storedMode!) ?? searchMode
        } else if storedMode == nil {
            try setMetaValueLocked("search_mode", searchMode.rawValue)
        }
        if (try? metaValueLocked("sqlite_version")) != capabilities.sqliteVersion {
            try setMetaValueLocked("sqlite_version", capabilities.sqliteVersion)
        }
        if let storedVer = try metaValueLocked("normalization_version") {
            if let v = Int(storedVer), v != Self.expectedNormalizationVersion {
                FileHandle.standardError.write(Data("[IndexStore] Warning: normalization version mismatch (found '\(storedVer)', expected '\(Self.expectedNormalizationVersion)'). Queries will be rejected until index is rebuilt.\n".utf8))
            }
        }
        __metaMs = Date().timeIntervalSince(__tOpen) * 1000 - __handleMs - __migrateMs - __selfhealMs
        // 开库分阶段计时（探针激活才输出 stderr）：total=handle+migrate+
        // selfheal+meta；用于观察 quick_check 节流与 fts_probe_ok_v1 状态。
        SearchPhaseTiming.emit("open total=\(SearchPhaseTiming.ms(Date().timeIntervalSince(__tOpen) * 1000))ms " +
                               "handle=\(SearchPhaseTiming.ms(__handleMs))ms migrate=\(SearchPhaseTiming.ms(__migrateMs))ms " +
                               "selfheal=\(SearchPhaseTiming.ms(__selfhealMs))ms meta=\(SearchPhaseTiming.ms(__metaMs))ms readonly=false")
    }

    // MARK: 共享连接的统一执行入口

    /// 持本类 `lock` 执行一整段共享连接访问。
    internal func withSharedConnection<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: — schema 版本门禁与启动自愈

    /// 门禁（init 已持锁调用）：库内 index_schema_version 高于应用已知版本
    /// 时抛错拒绝打开（明确提示升级应用，不静默降级）；无键（新库/老版本
    /// 库）或低于 → 放行，由 migrate 正常迁移。
    private func enforceSchemaVersionGateLocked() throws {
        guard let stored = try? metaValueLocked(Self.indexSchemaVersionMetaKey),
              let v = Int(stored) else { return }
        guard v <= Self.currentSchemaVersion else {
            throw StoreError.description(
                "索引 schema 版本 v\(v) 高于本应用支持的最高版本 v\(Self.currentSchemaVersion)。" +
                "请升级应用后再打开该索引库（为防新版表/列语义被误读，拒绝静默降级）。")
        }
    }

    // MARK: - 两库分离装配/门禁/整库重建
    //
    // 切分边界：fulltext.db 承载 pages、pages_fts、bigram_index、pages_wfts
    // （FTS5 external-content 同库约束）、book_native_counts、ft_meta；index.db
    // 留全部用户/声明制数据（books/user_highlights/favorites/daily_quotes/
    // ocr_*/page_map/index_queue/index_pending/classification/reading_*/…）。
    // legacy 单库形态通过 main.pages 表是否存在判定。
    // 迁移命令延后到写通道就绪，避免引入时序耦合。

    /// main 侧 pages 表存在性（legacy 单库形态判定；O(1) sqlite_master 探针）。
    /// internal（migrations 扩展跨文件使用；搬移先例同款扩级）。
    func mainPagesTableExistsLocked() -> Bool {
        guard let stmt = try? db.prepare("SELECT 1 FROM main.sqlite_master WHERE type='table' AND name='pages';") else {
            return false
        }
        return (try? stmt.step()) == true
    }

    /// 读写形态装配（init 已持锁；先于 migrate）：legacy → 不 ATTACH 走
    /// 旧读路；split → ATTACH＋格式门禁，任何不符走整库重建（可再生语义，
    /// 与 main 版本门禁的 fail-closed 用户数据保护相反）。
    private func setupFulltextLocked() throws {
        guard let ftURL = fulltextURL else { return }
        if mainPagesTableExistsLocked() {
            // legacy 单库（尚未迁移的旧格式）：绝不 ATTACH——main.pages
            // 会遮蔽 ft.pages 的未限定名解析，双份存在即语义事故。全量重排队
            // 等重建语义全部不适用（数据就在 main）。
            return
        }
        if FileManager.default.fileExists(atPath: ftURL.path) {
            do {
                try attachFulltextLocked(url: ftURL)
            } catch {
                // ATTACH 失败（文件损坏/半写）→ 整库重建（删件重来）。
                try rebuildFulltextLocked(reason: "ATTACH 失败: \(error)")
                return
            }
            if !fulltextSchemaValidLocked() {
                try rebuildFulltextLocked(reason: "fulltext 格式版本不符或 schema 缺失")
                return
            }
        } else {
            try createFulltextSchemaLocked()
            try requeueAllBooksForFulltextRebuildLocked()
        }
    }

    /// 副本形态装配（init 已持锁；只读连接）。三态见调用点注释。
    private func attachFulltextForReplicaLocked() throws {
        guard let ftURL = fulltextURL else { return }
        if FileManager.default.fileExists(atPath: ftURL.path) {
            try attachFulltextLocked(url: ftURL)   // 失败即抛：副本不可自愈重建
            guard fulltextSchemaValidLocked() else {
                throw StoreError.description(
                    "索引副本 fulltext.db 格式版本不符（期望 v\(Self.currentFulltextFormatVersion)）。" +
                    "请回 Mac 端重建索引并重新上传副本（只读端不做重建）。")
            }
        } else if mainPagesTableExistsLocked() {
            // 旧副本（分离前快照）：不 ATTACH 走旧读路。
            return
        } else {
            throw StoreError.description(
                "索引副本缺少 fulltext.db 且 index.db 无页行，无法检索。" +
                "请回 Mac 端重新生成并上传副本（fail-closed，不假装可搜）。")
        }
    }

    /// ATTACH fulltext.db（本实现 sqlite 实证：ATTACH 接受绑定参数；读写连接
    /// 上附带件同连接可写，只读连接上一切写 SQLITE_READONLY——句柄层纪律）。
    func attachFulltextLocked(url: URL) throws {
        let stmt = try db.prepare("ATTACH DATABASE ? AS ft;")
        try stmt.bindText(1, url.path)
        try stmt.run()
        fulltextAttached = true
        if !readOnlyReplica {
            try db.exec("PRAGMA ft.journal_mode=WAL;")
        }
    }

    /// fulltext schema 有效性（每次开库 O(1) 探针）：ft_meta 版本键＋
    /// pages/pages_fts 存在性。
    private func fulltextSchemaValidLocked() -> Bool {
        guard let v = (try? ftMetaValueLocked("fulltext_format_version")) ?? nil,
              let ver = Int(v), ver == Self.currentFulltextFormatVersion else { return false }
        return hasFulltextObjectLocked(type: "table", name: "pages")
            && hasFulltextObjectLocked(type: "table", name: "pages_fts")
    }

    /// ft 侧对象存在性探针（照 LatinProjection.hasSqliteObjectLocked 同构）。
    func hasFulltextObjectLocked(type: String, name: String) -> Bool {
        guard let stmt = try? db.prepare("SELECT 1 FROM ft.sqlite_master WHERE type = ? AND name = ?;") else {
            return false
        }
        do {
            try stmt.bindText(1, type)
            try stmt.bindText(2, name)
        } catch { return false }
        return (try? stmt.step()) == true
    }

    /// ft_meta 读写（fulltext.db 自有元数据——独立表，不与 main.meta 混名）。
    func ftMetaValueLocked(_ key: String) throws -> String? {
        let stmt = try db.prepare("SELECT value FROM ft.ft_meta WHERE key = ?;")
        try stmt.bindText(1, key)
        defer { stmt.reset() }
        if try stmt.step() { return stmt.textOrNull(0) }
        return nil
    }

    /// 建空 fulltext schema（新装/重建共用；DDL 全量 ft. 限定——未限定
    /// CREATE 恒落 main，本实现 sqlite 实证）。ft.pages 去 FK：跨库下
    /// REFERENCES books ON DELETE CASCADE 不成立，删书靠既有显式删序
    /// （先 pages 后 books）＋开库孤儿清扫降级处理（文档化）。
    func createFulltextSchemaLocked() throws {
        guard let ftURL = fulltextURL else { return }
        if ftURL.pathComponents.count > 1 {
            try? FileManager.default.createDirectory(at: ftURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
        }
        try attachFulltextLocked(url: ftURL)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS ft.ft_meta(
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS ft.pages(
            book_id TEXT NOT NULL,
            page_number INTEGER NOT NULL,
            label TEXT,
            printed_page INTEGER,
            text_original TEXT NOT NULL,
            text_norm TEXT NOT NULL,
            norm_starts BLOB NOT NULL,
            norm_ends BLOB NOT NULL,
            source TEXT NOT NULL DEFAULT 'native',
            text_latin TEXT NOT NULL DEFAULT '',
            PRIMARY KEY(book_id, page_number)
        );
        CREATE INDEX IF NOT EXISTS ft.idx_pages_book_source ON pages(book_id, source);
        CREATE TABLE IF NOT EXISTS ft.bigram_index(
            bigram TEXT PRIMARY KEY,
            rowids BLOB NOT NULL
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS ft.book_native_counts(
            book_id TEXT PRIMARY KEY,
            native_count INTEGER NOT NULL
        ) WITHOUT ROWID;
        """)
        if searchMode == .fts5Trigram {
            let ok = db.tryExec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS ft.pages_fts USING fts5(
                text_bigram,
                tokenize='unicode61',
                detail='none'
            );
            """)
            if !ok {
                searchMode = .likeFallback
                try setMetaValueLocked("search_mode", searchMode.rawValue)
            }
            _ = db.tryExec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS ft.pages_wfts USING fts5(
                text_latin,
                content='pages',
                content_rowid='rowid',
                tokenize='unicode61'
            );
            CREATE TRIGGER IF NOT EXISTS ft.pages_wfts_ai AFTER INSERT ON pages BEGIN
                INSERT INTO pages_wfts(rowid, text_latin) VALUES (new.rowid, new.text_latin);
            END;
            CREATE TRIGGER IF NOT EXISTS ft.pages_wfts_ad AFTER DELETE ON pages BEGIN
                INSERT INTO pages_wfts(pages_wfts, rowid, text_latin) VALUES ('delete', old.rowid, old.text_latin);
            END;
            CREATE TRIGGER IF NOT EXISTS ft.pages_wfts_au AFTER UPDATE ON pages
                WHEN old.text_latin IS NOT new.text_latin BEGIN
                INSERT INTO pages_wfts(pages_wfts, rowid, text_latin) VALUES ('delete', old.rowid, old.text_latin);
                INSERT INTO pages_wfts(rowid, text_latin) VALUES (new.rowid, new.text_latin);
            END;
            """)
        }
        try db.exec("INSERT OR REPLACE INTO ft.ft_meta(key, value) VALUES('fulltext_format_version', '\(Self.currentFulltextFormatVersion)');")
    }

    /// 整库重建（缺口补齐）：DETACH → 删 fulltext.db 三件套 → 重建空
    /// schema → 全量重排队。重建失败如实抛错（pages 查询将不可用，坏搜索
    /// 好过静默假搜索）；重排队由 runQueued 在下一显式触发点逐册重抽取
    /// （缓存命中者近免费）。
    private func rebuildFulltextLocked(reason: String) throws {
        if fulltextAttached {
            _ = db.tryExec("DETACH DATABASE ft;")
            fulltextAttached = false
        }
        if let ftURL = fulltextURL {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: ftURL.path + suffix)
            }
        }
        try createFulltextSchemaLocked()
        try requeueAllBooksForFulltextRebuildLocked()
        try setMetaValueLocked("fulltext_rebuilt_at", String(Date().timeIntervalSince1970))
        try setMetaValueLocked("fulltext_rebuilt_reason", reason)
        FileHandle.standardError.write(Data(
            "[IndexStore] fulltext.db 已整库重建（\(reason)）；全部书已重排队。\n".utf8))
    }

    /// 全量重排队（已持锁；books 空＝新装零操作）。照既有基准
    /// enqueueBook 全部 books、queued_version=currentPipelineVersion。
    /// 卫语句：books 表尚未建（全新安装 init 期 setupFulltextLocked 先于
    /// migrate 的 baseline DDL 到达本点）→ 零操作直接返回——无书可排，
    /// 且 meta 表同样未建不能落痕。
    private func requeueAllBooksForFulltextRebuildLocked() throws {
        guard !isReadOnlyReplica else { return }
        let booksTableExists: Bool
        if let stmt = try? db.prepare("SELECT 1 FROM main.sqlite_master WHERE type='table' AND name='books';") {
            booksTableExists = (try? stmt.step()) == true
        } else {
            booksTableExists = false
        }
        guard booksTableExists else { return }
        let books = try allBooksLocked()
        for b in books {
            try enqueueBookLocked(b.id)
        }
        if !books.isEmpty {
            try setMetaValueLocked("fulltext_requeued_at", String(Date().timeIntervalSince1970))
        }
    }

    /// 快照恢复后的全文库作废重建（公开 API；
    /// 恢复旧 index.db 与现 fulltext.db 指纹错位：unchanged 文件由确定性
    /// 抽取天然一致，changed 文件的队列行多为 indexed@current 不在到期集，
    /// 被动收敛不完备）。App 恢复路径（restore 完成后）显式调用：删 ft 三
    /// 件套→重建空 schema→全量重排队（books 有实时抽取需求，缓存命中者
    public func invalidateFulltextAfterRestore() throws {
        lock.lock(); defer { lock.unlock() }
        guard !isReadOnlyReplica else { return }
        if fulltextAttached || FileManager.default.fileExists(atPath: fulltextURL?.path ?? "") {
            try rebuildFulltextLocked(reason: "快照恢复后全文库作废重建")
        }
    }

    /// ft 侧完整性自愈（selfHealIfNeededLocked 头部调用；已持锁）：
    /// 节流 quick_check（24h 同惯例，独立节流键）失败 → 整库重建。
    private func selfHealFulltextIfNeededLocked() throws {
        guard fulltextAttached else { return }
        let lastRaw = (try? metaValueLocked("ft_quickcheck_ok_at")) ?? nil
        let lastOK = lastRaw.flatMap { TimeInterval($0) } ?? 0
        guard Date().timeIntervalSince1970 - lastOK > Self.quickCheckInterval else { return }
        var verdict = ""
        if let stmt = try? db.prepare("PRAGMA ft.quick_check(1);") {
            if let hasRow = try? stmt.step(), hasRow { verdict = stmt.text(0) }
        }
        if verdict == "ok" {
            try setMetaValueLocked("ft_quickcheck_ok_at", String(Date().timeIntervalSince1970))
        } else {
            try rebuildFulltextLocked(reason: "PRAGMA ft.quick_check 异常: \(verdict.isEmpty ? "无结果" : verdict)")
            // 重建后 schema 全新：本周期不再二次自愈。
            try setMetaValueLocked("ft_quickcheck_ok_at", String(Date().timeIntervalSince1970))
        }
    }

    /// 孤儿清扫（删书规则的降级处理）：ft.pages 中 book_id 不在 main.books 的
    /// 行为可再生数据，清扫安全；随 quickCheck 节流同频（24h）低频执行。
    /// internal（FulltextSplitTests 清扫路径测试直呼；节流键由调用方置 0）。
    func sweepOrphanFulltextPagesLocked() throws {
        guard fulltextAttached, !isReadOnlyReplica else { return }
        let lastRaw = (try? metaValueLocked("orphan_sweep_at")) ?? nil
        let lastOK = lastRaw.flatMap { TimeInterval($0) } ?? 0
        guard Date().timeIntervalSince1970 - lastOK > Self.quickCheckInterval else { return }
        try db.exec("DELETE FROM ft.pages WHERE book_id NOT IN (SELECT id FROM main.books);")
        try setMetaValueLocked("orphan_sweep_at", String(Date().timeIntervalSince1970))
    }


    /// 启动自检（init 已持锁调用）：对 bigram 倒排表做轻量 sanity——
    private func selfHealIfNeededLocked() throws {
        // ft 侧文件级完整性（节流 quick_check 失败 → 整库重建）
        // 与孤儿页清扫——均先于 LIKE 模式早退（与倒排表自愈正交）。
        try selfHealFulltextIfNeededLocked()
        try sweepOrphanFulltextPagesLocked()
        try selfHealWftsIfNeededLocked()   // 词级索引自愈（探针 O(1)，ready/dirty 键节流；见 LatinProjection.swift）
        guard searchMode == .fts5Trigram else { return }   // LIKE 模式无倒排表
        // 探针辅助：语句存在首行返回 true（O(1)，找到即停）。
        func hasRow(_ sql: String) -> Bool {
            guard let stmt = try? db.prepare(sql) else { return false }
            return (try? stmt.step()) == true
        }
        var reason: String?
        // 两库分离：bigram_index 随 pages 迁 ft——存在性探针必须 schema
        // 感知（未限定 sqlite_master 恒指 main，split 形态会误判缺失 →
        // DROP ft 侧真表＋在 main 误建影子，倒排路径整体断裂；本实现冒烟
        // 实证过该断裂形态后修复）。DROP/CREATE 同步 ft. 限定。
        let bidxSchema = fulltextAttached ? "ft" : "main"
        let tableExists = hasRow("SELECT name FROM \(bidxSchema).sqlite_master WHERE type='table' AND name='bigram_index';")
        if !tableExists {
            reason = "bigram_index 表缺失（外部删除或存储损坏）"
        } else {
            let built = (try? metaValueLocked("bidx_built_at")) != nil
            let dirty = (try? metaValueLocked("bidx_dirty")) == "1"
            if built, !dirty,
               !hasRow("SELECT 1 FROM bigram_index LIMIT 1;"),
               hasRow("SELECT 1 FROM pages WHERE TRIM(text_norm) != '' LIMIT 1;") {
                reason = "bigram_index 已建成未标脏但为空，而 pages 存在文本页"
            }
            if reason == nil {
                // quick_check 节流窗口（quickcheck_ok_at）：窗口内不重跑。
                let lastRaw = (try? metaValueLocked("quickcheck_ok_at")) ?? nil
                let lastOK = lastRaw.flatMap { TimeInterval($0) } ?? 0
                if Date().timeIntervalSince1970 - lastOK > Self.quickCheckInterval {
                    var verdict = ""
                    if let stmt = try? db.prepare("PRAGMA quick_check(1);") {
                        if let hasRow = try? stmt.step(), hasRow { verdict = stmt.text(0) }
                    }
                    if verdict == "ok" {
                        try setMetaValueLocked("quickcheck_ok_at", String(Date().timeIntervalSince1970))
                    } else {
                        reason = "PRAGMA quick_check 异常: \(verdict.isEmpty ? "无结果" : verdict)"
                    }
                }
            }
        }
        guard let reason else { return }
        do {
            _ = db.tryExec("DROP TABLE IF EXISTS \(ftQual)bigram_index;")
            guard db.tryExec("""
            CREATE TABLE IF NOT EXISTS \(ftQual)bigram_index(
                bigram TEXT PRIMARY KEY,
                rowids BLOB NOT NULL
            ) WITHOUT ROWID;
            """) else {
                throw StoreError.description("重建 bigram_index 的 DDL 执行失败")
            }
            try rebuildBigramInvertedIndexLocked()
        } catch {
            // 重建失败：置脏让下一次 ensureBigramIndexFresh 重试；查询侧
            // （candidatePageIDsViaInvertedIndexLocked）见脏标即走 FTS/LIKE。
            try? setMetaValueLocked("bidx_dirty", "1")
            try? setMetaValueLocked("last_selfheal_reason", "\(reason)；重建失败: \(error)")
            try? setMetaValueLocked("last_selfheal_at", String(Int(Date().timeIntervalSince1970)))
            try? setMetaValueLocked("last_selfheal_ok", "0")
            FileHandle.standardError.write(Data("[IndexStore] 自愈重建失败（搜索退化为 FTS/LIKE）: \(error)\n".utf8))
            return
        }
        try setMetaValueLocked("last_selfheal_at", String(Int(Date().timeIntervalSince1970)))
        try setMetaValueLocked("last_selfheal_reason", reason)
        try setMetaValueLocked("last_selfheal_ok", "1")
        FileHandle.standardError.write(Data("[IndexStore] 索引自愈完成: \(reason)\n".utf8))
    }

    /// Explicit metadata edit/import. Only the INDEX is written; original files
    /// are never touched. nil fields leave existing values unchanged.
    public func updateMetadata(bookID: String, title: String?, author: String?, version: String?,
                               language: String?, source: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard try bookByIDLocked(bookID) != nil else { return false }
        let stmt = try db.prepare("""
        UPDATE books SET title=COALESCE(?,title), author=COALESCE(?,author), version=COALESCE(?,version),
                         language=COALESCE(?,language), meta_source=?
        WHERE id = ?;
        """)
        if let t = title { try stmt.bindText(1, t) } else { try stmt.bindNull(1) }
        if let a = author { try stmt.bindText(2, a) } else { try stmt.bindNull(2) }
        if let v = version { try stmt.bindText(3, v) } else { try stmt.bindNull(3) }
        if let l = language { try stmt.bindText(4, l) } else { try stmt.bindNull(4) }
        try stmt.bindText(5, source)
        try stmt.bindText(6, bookID)

        try db.exec("BEGIN IMMEDIATE;")
        do {
            try stmt.run()
            let changed = stmt.changes > 0   // 连接级计数，须在 INSERT 前捕获
            try deletePinyinRowLocked(bookID: bookID)
            let src = try db.prepare("SELECT file_name, title, author FROM books WHERE id = ?;")
            try src.bindText(1, bookID)
            var projectionSource = ""
            if try src.step() {
                projectionSource = [src.text(0), src.text(1), src.text(2)]
                    .filter { !$0.isEmpty }.joined(separator: " ")
            }
            let ins = try db.prepare("INSERT OR REPLACE INTO book_pinyin(book_id, pinyin_norm) VALUES(?, ?);")
            try ins.bindText(1, bookID)
            try ins.bindText(2, PinyinNorm.transform(projectionSource))
            try ins.run()
            try db.exec("COMMIT;")
            invalidateAllBooksCacheLocked()
            return changed
        } catch {
            db.tryExec("ROLLBACK;")
            throw error
        }
    }

    // MARK: Coverage statistics (indexed / no-text awaiting-OCR / error / ...)

    public struct CoverageStats: Equatable {
        public var booksOK: Int
        public var booksError: Int
        public var pages: Int
        public var pagesWithoutText: Int   // indexed but no extractable text; OCR is NOT performed
    }

    public func coverageStats() throws -> CoverageStats {
        lock.lock(); defer { lock.unlock() }
        var stats = CoverageStats(booksOK: 0, booksError: 0, pages: 0, pagesWithoutText: 0)
        let books = try db.prepare("SELECT status, COUNT(*) FROM books GROUP BY status;")
        while try books.step() {
            if books.text(0) == "error" { stats.booksError = Int(books.int(1)) }
            else { stats.booksOK += Int(books.int(1)) }
        }
        let pages = try db.prepare("SELECT COUNT(*) FROM pages;")
        if try pages.step() { stats.pages = Int(pages.int(0)) }
        let noText = try db.prepare("SELECT COUNT(*) FROM pages WHERE TRIM(text_norm) = '';")
        if try noText.step() { stats.pagesWithoutText = Int(noText.int(0)) }
        return stats
    }

    /// Per-book page statistics for honest coverage classification
    /// (full / partial / needs-ocr / unknown — see BookPageStat.coverage) and
    /// for zero-hit explanation. One row per book, including error books
    /// (indexedPages 0) via the LEFT JOIN.
    public func perBookPageStats() throws -> [BookPageStat] {
        lock.lock(); defer { lock.unlock() }
        if let cached = perBookPageStatsCache {
            return cached
        }
        var out: [BookPageStat] = []
        let stmt = try db.prepare("""
        SELECT b.id, b.status,
               COALESCE(pg.n, 0),
               COALESCE(tx.m, 0)
        FROM books b
        LEFT JOIN (SELECT book_id, COUNT(page_number) AS n
                     FROM \(ftQual)pages GROUP BY book_id) pg ON pg.book_id = b.id
        LEFT JOIN (SELECT book_id,
                          COALESCE(SUM(CASE WHEN TRIM(text_norm) = '' THEN 0 ELSE 1 END), 0) AS m
                     FROM \(ftQual)pages GROUP BY book_id) tx ON tx.book_id = b.id
        ORDER BY b.rel_path;
        """)
        while try stmt.step() {
            out.append(BookPageStat(bookID: stmt.text(0), status: stmt.text(1),
                                    indexedPages: Int(stmt.int(2)), pagesWithText: Int(stmt.int(3))))
        }
        perBookPageStatsCache = out
        return out
    }

    // MARK: - 页统计覆盖索引：按需补建

    /// 补建 `ft.idx_pages_stats` 的结果（刷新批收尾顺带建；面板一行显示）。
    public struct PageStatsIndexResult: Equatable, Sendable {
        public enum Outcome: String, Equatable, Sendable {
            case built
            /// 已存在——`CREATE INDEX IF NOT EXISTS` 判别，O(1)。
            case alreadyPresent
            /// 无处置建：pages 表尚不存在（空库），或只读副本句柄写不了。
            case skipped
            /// 建失败（message 带 SQLite 错误原文）。
            case failed
        }

        public let outcome: Outcome
        /// 失败原文（outcome == .failed 时非 nil）；其余为 nil。
        public let message: String?
        public let seconds: Double

        public var isFailure: Bool { outcome == .failed }
    }

    /// 补建页统计覆盖索引（**复用 `migrateSchemaV14` 的同一条 DDL 通道**，
    /// 不另写 SQL）。设计取舍：
    ///
    /// - 该索引是性能增益，不是任何结果的正确性前提；因此本方法永不抛出——失败只以 `.failed` 如实
    @discardableResult
    public func ensurePageStatsIndex() -> PageStatsIndexResult {
        lock.lock(); defer { lock.unlock() }
        let started = Date()
        func outcome(_ o: PageStatsIndexResult.Outcome, _ msg: String? = nil) -> PageStatsIndexResult {
            PageStatsIndexResult(outcome: o, message: msg,
                                 seconds: Date().timeIntervalSince(started))
        }
        if readOnlyReplica { return outcome(.skipped) }
        guard hasSqliteObjectLocked(type: "table", name: "pages") else { return outcome(.skipped) }
        if hasSqliteObjectLocked(type: "index", name: Self.pageStatsIndexName) {
            return outcome(.alreadyPresent)
        }
        let previous = allowPageStatsStatsIndex
        allowPageStatsStatsIndex = true
        defer { allowPageStatsStatsIndex = previous }
        do {
            try migrateSchemaV14()
        } catch {
            return outcome(.failed, String(describing: error))
        }
        guard hasSqliteObjectLocked(type: "index", name: Self.pageStatsIndexName) else {
            return outcome(.failed, "CREATE INDEX 未报错但索引仍不存在")
        }
        return outcome(.built)
    }

    /// 页统计覆盖索引名（收尾建索引的探测与 DDL 目标同名；DDL 本体在
    /// migrateSchemaV14）。
    public static let pageStatsIndexName = "idx_pages_stats"

    // MARK: Meta

    public var storedNormalizationVersion: Int? {
        lock.lock(); defer { lock.unlock() }
        guard let str = try? metaValueLocked("normalization_version") else { return nil }
        return Int(str)
    }

    public var isNormalizationVersionValid: Bool {
        lock.lock(); defer { lock.unlock() }
        return isNormalizationVersionValidLocked()
    }

    private func isNormalizationVersionValidLocked() -> Bool {
        guard let str = try? metaValueLocked("normalization_version"), let v = Int(str) else { return false }
        return v == Self.expectedNormalizationVersion
    }

    public func setNormalizationVersion(_ version: Int? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        try setMetaValueLocked("normalization_version", String(version ?? Self.expectedNormalizationVersion))
    }

    public func metaValue(_ key: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return try metaValueLocked(key)
    }

    public func setMetaValue(_ key: String, _ value: String) throws {
        lock.lock(); defer { lock.unlock() }
        try setMetaValueLocked(key, value)
    }

    func metaValueLocked(_ key: String) throws -> String? {
        let stmt = try db.prepare("SELECT value FROM meta WHERE key = ?;")
        try stmt.bindText(1, key)
        defer { stmt.reset() }
        if try stmt.step() { return stmt.textOrNull(0) }
        return nil
    }

    func setMetaValueLocked(_ key: String, _ value: String) throws {
        // 只读纪律的关键一句：只读副本句柄上一切 meta 写（qc:/qt:
        // 查询级缓存、quickcheck 节流、search_mode 记录等）就地变 no-op，
        // 不抛错（检索路径调用点多带 try?，抛错反而破坏结果；放弃的只是
        // 缓存与记录——重复查询速度略降，结果零影响）。这句在即只读连接
        // 上永远不会真正写库。
        guard !readOnlyReplica else { return }
        let stmt = try db.prepare("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;")
        try stmt.bindText(1, key)
        try stmt.bindText(2, value)
        try stmt.run()
    }

    // MARK: Query candidate cache (persisted; latency slice)
    //
    // A 2-char CJK term cannot use the trigram index (3-gram minimum) and falls
    // back to a full LIKE scan of the pages btree — seconds on multi-GB
    // libraries. The INTERSECTED candidate row-id set for a normalized query is
    // cached in the meta namespace and reused verbatim; ANY write that can
    // change page content purges the whole namespace (writes are rare, purge is
    // one DELETE).

    private static let queryCachePrefix = "qc:"

    public func cachedCandidateRowIDs(normalizedQuery: String) throws -> [String]? {
        lock.lock(); defer { lock.unlock() }
        guard let raw = try metaValueLocked(Self.queryCachePrefix + normalizedQuery),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    public func storeCandidateRowIDsCache(normalizedQuery: String, rowIDs: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(rowIDs),
              let json = String(data: data, encoding: .utf8) else { return }
        try setMetaValueLocked(Self.queryCachePrefix + normalizedQuery, json)
    }

    public func purgeQueryCaches() throws {
        lock.lock(); defer { lock.unlock() }
        try purgeQueryCachesLocked()
    }

    /// All page row-ids of one book — cheap scoping for book-filtered searches:
    /// intersecting the (cached) query candidates with this set before loading
    /// page rows avoids materializing the whole library for one book's view.
    public func candidateRowIDs(bookID: String) throws -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("SELECT rowid FROM pages WHERE book_id = ?;")
        try stmt.bindText(1, bookID)
        var out = Set<String>()
        while try stmt.step() {
            out.insert(stmt.text(0))
        }
        return out
    }

    /// Caller must hold the lock. internal（migrations 扩展搬迁收尾复用；
    /// 跨文件 extension 同层封装先例）。
    func purgeQueryCachesLocked() throws {
        try db.exec("DELETE FROM meta WHERE key LIKE 'qc:%';")
        try db.exec("DELETE FROM meta WHERE key LIKE 'qt:%';")
        // Any content write invalidates the bigram inverted index; the next
        // ensureBigramIndexFresh (post-batch) rebuilds it once.
        try setMetaValueLocked("bidx_dirty", "1")
        invalidateRowidToBookIDCacheLocked()
        invalidateAllBooksCacheLocked()
        invalidatePerBookPageStatsCacheLocked()
    }

    // MARK: Books

    public func book(byRealPath realPath: String) throws -> BookRow? {
        lock.lock(); defer { lock.unlock() }
        return try bookByRealPathLocked(realPath)
    }

    public func book(byID id: String) throws -> BookRow? {
        lock.lock(); defer { lock.unlock() }
        return try bookByIDLocked(id)
    }

    public func allBooks() throws -> [BookRow] {
        lock.lock(); defer { lock.unlock() }
        return try allBooksLocked()
    }

    /// Caller must hold `lock`（allBooks 的无锁内核；供持锁上下文复用，
    /// 如 allBooksCached——公有 allBooks 不可重入）。
    private func allBooksLocked() throws -> [BookRow] {
        let stmt = try db.prepare("SELECT id, real_path, root_path, rel_path, file_name, title, author, version, language, meta_source, first_fingerprint, fingerprint, file_size, mtime, page_count, status, error, indexed_at, content_category FROM books ORDER BY rel_path;")
        var rows: [BookRow] = []
        while try stmt.step() { rows.append(bookRow(from: stmt)) }
        return rows
    }

    public func upsertBook(_ row: BookRow) throws {
        lock.lock(); defer { lock.unlock() }
        try writeIndexLocked { try upsertBookLocked(row) }
    }

    func saveIndexedBook(_ row: BookRow, pages: [PageRow]) throws {
        lock.lock(); defer { lock.unlock() }
        try writeIndexLocked {
            if let existing = try bookByIDLocked(row.id), existing.realPath != row.realPath {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: row.realPath])
            }
            try upsertBookLocked(row)
            try replacePagesLocked(bookID: row.id, pages)
        }
    }

    private func writeIndexLocked(_ write: () throws -> Void) throws {
        try db.exec("BEGIN IMMEDIATE;")
        do {
            try write()
            try purgeQueryCachesLocked()
            try db.exec("COMMIT;")
        } catch {
            db.tryExec("ROLLBACK;")
            throw error
        }
    }

    private func upsertBookLocked(_ row: BookRow) throws {
        let stmt = try db.prepare("""
        INSERT INTO books(id, real_path, root_path, rel_path, file_name, title, author, version, language, meta_source,
                          first_fingerprint, fingerprint, file_size, mtime, page_count, status, error, indexed_at,
                          content_category)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            real_path=excluded.real_path, root_path=excluded.root_path, rel_path=excluded.rel_path,
            file_name=excluded.file_name, fingerprint=excluded.fingerprint, file_size=excluded.file_size,
            mtime=excluded.mtime, page_count=excluded.page_count, status=excluded.status,
            error=excluded.error, indexed_at=excluded.indexed_at,
            content_category=excluded.content_category;
        """)
        try bindBook(stmt, row)
        try stmt.bindText(19, classifyContentCategory(path: row.realPath,
                                                       title: row.title ?? ""))
        try stmt.run()
        try deletePinyinRowLocked(bookID: row.id)
        let src = try db.prepare("SELECT file_name, title, author FROM books WHERE id = ?;")
        try src.bindText(1, row.id)
        var projectionSource = ""
        if try src.step() {
            projectionSource = [src.text(0), src.text(1), src.text(2)]
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
        let ins = try db.prepare("INSERT OR REPLACE INTO book_pinyin(book_id, pinyin_norm) VALUES(?, ?);")
        try ins.bindText(1, row.id)
        try ins.bindText(2, PinyinNorm.transform(projectionSource))
        try ins.run()
    }

    public func deleteBook(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        try deleteBookLocked(id: id)
        try purgeQueryCachesLocked()
    }

    // MARK: Pages

    /// Replaces all pages of a book atomically (single transaction) and keeps FTS in sync.
    ///
    /// Any native re-index replaces the exact content the OCR pairing was
    /// verified against, so the OCR registration is dropped here and must be
    /// re-imported against the new fingerprint. Recreated page rows are
    /// 'native' by default — OCR text never survives a re-index stale.
    public func replacePages(bookID: String, _ pages: [PageRow]) throws {
        lock.lock(); defer { lock.unlock() }
        try writeIndexLocked { try replacePagesLocked(bookID: bookID, pages) }
    }

    private func replacePagesLocked(bookID: String, _ pages: [PageRow]) throws {
        if searchMode == .fts5Trigram {
            let del = try db.prepare("DELETE FROM pages_fts WHERE rowid IN (SELECT rowid FROM pages WHERE book_id = ?);")
            try del.bindText(1, bookID)
            try del.run()
        }
        let delOCR = try db.prepare("DELETE FROM ocr_books WHERE book_id = ?;")
        try delOCR.bindText(1, bookID)
        try delOCR.run()
        let delPages = try db.prepare("DELETE FROM pages WHERE book_id = ?;")
        try delPages.bindText(1, bookID)
        try delPages.run()

        let ins = try db.prepare("""
        INSERT INTO pages(book_id, page_number, label, printed_page, text_original, text_norm, norm_starts, norm_ends, text_latin)
        VALUES(?,?,?,?,?,?,?,?,?);
        """)
        let insFTS = searchMode == .fts5Trigram ? try db.prepare("INSERT INTO pages_fts(rowid, text_bigram) VALUES(?, ?);") : nil
        for page in pages {
            ins.reset(); ins.clearBindings()
            try ins.bindText(1, bookID)
            try ins.bindInt(2, Int64(page.pageNumber))
            if let label = page.label { try ins.bindText(3, label) } else { try ins.bindNull(3) }
            if let printed = page.printedPage { try ins.bindInt(4, Int64(printed)) } else { try ins.bindNull(4) }
            try ins.bindText(5, page.textOriginal)
            try ins.bindText(6, page.textNorm)
            try ins.bindBlob(7, int32ArrayData(page.normStarts))
            try ins.bindBlob(8, int32ArrayData(page.normEnds))
            try ins.bindText(9, LatinProjection.transform(page.textNorm))
            try ins.run()
            if let insFTS {
                insFTS.reset(); insFTS.clearBindings()
                try insFTS.bindInt(1, ins.lastInsertRowid)
                try insFTS.bindText(2, Self.bigramize(page.textNorm))
                try insFTS.run()
            }
        }
        let count = try db.prepare("SELECT COUNT(*) FROM pages WHERE book_id = ?;")
        try count.bindText(1, bookID)
        var total = 0
        if try count.step() { total = Int(count.int(0)) }
        let upd = try db.prepare("UPDATE books SET page_count = ? WHERE id = ?;")
        try upd.bindInt(1, Int64(total))
        try upd.bindText(2, bookID)
        try upd.run()
    }

    public func pageCount(bookID: String) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        return try pageCountLocked(bookID: bookID)
    }

    public func page(bookID: String, pageNumber: Int) throws -> PageRow? {
        lock.lock(); defer { lock.unlock() }
        guard pageNumber >= 1 else { return nil }
        return try pageLocked(bookID: bookID, pageNumber: pageNumber)
    }

    /// Candidate pages whose normalized text contains the given normalized term.
    /// Uses FTS5 trigram MATCH when the term is >= 3 chars and FTS mode is active;
    /// otherwise (and as an automatic fallback) an escaped SQL LIKE scan.
    public func candidatePageIDs(term: String) throws -> [String] {
        // Term-level cache:  a 2-char CJK term's LIKE fallback scans
        // the whole pages btree (~seconds); caching per-term rowids makes
        // repeated terms (the dominant query vocabulary) millisecond-fast.
        // Purged with the query cache on any content write.
        lock.lock(); defer { lock.unlock() }
        if let cached = try cachedTermRowIDsLocked(term) { return cached }
        let ids: [String]
        if searchMode == .fts5Trigram, term.count >= 2 {
            // 首选自建倒排表（bigram AND 交集 2.6ms 级）；FTS5 MATCH 对高频
            // bigram 冷查询 23.5s，仅作倒排表缺失时的退化路径。
            let chars = Array(term)
            guard chars.count >= 2 else {
                ids = try candidatePagesLike(term: term)
                if !ids.isEmpty { try storeTermRowIDsCacheLocked(term, ids) }
                return ids
            }
            var grams: [String] = []
            for i in 0..<(chars.count - 1) { grams.append(String(chars[i]) + String(chars[i + 1])) }
            if let viaIndex = try candidatePageIDsViaInvertedIndexLocked(bigrams: grams) {
                ids = viaIndex
            } else {
                do { ids = try candidatePagesFTS(term: term) }
                catch { ids = try candidatePagesLike(term: term) }
            }
        } else {
            ids = try candidatePagesLike(term: term)
        }
        if !ids.isEmpty {
            try storeTermRowIDsCacheLocked(term, ids)
        }
        return ids
    }

    // MARK: Term candidate cache (per-term rowids; purged on content writes)

    private func cachedTermRowIDsLocked(_ term: String) throws -> [String]? {
        guard let raw = try metaValueLocked("qt:" + term),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    private func storeTermRowIDsCacheLocked(_ term: String, _ rowIDs: [String]) throws {
        guard let data = try? JSONEncoder().encode(rowIDs),
              let json = String(data: data, encoding: .utf8) else { return }
        try setMetaValueLocked("qt:" + term, json)
    }

    /// 英文短词快路：高频 bigram 词直接走 FTS5 AND 交集一次
    /// SQL 出 per-book 计数（亚秒级），绕过海量 rowid 字符串化+temp 灌装
    /// （57s）。语义=与 bigram 交集同候选集（unicode61 词法=bigram token 集
    public func candidateBookCountsViaFTS(term: String) throws -> [String: Int]? {
        lock.lock(); defer { lock.unlock() }
        let built = (try? metaValueLocked("bidx_built_at")) != nil
        let dirty = (try? metaValueLocked("bidx_dirty")) == "1"
        if ProcessInfo.processInfo.environment["LITERATURESEARCH_SEARCH_TRACE"] == "1" {
            FileHandle.standardError.write(Data("[fastpath] term=\(term) built=\(built) dirty=\(dirty) mode=\(searchMode.rawValue)\n".utf8))
        }
        guard built, !dirty, searchMode == .fts5Trigram, term.count >= 2,
              term.allSatisfy({ $0.isASCII }) else { return nil }
        let chars = Array(term)
        guard chars.count >= 2 else { return nil }
        var grams: [String] = []
        for i in 0..<(chars.count - 1) { grams.append(String(chars[i]) + String(chars[i + 1])) }
        var totalBytes = 0
        let sel = try db.prepare("SELECT length(rowids) FROM bigram_index WHERE bigram = ?;")
        for g in grams {
            sel.reset(); sel.clearBindings()
            try sel.bindText(1, g)
            guard try sel.step() else { return [:] }
            totalBytes += Int(sel.int(0))
        }
        guard totalBytes > 2_000_000 else { return nil }
        let ftsQuery = grams.joined(separator: " AND ")
        let stmt = try db.prepare("SELECT p.book_id, COUNT(*) FROM pages p JOIN pages_fts f ON f.rowid = p.rowid WHERE pages_fts MATCH ? GROUP BY p.book_id;")
        stmt.reset(); stmt.clearBindings()
        try stmt.bindText(1, ftsQuery)
        var out: [String: Int] = [:]
        while try stmt.step() { out[stmt.text(0)] = Int(stmt.int(1)) }
        return out
    }

    /// 英文高频词检索确定性快路预筛：返回该词的候选页 rowid 有序数组（[Int64]，严格单调递增），
    /// 走 FTS5 AND 交集（~0.08s）。仅当：索引已建未脏、mode=fts5Trigram、
    /// 词全 ASCII 且 ≥2 字符、各 bigram 在 bigram_index 的 blob 总量超 2MB（高频词才值得绕）。
    /// 不满足任一条件返回 nil=调用方回落常规路径。
    public func candidateRowIDsViaFTS(term: String) throws -> [Int64]? {
        lock.lock(); defer { lock.unlock() }
        let built = (try? metaValueLocked("bidx_built_at")) != nil
        let dirty = (try? metaValueLocked("bidx_dirty")) == "1"
        guard built, !dirty, searchMode == .fts5Trigram, term.count >= 2,
              term.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        let chars = Array(term)
        guard chars.count >= 2 else { return nil }
        var grams: [String] = []
        for i in 0..<(chars.count - 1) { grams.append(String(chars[i]) + String(chars[i + 1])) }
        var totalBytes = 0
        let sel = try db.prepare("SELECT length(rowids) FROM bigram_index WHERE bigram = ?;")
        for g in grams {
            sel.reset(); sel.clearBindings()
            try sel.bindText(1, g)
            guard try sel.step() else { return [] }
            totalBytes += Int(sel.int(0))
        }
        guard totalBytes > 2_000_000 else { return nil }
        let ftsQuery = grams.joined(separator: " AND ")
        // 【为何与既有 CLI 输出逐字节等价·候选全集】：任何包含 term 的页面必然包含其全部 bigram，
        // FTS5 MATCH 产出的候选集真阳性覆盖率 100%，假阴性（False Negative）严格为 0。
        // ORDER BY rowid ASC 保证输出流单调递增，消除 Swift 运行时 String 哈希随机化，
        // 直出有序 [Int64] 承接，与 SQLite 物理行升序严格同构。
        let ftsSel = try db.prepare("SELECT rowid FROM pages_fts WHERE pages_fts MATCH ? ORDER BY rowid ASC;")
        ftsSel.reset(); ftsSel.clearBindings()
        try ftsSel.bindText(1, ftsQuery)
        var out: [Int64] = []
        while try ftsSel.step() { out.append(ftsSel.int(0)) }
        return out
    }


    // MARK: - In-Memory Cache

    private var rowidToBookIDCache: [Int64: String]? = nil
    private var allBooksCache: [String: BookRow]? = nil

    func invalidateRowidToBookIDCacheLocked() {
        rowidToBookIDCache = nil
    }

    func invalidateAllBooksCacheLocked() {
        allBooksCache = nil
    }

    /// 全书页统计缓存（perBookPageStats 结果；失效点与上两件同款）。
    private var perBookPageStatsCache: [BookPageStat]? = nil

    func invalidatePerBookPageStatsCacheLocked() {
        perBookPageStatsCache = nil
    }

    /// 扩级 private → internal（LatinProjection.swift 的词路计数包装
    /// rowidToBookIDMappingCached 复用； 搬移批同款扩级先例，
    /// 行为零变化）。
    /// Caller must hold the lock.
    func ensureRowidToBookIDMappingLocked() throws -> [Int64: String] {
        if let cached = rowidToBookIDCache {
            return cached
        }
        let stmt = try db.prepare("SELECT rowid, book_id FROM pages;")
        var map: [Int64: String] = [:]
        while try stmt.step() {
            map[stmt.int(0)] = stmt.text(1)
        }
        rowidToBookIDCache = map
        return map
    }

    public func allBooksCached() throws -> [String: BookRow] {
        lock.lock(); defer { lock.unlock() }
        if let cached = allBooksCache { return cached }
        // 修订：此处持锁中，禁止再调公有的 allBooks
        // （其内部自取同一把非递归锁 ⇒ 自死锁；ClassificationRules.swift
        // 对该约束早有记载）。改走调用方须持锁的 allBooksLocked。
        let books = try allBooksLocked()
        var dict: [String: BookRow] = [:]
        dict.reserveCapacity(books.count)
        for b in books { dict[b.id] = b }
        allBooksCache = dict
        return dict
    }

    /// Aggregate per-book matching-page counts for the given page row-ids.
    /// 内存映射快查：常驻 `rowid -> bookID` 紧凑字典，避免候选集上的
    /// TEMP 表建表、写入与低效 JOIN。
    public func matchingPageCounts(rowIDs: [String]) throws -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        guard !rowIDs.isEmpty else { return [:] }
        let mapping = try ensureRowidToBookIDMappingLocked()
        var counts: [String: Int] = [:]
        counts.reserveCapacity(min(rowIDs.count, 4096))
        var seen = Set<Int64>()
        for raw in rowIDs {
            guard let id = Int64(raw), seen.insert(id).inserted, let bid = mapping[id] else { continue }
            counts[bid, default: 0] += 1
        }
        return counts
    }

    /// Count of pages whose text layer came from the ORIGINAL pdf (source
    /// 'native' — never OCR-sourced). Drives version-group primary choice:
    /// the variant with the most native text is the best representative.
    public func nativeTextPageCount(bookID: String) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("SELECT COUNT(*) FROM pages WHERE book_id=? AND source='native';")
        try stmt.bindText(1, bookID)
        guard try stmt.step() else { return 0 }
        return Int(stmt.int(0))
    }

    /// Native text-page counts for EVERY book in one GROUP BY pass. Replaces
    /// the per-book `nativeTextPageCount` loop in book-level search (one query
     /// instead of one per book — repeated queries add avoidable latency).
    public func nativeTextPageCountsByBook() throws -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        // 提速：聚合结果预存 book_native_counts 影子表（批末刷新），
        // 查询时 O(书数) 直读，免每次全 pages 表扫描。
        // 影子表随 pages 迁 ft——必须显式 ft. 限定（未限定 CREATE
        // 恒落 main，分离后会把影子建成 main 侧空表；legacy 形态 ftQual=""）。
        _ = try? db.exec("CREATE TABLE IF NOT EXISTS \(ftQual)book_native_counts(book_id TEXT PRIMARY KEY, native_count INTEGER NOT NULL) WITHOUT ROWID;")
        var out: [String: Int] = [:]
        let stmt = try db.prepare("SELECT book_id, native_count FROM \(ftQual)book_native_counts;")
        while try stmt.step() { out[stmt.text(0)] = Int(stmt.int(1)) }
        guard !out.isEmpty else {
            // 首次（影子未建）：现算一次并落影子。
            let full = try db.prepare("SELECT book_id, COUNT(*) FROM pages WHERE source='native' GROUP BY book_id;")
            var fresh: [String: Int] = [:]
            while try full.step() { fresh[full.text(0)] = Int(full.int(1)) }
            try db.exec("BEGIN IMMEDIATE;")
            let ins = try db.prepare("INSERT OR REPLACE INTO \(ftQual)book_native_counts VALUES(?,?);")
            for (k, v) in fresh {
                ins.reset(); ins.clearBindings()
                try ins.bindText(1, k); try ins.bindInt(2, Int64(v)); try ins.run()
            }
            try db.exec("COMMIT;")
            return fresh
        }
        return out
    }

    /// 批末刷新影子聚合（索引/导入后调用；删档同步删行）。
    public func refreshBookNativeCounts() throws {
        lock.lock(); defer { lock.unlock() }
        // 影子表随 pages 迁 ft（ft. 限定理由见 nativeTextPageCountsByBook）。
        _ = try? db.exec("CREATE TABLE IF NOT EXISTS \(ftQual)book_native_counts(book_id TEXT PRIMARY KEY, native_count INTEGER NOT NULL) WITHOUT ROWID;")
        try db.exec("DELETE FROM \(ftQual)book_native_counts;")
        try db.exec("INSERT INTO \(ftQual)book_native_counts(book_id, native_count) SELECT book_id, COUNT(*) FROM pages WHERE source='native' GROUP BY book_id;")
    }

    public func pages(rowIDs: [String]) throws -> [PageRow] {
        guard !rowIDs.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }

        var byRowID: [Int64: PageRow] = [:]
        var uniqueIDs: [Int64] = []
        var seen = Set<Int64>()
        for raw in rowIDs {
            if let id = Int64(raw), seen.insert(id).inserted {
                uniqueIDs.append(id)
            }
        }
        guard !uniqueIDs.isEmpty else { return [] }

        let chunkSize = 500
        var start = 0
        while start < uniqueIDs.count {
            let end = min(start + chunkSize, uniqueIDs.count)
            let chunk = uniqueIDs[start..<end]
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let stmt = try db.prepare("""
            SELECT p.book_id, p.page_number, p.label, p.printed_page, p.text_original, p.text_norm, p.norm_starts, p.norm_ends, p.rowid
            FROM pages p WHERE p.rowid IN (\(placeholders));
            """)
            for (i, id) in chunk.enumerated() {
                try stmt.bindInt(Int32(i + 1), id)
            }
            while try stmt.step() {
                let rowID = stmt.int(8)
                byRowID[rowID] = pageRow(from: stmt)
            }
            start = end
        }

        var out: [PageRow] = []
        out.reserveCapacity(rowIDs.count)
        for raw in rowIDs {
            if let id = Int64(raw), let row = byRowID[id] {
                out.append(row)
            }
        }
        return out
    }

    public struct LightPageRow: Sendable {
        public let rowID: Int64
        public let bookID: String
        public let pageNumber: Int
        public let label: String?
        public let printedPage: Int?
        public let textNorm: String

        public init(rowID: Int64, bookID: String, pageNumber: Int, label: String?, printedPage: Int?, textNorm: String) {
            self.rowID = rowID
            self.bookID = bookID
            self.pageNumber = pageNumber
            self.label = label
            self.printedPage = printedPage
            self.textNorm = textNorm
        }
    }

    /// Lightweight page projection for first-stage candidate verification and counting .
    /// Excludes `text_original`, `norm_starts` and `norm_ends` blobs to avoid heavy I/O
    /// and allocation amplification when scanning large candidate sets.
    public func lightPages(rowIDs: [String]) throws -> [LightPageRow] {
        guard !rowIDs.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }

        var byRowID: [Int64: LightPageRow] = [:]
        var uniqueIDs: [Int64] = []
        var seen = Set<Int64>()
        for raw in rowIDs {
            if let id = Int64(raw), seen.insert(id).inserted {
                uniqueIDs.append(id)
            }
        }
        guard !uniqueIDs.isEmpty else { return [] }

        let chunkSize = 500
        var start = 0
        while start < uniqueIDs.count {
            let end = min(start + chunkSize, uniqueIDs.count)
            let chunk = uniqueIDs[start..<end]
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let stmt = try db.prepare("""
            SELECT p.book_id, p.page_number, p.label, p.printed_page, p.text_norm, p.rowid
            FROM pages p WHERE p.rowid IN (\(placeholders));
            """)
            for (i, id) in chunk.enumerated() {
                try stmt.bindInt(Int32(i + 1), id)
            }
            while try stmt.step() {
                let rowID = stmt.int(5)
                byRowID[rowID] = LightPageRow(
                    rowID: rowID,
                    bookID: stmt.text(0),
                    pageNumber: Int(stmt.int(1)),
                    label: stmt.textOrNull(2),
                    printedPage: stmt.intOrNull(3).map(Int.init),
                    textNorm: stmt.text(4)
                )
            }
            start = end
        }

        var out: [LightPageRow] = []
        out.reserveCapacity(rowIDs.count)
        for raw in rowIDs {
            if let id = Int64(raw), let row = byRowID[id] {
                out.append(row)
            }
        }
        return out
    }

    /// 阶段一下推物化（确定性快路专用）
    /// 利用 TEMP 表 + SQLite C 层 `p.text_norm LIKE ? ESCAPE '\'` 谓词下推，
    /// 将 80%+ 的假候选在 SQLite 遍历 B 树记录时直接短路淘汰；
    /// Swift 侧仅接收确认命中的轻量元数据行（零 textNorm 跨桥复制与堆分配），
    /// 且输出严格按 `c.id ASC`（rowid ASC）单调递增，保证输出确定性与页级契约同构。
    public func lightPagesFiltered(rowIDs: [Int64], term: String) throws -> [LightPageRow] {
        guard !rowIDs.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }

        // 确定性命中行序的唯一来源＝输入 rowid 升序。先按序去重（相邻等值
        // 折叠，O(n)）：临时表主键与输出 ORDER BY c.id ASC 在去重后与旧
        // `INSERT OR IGNORE` 的集合语义完全一致。
        var uniqueRowIDs: [Int64] = []
        uniqueRowIDs.reserveCapacity(rowIDs.count)
        var previous: Int64?
        for id in rowIDs where id != previous {
            uniqueRowIDs.append(id)
            previous = id
        }

        // 确定性不变量（补证）：灌装输入必须按 rowid 非降——
        // 来源链＝上游 candidateRowIDsViaFTS 的 `ORDER BY rowid ASC`（严格
        // 单调契约）＋本函数书域 filter 保序（Array.filter 依序保留元素）；
        // 输出序终由 `ORDER BY c.id ASC` 锁定。断言仅 debug 编译，release
        // 零开销。
        #if DEBUG
        var prev = Int64.min
        for id in uniqueRowIDs {
            assert(id >= prev, "temp_candidates 灌装输入必须按 rowid 非降（有序契约被破坏）")
            prev = id
        }
        #endif

        let workerCount = min(Self.materializeMaxWorkers,
                              max(2, ProcessInfo.processInfo.activeProcessorCount),
                              uniqueRowIDs.count)
        if uniqueRowIDs.count >= Self.materializeParallelThreshold, workerCount >= 2 {
            let mainPath = db.path
            let ftPath = fulltextAttached ? fulltextURL : nil
            let ftAttached = fulltextAttached
            let termCopy = term
            let shardCount = workerCount
            let base = uniqueRowIDs.count / shardCount
            let remainder = uniqueRowIDs.count % shardCount
            var bounds: [(Int, Int)] = []
            bounds.reserveCapacity(shardCount)
            var cursor = 0
            for i in 0..<shardCount {
                let size = base + (i < remainder ? 1 : 0)
                bounds.append((cursor, cursor + size))
                cursor += size
            }
            // 每片独占自己的槽位（行或错误），并发写互不相交，无共享读改写。
            struct ShardOutcome {
                var rows: [LightPageRow] = []
                var error: Error?
            }
            let slots = UnsafeMutablePointer<ShardOutcome>.allocate(capacity: shardCount)
            slots.initialize(repeating: ShardOutcome(), count: shardCount)
            defer {
                slots.deinitialize(count: shardCount)
                slots.deallocate()
            }
            DispatchQueue.concurrentPerform(iterations: shardCount) { i in
                let slice = Array(uniqueRowIDs[bounds[i].0..<bounds[i].1])
                do {
                    slots[i].rows = try Self.materializeShard(
                        mainPath: mainPath, fulltextPath: ftPath,
                        fulltextAttached: ftAttached,
                        rowIDs: slice, term: termCopy)
                } catch {
                    slots[i].error = error
                }
            }
            var merged: [LightPageRow] = []
            merged.reserveCapacity(uniqueRowIDs.count)
            for i in 0..<shardCount {
                if let error = slots[i].error { throw error }
                merged.append(contentsOf: slots[i].rows)
            }
            return merged
        }

        // 1. 确保并重置临时表
        try db.exec("CREATE TEMP TABLE IF NOT EXISTS temp_candidates(id INTEGER PRIMARY KEY) WITHOUT ROWID;")
        try db.exec("DELETE FROM temp_candidates;")

        // 2. 批量将有序 rowids 灌入 temp_candidates
        do {
            try db.exec("BEGIN TRANSACTION;")
            let ins = try db.prepare("INSERT OR IGNORE INTO temp_candidates(id) VALUES (?);")
            for id in uniqueRowIDs {
                ins.reset()
                try ins.bindInt(1, id)
                try ins.run()
            }
            try db.exec("COMMIT;")
        } catch {
            _ = db.tryExec("ROLLBACK;")
            throw error
        }

        // 3. 执行下推校验查询：
        // 【为何与既有 CLI 输出逐字节等价·充要条件判定】：
        // term 已小写规范化；SQLite 内置 LIKE 在 ESCAPE '\\' 下执行标准字节子串扫描，
        // 与 Swift 侧 Self.firstRange 在输入输出域上完全同构。
        // ORDER BY c.id ASC 确保流式输出的 rowid 序列与 orderedRowIDs 升序严格 100% 同构。
        let escapedTerm = escapeForLike(term)
        let pattern = "%\(escapedTerm)%"
        // 拼音检索候选裁剪：INNER JOIN 可能让 SQLite 先扫描 pages，
        // 再逐项查找 temp_candidates，使大型库上的候选物化明显变慢。
        // CROSS JOIN 固定为先扫描 temp_candidates（候选集），再按 rowid
        // 精确查找 pages。ON 子句仍是相同的 rowid 等值条件，结果集不变；
        // ORDER BY c.id ASC 与 candidateRowIDsViaFTS 的 rowid 升序契约不变。
        let stmt = try db.prepare("""
        SELECT p.rowid, p.book_id, p.page_number, p.label, p.printed_page
        FROM temp_candidates c
        CROSS JOIN pages p ON p.rowid = c.id
        WHERE p.text_norm LIKE ? ESCAPE '\\'
        ORDER BY c.id ASC;
        """)
        try stmt.bindText(1, pattern)
        defer { stmt.reset() }

        var out: [LightPageRow] = []
        out.reserveCapacity(min(rowIDs.count, 32768))
        while try stmt.step() {
            out.append(LightPageRow(
                rowID: stmt.int(0),
                bookID: stmt.text(1),
                pageNumber: Int(stmt.int(2)),
                label: stmt.textOrNull(3),
                printedPage: stmt.intOrNull(4).map(Int.init),
                textNorm: "" // SQLite C 层已完成 LIKE 过滤，空串杜绝长文本跨 C-Swift 桥无谓复制
            ))
        }
        return out
    }

    static let materializeParallelThreshold = 8_000
    static let materializeMaxWorkers = 8

    private static func materializeShard(mainPath: String, fulltextPath: URL?,
                                         fulltextAttached: Bool,
                                         rowIDs: [Int64], term: String) throws -> [LightPageRow] {
        guard !rowIDs.isEmpty else { return [] }
        let worker = try SQLiteDatabase(path: mainPath, flags: SQLiteDatabase.readOnlyFlags)
        try worker.exec("PRAGMA foreign_keys=ON;")
        try worker.exec("PRAGMA mmap_size=268435456;")
        try worker.exec("PRAGMA cache_size=-16384;")
        let pagesTable: String
        if fulltextAttached, let ft = fulltextPath {
            let attach = try worker.prepare("ATTACH DATABASE ? AS ft;")
            try attach.bindText(1, ft.path)
            try attach.run()
            attach.reset()
            pagesTable = "ft.pages"
        } else {
            pagesTable = "pages"
        }
        try worker.exec("CREATE TEMP TABLE temp_candidates(id INTEGER PRIMARY KEY) WITHOUT ROWID;")
        do {
            try worker.exec("BEGIN TRANSACTION;")
            let ins = try worker.prepare("INSERT OR IGNORE INTO temp_candidates(id) VALUES (?);")
            for id in rowIDs {
                ins.reset()
                try ins.bindInt(1, id)
                try ins.run()
            }
            try worker.exec("COMMIT;")
        } catch {
            _ = worker.tryExec("ROLLBACK;")
            throw error
        }
        let pattern = "%\(escapeForLike(term))%"
        let stmt = try worker.prepare("""
        SELECT p.rowid, p.book_id, p.page_number, p.label, p.printed_page
        FROM temp_candidates c
        CROSS JOIN \(pagesTable) p ON p.rowid = c.id
        WHERE p.text_norm LIKE ? ESCAPE '\\'
        ORDER BY c.id ASC;
        """)
        try stmt.bindText(1, pattern)
        defer { stmt.reset() }
        var out: [LightPageRow] = []
        out.reserveCapacity(min(rowIDs.count, 32768))
        while try stmt.step() {
            out.append(LightPageRow(
                rowID: stmt.int(0),
                bookID: stmt.text(1),
                pageNumber: Int(stmt.int(2)),
                label: stmt.textOrNull(3),
                printedPage: stmt.intOrNull(4).map(Int.init),
                textNorm: ""))
        }
        return out
    }

    public func ocrBook(bookID: String) throws -> OCRBookRow? {
        lock.lock(); defer { lock.unlock() }
        return try ocrBookLocked(bookID)
    }

    public func ocrBookByOCRRealPath(_ realPath: String) throws -> OCRBookRow? {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("SELECT book_id, ocr_real_path, ocr_fingerprint, mapping_kind, created_at FROM ocr_books WHERE ocr_real_path = ?;")
        try stmt.bindText(1, realPath)
        defer { stmt.reset() }
        if try stmt.step() { return ocrBookRow(from: stmt) }
        return nil
    }

    public func allOCRBooks() throws -> [OCRBookRow] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("SELECT book_id, ocr_real_path, ocr_fingerprint, mapping_kind, created_at FROM ocr_books ORDER BY book_id;")
        var rows: [OCRBookRow] = []
        while try stmt.step() { rows.append(ocrBookRow(from: stmt)) }
        return rows
    }

    public func deleteOCRBook(bookID: String) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("DELETE FROM ocr_books WHERE book_id = ?;")
        try stmt.bindText(1, bookID)
        try stmt.run()
    }

    /// Pairing info for search/UI: the OCR file identity, the page mapping and
    /// which original pages currently carry OCR-derived text.
    public func ocrPairing(bookID: String) throws -> OCRPairingInfo? {
        lock.lock(); defer { lock.unlock() }
        guard let row = try ocrBookLocked(bookID) else { return nil }
        var map: [Int: Int] = [:]
        let m = try db.prepare("SELECT original_page, ocr_page FROM ocr_pages WHERE book_id = ? ORDER BY original_page;")
        try m.bindText(1, bookID)
        while try m.step() { map[Int(m.int(0))] = Int(m.int(1)) }
        var sourced = Set<Int>()
        let s = try db.prepare("SELECT page_number FROM pages WHERE book_id = ? AND source = 'ocr';")
        try s.bindText(1, bookID)
        while try s.step() { sourced.insert(Int(s.int(0))) }
        return OCRPairingInfo(ocrRealPath: row.ocrRealPath, ocrFingerprint: row.ocrFingerprint,
                              mappingKind: row.mappingKind, ocrPages: map, ocrSourcedPages: sourced)
    }

    /// Writes OCR text onto textless page rows of the ORIGINAL book (single
    /// transaction, FTS kept in sync) and records the pairing + page mapping.
    /// Pages with native text are never passed here by the engine — the two
    /// versions are never mixed on one page.
    public func applyOCRPages(bookID: String, ocrBook: OCRBookRow,
                              mapping: [OCRPagePair], updates: [OCRPageTextUpdate]) throws {
        lock.lock(); defer { lock.unlock() }
        guard try bookByIDLocked(bookID) != nil else {
            throw StoreError.description("unknown book: \(bookID)")
        }
        try db.exec("BEGIN IMMEDIATE;")
        do {
            let upBook = try db.prepare("""
            INSERT INTO ocr_books(book_id, ocr_real_path, ocr_fingerprint, mapping_kind, created_at)
            VALUES(?,?,?,?,?)
            ON CONFLICT(book_id) DO UPDATE SET
                ocr_real_path=excluded.ocr_real_path, ocr_fingerprint=excluded.ocr_fingerprint,
                mapping_kind=excluded.mapping_kind, created_at=excluded.created_at;
            """)
            try upBook.bindText(1, ocrBook.bookID)
            try upBook.bindText(2, ocrBook.ocrRealPath)
            try upBook.bindText(3, ocrBook.ocrFingerprint)
            try upBook.bindText(4, ocrBook.mappingKind)
            try upBook.bindDouble(5, ocrBook.createdAt)
            try upBook.run()

            let delMap = try db.prepare("DELETE FROM ocr_pages WHERE book_id = ?;")
            try delMap.bindText(1, bookID)
            try delMap.run()
            let insMap = try db.prepare("INSERT INTO ocr_pages(book_id, original_page, ocr_page) VALUES(?,?,?);")
            for p in mapping {
                insMap.reset(); insMap.clearBindings()
                try insMap.bindText(1, bookID)
                try insMap.bindInt(2, Int64(p.originalPage))
                try insMap.bindInt(3, Int64(p.ocrPage))
                try insMap.run()
            }

            let upd = try db.prepare("""
            UPDATE pages SET text_original=?, text_norm=?, norm_starts=?, norm_ends=?, source='ocr', text_latin=?
            WHERE book_id=? AND page_number=?;
            """)
            let delFTS = searchMode == .fts5Trigram
                ? try db.prepare("DELETE FROM pages_fts WHERE rowid IN (SELECT rowid FROM pages WHERE book_id=? AND page_number=?);")
                : nil
            let insFTS = searchMode == .fts5Trigram
                ? try db.prepare("INSERT INTO pages_fts(rowid, text_bigram) SELECT rowid, ?1 FROM pages WHERE book_id=?2 AND page_number=?3;")
                : nil
            for u in updates {
                if let delFTS {
                    delFTS.reset(); delFTS.clearBindings()
                    try delFTS.bindText(1, bookID)
                    try delFTS.bindInt(2, Int64(u.originalPage))
                    try delFTS.run()
                }
                upd.reset(); upd.clearBindings()
                try upd.bindText(1, u.textOriginal)
                try upd.bindText(2, u.textNorm)
                try upd.bindBlob(3, int32ArrayData(u.normStarts))
                try upd.bindBlob(4, int32ArrayData(u.normEnds))
                try upd.bindText(5, LatinProjection.transform(u.textNorm))
                try upd.bindText(6, bookID)
                try upd.bindInt(7, Int64(u.originalPage))
                try upd.run()
                if let insFTS {
                    insFTS.reset(); insFTS.clearBindings()
                    try insFTS.bindText(1, Self.bigramize(u.textNorm))
                    try insFTS.bindText(2, bookID)
                    try insFTS.bindInt(3, Int64(u.originalPage))
                    try insFTS.run()
                }
            }
            try db.exec("COMMIT;")
        } catch {
            db.tryExec("ROLLBACK;")
            throw error
        }
        try purgeQueryCachesLocked()
    }

    /// Removes the pairing and restores every OCR-sourced page to its honest
    /// textless state ('native', empty text). Called when the original or the
    /// OCR file changed — stale references must die, not linger.
    public func purgeOCR(bookID: String) throws {
        lock.lock(); defer { lock.unlock() }
        var pages: [Int] = []
        let sel = try db.prepare("""
        SELECT original_page FROM ocr_pages
        WHERE book_id = ?
          AND original_page IN (SELECT page_number FROM pages WHERE book_id = ? AND source = 'ocr');
        """)
        try sel.bindText(1, bookID)
        try sel.bindText(2, bookID)
        while try sel.step() { pages.append(Int(sel.int(0))) }
        guard !pages.isEmpty else {
            let del = try db.prepare("DELETE FROM ocr_books WHERE book_id = ?;")
            try del.bindText(1, bookID)
            try del.run()
            return
        }
        try db.exec("BEGIN IMMEDIATE;")
        do {
            let upd = try db.prepare("""
            UPDATE pages SET text_original='', text_norm='', norm_starts=X'', norm_ends=X'', source='native', text_latin=''
            WHERE book_id=? AND page_number=?;
            """)
            let delFTS = searchMode == .fts5Trigram
                ? try db.prepare("DELETE FROM pages_fts WHERE rowid IN (SELECT rowid FROM pages WHERE book_id=? AND page_number=?);")
                : nil
            for p in pages {
                if let delFTS {
                    delFTS.reset(); delFTS.clearBindings()
                    try delFTS.bindText(1, bookID)
                    try delFTS.bindInt(2, Int64(p))
                    try delFTS.run()
                }
                upd.reset(); upd.clearBindings()
                try upd.bindText(1, bookID)
                try upd.bindInt(2, Int64(p))
                try upd.run()
            }
            let delMap = try db.prepare("DELETE FROM ocr_pages WHERE book_id = ?;")
            try delMap.bindText(1, bookID)
            try delMap.run()
            let delBook = try db.prepare("DELETE FROM ocr_books WHERE book_id = ?;")
            try delBook.bindText(1, bookID)
            try delBook.run()
            try db.exec("COMMIT;")
        } catch {
            db.tryExec("ROLLBACK;")
            throw error
        }
        try purgeQueryCachesLocked()
    }

    // MARK: - Internals (assume lock held)

    private func ocrBookLocked(_ bookID: String) throws -> OCRBookRow? {
        let stmt = try db.prepare("SELECT book_id, ocr_real_path, ocr_fingerprint, mapping_kind, created_at FROM ocr_books WHERE book_id = ?;")
        try stmt.bindText(1, bookID)
        defer { stmt.reset() }
        if try stmt.step() { return ocrBookRow(from: stmt) }
        return nil
    }

    private func ocrBookRow(from stmt: SQLiteDatabase.Statement) -> OCRBookRow {
        OCRBookRow(bookID: stmt.text(0), ocrRealPath: stmt.text(1), ocrFingerprint: stmt.text(2),
                   mappingKind: stmt.text(3), createdAt: stmt.double(4))
    }

    private func bookRow(from stmt: SQLiteDatabase.Statement) -> BookRow {
        BookRow(
            id: stmt.text(0), realPath: stmt.text(1), rootPath: stmt.text(2),
            relPath: stmt.text(3), fileName: stmt.text(4),
            title: stmt.textOrNull(5), author: stmt.textOrNull(6), version: stmt.textOrNull(7),
            language: stmt.textOrNull(8), metaSource: stmt.textOrNull(9),
            firstFingerprint: stmt.text(10), fingerprint: stmt.text(11),
            fileSize: stmt.int(12), mtime: stmt.double(13), pageCount: Int(stmt.int(14)),
            status: stmt.text(15), error: stmt.textOrNull(16), indexedAt: stmt.double(17),
            contentCategory: stmt.text(18)
        )
    }

    private func pageRow(from stmt: SQLiteDatabase.Statement) -> PageRow {
        PageRow(
            bookID: stmt.text(0), pageNumber: Int(stmt.int(1)),
            label: stmt.textOrNull(2), printedPage: stmt.intOrNull(3).map(Int.init),
            textOriginal: stmt.text(4), textNorm: stmt.text(5),
            normStartsBlob: stmt.blob(6), normEndsBlob: stmt.blob(7)
        )
    }

    private func bindBook(_ stmt: SQLiteDatabase.Statement, _ row: BookRow) throws {
        try stmt.bindText(1, row.id)
        try stmt.bindText(2, row.realPath)
        try stmt.bindText(3, row.rootPath)
        try stmt.bindText(4, row.relPath)
        try stmt.bindText(5, row.fileName)
        if let t = row.title { try stmt.bindText(6, t) } else { try stmt.bindNull(6) }
        if let a = row.author { try stmt.bindText(7, a) } else { try stmt.bindNull(7) }
        if let v = row.version { try stmt.bindText(8, v) } else { try stmt.bindNull(8) }
        if let l = row.language { try stmt.bindText(9, l) } else { try stmt.bindNull(9) }
        if let m = row.metaSource { try stmt.bindText(10, m) } else { try stmt.bindNull(10) }
        try stmt.bindText(11, row.firstFingerprint)
        try stmt.bindText(12, row.fingerprint)
        try stmt.bindInt(13, row.fileSize)
        try stmt.bindDouble(14, row.mtime)
        try stmt.bindInt(15, Int64(row.pageCount))
        try stmt.bindText(16, row.status)
        if let e = row.error { try stmt.bindText(17, e) } else { try stmt.bindNull(17) }
        try stmt.bindDouble(18, row.indexedAt)
    }

    private func bookByRealPathLocked(_ realPath: String) throws -> BookRow? {
        let stmt = try db.prepare("SELECT id, real_path, root_path, rel_path, file_name, title, author, version, language, meta_source, first_fingerprint, fingerprint, file_size, mtime, page_count, status, error, indexed_at, content_category FROM books WHERE real_path = ?;")
        try stmt.bindText(1, realPath)
        defer { stmt.reset() }
        if try stmt.step() { return bookRow(from: stmt) }
        return nil
    }

    private func bookByIDLocked(_ id: String) throws -> BookRow? {
        let stmt = try db.prepare("SELECT id, real_path, root_path, rel_path, file_name, title, author, version, language, meta_source, first_fingerprint, fingerprint, file_size, mtime, page_count, status, error, indexed_at, content_category FROM books WHERE id = ?;")
        try stmt.bindText(1, id)
        defer { stmt.reset() }
        if try stmt.step() { return bookRow(from: stmt) }
        return nil
    }

    private func deleteBookLocked(id: String) throws {
        // 删书规则保持：先显式 DELETE pages（分离后在 ft；未限定名
        // 解析规则：main 无 pages 表即落 ft，本实现 sqlite 实证）再删 main.books。
        // recursive_triggers=OFF 下级联不触发的既有规则照旧（SCHEMA.md wfts 节）；
        // ft.pages 已去 FK，跨库删序由此显式序＋开库孤儿清扫（sweepOrphanFulltext
        // PagesLocked）双降级处理。
        if searchMode == .fts5Trigram {
            let del = try db.prepare("DELETE FROM pages_fts WHERE rowid IN (SELECT rowid FROM pages WHERE book_id = ?);")
            try del.bindText(1, id)
            try del.run()
        }
        let delPages = try db.prepare("DELETE FROM pages WHERE book_id = ?;")
        try delPages.bindText(1, id)
        try delPages.run()
        let delBook = try db.prepare("DELETE FROM books WHERE id = ?;")
        try delBook.bindText(1, id)
        try delBook.run()
        try? deletePinyinRowLocked(bookID: id)   // 拼音投影同步清理，防孤儿行
        do { let del = try db.prepare("DELETE FROM \(ftQual)book_native_counts WHERE book_id = ?;"); try del.bindText(1, id); try del.run() } catch {}
        invalidateRowidToBookIDCacheLocked()
        invalidateAllBooksCacheLocked()
        invalidatePerBookPageStatsCacheLocked()
    }

    /// 模内可见（AutoTOC 扩展同层使用）。
    func pageCountLocked(bookID: String) throws -> Int {
        let stmt = try db.prepare("SELECT COUNT(*) FROM pages WHERE book_id = ?;")
        try stmt.bindText(1, bookID)
        defer { stmt.reset() }
        if try stmt.step() { return Int(stmt.int(0)) }
        return 0
    }

    private func pageLocked(bookID: String, pageNumber: Int) throws -> PageRow? {
        let stmt = try db.prepare("""
        SELECT book_id, page_number, label, printed_page, text_original, text_norm, norm_starts, norm_ends
        FROM pages WHERE book_id = ? AND page_number = ?;
        """)
        try stmt.bindText(1, bookID)
        try stmt.bindInt(2, Int64(pageNumber))
        defer { stmt.reset() }
        if try stmt.step() { return pageRow(from: stmt) }
        return nil
    }


    // MARK: 自建倒排表（FTS5 bigram 查询的快速候选路径）

    /// Rebuilds the bigram inverted index from the pages table (one pass).
    /// Call after any batch of page writes (indexing/import) or explicitly.
    public func rebuildBigramInvertedIndex() throws {
        lock.lock(); defer { lock.unlock() }
        try rebuildBigramInvertedIndexLocked()
    }

    /// Must be called with `lock` already held.
    private func rebuildBigramInvertedIndexLocked() throws {
        // bigram_index 随形态限定（未限定写恒落 main；split 后真表在 ft）。
        try db.exec("DELETE FROM \(ftQual)bigram_index;")
        try db.exec("BEGIN IMMEDIATE;")
        do {
            let rows = try db.prepare("SELECT rowid, text_norm FROM pages WHERE TRIM(text_norm) != '' ORDER BY rowid;")
            // 内存聚合：bigram → rowid 数组（大型库一次装入，峰值内存仍可控）
            var index: [String: [UInt32]] = [:]
            while try rows.step() {
                let rowid = UInt32(max(0, rows.int(0)))
                let text = rows.text(1)
                let chars = Array(text)
                guard chars.count >= 2 else { continue }
                for i in 0..<(chars.count - 1) {
                    let g = String(chars[i]) + String(chars[i + 1])
                    index[g, default: []].append(rowid)
                }
            }
            let ins = try db.prepare("INSERT OR REPLACE INTO \(ftQual)bigram_index VALUES(?, ?);")
            for (g, ridsIn) in index {
                var rids = ridsIn
                rids.sort()
                var blob = Data(capacity: rids.count * 4)
                for r in rids {
                    withUnsafeBytes(of: r.bigEndian) { blob.append(contentsOf: $0) }
                }
                ins.reset(); ins.clearBindings()
                try ins.bindText(1, g)
                try ins.bindBlob(2, blob)
                try ins.run()
            }
            try setMetaValueLocked("bidx_dirty", "0")
            try setMetaValueLocked("bidx_built_at", String(Int(Date().timeIntervalSince1970)))
            try db.exec("COMMIT;")
        } catch {
            db.tryExec("ROLLBACK;")
            throw error
        }
    }

    /// Rebuilds the inverted index only when it is empty or stale (any page
    /// write sets `bidx_dirty` via purgeQueryCachesLocked). Idempotent.
    /// Returns true when a rebuild actually ran.
    @discardableResult
    public func ensureBigramIndexFresh() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let dirty = (try metaValueLocked("bidx_dirty")) == "1"
        let built = (try? metaValueLocked("bidx_built_at")) != nil
        guard dirty || !built else { return false }
        try rebuildBigramInvertedIndexLocked()
        return true
    }

    /// Candidates via the inverted index: per-bigram rowid sets intersected
    /// left-to-right. Returns nil when the index is empty or stale so the
    /// caller falls back to FTS/LIKE.
    public func candidatePageIDsViaInvertedIndex(bigrams: [String]) throws -> [String]? {
        lock.lock(); defer { lock.unlock() }
        return try candidatePageIDsViaInvertedIndexLocked(bigrams: bigrams)
    }

    /// Must be called with `lock` already held (candidatePageIDs holds it —
    /// a nested NSLock.lock on the same thread deadlocks).
    private func candidatePageIDsViaInvertedIndexLocked(bigrams: [String]) throws -> [String]? {
        // Built marker + dirty flag (meta lookups, O(1)) instead of a
        // COUNT(*) over the whole bigram table per term resolution.
        let built = (try? metaValueLocked("bidx_built_at")) != nil
        let dirty = (try? metaValueLocked("bidx_dirty")) == "1"
        guard built, !dirty else { return nil }   // not built / stale
        var current: Set<UInt32>? = nil
        let sel = try db.prepare("SELECT rowids FROM bigram_index WHERE bigram = ?;")
        // 英文短词优化：全 ASCII 词拆出的高频 bigram（re/ea/as/so/on 类）
        // 单 blob 很大，多路解压求交在大型库上会慢到数十秒。先查各 blob 总量，超 2MB 且全 ASCII 时改走 FTS5 AND
        // 交集预筛（unicode61 词法下与 bigram 同 token 集，快一到两个数量级）；页级
        // 精确匹配仍由调用方页内扫描承担——语义与既有实现一致。
        var totalBytes = 0
        var blobs: [Data?] = []
        for g in bigrams {
            sel.reset(); sel.clearBindings()
            try sel.bindText(1, g)
            guard (try sel.step()) else { return [] }
            let blob = sel.blob(0)
            if blob.isEmpty { return [] }
            totalBytes += blob.count
            blobs.append(Data(blob))
        }
        if totalBytes > 2_000_000, bigrams.allSatisfy({ $0.allSatisfy { $0.isASCII } }) {
            let ftsQuery = bigrams.joined(separator: " AND ")
            let ftsSel = try db.prepare("SELECT p.rowid FROM pages p JOIN pages_fts f ON f.rowid = p.rowid WHERE pages_fts MATCH ?;")
            ftsSel.reset(); ftsSel.clearBindings()
            try ftsSel.bindText(1, ftsQuery)
            var ftsSet = Set<UInt32>()
            while try ftsSel.step() {
                let rowid = ftsSel.int(0)
                if rowid > 0 { ftsSet.insert(UInt32(rowid)) }
            }
            return ftsSet.map { String($0) }
        }
        for blobData in blobs {
            guard let blobData, !blobData.isEmpty else { return [] }
            blobData.withUnsafeBytes { raw in
                var set = Set<UInt32>(minimumCapacity: raw.count / 4)
                for i in stride(from: 0, to: raw.count, by: 4) {
                    set.insert(raw.loadUnaligned(fromByteOffset: i, as: UInt32.self).bigEndian)
                }
                if let cur = current {
                    current = cur.intersection(set)
                } else {
                    current = set
                }
            }
            if current!.isEmpty { return [] }
        }
        return current!.map { String($0) }
    }

    /// Overlapping 2-gram serialization for the bigram FTS tokenizer
    /// (unicode61 splits on spaces; detail=none keeps the index small).
    /// Single characters pass through unchanged.
    public static func bigramize(_ text: String) -> String {
        let chars = Array(text)
        guard chars.count >= 2 else { return text }
        var out: [String] = []
        out.reserveCapacity(chars.count - 1)
        for i in 0..<(chars.count - 1) {
            out.append(String(chars[i]) + String(chars[i + 1]))
        }
        return out.joined(separator: " ")
    }

    /// Converts a search term to its bigram AND query form for the bigram FTS
    /// index: each overlapping 2-gram becomes a quoted token, joined with AND.
    public static func bigramQuery(_ term: String) -> String {
        let chars = Array(term)
        guard chars.count >= 2 else { return "\"\(term)\"" }
        var grams: [String] = []
        for i in 0..<(chars.count - 1) {
            let g = String(chars[i]) + String(chars[i + 1])
            grams.append("\"\(g)\"")
        }
        return grams.joined(separator: " AND ")
    }

    private func candidatePagesFTS(term: String) throws -> [String] {
        let stmt = try db.prepare("SELECT rowid FROM pages_fts WHERE pages_fts MATCH ? ORDER BY rowid;")
        try stmt.bindText(1, Self.bigramQuery(term))
        defer { stmt.reset() }
        var ids: [String] = []
        while try stmt.step() { ids.append(String(stmt.int(0))) }
        return ids
    }

    private func candidatePagesLike(term: String) throws -> [String] {
        let stmt = try db.prepare("SELECT rowid FROM pages WHERE text_norm LIKE ? ESCAPE '\\' ORDER BY rowid;")
        try stmt.bindText(1, "%\(escapeForLike(term))%")
        defer { stmt.reset() }
        var ids: [String] = []
        while try stmt.step() { ids.append(String(stmt.int(0))) }
        return ids
    }

    // MARK: Blob codecs for the normalization offset maps

    private func int32ArrayData(_ values: [Int32]) -> Data {
        var data = Data(capacity: values.count * 4)
        for v in values {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func int32Array(from data: Data) -> [Int32] {
        guard data.count % 4 == 0 else { return [] }
        var out: [Int32] = []
        out.reserveCapacity(data.count / 4)
        data.withUnsafeBytes { raw in
            for i in stride(from: 0, to: raw.count, by: 4) {
                let v = raw.loadUnaligned(fromByteOffset: i, as: Int32.self).littleEndian
                out.append(v)
            }
        }
        return out
    }

    // MARK: - Daily Quotes & Candidate Page Extraction

    public struct QuoteCandidatePage: Sendable {
        public var bookID: String
        public var fileName: String
        public var pageNumber: Int
        public var textOriginal: String
        public var textNorm: String
        public var rootPath: String

        public init(bookID: String, fileName: String, pageNumber: Int, textOriginal: String, textNorm: String, rootPath: String = "") {
            self.bookID = bookID
            self.fileName = fileName
            self.pageNumber = pageNumber
            self.rootPath = rootPath
            self.textOriginal = textOriginal
            self.textNorm = textNorm
        }
    }

    /// Iterates through candidate pages (status='ok' books, non-empty text_norm) for quote extraction.
    public func forEachCandidatePage(block: (QuoteCandidatePage) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("""
        SELECT p.book_id, b.file_name, p.page_number, p.text_original, p.text_norm, b.root_path
        FROM pages p
        JOIN books b ON b.id = p.book_id
        WHERE b.status = 'ok' AND TRIM(p.text_norm) != ''
        ORDER BY b.id, p.page_number;
        """)
        defer { stmt.reset() }
        while try stmt.step() {
            let page = QuoteCandidatePage(
                bookID: stmt.text(0),
                fileName: stmt.text(1),
                pageNumber: Int(stmt.int(2)),
                textOriginal: stmt.text(3),
                textNorm: stmt.text(4),
                rootPath: stmt.text(5)
            )
            try block(page)
        }
    }

    /// Idempotently writes quotes for the given date (deletes existing for date, then inserts).
    public func insertDailyQuotes(_ quotes: [Quote], forDate dateString: String) throws {
        lock.lock(); defer { lock.unlock() }
        try db.exec("BEGIN IMMEDIATE;")
        do {
            let del = try db.prepare("DELETE FROM daily_quotes WHERE quote_date = ?;")
            try del.bindText(1, dateString)
            try del.run()

            let ins = try db.prepare("""
            INSERT INTO daily_quotes(book_id, page_number, sentence, quote_date)
            VALUES(?, ?, ?, ?);
            """)
            for q in quotes {
                ins.reset(); ins.clearBindings()
                try ins.bindText(1, q.bookID)
                try ins.bindInt(2, Int64(q.pageNumber))
                try ins.bindText(3, q.sentence)
                try ins.bindText(4, dateString)
                try ins.run()
            }
            try db.exec("COMMIT;")
        } catch {
            db.tryExec("ROLLBACK;")
            throw error
        }
    }

    /// Returns all daily quotes from the store ordered by ID ascending.
    public func allDailyQuotes() throws -> [Quote] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("""
        SELECT q.id, q.book_id, COALESCE(b.file_name, ''), q.page_number, q.sentence, q.quote_date
        FROM daily_quotes q
        LEFT JOIN books b ON b.id = q.book_id
        ORDER BY q.id ASC;
        """)
        defer { stmt.reset() }
        var rows: [Quote] = []
        while try stmt.step() {
            rows.append(Quote(
                id: stmt.int(0),
                bookID: stmt.text(1),
                fileName: stmt.text(2),
                pageNumber: Int(stmt.int(3)),
                sentence: stmt.text(4),
                quoteDate: stmt.text(5)
            ))
        }
        return rows
    }

    /// Returns the total number of rows in daily_quotes.
    public func dailyQuotesCount() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("SELECT COUNT(*) FROM daily_quotes;")
        defer { stmt.reset() }
        if try stmt.step() { return Int(stmt.int(0)) }
        return 0
    }
}

extension SQLiteDatabase.Statement {
    // intOrNull lives inside SQLiteDatabase.Statement (see SQLiteDatabase.swift).
}
