import Foundation
import Combine
#if canImport(LiteratureCore)
import LiteratureCore
#endif

// MARK: - 索引刷新控制台 Store（实现；同日合并扩容）

public final class RefreshConsoleStore: ObservableObject {

    // MARK: - 注入

    public let engine: RefreshEngine
    /// 导出目录供给（App 侧接 state.exportDirectoryPath；缺省 nil＝调用方自选）。
    public var exportDirectoryProvider: (() -> URL?)?
    // MARK: - 发布面（主线程）

    @Published public private(set) var phase: RefreshEngine.Phase = .idle
    @Published public private(set) var plan: RefreshEngine.BatchPlan?
    @Published public private(set) var ledgerURL: URL?
    @Published public private(set) var progress: RefreshEngine.Progress = .init()
    @Published public private(set) var journalSummary: RefreshJournalSummary?
    /// 同步对账（只读半步）结果；nil＝尚未对账。
    @Published public private(set) var auditResult: RefreshEngine.SyncAuditResult?
    /// 对账进行中进度（done/total；total 未知时 -1——全库逐书哈希是长活）。
    @Published public private(set) var auditProgressDone = 0
    @Published public private(set) var auditing = false
    /// 已修复书集合（修复半步完成后回填；窗口期判定据此扣除）。
    @Published public private(set) var repairedBookIDs: Set<String> = []
    @Published public private(set) var message = ""

    /// 面板回执行写入口（复制/导出结果等 UI 侧回执；主线程调用）。
    public func setNotice(_ text: String) {
        message = text
    }

    // MARK: - 内部（跨模块程）

    private var repairPlanBookIDs: Set<String> = []

    func driveRepairCompletionForTesting(plan: Set<String>,
                                         snapshot: RefreshEngine.Progress) {
        repairPlanBookIDs = plan
        observeRepairCompletion(snapshot)
    }

    // MARK: - 初始化

