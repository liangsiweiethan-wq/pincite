import Foundation

// MARK: - 索引刷新流水账 RefreshJournal（实现，

/// journal 事件名常量（唯一事实源；写入与判定两侧共用，防字符串漂移）。
public enum RefreshJournalEventName {
    public static let batchStart = "batch-start"
    public static let bookStart = "book-start"
    public static let bookDone = "book-done"
    public static let bookSkip = "book-skip"
    public static let bookFail = "book-fail"
    public static let batchPause = "batch-pause"
    public static let batchResume = "batch-resume"
    public static let batchStop = "batch-stop"
    public static let auditPass = "audit-pass"
    public static let auditFail = "audit-fail"
    public static let batchFinalize = "batch-finalize"
    public static let batchComplete = "batch-complete"

    public static let batchTerminal: Set<String> = [batchStop, batchComplete]
}

/// 计划内单书的 journal 载荷（batch-start 内嵌完整计划）。跨启动续跑**只认**这份清单重建待跑集合——旧版 journal 无此
/// 载荷时问题续跑，绝不按 book-start 行反推（那会漏掉从未开跑的书）。
/// 业界同型：Spring Batch 先落 JobExecution 再执行、Meilisearch 任务先
/// 入队、GNU parallel done 白名单——待跑＝计划−已终态，而非−已开始。
public struct JournalPlanBook: Codable, Equatable, Sendable {
    public let bookID: String
    public let src: String
    public let shaExpect: String?
    public let declaredPages: Int?
    public let fileName: String
    public let title: String?

    public init(bookID: String, src: String, shaExpect: String?,
                declaredPages: Int?, fileName: String, title: String?) {
        self.bookID = bookID
        self.src = src
        self.shaExpect = shaExpect
        self.declaredPages = declaredPages
        self.fileName = fileName
        self.title = title
    }

    enum CodingKeys: String, CodingKey {
        case bookID = "book_id", src, shaExpect = "sha_expect",
             declaredPages = "declared_pages", fileName = "file_name", title
    }
}

/// 单条 journal 事件（jsonl 一行）。字段全部可选——不同事件只带各自相关
/// 字段，缺省不写键（编码时 nil 折叠，镜像清单的稀疏行风格）。
public struct RefreshJournalEvent: Codable, Equatable, Sendable {
    /// 本地时间戳 "yyyy-MM-dd'T'HH:mm:ss"（POSIX 断言固定，防系统日历漂移）。
    public var ts: String
    public var event: String
    public var batchID: String?
    public var kind: String?
    public var ledger: String?
    public var booksTotal: Int?
    public var pagesTotal: Int?
    public var bookID: String?
    public var src: String?
    public var shaExpect: String?
    public var shaBefore: String?
    public var shaAfter: String?
    public var pages: Int?
    public var verdict: String?
    public var error: String?
    // 收尾核对（batch-finalize 载荷）。
    public var checkBooksOk: Int?
    public var checkBooksFailed: Int?
    public var checkShaMismatch: Int?
    public var checkProbesFailed: Int?
    // 批间抽验（audit-pass/audit-fail 载荷）。
    public var checked: Int?
    // 完整计划随 batch-start 首事件持久化——
    // 续跑的唯一重建源（含 book_id/src/sha_expect/declared_pages 全量清单）。
    public var plan: [JournalPlanBook]?
    /// 计划载荷结构版本（现行 1；缺版本＝旧版 journal，续跑问题——学
    /// SQLite WAL 头版本字节的防旧版误恢复纪律）。
    public var planVersion: Int?

