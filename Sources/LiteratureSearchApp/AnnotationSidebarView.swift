import SwiftUI
import LiteratureCore
import LiteratureSearchUI


/// 侧边批注面板：右侧抽屉，宽 260，列表 + 快速批注输入框。
struct AnnotationSidebarView: View {
    /// 删除上抛全局 toast 撤销通道用（软删语义在 AppState）。
    @EnvironmentObject var state: AppState
    /// 阅读器桥（当前选区 / 当前页 / 跳页回调）。
    @ObservedObject var readerState: PDFReaderState
    /// 当前书身份（nil = store-only 动作禁用，与 PDFDetailView 同语义）。
    let bookID: String?
    let highlightStore: HighlightStore?
    /// 当前阅读视图来源（'ocr' / 'original'）：快速批注写入来源 + 跨来源
    let isOriginalView: Bool
    /// 批注增删改版本号：写入后 +1，驱动书内标注重贴与本面板刷新。
    @Binding var highlightsVersion: UInt64

    @Environment(\.colorScheme) private var scheme
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue
    // 开合偏好由 DetailChromeView 的 @AppStorage("showAnnotations") 持有
    //（本视图只在开启态挂载，持久化不能放这里——收起动作发生在挂载之外）。

    @State private var highlights: [UserHighlight] = []
    @State private var noteDrafts: [Int64: String] = [:]
    @State private var quickText = ""
    @State private var notice: String?

    /// 当前视图来源常量（跳页可用性判断用）。
    private var currentSource: String {
        isOriginalView ? HighlightStore.viewSourceOriginal : HighlightStore.viewSourceOCR
    }

    var body: some View {
        let theme = DS.Theme.storage(dsTheme)
        VStack(spacing: 0) {
            header(theme)
            quickNoteField(theme)
            if highlights.isEmpty {
                emptyState(theme)
            } else {
                List(highlights) { highlight in
                    AnnotationRow(
                        highlight: highlight,
                        theme: theme,
                        scheme: scheme,
                        canJumpToCurrentView: highlight.viewSource == currentSource,
                        noteDraft: noteDraftBinding(for: highlight),
                        onJump: { readerState.jump(to: highlight.pageNumber) },
                        onRecolor: { recolor(highlight, $0) },
                        onDelete: { delete(highlight) },
                        onSaveNote: { saveNote(highlight) })
                    .listRowSeparator(.visible)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(DS.Color.desk(theme, scheme))
        .accessibilityLabel(L10n.annotationsToggle)
        .onAppear(perform: reload)
        .onChange(of: highlightsVersion) { _ in reload() }
    }

    // MARK: Sections

    private func header(_ theme: DS.Theme) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: "note.text")
                .font(.caption)
                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            Text(L10n.annotationsToggle)
                .font(DS.Font.displaySection)
                .foregroundStyle(DS.Color.ink(theme, scheme))
            Spacer(minLength: DS.Spacing.xs)
            if !highlights.isEmpty {
                Text(L10n.annotationsCount(highlights.count))
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            }
            if let notice {
                Text(notice)
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.sm)
    }

    /// 快速批注输入框：有选区 → 锚选区写；无选区 → 当前页整页批注。
    private func quickNoteField(_ theme: DS.Theme) -> some View {
        TextField(L10n.annotationsQuickPlaceholder, text: $quickText)
            .textFieldStyle(.dsTextField)
            .font(.caption)
            .onSubmit(submitQuickNote)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.bottom, DS.Spacing.xs)
    }

