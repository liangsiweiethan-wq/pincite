import Foundation
import PDFKit

// MARK: - 索引刷新引擎 RefreshEngine（实现；同日合并扩容）

public final class RefreshEngine: @unchecked Sendable {

    // MARK: - 类型

    public enum Phase: String, Equatable, Sendable {
        case idle
        case backingUp
        case running
        case paused
        case stopped
        case completed
        case completedWithResidue
    }

    public enum BatchKind: String, Sendable {
        case ledger
        case syncRepair = "sync-repair"
    }

    /// 计划内单书（终账行 ↔ 库内书行的配对结果）。
    public struct PlanBook: Equatable, Sendable {
        public let bookID: String
        public let src: String
        public let shaExpect: String?
        public let declaredPages: Int?
        public let fileName: String
        public let title: String?

        /// 展示名（标题缺省回文件名——与书目列表同基准）。
        public var displayName: String { title ?? fileName }

        public init(bookID: String, src: String, shaExpect: String?,
                    declaredPages: Int?, fileName: String, title: String?) {
            self.bookID = bookID
            self.src = src
            self.shaExpect = shaExpect
            self.declaredPages = declaredPages
            self.fileName = fileName
            self.title = title
        }
    }

    public struct BatchPlan: Equatable, Sendable {
        public let ledgerPath: String
        public let books: [PlanBook]
        /// 终账有行、库里无对应书行的 src（只展示，不进刷新清单）。
        public let unresolvedSources: [String]

        public var pagesTotal: Int { books.reduce(0) { $0 + ($1.declaredPages ?? 0) } }

        public init(ledgerPath: String, books: [PlanBook], unresolvedSources: [String]) {
            self.ledgerPath = ledgerPath
            self.books = books
            self.unresolvedSources = unresolvedSources
        }
    }

    /// 失败书行（错误清单，可从面板复制或导出）。
    public struct BookFailure: Equatable, Sendable {
        public let bookID: String
        public let fileName: String
        public let message: String
    }

    // MARK: 同步对账（同步只读检查）

    /// 单书对账结果。issue=nil 即一致；差异＝issue 非 nil。
    public struct SyncAuditRow: Equatable, Sendable {
        public enum Issue: String, Equatable, Sendable {
            /// 盘上 sha256 ≠ 库内 fingerprint——窗口期红条书（可修复）。
            case mismatch
            /// 盘上文件缺失（不可由重索引修复，如实列）。
            case missingFile
            /// 文件不可读/哈希失败（如实列）。
            case readError
        }

        public let bookID: String
        public let fileName: String
        public let title: String?
        public let realPath: String
        public let dbFingerprint: String
        public let diskFingerprint: String?
        public let pageCount: Int
        public let issue: Issue?

        public var isDifference: Bool { issue != nil }
        /// 指纹前 8 位（差异清单展示基准）。
        public var dbSha8: String { String(dbFingerprint.prefix(8)) }
        public var diskSha8: String? { diskFingerprint.map { String($0.prefix(8)) } }
    }

    public struct SyncAuditResult: Equatable, Sendable {
        public let audited: Int
        public let rows: [SyncAuditRow]
        public var matched: Int { rows.filter { !$0.isDifference }.count }
        public var differences: [SyncAuditRow] { rows.filter(\.isDifference) }
        /// 可修复＝指纹失配书（missingFile/readError 不在修复范围）。
        public var repairable: [SyncAuditRow] { rows.filter { $0.issue == .mismatch } }
        public var missingFiles: [SyncAuditRow] { rows.filter { $0.issue == .missingFile } }
    }

    // MARK: 收尾三向对账

    public struct FinalCheckRow: Equatable, Sendable {
        public let bookID: String
        public let fileName: String
        public let ledgerSha8: String?
        public let dbSha8: String?
        public let diskSha8: String?
        public let pagesLedger: Int?
        public let pagesDB: Int?
        public let pagesDisk: Int?
        public let ok: Bool
        public let reasons: [String]
    }

    public struct FinalCheckResult: Equatable, Sendable {
        public let rows: [FinalCheckRow]
        /// 批间抽验失败残留（非空则整批不判 PASS）。
        public let probeFailures: [String]
        public var pass: Bool { rows.allSatisfy(\.ok) && probeFailures.isEmpty }
        public var booksOk: Int { rows.filter(\.ok).count }
        public var booksFailed: Int { rows.count - booksOk }
        /// 盘上 sha ≠ 库内 fingerprint 的行数（窗口期残留量）。
        public var shaMismatch: Int { rows.filter { $0.dbSha8 != $0.diskSha8 }.count }

        public init(rows: [FinalCheckRow], probeFailures: [String] = []) {
            self.rows = rows
            self.probeFailures = probeFailures
        }
    }

    public struct ResumableBatch: Equatable, Sendable {
        public let batchID: String
        public let kind: BatchKind
        public let plan: BatchPlan
        public let completedBookIDs: Set<String>
        public let failures: [BookFailure]
        public let succeededBookIDs: Set<String>
        /// 已终态书按 journal 落盘序（抽验样本取最近结算书）。
        public let settledOrder: [String]
        /// 上次运行的批间抽验失败原文，用于跨启动保留；续跑后重新通过
        /// 重新通过抽验，残留持续拖住收尾 PASS）。
        public let probeFailures: [String]
        public let pendingCount: Int
    }