    public init(ts: String = RefreshJournal.timestamp(),
                event: String,
                batchID: String? = nil,
                kind: String? = nil,
                ledger: String? = nil,
                booksTotal: Int? = nil,
                pagesTotal: Int? = nil,
                bookID: String? = nil,
                src: String? = nil,
                shaExpect: String? = nil,
                shaBefore: String? = nil,
                shaAfter: String? = nil,
                pages: Int? = nil,
                verdict: String? = nil,
                error: String? = nil,
                checkBooksOk: Int? = nil,
                checkBooksFailed: Int? = nil,
                checkShaMismatch: Int? = nil,
                checkProbesFailed: Int? = nil,
                checked: Int? = nil,
                plan: [JournalPlanBook]? = nil,
                planVersion: Int? = nil) {
        self.ts = ts
        self.event = event
        self.batchID = batchID
        self.kind = kind
        self.ledger = ledger
        self.booksTotal = booksTotal
        self.pagesTotal = pagesTotal
        self.bookID = bookID
        self.src = src
        self.shaExpect = shaExpect
        self.shaBefore = shaBefore
        self.shaAfter = shaAfter
        self.pages = pages
        self.verdict = verdict
        self.error = error
        self.checkBooksOk = checkBooksOk
        self.checkBooksFailed = checkBooksFailed
        self.checkShaMismatch = checkShaMismatch
        self.checkProbesFailed = checkProbesFailed
        self.checked = checked
        self.plan = plan
        self.planVersion = planVersion
    }

    enum CodingKeys: String, CodingKey {
        case ts, event, ledger, pages, verdict, error, kind, checked, plan
        case batchID = "batch_id"
        case booksTotal = "books_total"
        case pagesTotal = "pages_total"
        case bookID = "book_id"
        case src, shaExpect = "sha_expect"
        case shaBefore = "sha_before"
        case shaAfter = "sha_after"
        case checkBooksOk = "check_books_ok"
        case checkBooksFailed = "check_books_failed"
        case checkShaMismatch = "check_sha_mismatch"
        case checkProbesFailed = "check_probes_failed"
        case planVersion = "plan_version"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ts = try c.decodeIfPresent(String.self, forKey: .ts) ?? ""
        event = try c.decodeIfPresent(String.self, forKey: .event) ?? ""
        batchID = try c.decodeIfPresent(String.self, forKey: .batchID)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        ledger = try c.decodeIfPresent(String.self, forKey: .ledger)
        booksTotal = try c.decodeIfPresent(Int.self, forKey: .booksTotal)
        pagesTotal = try c.decodeIfPresent(Int.self, forKey: .pagesTotal)
        bookID = try c.decodeIfPresent(String.self, forKey: .bookID)
        src = try c.decodeIfPresent(String.self, forKey: .src)
        shaExpect = try c.decodeIfPresent(String.self, forKey: .shaExpect)
        shaBefore = try c.decodeIfPresent(String.self, forKey: .shaBefore)
        shaAfter = try c.decodeIfPresent(String.self, forKey: .shaAfter)
        pages = try c.decodeIfPresent(Int.self, forKey: .pages)
        verdict = try c.decodeIfPresent(String.self, forKey: .verdict)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        checkBooksOk = try c.decodeIfPresent(Int.self, forKey: .checkBooksOk)
        checkBooksFailed = try c.decodeIfPresent(Int.self, forKey: .checkBooksFailed)
        checkShaMismatch = try c.decodeIfPresent(Int.self, forKey: .checkShaMismatch)
        checkProbesFailed = try c.decodeIfPresent(Int.self, forKey: .checkProbesFailed)
        checked = try c.decodeIfPresent(Int.self, forKey: .checked)
        plan = try c.decodeIfPresent([JournalPlanBook].self, forKey: .plan)
        planVersion = try c.decodeIfPresent(Int.self, forKey: .planVersion)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ts, forKey: .ts)
        try c.encode(event, forKey: .event)
        try c.encodeIfPresent(batchID, forKey: .batchID)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(ledger, forKey: .ledger)
        try c.encodeIfPresent(booksTotal, forKey: .booksTotal)
        try c.encodeIfPresent(pagesTotal, forKey: .pagesTotal)
        try c.encodeIfPresent(bookID, forKey: .bookID)
        try c.encodeIfPresent(src, forKey: .src)
        try c.encodeIfPresent(shaExpect, forKey: .shaExpect)
        try c.encodeIfPresent(shaBefore, forKey: .shaBefore)
        try c.encodeIfPresent(shaAfter, forKey: .shaAfter)
        try c.encodeIfPresent(pages, forKey: .pages)
        try c.encodeIfPresent(verdict, forKey: .verdict)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(checkBooksOk, forKey: .checkBooksOk)
        try c.encodeIfPresent(checkBooksFailed, forKey: .checkBooksFailed)
        try c.encodeIfPresent(checkShaMismatch, forKey: .checkShaMismatch)
        try c.encodeIfPresent(checkProbesFailed, forKey: .checkProbesFailed)
        try c.encodeIfPresent(checked, forKey: .checked)
        try c.encodeIfPresent(plan, forKey: .plan)
        try c.encodeIfPresent(planVersion, forKey: .planVersion)
    }
}