    private func emptyState(_ theme: DS.Theme) -> some View {
        VStack(spacing: DS.Spacing.xs) {
            Spacer()
            Image(systemName: "note.text")
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            Text(L10n.annotationsSidebarEmpty)
                .font(.caption)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    /// 快速批注提交（唯一写盘入口，主线程）：参数归一走 AnnotationPlan
    /// （可测纯逻辑），落库走 HighlightStore；成功后版本号 +1 并清输入。
    private func submitQuickNote() {
        assert(Thread.isMainThread, "annotation writes must run on the main thread")
        let text = quickText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let store = highlightStore else {
            flash(L10n.annotationsStoreUnavailable)
            return
        }
        guard let bookID else {
            flash(L10n.annotationsStoreUnavailable)
            return
        }
        let selection = readerState.selectionInfo
        let selectionText = selection != nil ? readerState.pdfView?.currentSelection?.string : nil
        let viewSource = isOriginalView ? HighlightStore.viewSourceOriginal : HighlightStore.viewSourceOCR
        guard let plan = AnnotationPlan.make(selectionPage: selection?.pageNumber,
                                             selectionRange: selection?.utf16Range,
                                             selectionText: selectionText,
                                             currentPage: readerState.currentPage,
                                             note: text,
                                             viewSource: viewSource) else {
            flash(L10n.annotationsPageUnavailable)
            return
        }
        do {
            if plan.isPageNote {
                _ = try store.addPageNote(bookID: bookID, pageNumber: plan.pageNumber,
                                          note: plan.note, viewSource: plan.viewSource)
            } else {
                _ = try store.add(bookID: bookID, pageNumber: plan.pageNumber,
                                  utf16Start: plan.utf16Start, utf16End: plan.utf16End,
                                  color: .yellow, note: plan.note,
                                  anchorText: plan.anchorText, viewSource: plan.viewSource)
            }
            quickText = ""
            highlightsVersion &+= 1
            reload()
            flash(L10n.annotationsSaved)
        } catch {
            reload()
            flash(L10n.annotationsStoreUnavailable)
        }
    }

    private func reload() {
        assert(Thread.isMainThread, "annotation queries must run on the main thread")
        guard let store = highlightStore, let bookID else {
            highlights = []
            return
        }
        // 全部来源进面板（nil = 不过滤）；排序由 SQL 保证（页升序+偏移）。
        let loaded = (try? store.verifiedHighlightsForBook(bookID, viewSource: nil)) ?? []
        highlights = loaded
        var drafts: [Int64: String] = [:]
        for highlight in loaded { drafts[highlight.id] = highlight.note }
        noteDrafts = drafts
    }

    private func recolor(_ highlight: UserHighlight, _ color: HighlightColor) {
        guard let store = highlightStore else { return }
        try? store.updateColor(id: highlight.id, color: color)
        highlightsVersion &+= 1
        reload()
    }

    private func delete(_ highlight: UserHighlight) {
        state.requestAnnotationDelete(highlight)
        reload()
    }

    private func saveNote(_ highlight: UserHighlight) {
        guard let store = highlightStore,
              noteDrafts[highlight.id] != highlight.note else { return }
        try? store.updateNote(id: highlight.id, note: noteDrafts[highlight.id] ?? "")
        highlightsVersion &+= 1
        reload()
    }

    private func flash(_ text: String) {
        notice = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if notice == text { notice = nil }
        }
    }

    private func noteDraftBinding(for highlight: UserHighlight) -> Binding<String> {
        Binding(
            get: { noteDrafts[highlight.id] ?? "" },
            set: { noteDrafts[highlight.id] = $0 })
    }
}

/// 批注行：色点 + 页码 + 形态/来源标记 + 摘句 + note 预览；点击行跳原文
private struct AnnotationRow: View {
    let highlight: UserHighlight
    let theme: DS.Theme
    let scheme: ColorScheme
    let canJumpToCurrentView: Bool
    @Binding var noteDraft: String
    let onJump: () -> Void
    let onRecolor: (HighlightColor) -> Void
    let onDelete: () -> Void
    let onSaveNote: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Button(action: onJump) {
                HStack(alignment: .top, spacing: DS.Spacing.xs) {
                    Circle()
                        .fill(color(highlight.color))
                        .frame(width: 10, height: 10)
                        .padding(.top, 4)
                        .accessibilityLabel(L10n.highlightsColorAccessibility)
                    VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                        HStack(spacing: DS.Spacing.xxs) {
                            Text(L10n.highlightsPageLabel(highlight.pageNumber))
                                .font(.caption)
                                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                            Text(sourceBadge)
                                .font(.caption2)
                                .padding(.horizontal, DS.Spacing.xxs)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(DS.Color.surface(theme)))
                                .overlay(Capsule().stroke(DS.Color.stroke(theme, scheme), lineWidth: 0.5))
                                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                            if highlight.style == "underline" {
                                Image(systemName: "underline")
                                    .font(.caption2)
                                    .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                                    .accessibilityHidden(true) // 装饰：样式指示
                            }
                        }
                        Text(snippet)
                            .font(.callout)
                            .foregroundStyle(DS.Color.ink(theme, scheme))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !highlight.note.isEmpty {
                            Text(highlight.note)
                                .font(.caption)
                                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canJumpToCurrentView)
            .contextMenu {
                Menu {
                    Button(L10n.menuHighlightYellow) { onRecolor(.yellow) }
                    Button(L10n.menuHighlightGreen) { onRecolor(.green) }
                    Button(L10n.menuHighlightBlue) { onRecolor(.blue) }
                    Button(L10n.menuHighlightRed) { onRecolor(.red) }
                } label: {
                    Label(L10n.highlightsColorAccessibility, systemImage: "paintpalette")
                }
                Divider()
                Button(L10n.actionDelete) { onDelete() }
            }
            TextField(L10n.annotationsNotePlaceholder, text: $noteDraft)
                .font(.caption)
                .textFieldStyle(.dsTextField)
                .onSubmit(onSaveNote)
        }
        .padding(.vertical, DS.Spacing.xs)
        .dsHoverFade()
    }

    private var sourceBadge: String {
        if highlight.utf16Start == 0 && highlight.utf16End == 0 && highlight.anchorText.isEmpty {
            return L10n.annotationsPageNoteBadge
        }
        return highlight.viewSource == HighlightStore.viewSourceOriginal
            ? L10n.annotationsSourceOriginal
            : L10n.annotationsSourceOCR
    }

    /// 摘句：页级批注（无锚）显示整页徽标语义；有锚显示锚文本截断。
    private var snippet: String {
        if highlight.anchorText.isEmpty {
            return L10n.annotationsPageNoteBadge
        }
        return String(highlight.anchorText.prefix(80))
    }

    private func color(_ highlightColor: HighlightColor) -> Color {
        var s = highlightColor.colorHex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return .yellow }
        return Color(.sRGB,
                     red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
}
