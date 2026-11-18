import SwiftUI
import LiteratureCore
import LiteratureSearchUI

// MARK: - 批注区（三模式壳与摘录板）

struct ExcerptBoardView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dsTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    enum Mode: Int, Hashable {
        case board, list, review
    }

    @State private var mode: Mode = .board
    @State private var items: [UserHighlight] = []
    @State private var totalCount = 0
    @State private var bookCounts: [(bookID: String, total: Int, withNote: Int)] = []
    @State private var exportPresented = false

    //分页窗口（每页 50， allHighlights；已加载/总数如实标注）。
    static let pageSize = 50

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            switch mode {
            case .board:
                boardList
            case .list:
                AnnotationListView()
            case .review:
                DailyReviewView()
            }
        }
        .onAppear(perform: reload)
        .onChange(of: state.highlightsVersion) { _ in reload() }
        .sheet(isPresented: $exportPresented) {
            AnnotationExportView()
        }
    }

    // MARK: Sections

    private var toolbar: some View {
        HStack(spacing: DS.Spacing.sm) {
            Picker("", selection: $mode) {
                Text(L10n.excerptModeBoard).tag(Mode.board)
                Text(L10n.excerptModeList).tag(Mode.list)
                Text(L10n.excerptModeReview).tag(Mode.review)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)
            Spacer()
            Button(L10n.annotationExportOpen) { exportPresented = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(L10n.annotationExportTitle)
                .accessibilityLabel(L10n.annotationExportTitle)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
    }

    @ViewBuilder
    private var boardList: some View {
        if items.isEmpty {
            EmptyStateView(systemImage: "highlighter", title: L10n.annotationsLibraryEmpty)
        } else {
            let groups = UserHighlightGrouper.group(
                items, knownBookIDs: state.bookNames.isEmpty ? nil : Set(state.bookNames.keys))
            List {
                ForEach(groups, id: \.bookID) { group in
                    Section {
                        ForEach(group.items) { highlight in
                            ExcerptRowView(
                                highlight: highlight,
                                bookTitle: nil,
                                theme: theme, scheme: scheme,
                                onJump: {
                                    Task { await state.openBookPage(bookID: highlight.bookID,
                                                       pageNumber: highlight.pageNumber) }
                                },
                                onDelete: { state.requestAnnotationDelete(highlight) })
                            .listRowSeparator(.visible)
                        }
                    } header: {
                        HStack(spacing: DS.Spacing.xs) {
                            Text(bookTitle(for: group.bookID))
                                .font(DS.Font.displayGroup)
                                .foregroundStyle(DS.Color.ink(theme, scheme))
                            if let count = bookCounts.first(where: { $0.bookID == group.bookID }) {
                                Text(L10n.annotationsCount(count.total))
                                    .font(.caption2)
                                    .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                            }
                        }
                        .textCase(nil)
                    }
                }
                paginationFooter
            }
            .listStyle(.plain)
        }
    }

    /// 分页脚注：已加载/总数如实 + 「加载更多」（有剩余才出现）。
    @ViewBuilder
    private var paginationFooter: some View {
        Section {
            VStack(spacing: DS.Spacing.xs) {
                Text(L10n.annotationLoadedTotal(items.count, totalCount))
                    .font(.caption)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                if items.count < totalCount {
                    Button(L10n.excerptLoadMore) { loadMore() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
        }
    }

    // MARK: Data

    private func reload() {
        assert(Thread.isMainThread, "annotation queries must run on the main thread")
        totalCount = state.annotationTotalCount()
        bookCounts = state.excerptBookCounts()
        items = state.excerptWindows(limit: Self.pageSize, offset: 0)
    }

    private func loadMore() {
        assert(Thread.isMainThread, "annotation queries must run on the main thread")
        let next = state.excerptWindows(limit: Self.pageSize, offset: items.count)
        guard !next.isEmpty else { return }
        items.append(contentsOf: next)
    }

    /// 书名解析阶梯：bookNames → bookID（如实显示解析到哪级）；分组器保留组
    /// （bookID = ""）渲「未知来源」。
    private func bookTitle(for bookID: String) -> String {
        if bookID.isEmpty { return L10n.excerptUnknownSource }
        return state.bookNames[bookID] ?? bookID
    }
}

// MARK: - 批注行组件（共用「同款平铺」形态）

/// 色点 + 页码 + 来源徽标（可选书名徽标/时间）+ 摘句 + note 预览（可选
/// 行内编辑）。语义照 AnnotationSidebarView sourceBadge（自绘最小行，不复用
/// 其 private 结构）；摘句锚失效如实显示 highlightsStaleSnippet（不猜不装）。
//点击行跳原文；contextMenu 删除走 软删+toast 通道。
struct ExcerptRowView: View {
    let highlight: UserHighlight
    /// 书名徽标（跨书视图显示；nil = 不显示）。
    var bookTitle: String? = nil
    /// created_at 文本（每日回顾显示）。
    var createdAtText: String? = nil
    /// 行内 note 编辑（每日回顾；nil = 只读预览）。
    var noteDraft: Binding<String>? = nil
    var onSaveNote: (() -> Void)? = nil
    let theme: DS.Theme
    let scheme: ColorScheme
    let onJump: () -> Void
    let onDelete: () -> Void

    /// created_at 文本共享格式器（App 侧静态，避免每行新建）。
    static let createdAtFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

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
                            if let bookTitle {
                                Text(bookTitle)
                                    .font(.caption)
                                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                                    .lineLimit(1)
                            }
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
                                    .accessibilityHidden(true)
                            }
                            if let createdAtText {
                                Text(createdAtText)
                                    .font(.caption2)
                                    .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                            }
                        }
                        Text(snippet)
                            .font(.callout)
                            .foregroundStyle(
                                snippet == L10n.highlightsStaleSnippet
                                    ? DS.Color.inkSecondary(theme, scheme)
                                    : DS.Color.ink(theme, scheme))
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let noteDraft {
                            TextField(L10n.annotationsNotePlaceholder, text: noteDraft)
                                .font(.caption)
                                .textFieldStyle(.dsTextField)
                                .onSubmit { onSaveNote?() }
                        } else if !highlight.note.isEmpty {
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
            .contextMenu {
                Button(L10n.actionDelete) { onDelete() }
            }
        }
        .padding(.vertical, DS.Spacing.xxs)
        .dsHoverFade()
    }

    /// 来源徽标：页级批注 / 'ocr' / 'original'（语义照 AnnotationSidebarView
    /// sourceBadge: 310-317 同一判定）。
    private var sourceBadge: String {
        if highlight.utf16Start == 0 && highlight.utf16End == 0 && highlight.anchorText.isEmpty {
            return L10n.annotationsPageNoteBadge
        }
        return highlight.viewSource == HighlightStore.viewSourceOriginal
            ? L10n.annotationsSourceOriginal
            : L10n.annotationsSourceOCR
    }

    /// 摘句：页级批注显示整页批注语义；失效锚如实；否则锚文本前 80 字。
    private var snippet: String {
        if highlight.anchorText.isEmpty {
            return L10n.annotationsPageNoteBadge
        }
        if highlight.anchorVerified == -1 {
            return L10n.highlightsStaleSnippet
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