    /// 进度快照（批/书/页三层计数＋ETA—— 基准）。
    public struct Progress: Equatable, Sendable {
        public var phase: Phase = .idle
        public var batchID: String?
        public var batchKind: String?
        public var booksTotal: Int = 0
        public var booksDone: Int = 0
        public var booksFailed: Int = 0
        public var currentBookName: String?
        public var currentBookIndex: Int = 0
        // 页级进度（当前书）。
        public var currentBookPages: Int?
        public var currentBookPagesDone: Int?
        public var pagesSettled: Int = 0
        public var pagesPlanTotal: Int = 0
        public var ratePagesPerSecond: Double?
        public var etaSeconds: Int?
        public var elapsedActiveSeconds: Double = 0
        public var failed: [BookFailure] = []
        public var succeededBookIDs: Set<String> = []
        public var journalLines: Int = 0
        public var finalCheck: FinalCheckResult?
        /// 收尾顺带建页统计覆盖索引的结果（did/已建/已跳过/已失败）。
        public var pageStatsIndex: IndexStore.PageStatsIndexResult?
        /// 引擎级错误（备份失败/写 journal 失败等；batch 不开跑的直接原因）。
        public var lastError: String?

        public init() {}
    }

    // MARK: - 注入

    public let dbURL: URL
    public let policy: ExclusionPolicy
    public let snapshotDir: URL
    public let journalDir: URL
    /// 备份库源（SnapshotManager 基准；缺省 [("index", dbURL)]）。
    public let snapshotSources: [(name: String, url: URL)]

    /// 进度回调（锁内构造、锁外回调；调用方负责跳主线程）。
    public var onUpdate: (@Sendable (Progress) -> Void)?
    /// 测试注入点（密闭化说明，与 SnapshotManager.backupStepOverride 同款
    /// 纪律）：每本书终态落 journal 后调用（参数=计划内序号）。生产恒 nil。
    public var perBookHook: (@Sendable (Int) -> Void)?
    /// 测试注入点（密闭化说明）：批间抽验间隔（本数）。生产 50；测试调小
    /// 以触发。样本量 auditProbeSampleSize 同理（生产 5）。
    var auditProbeInterval = 50
    var auditProbeSampleSize = 5
    /// 测试注入点（密闭化说明，appendFailureHook 同款纪律）
    /// 名单内事件的 journal 写入抛错（模拟写失败）。生产恒空。
    var appendFailureEventNames: Set<String> = []

    // MARK: - 状态（锁保护）

    private let lock = NSLock()
    private var phase: Phase = .idle
    private var pauseRequested = false
    private var stopRequested = false
    private var currentPlan: BatchPlan?
    private var currentBatchID: String?
    private var currentKind: BatchKind = .ledger
    private var completedBookIDs: Set<String> = []
    private var failures: [BookFailure] = []
    private var journalLineCount = 0
    private var progress = Progress()
    private var lastError: String?
    private var throughputWindow: [(pages: Int, seconds: Double)] = []
    private var activeAccum: TimeInterval = 0
    private var activeSince: Date?
    private var settledOrder: [String] = []
    private var booksSinceProbe = 0

    // MARK: - 初始化

    public init(dbURL: URL,
                policy: ExclusionPolicy = ExclusionPolicy(),
                snapshotDir: URL,
                journalDir: URL,
                snapshotSources: [(name: String, url: URL)]? = nil) {
        self.dbURL = dbURL
        self.policy = policy
        self.snapshotDir = snapshotDir
        self.journalDir = journalDir
        self.snapshotSources = snapshotSources ?? [("index", dbURL)]
    }

    // MARK: - 计划生成（纯读零写）

    public func loadLedger(_ ledgerURL: URL) throws -> BatchPlan {
        guard let text = try? String(contentsOf: ledgerURL, encoding: .utf8) else {
            throw NSError(domain: "RefreshEngineError", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cannot read ledger: \(ledgerURL.path)"])
        }
        struct Row { var src: String; var shaAfter: String?; var pages: Int? }
        var latest: [String: Row] = [:]
        var order: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let src = obj["src"] as? String, !src.isEmpty else { continue }
            if latest[src] == nil { order.append(src) }
            latest[src] = Row(src: src,
                              shaAfter: obj["sha_after"] as? String,
                              pages: obj["pages"] as? Int)
        }
        // 库内书行快照一次（real_path → 行；allBooks 纯读）。
        let store = try IndexStore(path: dbURL)
        let byPath = Dictionary(uniqueKeysWithValues: (try store.allBooks()).map { ($0.realPath, $0) })

        var books: [PlanBook] = []
        var unresolved: [String] = []
        for src in order {
            guard let row = latest[src], row.shaAfter != nil else { continue }
            if let book = byPath[src] {
                books.append(PlanBook(bookID: book.id,
                                      src: src,
                                      shaExpect: row.shaAfter,
                                      declaredPages: row.pages,
                                      fileName: book.fileName,
                                      title: book.title))
            } else {
                unresolved.append(src)
            }
        }
        return BatchPlan(ledgerPath: ledgerURL.path, books: books, unresolvedSources: unresolved)
    }

    // MARK: 同步对账（只读半步，句柄层零写）

    /// 全库只读对账：逐书比盘上 sha256 与库内 fingerprint（＋sha8 展示与
    /// OCR 配对无关的如实基准：missingFile/readError 如实列）。全程
    /// SQLITE_OPEN_READONLY——不开 IndexStore、句柄层拿不到写权限。
    public func auditLibrary(onProgress: (@Sendable (Int, Int) -> Void)? = nil) throws -> SyncAuditResult {
        let db = try SQLiteDatabase(path: dbURL.path, flags: SQLiteDatabase.readOnlyFlags)
        let stmt = try db.prepare(
            "SELECT id, real_path, file_name, title, fingerprint, page_count FROM books ORDER BY file_name;")
        var rows: [SyncAuditRow] = []
        while try stmt.step() {
            let id = stmt.text(0)
            let realPath = stmt.text(1)
            let fileName = stmt.text(2)
            let title = stmt.textOrNull(3)
            let fingerprint = stmt.text(4)
            let pageCount = Int(stmt.int(5))
            var issue: SyncAuditRow.Issue?
            var diskFP: String?
            let url = URL(fileURLWithPath: realPath)
            if !FileManager.default.fileExists(atPath: url.path) {
                issue = .missingFile
            } else if let sha = try? Fingerprint.sha256Hex(ofFileAt: url) {
                diskFP = sha
                if sha != fingerprint { issue = .mismatch }
            } else {
                issue = .readError
            }
            rows.append(SyncAuditRow(bookID: id, fileName: fileName, title: title,
                                     realPath: realPath, dbFingerprint: fingerprint,
                                     diskFingerprint: diskFP, pageCount: pageCount,
                                     issue: issue))
            onProgress?(rows.count, -1)
        }
        return SyncAuditResult(audited: rows.count, rows: rows)
    }


