import SwiftUI
import LiteratureCore
import LiteratureSearchUI

// MARK: - 批注总列表（第二模式）
//
// 全库批注按 created_at DESC 全序平铺（不分书分组，行形态＝摘录板行组件
// 同款）；行内删除走同一条软删 + toast 撤销通道（AppState.requestAnnotationDelete）；
// 行点击跳原文（openBookPage 既有管线）。分页每页 50，已加载/总数如实标注。

struct AnnotationListView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dsTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    @State private var items: [UserHighlight] = []
    @State private var totalCount = 0

    var body: some View {
        Group {
            if items.isEmpty {
                EmptyStateView(systemImage: "note.text", title: L10n.annotationsLibraryEmpty)
            } else {
                List {
                    ForEach(items) { highlight in
                        ExcerptRowView(
                            highlight: highlight,
                            bookTitle: state.bookNames[highlight.bookID] ?? highlight.bookID,
                            theme: theme, scheme: scheme,
                            onJump: {
                                Task { await state.openBookPage(bookID: highlight.bookID,
                                                   pageNumber: highlight.pageNumber) }
                            },
                            onDelete: { state.requestAnnotationDelete(highlight) })
                        .listRowSeparator(.visible)
                    }
                    paginationFooter
                }
                .listStyle(.plain)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: state.highlightsVersion) { _ in reload() }
    }

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

    private func reload() {
        assert(Thread.isMainThread, "annotation queries must run on the main thread")
        totalCount = state.annotationTotalCount()
        items = state.excerptWindows(limit: ExcerptBoardView.pageSize, offset: 0)
    }

    private func loadMore() {
        assert(Thread.isMainThread, "annotation queries must run on the main thread")
        let next = state.excerptWindows(limit: ExcerptBoardView.pageSize, offset: items.count)
        guard !next.isEmpty else { return }
        items.append(contentsOf: next)
    }
}
