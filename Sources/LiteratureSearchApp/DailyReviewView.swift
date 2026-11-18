import SwiftUI
import LiteratureCore
import LiteratureSearchUI

// MARK: - 每日回顾（第三模式）

struct DailyReviewView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dsTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    /// 档位（视图本地枚举；区间换算映射到 DailyReviewRange.Preset 纯函数）。
    enum Preset: Int, Hashable {
        case yesterday, last7, last30, custom
    }

    @State private var preset: Preset = .yesterday
    @State private var customStart = Calendar.current.startOfDay(for: Date())
    @State private var customEnd = Calendar.current.startOfDay(for: Date())
    @State private var items: [UserHighlight] = []
    @State private var totalCount = 0
    @State private var noteDrafts: [Int64: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            presetBar
            Divider()
            Group {
                if items.isEmpty {
                    EmptyStateView(systemImage: "calendar",
                                   title: preset == .yesterday
                                      ? L10n.reviewEmptyYesterday
                                      : L10n.reviewEmptyRange)
                } else {
                    reviewList
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: state.highlightsVersion) { _ in reload() }
        .onChange(of: preset) { _ in reload() }
    }

    private var presetBar: some View {
        HStack(spacing: DS.Spacing.sm) {
            Picker("", selection: $preset) {
                Text(L10n.reviewPresetYesterday).tag(Preset.yesterday)
                Text(L10n.reviewPresetLast7).tag(Preset.last7)
                Text(L10n.reviewPresetLast30).tag(Preset.last30)
                Text(L10n.reviewPresetCustom).tag(Preset.custom)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)
            if preset == .custom {
                DatePicker(L10n.reviewCustomStart, selection: $customStart, displayedComponents: [.date])
                    .onChange(of: customStart) { _ in reload() }
                DatePicker(L10n.reviewCustomEnd, selection: $customEnd, displayedComponents: [.date])
                    .onChange(of: customEnd) { _ in reload() }
            }
            Spacer()
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
    }

    @ViewBuilder
    private var reviewList: some View {
        List {
            ForEach(items) { highlight in
                VStack(alignment: .leading, spacing: 0) {
                    ExcerptRowView(
                        highlight: highlight,
                        bookTitle: state.bookNames[highlight.bookID] ?? highlight.bookID,
                        createdAtText: ExcerptRowView.createdAtFormatter.string(from: highlight.createdAt),
                        noteDraft: draftBinding(for: highlight),
                        onSaveNote: { saveNote(highlight) },
                        theme: theme, scheme: scheme,
                        onJump: {
                            Task { await state.openBookPage(bookID: highlight.bookID,
                                               pageNumber: highlight.pageNumber) }
                        },
                        onDelete: { state.requestAnnotationDelete(highlight) })
                }
                .listRowSeparator(.visible)
            }
            paginationFooter
        }
        .listStyle(.plain)
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

    // MARK: Data

    /// 当前档位 → 闭开区间（纯函数注入 Calendar.current；换算失败 = 如实空）。
    private var activeRange: (from: Date, to: Date)? {
        let mapped: DailyReviewRange.Preset
        switch preset {
        case .yesterday: mapped = .yesterday
        case .last7: mapped = .last7Days
        case .last30: mapped = .last30Days
        case .custom: mapped = .custom(startDay: customStart, endDay: customEnd)
        }
        return DailyReviewRange.range(for: mapped, now: Date(), calendar: Calendar.current)
    }

    private func reload() {
        assert(Thread.isMainThread, "annotation queries must run on the main thread")
        guard let range = activeRange else {
            items = []; totalCount = 0; noteDrafts = [:]
            return
        }
        totalCount = state.reviewTotalCount(from: range.from, to: range.to)
        let loaded = state.reviewWindows(from: range.from, to: range.to,
                                         limit: ExcerptBoardView.pageSize, offset: 0)
        items = loaded
        var drafts: [Int64: String] = [:]
        for highlight in loaded { drafts[highlight.id] = highlight.note }
        noteDrafts = drafts
    }

    private func loadMore() {
        assert(Thread.isMainThread, "annotation queries must run on the main thread")
        guard let range = activeRange else { return }
        let next = state.reviewWindows(from: range.from, to: range.to,
                                       limit: ExcerptBoardView.pageSize, offset: items.count)
        guard !next.isEmpty else { return }
        items.append(contentsOf: next)
        for highlight in next where noteDrafts[highlight.id] == nil {
            noteDrafts[highlight.id] = highlight.note
        }
    }

    private func saveNote(_ highlight: UserHighlight) {
        assert(Thread.isMainThread, "annotation writes must run on the main thread")
        guard let store = state.highlightStore,
              noteDrafts[highlight.id] != highlight.note else { return }
        try? store.updateNote(id: highlight.id, note: noteDrafts[highlight.id] ?? "")
        state.highlightsVersion &+= 1
    }

    private func draftBinding(for highlight: UserHighlight) -> Binding<String> {
        Binding(
            get: { noteDrafts[highlight.id] ?? "" },
            set: { noteDrafts[highlight.id] = $0 })
    }
}