    @discardableResult
    public func start(plan: BatchPlan, kind: BatchKind = .ledger) async -> Bool {
        lock.lock()
        guard phase == .idle || phase == .stopped || phase == .completed || phase == .completedWithResidue else {
            lock.unlock()
            return false
        }
        lock.unlock()

        // 开跑前自动备份（唯一快照）：备份失败＝不开跑。
        setPhase(.backingUp)
        do {
            let manager = SnapshotManager(snapshotDir: snapshotDir, sources: snapshotSources, keep: 1)
            _ = try manager.takeSnapshot()
        } catch {
            failClosed(error)
            return false
        }

        // 已有同名 journal 时添加后缀，避免追加或覆盖既有文件。
        let batchID = RefreshJournal.uniqueBatchID(in: journalDir)
        lock.lock()
        currentPlan = plan
        currentBatchID = batchID
        currentKind = kind
        completedBookIDs = []
        failures = []
        // 新批显式清零生命周期旗标——旧批
        // 残留（暂停/停止请求）绝不带进新批首书。
        pauseRequested = false
        stopRequested = false
        journalLineCount = 0
        throughputWindow = []
        activeAccum = 0
        activeSince = nil
        settledOrder = []
        booksSinceProbe = 0
        progress = Progress()
        progress.phase = .backingUp
        progress.batchID = batchID
        progress.batchKind = kind == .syncRepair ? BatchKind.syncRepair.rawValue : nil
        progress.booksTotal = plan.books.count
        progress.pagesPlanTotal = plan.pagesTotal
        lock.unlock()

        // journal 只留最近一份：新批开跑删旧批。
        let journalURL = journalDir.appendingPathComponent(RefreshJournal.fileName(forBatchID: batchID))
        do {
            let writer = try RefreshJournal.Writer(directory: journalDir, batchID: batchID)
            RefreshJournal.pruneOldJournals(in: journalDir, keeping: journalURL)
            // 完整计划随首事件持久化——崩溃后续跑
            // 只认这份清单，从未开跑的书天然在待跑集合里。
            let journalPlan = plan.books.map {
                JournalPlanBook(bookID: $0.bookID, src: $0.src, shaExpect: $0.shaExpect,
                                declaredPages: $0.declaredPages, fileName: $0.fileName,
                                title: $0.title)
            }
            try append(writer) {
                RefreshJournalEvent(event: RefreshJournalEventName.batchStart,
                                    batchID: batchID,
                                    kind: kind == .syncRepair ? BatchKind.syncRepair.rawValue : nil,
                                    ledger: kind == .ledger ? plan.ledgerPath : nil,
                                    booksTotal: plan.books.count,
                                    pagesTotal: plan.pagesTotal,
                                    plan: journalPlan,
                                    planVersion: RefreshJournal.currentPlanVersion)
            }
            setPhase(.running)
            noteActiveStart()
            await runRemainingBooks(plan: plan, writer: writer)
            return true
        } catch {
            failClosed(error)
            return false
        }
    }

    @discardableResult
    public func repair(books: [SyncAuditRow]) async -> Bool {
        let planBooks = books.map {
            PlanBook(bookID: $0.bookID, src: $0.realPath, shaExpect: nil,
                     declaredPages: $0.pageCount, fileName: $0.fileName, title: $0.title)
        }
        guard !planBooks.isEmpty else { return false }
        let plan = BatchPlan(ledgerPath: "", books: planBooks, unresolvedSources: [])
        return await start(plan: plan, kind: .syncRepair)
    }

    /// 暂停：当前书跑完后停在书边界（不打断书内事务）。
    public func pause() {
        lock.lock()
        if phase == .running { pauseRequested = true }
        lock.unlock()
    }

    /// 继续（会话内）：从计划内未完成的书接着跑。
    /// paused/stopped 起可续；续跑前若无快照先补备一份再动库。
    @discardableResult
    public func resume() async -> Bool {
        lock.lock()
        guard phase == .paused || phase == .stopped,
              let plan = currentPlan, currentBatchID != nil else {
            lock.unlock()
            return false
        }
        pauseRequested = false
        stopRequested = false
        lock.unlock()

        if !(await runWithFreshSnapshotIfMissing(plan: plan)) { return false }
        do {
            let writer = try RefreshJournal.Writer(directory: journalDir, batchID: currentBatchIDNonNil())
            try append(writer) {
                RefreshJournalEvent(event: RefreshJournalEventName.batchResume,
                                    batchID: currentBatchIDNonNil())
            }
            setPhase(.running)
            noteActiveStart()
            await runRemainingBooks(plan: plan, writer: writer, probeFirst: true)
            return true
        } catch {
            failClosed(error)
            return false
        }
    }

