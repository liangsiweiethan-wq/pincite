import SwiftUI
import LiteratureCore
import LiteratureSearchUI

// MARK: - 批量导出 sheet
//
// 格式勾选（MD/CSV × 批注/引注）+ 进度条 + 取消按钮 + 断点续跑提示。
// 导出根 = exportDirectoryPath 既有偏好（目录选择在书库页既有入口，本
// sheet 不另写选择器）。管道在后台 Task 逐书切片推进：取消即停、同目录
// 重跑续传（export_state.json 记账）；新导出 = 新目录不续旧账。

struct AnnotationExportView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dsTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    @State private var annotationsMD = true
    @State private var annotationsCSV = true
    @State private var citationsMD = true
    @State private var citationsCSV = true
    /// 批注 HTML/TXT 两格式（默认关——不破旧调用）。
    @State private var annotationsHTML = false
    @State private var annotationsTXT = false
    /// 续跑候选（最近一个未完成的导出目录；onAppear 扫描，nil = 无）。
    @State private var resumeCandidate: URL?

    private var selection: AnnotationExportSelection {
        AnnotationExportSelection(annotationsMarkdown: annotationsMD,
                                  annotationsCSV: annotationsCSV,
                                  citationsMarkdown: citationsMD,
                                  citationsCSV: citationsCSV,
                                  annotationsHTML: annotationsHTML,
                                  annotationsTXT: annotationsTXT)
    }

    private var isRunning: Bool { state.annotationExportRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Text(L10n.annotationExportTitle)
                .font(DS.Font.displayGroup)
                .foregroundStyle(DS.Color.ink(theme, scheme))

            if isRunning {
                progressSection
            } else {
                selectionSection
                directorySection
                if let candidate = resumeCandidate {
                    resumeSection(candidate)
                }
                if let error = state.annotationExportError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                }
                if let summary = state.annotationExportSummary {
                    summarySection(summary)
                }
                startButtons
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.lg)
        .frame(width: 480)
        .onAppear(perform: detectResumeCandidate)
    }

    // MARK: Sections

    private var selectionSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Toggle(L10n.annotationExportAnnotationsMD, isOn: $annotationsMD)
            Toggle(L10n.annotationExportAnnotationsCSV, isOn: $annotationsCSV)
            Toggle(L10n.annotationExportAnnotationsHTML, isOn: $annotationsHTML)
            Toggle(L10n.annotationExportAnnotationsTXT, isOn: $annotationsTXT)
            Toggle(L10n.annotationExportCitationsMD, isOn: $citationsMD)
            Toggle(L10n.annotationExportCitationsCSV, isOn: $citationsCSV)
        }
        .font(.callout)
        .foregroundStyle(DS.Color.ink(theme, scheme))
    }

    private var directorySection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(L10n.annotationExportDirectoryHint)
                .font(.caption)
                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            Text(state.exportDirectoryPath)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private func resumeSection(_ candidate: URL) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(L10n.annotationExportResumeHint)
                .font(.caption)
                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            Text(candidate.lastPathComponent)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                .lineLimit(1)
                .truncationMode(.middle)
            Button(L10n.annotationExportResume) {
                state.runAnnotationExport(directory: candidate, selection: selection)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!hasAnySelection)
        }
    }

    private func summarySection(_ summary: AnnotationExportPipeline.Summary) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            if summary.cancelled {
                Text(L10n.annotationExportCancelledLine(summary.writtenFiles.count))
                    .font(.caption)
            } else {
                Text(L10n.annotationExportDoneLine(summary.writtenFiles.count,
                                                   summary.annotationRows))
                    .font(.caption)
            }
            Text(summary.directory.path)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                .lineLimit(2)
                .truncationMode(.middle)
            if !summary.failedBooks.isEmpty {
                Text(L10n.annotationExportFailedBooks)
                    .font(.caption)
                ForEach(summary.failedBooks, id: \.id) { failure in
                    Text("\(failure.id)：\(failure.error)")
                        .font(.caption2)
                        .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                        .lineLimit(1)
                }
            }
        }
        .foregroundStyle(DS.Color.ink(theme, scheme))
    }

    private var startButtons: some View {
        HStack {
            Spacer()
            Button(L10n.annotationExportStart) { startNewExport() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!hasAnySelection)
            Button(L10n.aiCancelSend) { dismiss() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            if let progress = state.annotationExportProgress {
                if progress.total > 0 {
                    ProgressView(value: Double(progress.done), total: Double(progress.total))
                } else {
                    ProgressView()
                }
                Text(L10n.annotationExportProgressLine(progress.done, progress.total,
                                                       progress.failed))
                    .font(.caption)
                    .foregroundStyle(DS.Color.ink(theme, scheme))
                if let book = progress.currentBook {
                    Text(L10n.annotationExportCurrentBook(book))
                        .font(.caption2)
                        .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            HStack {
                Spacer()
                Button(L10n.annotationExportCancel) { state.cancelAnnotationExport() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    // MARK: Actions

    private var hasAnySelection: Bool {
        selection != AnnotationExportSelection(annotationsMarkdown: false,
                                               annotationsCSV: false,
                                               citationsMarkdown: false,
                                               citationsCSV: false,
                                               annotationsHTML: false,
                                               annotationsTXT: false)
    }

    private func startNewExport() {
        do {
            let directory = try AnnotationExportPipeline.newRunDirectory(in: state.exportDirectoryURL)
            state.runAnnotationExport(directory: directory, selection: selection)
        } catch {
            state.annotationExportError = String(describing: error)
        }
    }

    /// 扫描导出根下最近一个未完成目录（有 export_state.json 且有非 done
    /// 记账）；找不到 = 无续跑候选（如实不显示提示）。
    private func detectResumeCandidate() {
        let root = state.exportDirectoryURL
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]) else {
            resumeCandidate = nil
            return
        }
        let runs = contents
            .filter { $0.lastPathComponent.hasPrefix(AnnotationExportPipeline.runDirectoryPrefix) }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return da > db
            }
        for run in runs {
            let stateURL = run.appendingPathComponent("export_state.json")
            guard let data = try? Data(contentsOf: stateURL),
                  let exportState = AnnotationExportState.parse(data) else { continue }
            if exportState.books.contains(where: { $0.value.status != "done" }) {
                resumeCandidate = run
                return
            }
        }
        resumeCandidate = nil
    }
}
