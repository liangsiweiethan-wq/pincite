import SwiftUI
import LiteratureCore
import LiteratureSearchUI

/// Coverage page: aggregate stats as paper-card stat plates (tap = filter the
/// per-book detail below), classification lines, last-run record and the
/// per-book detail list (honest: needs-OCR books are visible as such).
struct CoverageView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue

    @State private var activeFilter: DS.Color.Status?
    /// Detail-list-only text filter (filename / title / author). Never affects
    /// the stat plates or the classification lines above.
    @State private var detailFilter: String = ""

    private var theme: DS.Theme { .storage(dsTheme) }

    private var filteredStats: [BookPageStat] {
        let base = activeFilter == nil ? state.perBookStats
            : state.perBookStats.filter { status(for: $0) == activeFilter }
        guard !detailFilter.trimmingCharacters(in: .whitespaces).isEmpty else { return base }
        let f = detailFilter.lowercased()
        return base.filter { matchesDetailFilter($0, f) }
    }

    /// File name always matches; title/author match only when the book row is
    /// in the library cache (same three fields the placeholder promises).
    private func matchesDetailFilter(_ stat: BookPageStat, _ f: String) -> Bool {
        if let b = state.libraryBooks.first(where: { $0.id == stat.bookID }) {
            return b.fileName.lowercased().contains(f)
                || (b.title?.lowercased().contains(f) ?? false)
                || (b.author?.lowercased().contains(f) ?? false)
        }
        return (state.bookNames[stat.bookID] ?? stat.bookID).lowercased().contains(f)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                Text(L10n.navCoverage)
                    .font(DS.Font.displayPage)
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.bottom, DS.Spacing.sm)

                statsCard

                if !state.perBookStats.isEmpty {
                    Text(L10n.coveragePerBookDetail)
                        .font(DS.Font.displaySection)
                        .padding(.horizontal, DS.Spacing.xxs)
                    TextField(L10n.searchBooksPlaceholder, text: $detailFilter)
                        .textFieldStyle(.dsTextField)
                        .controlSize(.small)
                        .padding(.horizontal, DS.Spacing.xxs)
                    if !filteredStats.isEmpty {
                        VStack(spacing: DS.Spacing.xs) {
                            ForEach(filteredStats, id: \.bookID) { stat in
                                HStack(spacing: DS.Spacing.xs) {
                                    Circle()
                                        .fill(DS.Color.forStatus(status(for: stat), theme: theme, scheme: scheme))
                                        .frame(width: 8, height: 8)
                                    Text(state.bookNames[stat.bookID] ?? stat.bookID)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Spacer(minLength: DS.Spacing.xs)
                                    Text(perBookText(stat))
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                                }
                                .padding(.horizontal, DS.Spacing.sm)
                                .padding(.vertical, DS.Spacing.xxs)
                                .paperCard(radius: DS.Radius.small)
                            }
                        }
                    }
                }
            }
            .padding(DS.Spacing.md)
        }
        // 走查：页面地面统一 desk token（统计牌等纸卡浮在桌面上）。
        .background(DS.Color.desk(theme, scheme))
    }

    // MARK: Stats card

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text(L10n.coverageSectionTitle)
                .font(DS.Font.displaySection)
            if let stats = state.coverageStats {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: DS.Spacing.sm)],
                          alignment: .leading, spacing: DS.Spacing.sm) {
                    StatPlate(value: "\(stats.booksOK)", label: L10n.coverageBooksLine,
                              status: .success, isActive: activeFilter == .success) {
                        toggleFilter(.success)
                    }
                    StatPlate(value: "\(stats.pages)", label: L10n.coveragePagesLine,
                              status: .neutral, isActive: activeFilter == .neutral) {
                        toggleFilter(.neutral)
                    }
                    StatPlate(value: "\(stats.pagesWithoutText)", label: L10n.coverageNoTextLine,
                              status: .ocr, isActive: activeFilter == .ocr) {
                        toggleFilter(.ocr)
                    }
                    StatPlate(value: "\(stats.booksError)", label: L10n.coverageErrorBooksLine,
                              status: .warning, isActive: activeFilter == .warning) {
                        toggleFilter(.warning)
                    }
                }
                if activeFilter != nil {
                    HStack(spacing: DS.Spacing.sm) {
                        Button(L10n.clearFilter) { activeFilter = nil }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Text(L10n.filterActiveHint)
                            .font(.caption)
                            .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                        Spacer()
                    }
                }
            } else {
                Text(L10n.coverageNotBuilt)
                    .font(.callout)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }
            if let cls = state.coverageClassification {
                ForEach(Array(HitRouter.coverageClassificationLines(cls).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let run = state.lastRunRecord {
                Text("\(L10n.coverageLastRunPrefix)\(Self.timestampFormatter.string(from: run.at)) · 排除 \(run.excluded) · 不支持 \(run.unsupported) · 失败 \(run.failed)\(run.cancelled ? " · 已取消" : "")")
                    .font(.caption)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }
            HStack {
                Spacer()
                Button(L10n.coverageRefresh) { state.refreshCoverageFromStore() }
                    .buttonStyle(.bordered)
                    .font(.caption)
            }
        }
        .paperCard(radius: DS.Radius.large)
    }

    private func toggleFilter(_ status: DS.Color.Status) {
        activeFilter = (activeFilter == status) ? nil : status
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private func perBookText(_ stat: BookPageStat) -> String {
        "\(L10n.physicalPageTrack) \(stat.pagesWithText)/\(stat.indexedPages)"
    }

    /// Per-book classification: full = success, partial = warning,
    /// needs-OCR (0 pages with text) = OCR amber, unknown/neutral = secondary.
    /// Shared by the detail dots and the stat-plate filter so the two can
    /// never drift apart.
    private func status(for stat: BookPageStat) -> DS.Color.Status {
        guard stat.indexedPages > 0 else { return .neutral }
        if stat.pagesWithText == 0 { return .ocr }
        if stat.pagesWithText == stat.indexedPages { return .success }
        return .warning
    }
}