    /// 跨启动续跑（崩溃三态恢复）：读最近 journal，未收尾且有待跑书时，
    /// 按 batch-start 内嵌完整计划重建（计划缺失/
    /// 版本不符/自洽性不过一律问题并把原因落 lastError，绝不降级处理反推）
    /// → 种入已完成集合续跑。悬挂书（有 book-start 无终态）归待跑重放。
    /// 续跑前若无快照先补备（fail-closed 同款）。
    @discardableResult
    public func resumeLastBatch() async -> Bool {
        lock.lock()
        let ph = phase
        lock.unlock()
        guard ph != .running, ph != .backingUp else { return false }
        guard let resumable = loadResumableBatch() else {
            if let reason = lastResumableBlockReason() {
                failClosed(NSError(domain: "RefreshEngineError", code: 3,
                                   userInfo: [NSLocalizedDescriptionKey: reason]))
            }
            return false
        }

        // 已终态书计数镜像 journal：done+skip 与 fail 分开。
        let settledCount = resumable.plan.books
            .filter { resumable.completedBookIDs.contains($0.bookID) }.count
        lock.lock()
        currentPlan = resumable.plan
        currentBatchID = resumable.batchID
        currentKind = resumable.kind
        completedBookIDs = resumable.completedBookIDs
        failures = resumable.failures
        journalLineCount = RefreshJournal.readEvents(
            at: journalDir.appendingPathComponent(RefreshJournal.fileName(forBatchID: resumable.batchID))).count
        throughputWindow = []
        activeAccum = 0
        activeSince = nil
        // 按 journal 落盘序恢复——抽验样本取最近结算书（非 Set 随机序）。
        settledOrder = resumable.settledOrder
        booksSinceProbe = 0
        progress = Progress()
        progress.phase = .backingUp
        progress.batchID = resumable.batchID
        progress.batchKind = resumable.kind == .syncRepair ? BatchKind.syncRepair.rawValue : nil
        progress.booksTotal = resumable.plan.books.count
        progress.pagesPlanTotal = resumable.plan.pagesTotal
        // 抽验残留种子不计入失败书数（progress.failed 全量保留供展示/收尾对账）。
        progress.booksFailed = resumable.failures.filter { $0.bookID != "audit-probe" }.count
        progress.booksDone = settledCount - progress.booksFailed
        progress.succeededBookIDs = resumable.succeededBookIDs
        progress.failed = resumable.failures
        progress.journalLines = journalLineCount
        lock.unlock()
        publishLocked()

        if !(await runWithFreshSnapshotIfMissing(plan: resumable.plan)) { return false }
        do {
            let writer = try RefreshJournal.Writer(directory: journalDir, batchID: resumable.batchID)
            try append(writer) {
                RefreshJournalEvent(event: RefreshJournalEventName.batchResume,
                                    batchID: resumable.batchID)
            }
            setPhase(.running)
            noteActiveStart()
            await runRemainingBooks(plan: resumable.plan, writer: writer, probeFirst: true)
            return true
        } catch {
            failClosed(error)
            return false
        }
    }

    public func loadResumableBatch() -> ResumableBatch? {
        guard let url = RefreshJournal.latestJournalURL(in: journalDir),
              let summary = RefreshJournal.summarize(at: url) else {
            recordResumableBlock(nil)
            return nil
        }
        guard summary.unfinished else {
            recordResumableBlock(nil)
            return nil
        }

        let problems = RefreshJournal.integrityProblems(
            events: RefreshJournal.readEvents(at: url),
            fileNameStem: url.deletingPathExtension().lastPathComponent)
        if !problems.isEmpty {
            recordResumableBlock("journal 完整性不过：\(problems.joined(separator: "；"))——已阻断续跑（防串批/防缺字段记录绕过计划归属）")
            return nil
        }

        guard let planBooks = summary.planBooks, !planBooks.isEmpty else {
            recordResumableBlock("上次批次（\(summary.batchID)）的 journal 缺完整计划记录（旧版格式）——已阻断续跑，不会按开跑记录猜测书单；请重新载入终账生成计划后开启新批")
            return nil
        }
        guard let version = summary.planVersion else {
            recordResumableBlock("上次批次的计划缺版本标记——已阻断续跑")
            return nil
        }
        guard version == RefreshJournal.currentPlanVersion else {
            recordResumableBlock("计划版本不符（journal \(version) ≠ 现行 \(RefreshJournal.currentPlanVersion)）——已阻断续跑")
            return nil
        }
        if let total = summary.booksTotal, total != planBooks.count {
            recordResumableBlock("计划书数（\(planBooks.count)）与批次声明（\(total)）不符——journal 自洽性不过，已阻断续跑")
            return nil
        }
        let planIDs = Set(planBooks.map(\.bookID))
        guard planIDs.count == planBooks.count else {
            recordResumableBlock("计划内书号重复——journal 损坏嫌疑，已阻断续跑")
            return nil
        }
        if !Set(summary.bookVerdicts.keys).isSubset(of: planIDs)
            || !Set(summary.startedBooks.map(\.bookID)).isSubset(of: planIDs) {
            recordResumableBlock("journal 内存在计划外书的记录——防串批，已阻断续跑")
            return nil
        }

        let books = planBooks.map {
            PlanBook(bookID: $0.bookID, src: $0.src, shaExpect: $0.shaExpect,
                     declaredPages: $0.declaredPages, fileName: $0.fileName, title: $0.title)
        }
        // kind 未知值 fail-closed——写侧值域只有 nil（ledger）
        // 与 "sync-repair"；其余＝损坏或串批嫌疑，绝不静默按 ledger 解释。
        let kind: BatchKind
        switch summary.kind {
        case nil: kind = .ledger
        case BatchKind.syncRepair.rawValue: kind = .syncRepair
        default:
            recordResumableBlock("journal 批次 kind（\(summary.kind ?? "")）不在允许值域（ledger/sync-repair）——损坏或串批嫌疑，已阻断续跑")
            return nil
        }
        let resolved = BatchPlan(ledgerPath: summary.ledgerPath ?? "",
                                 books: books, unresolvedSources: [])
        let completed = Set(summary.bookVerdicts.keys)
        let byID = Dictionary(uniqueKeysWithValues: books.map { ($0.bookID, $0) })
        var seededFailures: [BookFailure] = []
        for (id, message) in summary.failures {
            let fileName = byID[id]?.fileName ?? id
            seededFailures.append(BookFailure(bookID: id, fileName: fileName,
                                              message: message.isEmpty ? "上次运行失败" : message))
        }
        // 抽验失败跨启动保留——载入错误清单（收尾对账据此保持
        // 残留），续跑段须重新通过抽验。
        for err in summary.auditFailures {
            seededFailures.append(BookFailure(bookID: "audit-probe",
                                              fileName: "批间抽验",
                                              message: "上次运行抽验失败（跨启动保留）：\(err)"))
        }
        let pending = books.filter { !completed.contains($0.bookID) }.count
        let succeeded = Set(summary.bookVerdicts
            .filter { $0.value == RefreshJournalEventName.bookDone
                   || $0.value == RefreshJournalEventName.bookSkip }
            .map { $0.key })
        recordResumableBlock(nil)
        return ResumableBatch(batchID: summary.batchID,
                              kind: kind,
                              plan: resolved,
                              completedBookIDs: completed,
                              failures: seededFailures,
                              succeededBookIDs: succeeded,
                              settledOrder: summary.settledOrder,
                              probeFailures: summary.auditFailures,
                              pendingCount: pending)
    }

