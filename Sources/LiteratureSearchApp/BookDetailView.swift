import SwiftUI
import LiteratureCore
import LiteratureSearchUI

/// Book detail sheet (citation upgrade slice): identity fields,
/// editable index-only metadata, citations in both house styles + BibTeX, file
/// facts, and text-layer coverage. Reads the index only — originals are never
/// touched, and unknown metadata stays unknown (no guessing).
struct BookDetailView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dsTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    // 正文起始物理页本地编辑态（进面板读现值）。
    @State private var bodyStartInput = ""
    @State private var bodyStartMessage: String?
    // 烧录导出运行态。
    @State private var burnExportRunning = false
    @State private var burnExportMessage: String?

    var body: some View {
        Group {
            if let book = state.bookDetail {
                detail(book)
            } else {
                EmptyStateView(systemImage: "book.closed",
                               title: L10n.bookDetailTitle,
                               detail: L10n.bookDetailMissing)
            }        }
        .padding(DS.Spacing.md)
        .frame(minWidth: 480, minHeight: 540)
        .dsAppear()
    }

    private func detail(_ book: IndexStore.BookRow) -> some View {
        ScrollView {
            // 留白：区块间距 16 → 24。
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                header(book)
                citationPanel(book)
                metaEditor(book)
                fetchPanel(book)
                frontMatterPanel(book)    // 正文起始页（手动校正）
                fileFacts(book)
                coveragePanel
                similarBooksPanel(book)   // 相似文档（bigram 共现）
                burnExportPanel(book)     // 烧录导出副本
                if let msg = state.bookDetailMessage {
                    StatusRow(systemImage: "checkmark.circle.fill", text: msg,
                              color: DS.Color.success(theme, scheme))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK:：正文起始物理页（手动校正；立即生效）

    private func frontMatterPanel(_ book: IndexStore.BookRow) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(L10n.bodyStartFieldLabel).font(DS.Font.displaySection)
            HStack(spacing: DS.Spacing.sm) {
                TextField(L10n.bodyStartFieldPlaceholder, text: $bodyStartInput)
                    .textFieldStyle(.dsTextField)
                    .frame(width: 160)
                    .accessibilityLabel(L10n.bodyStartFieldLabel)
                Button(L10n.bookSaveMeta) { saveBodyStart(book) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(L10n.bodyStartCleared) { clearBodyStart(book) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Text(L10n.bodyStartFieldHint)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            if let msg = bodyStartMessage {
                Text(msg).font(.caption)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }
        }
        .onAppear {
            if bodyStartInput.isEmpty, let current = state.frontMatterBodyStart(bookID: book.id) {
                bodyStartInput = String(current)
            }
        }
    }

    private func saveBodyStart(_ book: IndexStore.BookRow) {
        let trimmed = bodyStartInput.trimmingCharacters(in: .whitespaces)
        guard let page = Int(trimmed), page >= 1, page <= max(book.pageCount, 1) else {
            bodyStartMessage = L10n.bodyStartInvalid
            return
        }
        do {
            try state.frontMatterWriteBodyStart(bookID: book.id, page: page)
            bodyStartMessage = L10n.bodyStartSaved
        } catch {
            bodyStartMessage = String(describing: error)
        }
    }

    private func clearBodyStart(_ book: IndexStore.BookRow) {
        do {
            try state.frontMatterWriteBodyStart(bookID: book.id, page: nil)
            bodyStartInput = ""
            bodyStartMessage = L10n.bodyStartCleared
        } catch {
            bodyStartMessage = String(describing: error)
        }
    }

    // MARK:：烧录导出（副本出口；原件永不写）

    private func burnExportPanel(_ book: IndexStore.BookRow) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(L10n.burnExportEntry).font(DS.Font.displaySection)
            HStack(spacing: DS.Spacing.sm) {
                Button(L10n.burnExportEntry) { runBurnExport(book) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(burnExportRunning)
                if burnExportRunning { ProgressView().controlSize(.small) }
            }
            Text(L10n.burnExportNote)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            if let msg = burnExportMessage {
                Text(msg).font(.caption)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    .textSelection(.enabled)
            }
        }
    }

    /// 后台跑 PDFBurnExporter：原件只读打开 → 自有库读齐四类（Mac 侧
    private func runBurnExport(_ book: IndexStore.BookRow) {
        let originalURL = URL(fileURLWithPath: book.realPath)
        guard FileManager.default.fileExists(atPath: originalURL.path) else {
            burnExportMessage = L10n.burnExportOriginalMissing
            return
        }
        burnExportRunning = true
        burnExportMessage = nil
        let highlights = (try? state.highlightStore?.highlightsForBook(book.id, viewSource: nil)) ?? []
        let items = highlights.map { h in
            BurnExportSource.Highlight(pageNumber: h.pageNumber,
                                       utf16Start: h.utf16Start,
                                       utf16End: h.utf16End,
                                       colorHex: h.color.colorHex,
                                       style: h.style,
                                       note: h.note,
                                       anchorText: h.anchorText)
        }
        Task.detached(priority: .userInitiated) {
            do {
                let destination = PDFBurnExporter.exportDestination(for: originalURL,
                                                                    in: originalURL.deletingLastPathComponent())
                let report = try PDFBurnExporter.export(
                    source: BurnExportSource(highlights: items, inkStrokes: []),
                    from: originalURL, to: destination,
                    fingerprint: { try Fingerprint.sha256Hex(ofFileAt: $0) })
                await MainActor.run {
                    burnExportRunning = false
                    burnExportMessage = L10n.burnExportDoneWithCount(report.destination.lastPathComponent,
                                                                      applied: report.highlightsApplied,
                                                                      skipped: report.highlightsSkipped)
                }
            } catch {
                await MainActor.run {
                    burnExportRunning = false
                    burnExportMessage = L10n.burnExportFailed(String(describing: error))
                }
            }
        }
    }

    /// 相似文档：进 sheet 即触发计算（进程内缓存；未建倒排/单词
    /// 书如实空态）。分数与排序如实呈现，不猜。
    private func similarBooksPanel(_ book: IndexStore.BookRow) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.xs) {
                Text(L10n.similarBooksTitle).font(DS.Font.displaySection)
                Spacer(minLength: 0)
                if state.similarLoading { Text(L10n.similarBooksLoading).font(.caption2) }
            }
            if state.similarBooksFor != book.id && !state.similarLoading {
                Text("").onAppear { state.loadSimilarBooks(bookID: book.id) }
            }
            if state.similarBooks.isEmpty && !state.similarLoading {
                Text(L10n.similarBooksEmpty).font(.caption)
                    .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            }
            ForEach(state.similarBooks) { similar in
                HStack(spacing: DS.Spacing.xs) {
                    Button {
                        // 相似书行点开该书详情（库内动线）。
                        state.openBookDetail(bookID: similar.bookID)
                    } label: {
                        Text(similar.title ?? similar.fileName)
                            .font(.callout)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: DS.Spacing.xs)
                    Text(L10n.similarScore(similar.score))
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                }
                .padding(.vertical, 1)
                .overlay(alignment: .bottom) { Hairline() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard(radius: DS.Radius.small)
    }

    private func header(_ book: IndexStore.BookRow) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(book.title ?? book.fileName)
                .font(DS.Font.displayPage)
                .lineLimit(2)
            if let author = book.author {
                Text(author).font(.subheadline).foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }
            CitationLine(text: CitationFormatter.bookCitation(fileName: book.fileName, title: book.title),
                         font: .caption)
        }
    }

    private func citationPanel(_ book: IndexStore.BookRow) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.sm) {
                Text(L10n.citationStyleLabel).font(DS.Font.displaySection)
                Picker(L10n.citationStyleLabel, selection: $state.citationStyle) {
                    ForEach(CitationFormatGroup.allCases, id: \.self) { group in
                        Section(header: Text(styleGroupLabel(group))) {
                            ForEach(CitationFormatRegistry.styles(in: group), id: \.self) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Spacer(minLength: 0)
            }
            // 逐体例书目级预览，按注册表三组分区（中文 / 英文国际 / 其他）。
            ForEach(CitationFormatGroup.allCases, id: \.self) { group in
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text(styleGroupLabel(group))
                        .font(.caption2)
                        .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                    ForEach(CitationFormatRegistry.styles(in: group), id: \.self) { style in
                        HStack(alignment: .top, spacing: DS.Spacing.xs) {
                            Text(style.displayName)
                                .font(.caption)
                                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                                .frame(width: 170, alignment: .leading)
                            Text(CitationFormatter.bookCitation(fileName: book.fileName,
                                                                title: book.title,
                                                                style: style))
                                .font(.callout)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                            Button(L10n.copyBookCitationCurrent) {
                                state.copyString(CitationFormatter.bookCitation(fileName: book.fileName,
                                                                                title: book.title,
                                                                                style: style))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
            HStack(spacing: DS.Spacing.sm) {
                Button(L10n.copyBibtex) {
                    state.copyString(CitationFormatter.bibtex(fileName: book.fileName,
                                                              title: book.title,
                                                              author: book.author,
                                                              language: book.language))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                // 收藏入口（详情页）：与书目行右键同一动作。
                Button(L10n.favoriteBook) {
                    state.favoriteBook(bookID: book.id, fileName: book.fileName, title: book.title)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Text(L10n.bibtexNote)
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard(radius: DS.Radius.small)
    }

    private func metaEditor(_ book: IndexStore.BookRow) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(L10n.metadataNote).font(DS.Font.displaySection)
            HStack(spacing: DS.Spacing.sm) {
                TextField(L10n.metaFieldTitle, text: $state.bookDetailMetaEdit.title)
                    .textFieldStyle(.dsTextField)
                TextField(L10n.metaFieldAuthor, text: $state.bookDetailMetaEdit.author)
                    .textFieldStyle(.dsTextField)
            }
            HStack(spacing: DS.Spacing.sm) {
                TextField(L10n.metaFieldVersion, text: $state.bookDetailMetaEdit.version)
                    .textFieldStyle(.dsTextField)
                TextField(L10n.metaFieldLanguage, text: $state.bookDetailMetaEdit.language)
                    .textFieldStyle(.dsTextField)
                Button(L10n.bookSaveMeta) { state.saveBookDetailMetadata() }
                    .buttonStyle(.bordered)
            }
            Text("\(L10n.metaSourceLabel)：\(book.metaSource ?? L10n.bookFactUnknown)")
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
        }
    }

    /// 在线补全（手动唯一）。总开关关 → 按钮禁用 + 说明；
    /// 只填空字段，既有值一律不覆盖（JabRef 式保守合并）。
    private func fetchPanel(_ book: IndexStore.BookRow) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(L10n.metadataSection).font(DS.Font.displaySection)
            HStack(spacing: DS.Spacing.sm) {
                TextField(L10n.metadataDOIPlaceholder, text: $state.fetchDOIInput)
                    .textFieldStyle(.dsTextField)
                    .accessibilityLabel(L10n.metadataDOIPlaceholder)
                TextField(L10n.metadataArxivPlaceholder, text: $state.fetchArxivInput)
                    .textFieldStyle(.dsTextField)
                    .accessibilityLabel(L10n.metadataArxivPlaceholder)
            }
            HStack(spacing: DS.Spacing.sm) {
                Button(L10n.metadataFetchButton) {
                    state.fetchMetadataForBookDetail()
                }
                .buttonStyle(.bordered)
                .disabled(!state.metadataFetchEnabled || state.fetchRunning)
                .help(state.metadataFetchEnabled
                      ? L10n.metadataFetchButton : L10n.metadataFetchDisabledNote)
                .accessibilityLabel(L10n.metadataFetchButton)
            }
            Text(L10n.metadataFetchToggleNote)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            if let msg = state.fetchMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    .accessibilityLabel(msg)
            }
        }
    }

    private func fileFacts(_ book: IndexStore.BookRow) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(L10n.bookFileFacts).font(DS.Font.displaySection)
            factRow(L10n.bookFactFileName, book.fileName)
            factRow(L10n.bookFactSize, ByteCountFormatter.string(fromByteCount: book.fileSize, countStyle: .file))
            factRow(L10n.bookFactPhysicalPages, "\(book.pageCount)")
            factRow(L10n.bookFactIndexedAt, DateFormatter.localizedString(from: Date(timeIntervalSince1970: book.indexedAt),
                                                              dateStyle: .short, timeStyle: .short))
            factRow(L10n.bookFactStatus, book.status == "ok" ? L10n.bookStatusOK : (book.error ?? book.status))
        }
    }

    private var coveragePanel: some View {
        Group {
            if let stat = state.bookDetailStat {
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text(L10n.bookCoverageLine).font(DS.Font.displaySection)
                    let coverageText: String = {
                        switch stat.coverage {
                        case .full: return L10n.bookCoverageFull(pagesWithText: stat.pagesWithText,
                                                                indexedPages: stat.indexedPages)
                        case .partial: return L10n.bookCoveragePartial(pagesWithText: stat.pagesWithText,
                                                                      indexedPages: stat.indexedPages)
                        case .needsOCR: return L10n.bookCoverageNeedsOCR
                        case .unknown: return L10n.bookCoverageUnknown
                        }
                    }()
                    StatusRow(systemImage: "doc.text.magnifyingglass",
                              text: coverageText, color: DS.Color.inkSecondary(theme, scheme))
                }
            }
        }
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Text(label)
                .font(.caption)
                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func styleGroupLabel(_ group: CitationFormatGroup) -> String {
        switch group {
        case .chinese: return L10n.styleGroupChinese
        case .englishIntl: return L10n.styleGroupEnglish
        case .other: return L10n.styleGroupOther
        }
    }
}
