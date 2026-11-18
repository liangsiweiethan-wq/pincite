import WidgetKit
import SwiftUI
import Foundation
import AppKit

// Recent-searches widget (small + medium).
//
// Contract with the app (enforced by SharedHistoryStore's data shape):
// - The AppGroup surface carries ONLY query history and coverage counters.
//   No original text and no snippets ever cross into the widget.
// - The widget does NOT search by itself: tapping opens the app via the
//   literaturesearch:// deep link with the query prefilled.
// - Deep links are only emitted for non-empty queries; there is NEVER a
//   file:/// fallback URL.

private func deepLink(query: String) -> URL? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return DeepLink.search(query: trimmed).build()
}

struct HistoryEntryUI: Identifiable, Equatable {
    var id: String { query }
    var query: String
    var at: Date
    var hitCount: Int
}

struct CoverageUI: Equatable {
    var bookCount: Int
    var pageCount: Int
    var pagesWithoutText: Int?
    var errorBooks: Int?
    var rootName: String?
}

struct WidgetEntry: TimelineEntry {
    var date: Date
    var history: [HistoryEntryUI]
    var coverage: CoverageUI?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetEntry {
        WidgetEntry(date: Date(), history: sampleHistory, coverage: sampleCoverage)
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        completion(load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let entry = load()
        // Refresh periodically; the widget is a passive surface.
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: entry.date) ?? entry.date.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func load() -> WidgetEntry {
        let store = SharedHistoryStore(fileURL: SharedHistoryStore.sharedFileURL())
        let history = store.history(limit: 6).map {
            HistoryEntryUI(query: $0.query, at: $0.at, hitCount: $0.hitCount)
        }
        let coverage = store.coverage().map {
            CoverageUI(bookCount: $0.bookCount, pageCount: $0.pageCount,
                       pagesWithoutText: $0.pagesWithoutText, errorBooks: $0.errorBooks,
                       rootName: $0.rootName)
        }
        return WidgetEntry(date: Date(), history: history, coverage: coverage)
    }

    private var sampleHistory: [HistoryEntryUI] {
        [HistoryEntryUI(query: "检索示例", at: Date(), hitCount: 0)]
    }
    private var sampleCoverage: CoverageUI {
        CoverageUI(bookCount: 0, pageCount: 0, pagesWithoutText: nil, errorBooks: nil, rootName: nil)
    }
}

struct RecentSearchesWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: WidgetEntry

    var body: some View {
        Group {
            content
        }
        .modifier(WidgetContainerBackground())
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemSmall:
            small
        default:
            medium
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("最近检索")
                .font(.caption2)
                .foregroundStyle(.secondary)
            // Only a real deep link becomes a link; empty history stays plain text.
            if let latest = entry.history.first, let url = deepLink(query: latest.query) {
                Link(destination: url) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(latest.query)
                            .font(.callout)
                            .lineLimit(1)
                        Text("在应用中打开搜索")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("暂无历史").font(.caption).foregroundStyle(.secondary)
            }
            if let c = entry.coverage {
                Spacer()
                Text("书 \(c.bookCount) · 页 \(c.pageCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(2)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("最近检索")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(entry.history.prefix(4)) { item in
                    if let url = deepLink(query: item.query) {
                        Link(destination: url) {
                            HStack {
                                Text(item.query).lineLimit(1)
                                Spacer()
                                Text("\(item.hitCount)").foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    } else {
                        Text(item.query).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                    }
                }
                if entry.history.isEmpty {
                    Text("暂无历史").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let c = entry.coverage {
                VStack(alignment: .leading, spacing: 2) {
                    Text("已索引")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("书目 \(c.bookCount)").font(.caption)
                    Text("页面 \(c.pageCount)").font(.caption)
                    if let noText = c.pagesWithoutText {
                        Text("无文本页 \(noText)").font(.caption2).foregroundStyle(.secondary)
                    }
                    if let errors = c.errorBooks, errors > 0 {
                        Text("错误 \(errors)").font(.caption2).foregroundStyle(.secondary)
                    }
                    if let root = c.rootName {
                        Text(root).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(width: 90, alignment: .leading)
            }
        }
        .padding(2)
    }
}

struct WidgetContainerBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOSApplicationExtension 14.0, *) {
            content.containerBackground(for: .widget) {
                Color(nsColor: .windowBackgroundColor)
            }
        } else {
            content.background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

struct RecentSearchesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RecentSearchesWidget", provider: Provider()) { entry in
            RecentSearchesWidgetView(entry: entry)
        }
        .configurationDisplayName("最近检索")
        .description("显示最近的检索历史与索引覆盖统计；点击深链接在应用中打开搜索。小组件内不进行检索，也不展示原文。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