    // MARK: 续跑问题原因（锁保护）

    private var resumableBlockReason: String?

    private func recordResumableBlock(_ reason: String?) {
        lock.lock()
        resumableBlockReason = reason
        lock.unlock()
    }

    /// 只读：最近一次 loadResumableBatch 判「不可续」的问题原因（面板经
    public func lastResumableBlockReason() -> String? {
        lock.lock(); defer { lock.unlock() }
        return resumableBlockReason
    }

    /// 停止：当前书收摊（书边界），journal 落 batch-stop；已完成部分保留。
    /// paused 态无在跑书，直接收摊。
    public func stop() {
        lock.lock()
        let inLoop = (phase == .running)
        guard phase == .running || phase == .paused else { lock.unlock(); return }
        stopRequested = true
        let batchID = currentBatchID
        lock.unlock()
        if !inLoop, let batchID {
            // 暂停态直接停止：补 batch-stop 终态行（journal 读侧据此判已收尾）。
            // Writer 建不出或事件写失败＝恢复依据丢失——
            // fail-closed（不切 .stopped，绝不假装已停止）。
            do {
                let writer = try RefreshJournal.Writer(directory: journalDir, batchID: batchID)
                try append(writer) {
                    RefreshJournalEvent(event: RefreshJournalEventName.batchStop, batchID: batchID)
                }
            } catch {
                failClosed(error)
                return
            }
            noteActiveBoundary()
            setPhase(.stopped)
        }
        // running 态由 run loop 在书边界收摊。
    }

    /// 只读：当前进度快照。
    public func currentProgress() -> Progress {
        lock.lock(); defer { lock.unlock() }
        var snapshot = progress
        // 活跃时长是即时量：发布快照时按需合成（running 中含当前段）。
        if snapshot.phase == .running, let since = activeSince {
            snapshot.elapsedActiveSeconds = activeAccum + Date().timeIntervalSince(since)
        } else {
            snapshot.elapsedActiveSeconds = activeAccum
        }
        return snapshot
    }

    // MARK: - 运行环（书边界循环）