/// journal 读出摘要：崩溃/重启后的「已完成与待跑」只读视图。
public struct RefreshJournalSummary: Equatable, Sendable {
    /// book-start 行的三元组（计划重建的最小充分信息）。
    public struct StartedBook: Equatable, Sendable {
        public let bookID: String
        public let src: String
        public let shaExpect: String?
    }

    public let batchFileName: String
    public let batchID: String
    public let kind: String?
    /// batch-start 携带的终账路径（跨启动续跑用；可能缺）。
    public let ledgerPath: String?
    /// batch-start 携带的书总数（无法读出时为 nil）。
    public let booksTotal: Int?
    /// batch-start 内嵌的完整计划（跨启动续跑的唯一重建源；旧版 journal 为
    /// nil——此时续跑必须问题）。
    public let planBooks: [JournalPlanBook]?
    /// 计划载荷结构版本（现行 1；nil＝旧版无计划 journal）。
    public let planVersion: Int?
    /// 已到终态的书事件数（done + skip + fail）。
    public let booksSettled: Int
    /// 逐书终态：bookID → 事件名（book-done/book-skip/book-fail）。
    public let bookVerdicts: [String: String]
    /// 失败书清单（bookID → 错误原文）。
    public let failures: [String: String]
    /// book-start 三元组按落盘序（跨启动重建计划用）。
    public let startedBooks: [StartedBook]
    /// 已终态书按 journal 落盘序（续跑抽验样本须取**最近**结算书，
    /// 不得从 Set 恢复随机顺序）。
    public let settledOrder: [String]
    /// audit-fail 事件的错误原文清单，用于跨启动保留抽验问题。
    public let auditFailures: [String]
    /// batch-finalize 载荷（收尾三向对账结果；跨启动残留判定源）。
    public let finalizeBooksFailed: Int?
    public let finalizeShaMismatch: Int?
    public let finalizeProbesFailed: Int?
    /// 收尾对账有残留（失败书>0、sha 失配>0 或抽验残留>0）——跨启动
    /// 横幅判定源：completedWithResidue 重启后保留提示。
    public var finalizeResidue: Bool {
        (finalizeBooksFailed ?? 0) > 0 || (finalizeShaMismatch ?? 0) > 0
            || (finalizeProbesFailed ?? 0) > 0
    }
    /// 最后一条事件名。
    public let lastEvent: String
    public let interrupted: Bool

    /// 待跑书数（总数 − 已终态；booksTotal 缺失时为 nil）。
    public var pendingCount: Int? {
        guard let total = booksTotal else { return nil }
        return max(0, total - booksSettled)
    }

    public var unfinished: Bool {
        interrupted || (pendingCount ?? 0) > 0
    }
}

public enum RefreshJournal {

    /// 计划载荷结构版本（batch-start.plan_version；升版时旧版 journal
    /// 问题续跑——SQLite WAL 头版本字节同款纪律）。
    public static let currentPlanVersion = 1

