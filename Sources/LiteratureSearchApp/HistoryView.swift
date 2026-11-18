import SwiftUI
import LiteratureCore
import LiteratureSearchUI

/// Search history page: taps refill the query and jump back to search.
/// Same shared store the Widget/watch read — no new storage.
struct HistoryView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dsTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    /// Transient "已清空" notice, shown until a new entry lands (same caption
    /// idiom as the sync message in settings — set the string, display as
    /// caption2, no toast machinery).
    @State private var cleared = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text(L10n.historyPageTitle)
                        .font(DS.Font.displayPage)
                    Text(L10n.historyLimitNote)
                        .font(.caption2)
                        .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                }
                Spacer()
                if !state.historyEntries.isEmpty {
                    Button(L10n.clearHistory) {
                        state.clearHistory()
                        cleared = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, DS.Spacing.md)
            .padding(.bottom, DS.Spacing.sm)
            if state.historyEntries.isEmpty {
                VStack {
                    Spacer()
                    if cleared {
                        Text(L10n.historyCleared)
                            .font(.caption2)
                            .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                            .padding(.bottom, DS.Spacing.xs)
                    }
                    EmptyStateView(systemImage: "clock",
                                   title: L10n.historyEmpty,
                                   detail: L10n.historyEmptyDetail)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(state.historyEntries, id: \.at) { entry in
                            HistoryRow(entry: entry)
                        }
                    }
                }
            }
        }
        .dsAppear()
        .background(DS.Color.desk(theme, scheme))
        .onAppear {
            state.refreshHistory()
            if !state.historyEntries.isEmpty { cleared = false }
        }
    }
}

/// One history row: tap refills the query and runs the search. Hover lifts
/// the row background slightly above a bottom hairline (the hover idiom)
/// so the plain rows still read as interactive.
private struct HistoryRow: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dsTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    let entry: HistoryEntry
    @State private var isHovered = false

    var body: some View {
        Button {
            state.query = entry.query
            state.sidebarSection = .search
            state.search()
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Text(entry.query)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                Text("\(L10n.resultSummaryHits) \(entry.hitCount) \(L10n.pageUnit)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                HStack(spacing: DS.Spacing.xxs) {
                    Text(entry.at, style: .date)
                    Text(entry.at, style: .time)
                }
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
            .contentShape(Rectangle())
            .background(isHovered
                ? DS.Color.inkTertiary(theme, scheme).opacity(0.08)
                : Color.clear)
            .overlay(alignment: .bottom) {
                Hairline()
            }
            // 动效门盘点：hover 背景为纯透明度 crossfade（无位移
            // 通道），按 先例计已门控语义，reduceMotion 下保留瞬时反馈。
            .animation(.easeOut(duration: DS.Motion.hoverDuration), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(entry.query)，\(L10n.resultSummaryHits) \(entry.hitCount) \(L10n.pageUnit)")
    }
}