    private func runRemainingBooks(plan: BatchPlan, writer: RefreshJournal.Writer,
                                   probeFirst: Bool = false) async {
        guard let store = try? IndexStore(path: dbURL) else {
            failClosed(NSError(domain: "RefreshEngineError", code: 2,
                               userInfo: [NSLocalizedDescriptionKey: "cannot open index store: \(dbURL.path)"]))
            return
        }
        let indexingEngine = IndexingEngine(store: store, policy: policy)
        let pending = plan.books.filter { !completedBookIDsCopy().contains($0.bookID) }
        var skipLoop = false
        // 门禁不设 pending 非空前提——全书已结算＋抽验残留的收尾
        // 续跑同样先过抽验（不过→全终态按残留收尾，语义不变）。
        if probeFirst, !completedBookIDsCopy().isEmpty {
            do { try runAuditProbe(store: store, plan: plan, writer: writer) }
            catch {
                lock.lock()
                pauseRequested = true
                failures.append(BookFailure(bookID: "audit-probe",
                                            fileName: "批间抽验",
                                            message: "续跑前抽验执行失败：\(error)"))
                progress.failed = failures
                lock.unlock()
                publishLocked()
            }
            if pauseRequestedCopy() {
                lock.lock()
                let allSettled = progress.booksDone + progress.booksFailed >= plan.books.count
                lock.unlock()
                if allSettled {
                    // 全数已终态：按收尾语义继续（残留如实列）。门禁旗标必须
                    // 就地清除——否则残留到下一批，start 后
                    // 首书即被旧旗标暂停（「污染下一批」形态）。
                    lock.lock()
                    pauseRequested = false
                    lock.unlock()
                    skipLoop = true
                } else {
                    finishPaused(writer)
                    return
                }
            }
        }
        var index = 0
        if !skipLoop {
            for book in pending {
            lock.lock()
            if stopRequested {
                lock.unlock()
                finishStopped(writer)
                return
            }
            if pauseRequested {
                lock.unlock()
                finishPaused(writer)
                return
            }
            progress.currentBookName = book.displayName
            progress.currentBookIndex = index + 1
            progress.currentBookPages = book.declaredPages
            progress.currentBookPagesDone = book.declaredPages != nil ? 0 : nil
            lock.unlock()
            publishLocked()

            // journal 写失败＝断点依据丢失——立即
            // fail-closed 停批（不再写库、不宣告完成），绝不 try? 吞掉。
            do {
                try append(writer) {
                    RefreshJournalEvent(event: RefreshJournalEventName.bookStart,
                                        batchID: currentBatchIDNonNil(),
                                        bookID: book.bookID,
                                        src: book.src,
                                        shaExpect: book.shaExpect)
                }
            } catch {
                failClosed(error)
                return
            }

            // 页级进度回调：逐页回调经 reindexBook 透传抽取循环。
            let result = (try? await indexingEngine.reindexBook(bookID: book.bookID) { [weak self] page, _ in
                guard let self else { return }
                self.lock.lock()
                self.progress.currentBookPagesDone = page
                self.progress.currentBookPages = max(self.progress.currentBookPages ?? 0, page)
                self.lock.unlock()
                self.publishLocked()
            }) ?? IndexingEngine.ReindexBookResult(bookID: book.bookID,
                                                   verdict: .error, pages: 0, seconds: 0,
                                                   message: "engine call failed")

            let eventName: String
            switch result.verdict {
            case .updated: eventName = RefreshJournalEventName.bookDone
            case .unchanged: eventName = RefreshJournalEventName.bookSkip
            case .missing, .error: eventName = RefreshJournalEventName.bookFail
            }
            do {
                try append(writer) {
                    RefreshJournalEvent(event: eventName,
                                        batchID: currentBatchIDNonNil(),
                                        bookID: book.bookID,
                                        src: book.src,
                                        shaExpect: book.shaExpect,
                                        pages: result.pages,
                                        verdict: result.verdict.rawValue,
                                        error: result.message)
                }
            } catch {
                failClosed(error)
                return
            }

            lock.lock()
            completedBookIDs.insert(book.bookID)
            settledOrder.append(book.bookID)
            booksSinceProbe += 1
            switch result.verdict {
            case .updated, .unchanged:
                progress.booksDone += 1
                progress.succeededBookIDs.insert(book.bookID)
            case .missing, .error:
                progress.booksFailed += 1
                failures.append(BookFailure(bookID: book.bookID,
                                            fileName: book.fileName,
                                            message: result.message ?? result.verdict.rawValue))
                progress.failed = failures
            }
            progress.currentBookName = nil
            progress.currentBookPagesDone = result.pages > 0 ? result.pages : progress.currentBookPagesDone
            progress.pagesSettled += max(result.pages, 0)
            throughputWindow.append((max(result.pages, 0), max(result.seconds, 0.001)))
            if throughputWindow.count > 20 { throughputWindow.removeFirst() }
            let windowPages = throughputWindow.reduce(0) { $0 + $1.pages }
            let windowSeconds = throughputWindow.reduce(0.0) { $0 + $1.seconds }
            if windowSeconds > 0, windowPages > 0 {
                let rate = Double(windowPages) / windowSeconds
                if rate.isFinite, rate > 0 {
                    progress.ratePagesPerSecond = rate
                    let remaining = Double(progress.pagesPlanTotal - progress.pagesSettled)
                    if remaining > 0 {
                        let eta = remaining / rate
                        progress.etaSeconds = eta.isFinite ? Int(eta.rounded()) : nil
                    } else {
                        progress.etaSeconds = 0
                    }
                }
            }
            lock.unlock()
            publishLocked()
            perBookHook?(index)
            index += 1

            // 批间只读抽验：到间隔即抽最近样本；不过自动暂停。
            if booksSinceProbe >= auditProbeInterval {
                lock.lock(); booksSinceProbe = 0; lock.unlock()
                do {
                    try runAuditProbe(store: store, plan: plan, writer: writer)
                } catch {
                    // 探针 SQL/检索抛错或抽验账目写失败——与抽验不过同样处理，
                    // 一律置暂停不续写。
                    lock.lock()
                    pauseRequested = true
                    failures.append(BookFailure(bookID: "audit-probe",
                                                fileName: "批间抽验",
                                                message: "抽验执行失败：\(error)"))
                    progress.failed = failures
                    lock.unlock()
                    publishLocked()
                }
                lock.lock()
                let paused = pauseRequested
                lock.unlock()
                if paused {
                    // 抽验不过已置暂停：书已全部终态则照常收尾（残留如实列），
                    // 否则立即在书边界收摊暂停（「不继续写」）。
                    lock.lock()
                    if progress.booksDone + progress.booksFailed >= plan.books.count {
                        pauseRequested = false
                        lock.unlock()
                        break
                    }
                    lock.unlock()
                    finishPaused(writer)
                    return
                }
            }
            }
        }
        let check = finalThreeWayCheck(plan: plan, store: store)
        lock.lock()
        progress.finalCheck = check
        lock.unlock()
        do {
            try append(writer) {
                RefreshJournalEvent(event: RefreshJournalEventName.batchFinalize,
                                    batchID: currentBatchIDNonNil(),
                                    checkBooksOk: check.booksOk,
                                    checkBooksFailed: check.booksFailed,
                                    checkShaMismatch: check.shaMismatch,
                                    checkProbesFailed: check.probeFailures.count)
            }
        } catch {
            failClosed(error)
            return
        }
        do {
            try append(writer) {
                var e = RefreshJournalEvent(event: RefreshJournalEventName.batchComplete,
                                            batchID: currentBatchIDNonNil())
                e.booksTotal = plan.books.count
                e.pagesTotal = pagesSettledCopy()
                return e
            }
        } catch {
            failClosed(error)
            return
        }
        buildPageStatsIndex(store: store)
        noteActiveBoundary()
        setPhase(check.pass ? .completed : .completedWithResidue)
    }

    private func buildPageStatsIndex(store: IndexStore) {
        let result = store.ensurePageStatsIndex()
        lock.lock()
        progress.pageStatsIndex = result
        lock.unlock()
        publishLocked()
    }