    /// 时间戳基准（POSIX 断言固定——SnapshotManager.makeTimestampFormatter 同款
    /// 纪律：固定格式不断言 locale 会跟随系统日历漂移）。
    public static func timestamp(for date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: date)
    }

    public static func makeBatchID(for date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    /// 同秒生成名称时，若目录中已有同名 journal，则依次尝试 -2/-3…，避免
    public static func uniqueBatchID(in directory: URL,
                                     taken: Set<String> = [],
                                     for date: Date = Date()) -> String {
        let base = makeBatchID(for: date)
        var candidate = base
        var n = 2
        let occupied = { () -> Set<String> in
            Set(journalURLs(in: directory).map { $0.deletingPathExtension().lastPathComponent })
        }()
        while occupied.contains(candidate) || taken.contains(candidate) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }

    /// journal 文件名（<batch_id>.jsonl）。
    public static func fileName(forBatchID batchID: String) -> String {
        batchID + ".jsonl"
    }

    // MARK: - 写侧（追加写）

    /// jsonl 追加写器：打开一次句柄、逐行 append＋同步落盘（synchronize），
    /// deinit 关闭。写失败抛错（不静默——journal 是断点续跑的依据）。
    /// append 事件级原子——写入后任一步失败即截尾回退到
    /// 写前偏移（回退以文件长度确证，禁 try? 吞错语义）；回退未确证即
    /// rollbackFailed=true，此后一切写入直接拒绝（账本状态未知，续跑依据
    /// 不可信＝fail-closed，人工核查），与既有输出基线 LedgerWriter 同款契约。
    /// 回退抽显式 rollback(to:)——truncate/seek/长度
    /// 读取/回退后 synchronize 逐步 do/catch，任一步失败都落 rollbackFailed
    /// （不再有 try? 缝隙）；写前偏移取得失败（offset 与 seekToEnd 均败）
    /// ⇒禁止写入 fail-closed（绝不以 0 降级处理——0 不是已确证偏移，回退会把
    /// 整份 journal 截空还可能被长度确证误判成功）。
    public final class Writer {
        let url: URL
        private let handle: FileHandle
        public private(set) var rollbackFailed = false

        /// 测试注入点（生产恒 nil）：指定 writtenCount 时 append 在写入后、
        /// 同步前抛错——用于断言「写后失败⇒无可见事件＋回退确证」契约。
        static var postWriteFailureHook: (@Sendable (Int) -> Bool)?
        /// 测试注入点（生产恒 nil）：写后失败触发回退时注入「回退未确证」——
        /// 返回 true＝跳过截尾/归位、按回退失败路径处理（rollbackFailed＋禁写）。
        static var rollbackFailureHook: (@Sendable () -> Bool)?
        /// 测试注入点（生产恒 nil）：操作级失败
        /// 注入——步名 "offset"/"seekToEnd"/"truncate"/"seek"/"sizeCheck"/
        /// "resync"；返回非 nil＝该操作在**真实调用点**抛出此错误。与旧
        /// 「操作前短路」缝的本质区别：注入错误与真实操作失败走**同一条
        /// do/catch 通路**（catch 分支、降级处理分支、rollbackFailed 落旗路径
        /// 全部真实执行），拆掉任一 do/catch（如还原 try? 吞错）测试即红。
        static var opFailureHook: (@Sendable (String) -> (any Error)?)?
        private var writtenCount = 0

        public init(directory: URL, batchID: String) throws {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            self.url = directory.appendingPathComponent(RefreshJournal.fileName(forBatchID: batchID))
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let h = FileHandle(forWritingAtPath: url.path) else {
                throw NSError(domain: "RefreshJournalError", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "cannot open journal for writing: \(url.path)"])
            }
            self.handle = h
            // 截尾修复：append-only 文件崩溃 torn write 只可能
            // 在尾部——续写前把无效尾部截掉，否则续跑事件接在坏行之后
            // 永远读不到（读侧已按有效前缀截断，写侧必须配套修复）。
            if let existing = FileManager.default.contents(atPath: url.path) {
                let valid = RefreshJournal.validPrefixBytes(of: existing)
                if valid < existing.count {
                    try h.truncate(atOffset: UInt64(valid))
                }
            }
            _ = try h.seekToEnd()
        }

        public func append(_ event: RefreshJournalEvent) throws {
            if rollbackFailed {
                throw NSError(domain: "RefreshJournalError", code: 2,
                              userInfo: [NSLocalizedDescriptionKey:
                                "journal 账本先前回退未确证（\(url.path)），已禁止继续写入——请人工核查"])
            }
            // 操作级注入助手：注入错误从**真实调用点**
            // 抛出（与真实 IO 失败同一条 do/catch 通路），不再在操作前短路。
            func op(_ step: String) throws {
                if let err = Writer.opFailureHook?(step) { throw err }
            }
            let encoder = JSONEncoder()
            var data = try encoder.encode(event)
            data.append(0x0A)
            // 写前偏移必须**确证取得**——offset 失败再以
            // seekToEnd 降级处理；两者皆败＝偏移未知，禁止写入（绝不以 0 降级处理：
            // 0 不是确证偏移，回退会把已有 journal 截空且长度恰等 0 可能被
            // 误判「回退成功」）。
            let offsetBefore: UInt64
            do {
                try op("offset")
                offsetBefore = try handle.offset()
            } catch {
                do {
                    try op("seekToEnd")
                    offsetBefore = try handle.seekToEnd()
                } catch {
                    rollbackFailed = true
                    throw NSError(domain: "RefreshJournalError", code: 5,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "journal 写前偏移取得失败（offset 与 seekToEnd 均败）（\(url.path)），偏移未知已禁止写入——请人工核查；原始失败：\(error.localizedDescription)"])
                }
            }
            do {
                try handle.write(contentsOf: data)
                if let hook = Writer.postWriteFailureHook, hook(writtenCount) {
                    throw NSError(domain: "RefreshJournalError", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "注入的 journal 写后失败（writtenCount=\(writtenCount)）"])
                }
                try handle.synchronize()
            } catch {
                // 显式分步回退——truncate/seek/长度
                // 确证/回退后 synchronize 逐步 do/catch；任一步失败都落
                // rollbackFailed（回退后不同步，进程重启仍可能看到已抛错
                // 事件＝回退未确证）。：注入走同一条 catch 通路。
                var rolledBack = false
                var rollbackError: (any Error)?
                if Writer.rollbackFailureHook?() == true {
                    rolledBack = false
                } else {
                    do {
                        try op("truncate")
                        try handle.truncate(atOffset: offsetBefore)
                        try op("seek")
                        try handle.seek(toOffset: offsetBefore)
                        try op("sizeCheck")
                        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                        let size = (attrs[.size] as? NSNumber)?.uint64Value
                        if size == offsetBefore {
                            try op("resync")
                            try handle.synchronize()
                            rolledBack = true
                        } else {
                            rolledBack = false
                        }
                    } catch {
                        rolledBack = false
                        rollbackError = error
                    }
                }
                if !rolledBack {
                    rollbackFailed = true
                    // 回退步骤的原始失败必须随禁写文案带出
                    // （人工核查需知道是哪一步、什么错）；长度不匹配等非抛错
                    // 失败以「回退确证失败」标注。
                    let rbDetail = rollbackError.map { "回退步骤失败：\($0.localizedDescription)；" } ?? "回退确证失败；"
                    throw NSError(domain: "RefreshJournalError", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "journal 写后失败且截尾回退未确证（\(url.path)），账本状态未知，已禁止继续写入——请人工核查；\(rbDetail)原始失败：\(error.localizedDescription)"])
                }
                throw error
            }
            writtenCount += 1
        }

        deinit {
            try? handle.close()
        }
    }

    // MARK: - 读侧（崩溃判定与「上次停在何处」展示）

    /// 读单个 journal 文件为事件序列。WAL 截断语义（学 SQLite WAL：append-only 文件的 torn write 只可能在尾部）——
    /// 首个坏行即视为崩溃截尾，该行及其后内容当作从未写入，保留此前全部
    /// 有效事件。续跑安全优先于展示最大化：截尾后丢的事件至多导致幂等重放。
    public static func readEvents(at url: URL) -> [RefreshJournalEvent] {
        readEventsDetailed(at: url).events
    }

    /// 字节级读出结果：events＝有效前缀内的事件；truncated＝
    /// 尾部存在损坏字节（torn write）。写侧（Writer.init）据此修复截尾后
    /// 才续写——否则续跑事件接在坏行之后永远读不到。
    public struct JournalReadResult: Equatable, Sendable {
        public let events: [RefreshJournalEvent]
        public let validBytes: Int
        public let fileSize: Int
        public var truncated: Bool { validBytes < fileSize }
    }

    public static func readEventsDetailed(at url: URL) -> JournalReadResult {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return JournalReadResult(events: [], validBytes: 0, fileSize: 0)
        }
        let valid = validPrefixBytes(of: data)
        let decoder = JSONDecoder()
        let events = Data(data.prefix(valid))
            .split(separator: 0x0A)
            .compactMap { try? decoder.decode(RefreshJournalEvent.self, from: $0) }
        return JournalReadResult(events: events, validBytes: valid, fileSize: data.count)
    }

    /// 有效前缀字节长度：逐行扫描，最后一条完整可解析事件的结尾偏移——
    /// 无换行的尾段（半行 JSON）、截断 UTF-8、坏行及其后内容均为截尾。
    /// 按字节操作（截断 UTF-8 场景 String 整读会连有效前缀一起失败）。
    static func validPrefixBytes(of data: Data) -> Int {
        let bytes = [UInt8](data)
        let decoder = JSONDecoder()
        var index = 0
        var valid = 0
        while index < bytes.count {
            guard let newline = bytes[index...].firstIndex(of: 0x0A) else { break }
            let line = Data(bytes[index..<newline])
            guard !line.isEmpty,
                  (try? decoder.decode(RefreshJournalEvent.self, from: line)) != nil else {
                break
            }
            valid = newline + 1
            index = newline + 1
        }
        return valid
    }

    /// 目录内最新 journal 文件（按文件名倒序取首；目录缺失/为空返回 nil）。
    public static func latestJournalURL(in directory: URL) -> URL? {
        let urls = journalURLs(in: directory)
        return urls.first
    }

    /// 目录内全部 journal 文件（文件名倒序＝新在前）。
    public static func journalURLs(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    public static func summarize(at url: URL) -> RefreshJournalSummary? {
        let events = readEvents(at: url)
        guard !events.isEmpty else { return nil }
        var batchIDFromEvent: String?
        var kind: String?
        var ledgerPath: String?
        var booksTotal: Int?
        var planBooks: [JournalPlanBook]?
        var planVersion: Int?
        var verdicts: [String: String] = [:]
        var failures: [String: String] = [:]
        var startedBooks: [RefreshJournalSummary.StartedBook] = []
        var settledOrder: [String] = []
        var auditFailures: [String] = []
        var finalizeBooksFailed: Int?
        var finalizeShaMismatch: Int?
        var finalizeProbesFailed: Int?
        var interrupted = true
        var lastEvent = ""
        for e in events {
            lastEvent = e.event
            switch e.event {
            // 生命周期按**末次**事件判定——stop→resume→末书完成→
            // 崩溃（未及收尾）必须仍判可续，不能因「历史上出现过终态」失效。
            case RefreshJournalEventName.batchResume, RefreshJournalEventName.batchPause:
                interrupted = true
            case RefreshJournalEventName.batchStart:
                batchIDFromEvent = e.batchID
                kind = e.kind
                ledgerPath = e.ledger
                booksTotal = e.booksTotal
                planBooks = e.plan
                planVersion = e.planVersion
            case RefreshJournalEventName.bookStart:
                if let id = e.bookID, let src = e.src {
                    startedBooks.append(.init(bookID: id, src: src, shaExpect: e.shaExpect))
                }
            case RefreshJournalEventName.bookDone, RefreshJournalEventName.bookSkip:
                if let id = e.bookID {
                    verdicts[id] = e.event
                    if !settledOrder.contains(id) { settledOrder.append(id) }
                }
            case RefreshJournalEventName.bookFail:
                if let id = e.bookID {
                    verdicts[id] = e.event
                    failures[id] = e.error ?? ""
                    if !settledOrder.contains(id) { settledOrder.append(id) }
                }
            case RefreshJournalEventName.auditFail:
                if let err = e.error, !err.isEmpty { auditFailures.append(err) }
            case RefreshJournalEventName.batchFinalize:
                finalizeBooksFailed = e.checkBooksFailed
                finalizeShaMismatch = e.checkShaMismatch
                finalizeProbesFailed = e.checkProbesFailed
            case RefreshJournalEventName.batchStop, RefreshJournalEventName.batchComplete:
                interrupted = false
            default:
                break
            }
        }
        return RefreshJournalSummary(batchFileName: url.lastPathComponent,
                                     batchID: batchIDFromEvent
                                        ?? url.deletingPathExtension().lastPathComponent,
                                     kind: kind,
                                     ledgerPath: ledgerPath,
                                     booksTotal: booksTotal,
                                     planBooks: planBooks,
                                     planVersion: planVersion,
                                     booksSettled: verdicts.count,
                                     bookVerdicts: verdicts,
                                     failures: failures,
                                     startedBooks: startedBooks,
                                     settledOrder: settledOrder,
                                     auditFailures: auditFailures,
                                     finalizeBooksFailed: finalizeBooksFailed,
                                     finalizeShaMismatch: finalizeShaMismatch,
                                     finalizeProbesFailed: finalizeProbesFailed,
                                     lastEvent: lastEvent,
                                     interrupted: interrupted)
    }

    /// 只留最近一份：删除 directory 内除 keeping 外的全部 *.jsonl（新批
    /// batch-start 时调用）。返回被删文件名供记录。
    @discardableResult
    public static func pruneOldJournals(in directory: URL, keeping: URL) -> [String] {
        var removed: [String] = []
        for url in journalURLs(in: directory) where url.lastPathComponent != keeping.lastPathComponent {
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removed.append(url.lastPathComponent)
            }
        }
        return removed
    }

    /// journal 完整性校验：返回问题清单（空=通过）
    public static func integrityProblems(events: [RefreshJournalEvent],
                                         fileNameStem: String) -> [String] {
        var problems: [String] = []
        guard let first = events.first else { return problems }
        if first.event != RefreshJournalEventName.batchStart {
            problems.append("首事件不是 batch-start（实际 \(first.event)）")
        }
        let startCount = events.filter { $0.event == RefreshJournalEventName.batchStart }.count
        if startCount > 1 { problems.append("batch-start 出现 \(startCount) 次（应唯一）") }
        if first.event == RefreshJournalEventName.batchStart, first.booksTotal == nil {
            problems.append("batch-start 缺 books_total 声明数")
        }
        if let declared = first.batchID, declared != fileNameStem {
            problems.append("事件 batch_id（\(declared)）与文件名（\(fileNameStem)）不符")
        }
        let batchID = first.batchID ?? fileNameStem
        for e in events where e.batchID != nil && e.batchID != batchID {
            problems.append("事件 batch_id 不一致（\(e.batchID ?? "")）")
            break
        }
        for e in events {
            switch e.event {
            case RefreshJournalEventName.bookStart:
                if e.bookID == nil || e.src == nil {
                    problems.append("book-start 缺 book_id/src 字段")
                }
            case RefreshJournalEventName.bookDone, RefreshJournalEventName.bookSkip, RefreshJournalEventName.bookFail:
                if e.bookID == nil { problems.append("\(e.event) 缺 book_id 字段") }
            default:
                break
            }
        }
        var settledSeen = Set<String>()
        for e in events {
            guard [RefreshJournalEventName.bookDone, RefreshJournalEventName.bookSkip,
                   RefreshJournalEventName.bookFail].contains(e.event),
                  let id = e.bookID else { continue }
            if !settledSeen.insert(id).inserted {
                problems.append("书 \(id) 存在重复终态记录（\(e.event)）——损坏或串批嫌疑")
                break
            }
        }
        return problems
    }
}