    /// dbURL 传 nil 时按 AppSupportPaths 生产基准推导（与 AppState.dbURL
    /// 同源）；snapshotDir 缺省与快照面板同一目录（keep=1 建新删旧共用同一
    /// 快照纪律），journalDir 缺省 refresh-journal/。
    public init(dbURL: URL? = nil,
                snapshotDir: URL? = nil,
                journalDir: URL? = nil) {
        let db = dbURL ?? AppSupportPaths.appDirectory().appendingPathComponent("index.db")
        self.engine = RefreshEngine(dbURL: db,
                                    snapshotDir: snapshotDir ?? AppSupportPaths.appDirectory("snapshots"),
                                    journalDir: journalDir ?? AppSupportPaths.appDirectory("refresh-journal"))
        engine.onUpdate = { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self else { return }
                self.progress = snapshot
                self.phase = snapshot.phase
                self.cacheFinalCheckIfNeeded(snapshot)
                self.observeRepairCompletion(snapshot)
                switch snapshot.phase {
                case .stopped, .paused, .completed, .completedWithResidue:
                    self.refreshJournalStatus()
                default:
                    break
                }
            }
        }
        refreshJournalStatus()
    }

    // MARK: - 终账载入（纯读零写）

    public func loadLedger(at url: URL) {
        let engine = self.engine
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try engine.loadLedger(url) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let plan):
                    self.ledgerURL = url
                    self.plan = plan
                    self.message = plan.books.isEmpty
                        ? L10n.indexRefreshPlanEmpty
                        : L10n.indexRefreshPlanLoaded(plan.books.count, plan.pagesTotal,
                                                      plan.unresolvedSources.count)
                case .failure(let error):
                    self.message = L10n.indexRefreshLedgerFailedPrefix
                        + String(describing: error)
                }
            }
        }
    }


    public func start() {
        guard let plan, !plan.books.isEmpty else { return }
        message = L10n.indexRefreshStarting
        let engine = self.engine
        Task.detached(priority: .userInitiated) {
            _ = await engine.start(plan: plan)
        }
    }

    public func pause() {
        engine.pause()
    }

    public func resume() {
        let engine = self.engine
        Task.detached(priority: .userInitiated) {
            _ = await engine.resume()
        }
    }

    /// 跨启动续跑：按 batch-start 内嵌完整计划重建待跑集合。
    /// 计划缺失、版本不符或自洽性检查失败时均展示原因，绝不按开跑记录
    /// 反推），续跑前无快照先补备（引擎 fail-closed）。
    public func resumeLastBatch() {
        message = L10n.indexRefreshResumingLast
        let engine = self.engine
        Task.detached(priority: .userInitiated) { [weak self] in
            let started = await engine.resumeLastBatch()
            await MainActor.run {
                guard let self else { return }
                self.message = started
                    ? L10n.indexRefreshResumedLast
                    : (engine.lastResumableBlockReason() ?? L10n.indexRefreshResumeLastUnavailable)
            }
        }
    }

    public func stop() {
        engine.stop()
    }

    // MARK: - 同步对账（只读半步＋修复半步）

    /// 只读对账：全库逐书比盘上 sha256 与库内 fingerprint（句柄层只读，
    /// 零写库）。完成后发布差异总清单；零差异时面板明示「无需修复」。
    public func auditSync() {
        guard !auditing else { return }
        auditing = true
        auditProgressDone = 0
        message = L10n.indexRefreshAuditRunning
        let engine = self.engine
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try engine.auditLibrary { done, _ in
                DispatchQueue.main.async { self?.auditProgressDone = done }
            } }
            DispatchQueue.main.async {
                guard let self else { return }
                self.auditing = false
                switch result {
                case .success(let audit):
                    self.auditResult = audit
                    self.repairedBookIDs = []
                    self.message = audit.differences.isEmpty
                        ? L10n.indexRefreshAuditClean(audit.audited)
                        : L10n.indexRefreshAuditFound(audit.audited - audit.matched,
                                                      audit.differences.count)
                case .failure(let error):
                    self.message = L10n.indexRefreshAuditFailedPrefix
                        + String(describing: error)
                }
            }
        }
    }

    public func repairDifferences() {
        guard let audit = auditResult, !audit.repairable.isEmpty else { return }
        let books = audit.repairable
        repairPlanBookIDs = Set(books.map(\.bookID))
        message = L10n.indexRefreshRepairStarting(books.count)
        let engine = self.engine
        Task.detached(priority: .userInitiated) {
            _ = await engine.repair(books: books)
        }
    }

    /// 修复批完成后回填已修复集合（供窗口期判定扣除已修复书）。
    private func observeRepairCompletion(_ snapshot: RefreshEngine.Progress) {
        guard !repairPlanBookIDs.isEmpty else { return }
        switch snapshot.phase {
        case .completed, .completedWithResidue:
            // 只认实际成功终态（done/skip 书集合）——首次失败续跑
            // 成功的书不再被历史 failed 记录错误排除。
            let ok = repairPlanBookIDs.intersection(snapshot.succeededBookIDs)
            let failedIDs = repairPlanBookIDs.subtracting(ok)
            repairedBookIDs.formUnion(ok)
            repairPlanBookIDs = []
            message = L10n.indexRefreshRepairDone(ok.count, failedIDs.count)
        case .stopped, .idle:
            repairPlanBookIDs = []
        default:
            break
        }
    }


    /// 窗口期是否活跃——全局顶栏横幅与红条旁就地说明的判定源：
    public var windowPeriodActive: Bool {
        switch phase {
        case .backingUp, .running, .paused, .completedWithResidue:
            return true
        case .idle, .stopped, .completed:
            break
        }
        if journalSummary?.unfinished == true { return true }
        // 收尾三向对账有残留（completedWithResidue 的 journal
        // 化）——重启后 progress.finalCheck 已失，横幅须由 journal 残留源保持。
        if journalSummary?.finalizeResidue == true { return true }
        if let check = progress.finalCheck, !check.pass { return true }
        if let audit = auditResult,
           audit.repairable.contains(where: { !repairedBookIDs.contains($0.bookID) }) {
            return true
        }
        return false
    }

    /// 横幅文案所需的书进度（运行中取引擎计数；否则取 journal 待跑）。
    public var windowPeriodProgressText: String? {
        switch phase {
        case .running, .backingUp, .paused:
            let done = progress.booksDone + progress.booksFailed
            return done > 0 || progress.booksTotal > 0
                ? L10n.indexRefreshWindowPeriodProgress(done, progress.booksTotal)
                : nil
        default:
            if let summary = journalSummary, summary.unfinished,
               let pending = summary.pendingCount {
                return L10n.indexRefreshWindowPeriodPending(pending)
            }
            return nil
        }
    }


    public func refreshJournalStatus() {
        let dir = engine.journalDir
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let summary = RefreshJournal.latestJournalURL(in: dir)
                .flatMap { RefreshJournal.summarize(at: $0) }
            DispatchQueue.main.async {
                self?.journalSummary = summary
            }
        }
    }

    // MARK: - 导出文本（错误清单/差异清单/三向对账总表——可复制可导出）

    public func errorListText() -> String {
        var lines: [String] = [L10n.indexRefreshExportErrorsHeader(progress.batchID ?? "")]
        guard !progress.failed.isEmpty else {
            lines.append(L10n.indexRefreshExportEmpty)
            return lines.joined(separator: "\n")
        }
        for failure in progress.failed {
            lines.append("✕ \(failure.fileName) — \(failure.message)")
        }
        return lines.joined(separator: "\n")
    }

    /// 同步对账差异清单纯文本（含 sha8 配对列——同步差异总清单）。
    public func auditDiffText() -> String {
        guard let audit = auditResult else { return "" }
        var lines = [L10n.indexRefreshExportAuditHeader(audit.audited)]
        if audit.differences.isEmpty {
            lines.append(L10n.indexRefreshAuditClean(audit.audited))
            return lines.joined(separator: "\n")
        }
        for row in audit.differences {
            let reason: String
            switch row.issue {
            case .mismatch: reason = L10n.indexRefreshAuditIssueMismatch
            case .missingFile: reason = L10n.indexRefreshAuditIssueMissing
            case .readError: reason = L10n.indexRefreshAuditIssueReadError
            case nil: continue
            }
            let disk = row.diskSha8 ?? L10n.indexRefreshAuditSha8None
            let repairedMark = repairedBookIDs.contains(row.bookID)
                ? L10n.indexRefreshAuditRepairedMark : ""
            lines.append("✕ \(row.fileName) — \(reason)"
                + L10n.indexRefreshAuditShaPair(row.dbSha8, disk)
                + repairedMark)
        }
        return lines.joined(separator: "\n")
    }

    /// 收尾三向对账总表纯文本（清单 sha8 / 库 sha8 / 盘 sha8＋页数三方）。
    public func finalCheckText() -> String {
        guard let check = progress.finalCheck ?? lastCompletedFinalCheck else { return "" }
        var lines = [L10n.indexRefreshExportFinalHeader(check.booksOk,
                                                        check.booksFailed,
                                                        check.shaMismatch)]
        for row in check.rows where !row.ok {
            lines.append("✕ \(row.fileName) — \(row.reasons.joined(separator: "；"))")
        }
        if check.probeFailures.isEmpty == false {
            for p in check.probeFailures {
                lines.append("✕ [\(L10n.indexRefreshProbeLabel)] \(p)")
            }
        }
        if check.pass { lines.append(L10n.indexRefreshFinalPassLine) }
        if let indexLine = pageStatsIndexLine {
            lines.append("· \(L10n.indexRefreshStatsIndexTitle)：\(indexLine)")
        }
        return lines.joined(separator: "\n")
    }

    public private(set) var lastCompletedFinalCheck: RefreshEngine.FinalCheckResult?

    /// progress 快照到达时缓存 finalCheck（completed 后 progress 不再更新）。
    private func cacheFinalCheckIfNeeded(_ snapshot: RefreshEngine.Progress) {
        if let check = snapshot.finalCheck {
            lastCompletedFinalCheck = check
        }
        // 收尾建索引的结果同样要缓存——completed 后 progress 不再更新，
        // 而面板要一直显示「已建/已跳过/已失败」这一行。
        if let result = snapshot.pageStatsIndex {
            lastPageStatsIndexResult = result
        }
    }

    // MARK: - 收尾建页统计索引

    /// 最近一次收尾建索引的结果（progress.pageStatsIndex 的降级处理；面板一行）。
    public private(set) var lastPageStatsIndexResult: IndexStore.PageStatsIndexResult?
    /// 面板一行文案（四态＋耗时＋失败原文）。nil＝本会话还没跑到该步。
    public var pageStatsIndexLine: String? {
        guard let result = lastPageStatsIndexResult else { return nil }
        let base: String
        switch result.outcome {
        case .built:
            base = L10n.indexRefreshStatsIndexBuilt + " "
                + L10n.indexRefreshStatsIndexSeconds(result.seconds)
        case .alreadyPresent:
            base = L10n.indexRefreshStatsIndexAlready
        case .skipped:
            base = L10n.indexRefreshStatsIndexSkipped
        case .failed:
            base = L10n.indexRefreshStatsIndexFailed(result.message ?? "—")
        }
        return base
    }
}