    /// 批间只读抽验（借 IndexReplicaManager「校验过了才继续」纪律）：
    private func runAuditProbe(store: IndexStore, plan: BatchPlan, writer: RefreshJournal.Writer) throws {
        lock.lock()
        let sampleIDs = Array(settledOrder.suffix(auditProbeSampleSize))
        lock.unlock()
        let byID = Dictionary(uniqueKeysWithValues: plan.books.map { ($0.bookID, $0) })
        var errors: [String] = []

        for id in sampleIDs {
            let display = byID[id]?.displayName ?? id
            do {
                guard let row = try store.book(byID: id) else {
                    errors.append("抽验不过：\(display)——库内无书行")
                    continue
                }
                let url = URL(fileURLWithPath: row.realPath)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    errors.append("抽验不过：\(display)——盘上文件缺失")
                    continue
                }
                let sha = try Fingerprint.sha256Hex(ofFileAt: url)
                if sha != row.fingerprint {
                    errors.append("抽验不过：\(display)——指纹不一致（库 \(String(row.fingerprint.prefix(8))) ≠ 盘 \(String(sha.prefix(8)))）")
                }
                do {
                    let countStmt = try store.db.prepare(
                        "SELECT COUNT(*) FROM \(store.ftQual)pages WHERE book_id = ?;")
                    try countStmt.bindText(1, id)
                    var pageRows = 0
                    if try countStmt.step() { pageRows = Int(countStmt.int(0)) }
                    if pageRows != row.pageCount {
                        errors.append("抽验不过：\(display)——页行数 \(pageRows) ≠ 声明 \(row.pageCount)")
                    }
                } catch {
                    errors.append("抽验不过：\(display)——页行数查询失败：\(error)")
                }
            } catch {
                errors.append("抽验不过：\(display)——\(error)")
            }
        }

        // FTS 探针：样本首页取词真检索，返回须非空；取词/检索
        // 抛错计入失败——仅「确认无文本」才明确跳过）。
        var probeTerm: String?
        do {
            for id in sampleIDs {
                let stmt = try store.db.prepare(
                    "SELECT text_norm FROM \(store.ftQual)pages WHERE book_id = ? AND page_number = 1 LIMIT 1;")
                try stmt.bindText(1, id)
                if try stmt.step() {
                    probeTerm = Self.firstSearchTerm(in: stmt.text(0))
                    if probeTerm != nil { break }
                }
            }
        } catch {
            errors.append("抽验不过：FTS 探针取词失败：\(error)")
        }
        if let term = probeTerm {
            do {
                let service = SearchService(store: store, policy: policy)
                let result = try service.searchDetailed(term, options: SearchOptions(limit: 1))
                if result.totalPageMatches == 0 {
                    errors.append("抽验不过：FTS 探针零命中（词「\(term)」）")
                }
            } catch {
                errors.append("抽验不过：FTS 探针执行失败（词「\(term)」）：\(error)")
            }
        }

