import SwiftUI
import LiteratureCore
import LiteratureSearchUI

// MARK: - 索引刷新面板（实现；同日合并扩容）

struct IndexRefreshPanel: View {
    @ObservedObject var store: RefreshConsoleStore
    @Environment(\.colorScheme) private var scheme
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue
    @State private var confirming = false
    @State private var confirmingRepair = false
    @State private var showingFinalTable = false

    private var theme: DS.Theme { .storage(dsTheme) }

    private var busy: Bool {
        store.phase == .backingUp || store.phase == .running
    }

    private var canStart: Bool {
        if busy { return false }
        guard let plan = store.plan else { return false }
        return !plan.books.isEmpty
    }

    private var canResumeLast: Bool {
        guard store.journalSummary?.unfinished == true else { return false }
        switch store.phase {
        case .idle, .stopped, .completed, .completedWithResidue, .paused: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text(L10n.indexRefreshNote)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                .fixedSize(horizontal: false, vertical: true)

            windowPeriodBanner

            ledgerRow

            if canResumeLast {
                resumeRow
            }

            actionRow

            if store.plan != nil {
                progressBlock
            }

            auditBlock

            finalCheckBlock

            statsIndexRow


            journalBlock

            Text(L10n.indexRefreshLifecycleNote)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                .fixedSize(horizontal: false, vertical: true)


            if !store.message.isEmpty {
                Text(store.message)
                    .font(.caption)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = store.progress.lastError {
                StatusRow(systemImage: "exclamationmark.triangle.fill",
                          text: L10n.indexRefreshFailedPrefix + error,
                          color: DS.Color.error(theme, scheme))
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $confirming) {
            IndexRefreshConfirmSheet(store: store) {
                confirming = false
                store.start()
            } onCancel: {
                confirming = false
            }
        }
        .sheet(isPresented: $confirmingRepair) {
            IndexRefreshRepairSheet(store: store) {
                confirmingRepair = false
                store.repairDifferences()
            } onCancel: {
                confirmingRepair = false
            }
        }
        .sheet(isPresented: $showingFinalTable) {
            IndexRefreshFinalTableSheet(store: store) {
                showingFinalTable = false
            }
        }
    }

    // MARK: 窗口期横幅（自动显隐；文案点名红条语义）

    @ViewBuilder
    private var windowPeriodBanner: some View {
        if store.windowPeriodActive {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                StatusRow(systemImage: "arrow.triangle.2.circlepath.circle",
                          text: L10n.indexRefreshWindowBannerTitle,
                          color: DS.Color.warning(theme, scheme))
                if let progress = store.windowPeriodProgressText, !progress.isEmpty {
                    Text(progress)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                }
            }
        }
    }

    // MARK: 终账行（未载入＝空态引导：主句＋补充说明；已载入＝文件名＋重载/刷新）

    @ViewBuilder
    private var ledgerRow: some View {
        if let url = store.ledgerURL {
            HStack(spacing: DS.Spacing.sm) {
                Text(url.lastPathComponent)
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                Button(L10n.indexRefreshReloadLedger) { store.loadLedger(at: url) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(busy)
                    .accessibilityLabel(L10n.indexRefreshReloadLedger)
                Button(L10n.indexRefreshRefreshDisplay) { store.refreshJournalStatus() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(L10n.indexRefreshRefreshDisplay)
                Spacer(minLength: 0)
                Button(L10n.indexRefreshChooseLedger) { chooseLedger() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(busy)
                    .accessibilityLabel(L10n.indexRefreshChooseLedger)
            }
        } else {
            // 空态文案由主句和补充说明组成。
            Text(L10n.indexRefreshNoLedgerTitle)
                .font(.caption)
                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            Text(L10n.indexRefreshNoLedger)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Spacing.sm) {
                Button(L10n.indexRefreshChooseLedger) { chooseLedger() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(L10n.indexRefreshChooseLedger)
            }
        }
    }

    // MARK: 跨启动续跑行（journal 未收尾时一键续）

    private var resumeRow: some View {
        HStack(spacing: DS.Spacing.sm) {
            Button(L10n.indexRefreshResumeLastButton) { store.resumeLastBatch() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel(L10n.indexRefreshResumeLastButton)
        }
    }

    // MARK: 动作行（开启经确认表；暂停/继续/停止按相位裁；同步对账独立动作）

    private var actionRow: some View {
        HStack(spacing: DS.Spacing.sm) {
            Button(L10n.indexRefreshStart) { confirming = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canStart)
                .accessibilityLabel(L10n.indexRefreshStart)
            switch store.phase {
            case .running:
                Button(L10n.indexRefreshPause) { store.pause() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(L10n.indexRefreshPause)
                Button(L10n.indexRefreshStop) { store.stop() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(L10n.indexRefreshStop)
            case .paused, .stopped:
                Button(L10n.indexRefreshResume) { store.resume() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(L10n.indexRefreshResume)
                if store.phase == .paused {
                    Button(L10n.indexRefreshStop) { store.stop() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel(L10n.indexRefreshStop)
                }
            default:
                EmptyView()
            }
            Spacer(minLength: 0)
            Button(L10n.indexRefreshSyncAuditButton) { store.auditSync() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.auditing)
                .accessibilityLabel(L10n.indexRefreshSyncAuditButton)
        }
    }

    // MARK: 进度块（批/书/页三层计数＋ETA＋错误清单复制导出—— 基准）

    @ViewBuilder
    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(L10n.indexRefreshBatchProgress(store.progress.booksDone + store.progress.booksFailed,
                                                store.progress.booksTotal))
                .monospacedDigit()
                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            if let current = store.progress.currentBookName {
                Text(L10n.indexRefreshCurrentBook(current,
                                                  store.progress.currentBookIndex,
                                                  store.progress.booksTotal))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                // 页级进度（书层：书名·总页数·已索引页数）。
                let pageLine = L10n.indexRefreshPageProgress(store.progress.currentBookPagesDone,
                                                             store.progress.currentBookPages)
                if !pageLine.isEmpty {
                    Text(pageLine)
                        .monospacedDigit()
                        .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                }
            }
            // 速率与预计剩余（滑动均值估速；流水账行数=证据量）。
            let eta = etaLine
            if !eta.isEmpty {
                Text(eta)
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            }
            if store.phase == .paused {
                StatusRow(systemImage: "pause.circle.fill",
                          text: L10n.indexRefreshPausedStatus,
                          color: DS.Color.warning(theme, scheme))
            }
            ForEach(store.progress.failed, id: \.bookID) { failure in
                StatusRow(systemImage: "exclamationmark.triangle.fill",
                          text: "✕ \(failure.fileName) — \(failure.message)",
                          color: DS.Color.error(theme, scheme))
            }
            let failedText = L10n.indexRefreshFailedCount(store.progress.booksFailed)
            if !failedText.isEmpty {
                HStack(spacing: DS.Spacing.sm) {
                    Text(failedText)
                        .font(.caption2)
                        .foregroundStyle(DS.Color.error(theme, scheme))
                    Button(L10n.indexRefreshCopyButton) { copyText(store.errorListText()) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button(L10n.indexRefreshExportButton) { exportText(store.errorListText(),
                                                                       defaultName: L10n.indexRefreshExportErrorsFileName) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    /// 速率/ETA/已运行/流水账行数合成行（任一成分缺则整行隐藏）。
    private var etaLine: String {
        guard let rate = store.progress.ratePagesPerSecond, rate > 0 else { return "" }
        let rateText = L10n.indexRefreshRateText(rate)
        let etaText: String
        if let eta = store.progress.etaSeconds {
            etaText = Self.formatDuration(eta)
        } else {
            etaText = "—"
        }
        return L10n.indexRefreshEtaLine(rateText, etaText,
                                        Self.formatDuration(Int(store.progress.elapsedActiveSeconds)),
                                        store.progress.journalLines)
    }

    // MARK: 同步对账块（只读半步差异清单＋整批一次确认修复）

    @ViewBuilder
    private var auditBlock: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(L10n.indexRefreshSyncAuditButton.replacingOccurrences(of: "…", with: ""))
                .font(.caption)
                .foregroundStyle(DS.Color.ink(theme, scheme))
            if store.auditing {
                Text(L10n.indexRefreshAuditProgress(store.auditProgressDone))
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            } else if let audit = store.auditResult {
                if audit.differences.isEmpty {
                    Text(L10n.indexRefreshAuditClean(audit.audited))
                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                } else {
                    Text(L10n.indexRefreshAuditFound(audit.differences.count, audit.audited))
                        .foregroundStyle(DS.Color.warning(theme, scheme))
                    List(audit.differences, id: \.bookID) { row in
                        AuditDiffRow(row: row,
                                     repaired: store.repairedBookIDs.contains(row.bookID),
                                     theme: theme, scheme: scheme)
                    }
                    .listStyle(.inset)
                    .frame(maxHeight: 160)
                    HStack(spacing: DS.Spacing.sm) {
                        Button(L10n.indexRefreshCopyButton) { copyText(store.auditDiffText()) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button(L10n.indexRefreshExportButton) { exportText(store.auditDiffText(),
                                                                           defaultName: L10n.indexRefreshExportAuditFileName) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Spacer(minLength: 0)
                        if !audit.repairable.isEmpty {
                            Button(L10n.indexRefreshRepairRunButton(audit.repairable.count)) {
                                confirmingRepair = true
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(busy)
                        }
                    }
                }
            }
        }
    }


    /// 一行显示收尾建索引的结果。放在收尾对账块之后：它属于「收尾做了什么」
    @ViewBuilder
    private var statsIndexRow: some View {
        if let line = store.pageStatsIndexLine {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(L10n.indexRefreshStatsIndexTitle)
                    .font(.caption)
                    .foregroundStyle(DS.Color.ink(theme, scheme))
                Text(line)
                    .font(.caption2)
                    .foregroundStyle(statsIndexFailed
                                     ? DS.Color.warning(theme, scheme)
                                     : DS.Color.inkSecondary(theme, scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statsIndexFailed: Bool {
        store.lastPageStatsIndexResult?.isFailure == true
    }

    // MARK: 收尾三向对账块（总表展示与导出）

    @ViewBuilder
    private var finalCheckBlock: some View {
        if let check = store.progress.finalCheck ?? store.lastCompletedFinalCheck {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(L10n.indexRefreshFinalCheckTitle)
                    .font(.caption)
                    .foregroundStyle(DS.Color.ink(theme, scheme))
                Text(L10n.indexRefreshFinalCheckSummary(check.booksOk, check.booksFailed, check.shaMismatch))
                    .monospacedDigit()
                    .foregroundStyle(check.pass
                                     ? DS.Color.inkSecondary(theme, scheme)
                                     : DS.Color.error(theme, scheme))
                StatusRow(systemImage: check.pass ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                          text: check.pass ? L10n.indexRefreshFinalPassStatus : L10n.indexRefreshFinalResidueStatus,
                          color: check.pass ? DS.Color.select(theme, scheme) : DS.Color.warning(theme, scheme))
                HStack(spacing: DS.Spacing.sm) {
                    Button(L10n.indexRefreshExportButton) { exportText(store.finalCheckText(),
                                                                       defaultName: L10n.indexRefreshExportFinalFileName) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    if !check.rows.filter({ !$0.ok }).isEmpty {
                        Button(L10n.indexRefreshFinalViewTableButton) { showingFinalTable = true }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }



    private var journalBlock: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(L10n.indexRefreshJournalTitle)
                .font(.caption)
                .foregroundStyle(DS.Color.ink(theme, scheme))
            if let summary = store.journalSummary {
                if summary.interrupted {
                    StatusRow(systemImage: "exclamationmark.circle.fill",
                              text: L10n.indexRefreshJournalInterrupted(summary.pendingCount ?? 0),
                              color: DS.Color.warning(theme, scheme))
                } else {
                    Text(L10n.indexRefreshJournalSettled(summary.batchFileName, summary.lastEvent))
                        .font(.caption2.monospacedDigit())
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                }
            } else {
                Text(L10n.indexRefreshJournalNone)
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            }
        }
    }

    // MARK: 复制/导出（错误清单、差异清单、三向总表共用）

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        store.setNotice(L10n.indexRefreshCopied)
    }

    private func exportText(_ text: String, defaultName: String) {
        if let url = store.exportDirectoryProvider?()
            .map({ $0.appendingPathComponent("\(defaultName)-\(RefreshJournal.makeBatchID()).txt") }) {
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                store.setNotice(L10n.indexRefreshExportDone(url.path))
                return
            } catch {
                store.setNotice(L10n.indexRefreshFailedPrefix + String(describing: error))
                return
            }
        }
        // 无导出目录供给：NSSavePanel 降级处理。
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(defaultName).txt"
        if panel.runModal() == .OK, let target = panel.url {
            do {
                try text.write(to: target, atomically: true, encoding: .utf8)
                store.setNotice(L10n.indexRefreshExportDone(target.path))
            } catch {
                store.setNotice(L10n.indexRefreshFailedPrefix + String(describing: error))
            }
        }
    }

    static func formatDuration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: 终账选择（NSOpenPanel；prompt 用系统对话框英文串，非面板文案）

    private func chooseLedger() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the final ledger (.jsonl)"
        if panel.runModal() == .OK, let url = panel.url {
            store.loadLedger(at: url)
        }
    }
}

// MARK: - 对账差异行（书名＋原因＋sha8 配对列＋已修复标记）

private struct AuditDiffRow: View {
    let row: RefreshEngine.SyncAuditRow
    let repaired: Bool
    let theme: DS.Theme
    let scheme: ColorScheme

    private var reasonText: String {
        switch row.issue {
        case .mismatch: return L10n.indexRefreshAuditIssueMismatch
        case .missingFile: return L10n.indexRefreshAuditIssueMissing
        case .readError: return L10n.indexRefreshAuditIssueReadError
        case nil: return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: DS.Spacing.xs) {
                Text(row.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if repaired {
                    Text(L10n.indexRefreshAuditRepairedMark)
                        .font(.caption2)
                        .foregroundStyle(DS.Color.select(theme, scheme))
                }
                Spacer(minLength: 0)
            }
            Text("\(reasonText) \(L10n.indexRefreshAuditShaPair(row.dbSha8, row.diskSha8 ?? L10n.indexRefreshAuditSha8None))")
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                .lineLimit(2)
        }
        .padding(.vertical, 1)
    }
}


private struct IndexRefreshConfirmSheet: View {
    @ObservedObject var store: RefreshConsoleStore
    let onRun: () -> Void
    let onCancel: () -> Void
    @Environment(\.colorScheme) private var scheme
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue

    private var theme: DS.Theme { .storage(dsTheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            if let plan = store.plan {
                Text(L10n.indexRefreshConfirmTitle)
                    .font(DS.Font.displaySection)
                Text(L10n.indexRefreshPlanLoaded(plan.books.count, plan.pagesTotal,
                                                 plan.unresolvedSources.count))
                    .font(.callout)
                    .monospacedDigit()
                Text(L10n.indexRefreshConfirmNote)
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                    .fixedSize(horizontal: false, vertical: true)
                bookList(plan)
                HStack(spacing: DS.Spacing.sm) {
                    Button(L10n.indexRefreshConfirmRun, action: onRun)
                        .buttonStyle(.borderedProminent)
                    Button(L10n.indexRefreshCancel, action: onCancel)
                        .buttonStyle(.bordered)
                    Spacer(minLength: 0)
                }
            } else {
                Text(L10n.indexRefreshNoLedgerTitle)
                    .font(.callout)
                Button(L10n.indexRefreshCancel, action: onCancel)
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(width: 560, height: 420)
    }

    /// 将刷书目总表（书名/声明页数/期望指纹前 8 位）。
    private func bookList(_ plan: RefreshEngine.BatchPlan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                ForEach(Array(plan.books.enumerated()), id: \.element.bookID) { _, book in
                    HStack(spacing: DS.Spacing.sm) {
                        Text(book.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        if let pages = book.declaredPages {
                            Text("\(pages)")
                                .monospacedDigit()
                                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                        }
                        if let sha = book.shaExpect {
                            Text(String(sha.prefix(8)))
                                .font(.caption2.monospaced())
                                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .frame(maxHeight: .infinity)
    }
}


private struct IndexRefreshRepairSheet: View {
    @ObservedObject var store: RefreshConsoleStore
    let onRun: () -> Void
    let onCancel: () -> Void
    @Environment(\.colorScheme) private var scheme
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue

    private var theme: DS.Theme { .storage(dsTheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            if let audit = store.auditResult {
                Text(L10n.indexRefreshRepairConfirmTitle)
                    .font(DS.Font.displaySection)
                Text(L10n.indexRefreshRepairConfirmNote(audit.repairable.count))
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                    .fixedSize(horizontal: false, vertical: true)
                List(audit.repairable, id: \.bookID) { row in
                    AuditDiffRow(row: row, repaired: false, theme: theme, scheme: scheme)
                }
                .listStyle(.inset)
                .frame(maxHeight: .infinity)
                HStack(spacing: DS.Spacing.sm) {
                    Button(L10n.indexRefreshRepairRunButton(audit.repairable.count), action: onRun)
                        .buttonStyle(.borderedProminent)
                    Button(L10n.indexRefreshCancel, action: onCancel)
                        .buttonStyle(.bordered)
                    Spacer(minLength: 0)
                }
            } else {
                Button(L10n.indexRefreshCancel, action: onCancel)
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(width: 560, height: 420)
    }
}

// MARK: - 收尾三向对账总表（清单/库内/盘上 sha8＋页数三方＋差异原因）

private struct IndexRefreshFinalTableSheet: View {
    @ObservedObject var store: RefreshConsoleStore
    let onClose: () -> Void
    @Environment(\.colorScheme) private var scheme
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue

    private var theme: DS.Theme { .storage(dsTheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            if let check = store.progress.finalCheck ?? store.lastCompletedFinalCheck {
                Text(L10n.indexRefreshFinalCheckTitle)
                    .font(DS.Font.displaySection)
                Text(L10n.indexRefreshFinalCheckSummary(check.booksOk, check.booksFailed, check.shaMismatch))
                    .font(.callout)
                    .monospacedDigit()
                TableHeaderRow(theme: theme, scheme: scheme)
                List(check.rows, id: \.bookID) { row in
                    FinalCheckRowView(row: row, theme: theme, scheme: scheme)
                }
                .listStyle(.inset)
                HStack(spacing: DS.Spacing.sm) {
                    Button(L10n.indexRefreshCancel, action: onClose)
                        .buttonStyle(.bordered)
                    Spacer(minLength: 0)
                }
            } else {
                Button(L10n.indexRefreshCancel, action: onClose)
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(width: 640, height: 460)
    }

    private struct TableHeaderRow: View {
        let theme: DS.Theme
        let scheme: ColorScheme
        var body: some View {
            HStack(spacing: DS.Spacing.sm) {
                Text(L10n.indexRefreshFinalColBook).frame(width: 150, alignment: .leading)
                Text(L10n.indexRefreshFinalColLedger).frame(width: 80, alignment: .leading)
                Text(L10n.indexRefreshFinalColDB).frame(width: 80, alignment: .leading)
                Text(L10n.indexRefreshFinalColDisk).frame(width: 80, alignment: .leading)
                Text(L10n.indexRefreshFinalColPages).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
        }
    }
}

private struct FinalCheckRowView: View {
    let row: RefreshEngine.FinalCheckRow
    let theme: DS.Theme
    let scheme: ColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: DS.Spacing.sm) {
                Text(row.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 150, alignment: .leading)
                Text(row.ledgerSha8 ?? "—").font(.caption2.monospaced()).frame(width: 80, alignment: .leading)
                Text(row.dbSha8 ?? "—").font(.caption2.monospaced()).frame(width: 80, alignment: .leading)
                Text(row.diskSha8 ?? "—").font(.caption2.monospaced()).frame(width: 80, alignment: .leading)
                Text("\(row.pagesLedger.map(String.init) ?? "—")/\(row.pagesDB.map(String.init) ?? "—")/\(row.pagesDisk.map(String.init) ?? "—")")
                    .font(.caption2.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: row.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(row.ok ? DS.Color.select(theme, scheme) : DS.Color.error(theme, scheme))
            }
            if !row.ok {
                Text(row.reasons.joined(separator: "；"))
                    .font(.caption2)
                    .foregroundStyle(DS.Color.error(theme, scheme))
                    .lineLimit(2)
            }
        }
    }
}