        if errors.isEmpty {
            try append(writer) {
                RefreshJournalEvent(event: RefreshJournalEventName.auditPass,
                                    batchID: currentBatchIDNonNil(),
                                    checked: sampleIDs.count)
            }
        } else {
            // 单条合并残留（bookID 恒 "audit-probe"——错误清单行的稳定 id，
            // 消息内逐条列出；多条分裂会造成清单重复 id）。
            lock.lock()
            failures.append(BookFailure(bookID: "audit-probe",
                                        fileName: "批间抽验",
                                        message: errors.joined(separator: "；")))
            progress.failed = failures
            pauseRequested = true
            lock.unlock()
            publishLocked()
            try append(writer) {
                RefreshJournalEvent(event: RefreshJournalEventName.auditFail,
                                    batchID: currentBatchIDNonNil(),
                                    error: errors.joined(separator: "；"),
                                    checked: sampleIDs.count)
            }
        }
    }

    /// 从首页规范文本取一个可检索词（CJK 双字优先，退而拉丁词）。
    static func firstSearchTerm(in normalized: String) -> String? {
        let chars = Array(normalized)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.unicodeScalars.count == 1,
               let sc = c.unicodeScalars.first,
               (0x4E00...0x9FFF).contains(sc.value), i + 1 < chars.count,
               let next = chars[i + 1].unicodeScalars.first,
               (0x4E00...0x9FFF).contains(next.value) {
                return String(chars[i...i + 1])
            }
            if c.isLetter, c.isASCII {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber, chars[j].isASCII { j += 1 }
                if j - i >= 2 { return String(chars[i..<j]).lowercased() }
                i = j
                continue
            }
            i += 1
        }
        return nil
    }

    /// 收尾三向对账：逐书核 清单 sha_after ＝ 库 fingerprint ＝
    /// 盘上 sha256；页数 清单声明 ＝ 库 page_count ＝ 盘上 PDF 页数；
    /// 失败书（verdict missing/error）一律 ok=false。差异如实列不静默。
    private func finalThreeWayCheck(plan: BatchPlan, store: IndexStore) -> FinalCheckResult {
        var rows: [FinalCheckRow] = []
        let failureByID = Dictionary(failures.map { ($0.bookID, $0.message) },
                                     uniquingKeysWith: { first, _ in first })
        lock.lock()
        let probeFailures = failures.filter { $0.bookID == "audit-probe" }.map(\.message)
        lock.unlock()
        for book in plan.books {
            var reasons: [String] = []
            let dbRow = try? store.book(byID: book.bookID)
            let dbFP = (dbRow?.fingerprint).map { String($0.prefix(8)) }
            let dbPages = dbRow?.pageCount
            var diskFP: String?
            var diskPages: Int?
            let url = URL(fileURLWithPath: book.src)
            if FileManager.default.fileExists(atPath: url.path) {
                diskFP = (try? Fingerprint.sha256Hex(ofFileAt: url)).map { String($0.prefix(8)) }
                diskPages = PDFDocument(url: url)?.pageCount
            }
            if let message = failureByID[book.bookID] {
                reasons.append("批次内失败：\(message)")
            }
            if dbRow == nil { reasons.append("库内无书行") }
            if diskFP == nil { reasons.append("盘上文件缺失或不可读") }
            if let diskFP, let dbFP, diskFP != dbFP {
                reasons.append("库指纹 \(dbFP) ≠ 盘上 \(diskFP)")
            }
            if let expect = book.shaExpect.map({ String($0.prefix(8)) }) {
                let ledgerSha = expect
                if let diskFP, ledgerSha != diskFP { reasons.append("清单 \(ledgerSha) ≠ 盘上 \(diskFP)") }
                if let dbFP, ledgerSha != dbFP { reasons.append("清单 \(ledgerSha) ≠ 库 \(dbFP)") }
            }
            if let declared = book.declaredPages, let dbPages, declared != dbPages {
                reasons.append("页数：清单 \(declared) ≠ 库 \(dbPages)")
            }
            if let diskPages, let dbPages, diskPages != dbPages {
                reasons.append("页数：盘上 \(diskPages) ≠ 库 \(dbPages)")
            }
            if let declared = book.declaredPages, let diskPages, declared != diskPages {
                reasons.append("页数：清单 \(declared) ≠ 盘上 \(diskPages)")
            }
            rows.append(FinalCheckRow(bookID: book.bookID,
                                      fileName: book.fileName,
                                      ledgerSha8: book.shaExpect.map { String($0.prefix(8)) },
                                      dbSha8: dbFP,
                                      diskSha8: diskFP,
                                      pagesLedger: book.declaredPages,
                                      pagesDB: dbPages,
                                      pagesDisk: diskPages,
                                      ok: reasons.isEmpty,
                                      reasons: reasons))
        }
        return FinalCheckResult(rows: rows, probeFailures: probeFailures)
    }

    private func finishPaused(_ writer: RefreshJournal.Writer) {
        // 生命周期事件写失败＝恢复依据丢失——与书级事件同样
        // fail-closed（不清请求旗标、不切相位，内存态绝不假装已暂停）。
        do {
            try append(writer) {
                RefreshJournalEvent(event: RefreshJournalEventName.batchPause, batchID: currentBatchIDNonNil())
            }
        } catch {
            failClosed(error)
            return
        }
        lock.lock()
        pauseRequested = false
        lock.unlock()
        noteActiveBoundary()
        setPhase(.paused)
    }

    private func finishStopped(_ writer: RefreshJournal.Writer) {
        do {
            try append(writer) {
                RefreshJournalEvent(event: RefreshJournalEventName.batchStop, batchID: currentBatchIDNonNil())
            }
        } catch {
            failClosed(error)
            return
        }
        lock.lock()
        stopRequested = false
        lock.unlock()
        noteActiveBoundary()
        setPhase(.stopped)
    }

    /// 续跑前快照检查：无快照先补备，失败＝不续跑（fail-closed）。
    private func runWithFreshSnapshotIfMissing(plan: BatchPlan) async -> Bool {
        let manager = SnapshotManager(snapshotDir: snapshotDir, sources: snapshotSources, keep: 1)
        if manager.listSnapshots().isEmpty {
            setPhase(.backingUp)
            do {
                _ = try manager.takeSnapshot()
            } catch {
                failClosed(error)
                return false
            }
        }
        return true
    }

    // MARK: - 状态小件

    private func pauseRequestedCopy() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pauseRequested
    }

    private func completedBookIDsCopy() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return completedBookIDs
    }

    private func currentBatchIDNonNil() -> String {
        lock.lock(); defer { lock.unlock() }
        return currentBatchID ?? ""
    }

    private func noteActiveStart() {
        lock.lock(); defer { lock.unlock() }
        if activeSince == nil { activeSince = Date() }
    }

    private func noteActiveBoundary() {
        lock.lock(); defer { lock.unlock() }
        if let since = activeSince {
            activeAccum += Date().timeIntervalSince(since)
            activeSince = nil
        }
    }

    private func setPhase(_ newPhase: Phase) {
        lock.lock()
        phase = newPhase
        progress.phase = newPhase
        lock.unlock()
        publishLocked()
    }

    private func failClosed(_ error: Error) {
        lock.lock()
        lastError = String(describing: error)
        progress.lastError = lastError
        phase = .idle
        progress.phase = .idle
        lock.unlock()
        publishLocked()
    }

    private func append(_ writer: RefreshJournal.Writer,
                        _ make: () -> RefreshJournalEvent) throws {
        let event = make()
        // 测试注入点：名单内事件模拟 journal 写失败（生产 appendFailureEventNames 恒空）。
        if appendFailureEventNames.contains(event.event) {
            throw NSError(domain: "RefreshJournalError", code: 99,
                          userInfo: [NSLocalizedDescriptionKey: "注入的 journal 写失败（\(event.event)）"])
        }
        try writer.append(event)
        lock.lock()
        journalLineCount += 1
        progress.journalLines = journalLineCount
        lock.unlock()
    }

    private func publishLocked() {
        lock.lock()
        var snapshot = progress
        if snapshot.phase == .running, let since = activeSince {
            snapshot.elapsedActiveSeconds = activeAccum + Date().timeIntervalSince(since)
        } else {
            snapshot.elapsedActiveSeconds = activeAccum
        }
        let handler = onUpdate
        lock.unlock()
        handler?(snapshot)
    }
}

// MARK: - Progress 私有便利

private extension RefreshEngine {
    /// 锁内读 pagesSettled（batch-complete 载荷；调用点在 append 前、锁外）。
    func pagesSettledCopy() -> Int {
        lock.lock(); defer { lock.unlock() }
        return progress.pagesSettled
    }
}
