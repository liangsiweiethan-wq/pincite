import WidgetKit
import SwiftUI
import Foundation

// watchOS widget — accessory families (circular / rectangular / corner /
// inline). SUMMARY ONLY: counters + the newest truncated query. Tapping opens
// the watch app via the literaturesearch:// deep link (the watch app itself
// is the summary surface; there is no search on the watch).

private func watchDeepLink() -> URL? {
    DeepLink.search(query: "summary").build()
}

private func loadSummary() -> (WatchSummary, Bool)? {
    guard let data = WatchSummaryCache.load(),
          let summary = try? WatchSummaryCodec.decode(data) else { return nil }
    return (summary, summary.isExpired())
}

struct WatchSummaryEntry: TimelineEntry {
    var date: Date
    var summary: WatchSummary?
    var expired: Bool
}

struct WatchSummaryProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchSummaryEntry {
        WatchSummaryEntry(date: Date(), summary: nil, expired: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchSummaryEntry) -> Void) {
        completion(load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchSummaryEntry>) -> Void) {
        let entry = load()
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: entry.date)
            ?? entry.date.addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func load() -> WatchSummaryEntry {
        if let (summary, expired) = loadSummary() {
            return WatchSummaryEntry(date: Date(), summary: summary, expired: expired)
        }
        return WatchSummaryEntry(date: Date(), summary: nil, expired: false)
    }
}

struct WatchSummaryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: WatchSummaryEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: circular
            case .accessoryCorner: corner
            case .accessoryInline: inline
            default: rectangular
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(watchDeepLink())
    }

    private var countsLine: String {
        guard let s = entry.summary else { return "无摘要" }
        return "书 \(s.bookCount) 页 \(s.pageCount)"
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Text(entry.summary.map { "\($0.bookCount)" } ?? "—")
                    .font(.headline)
                Text(entry.summary.map { "\($0.pageCount)" } ?? "")
                    .font(.caption2)
            }
        }
    }

    private var corner: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(entry.summary.map { "\($0.bookCount)" } ?? "—")
                .font(.title3)
                .widgetLabel {
                    Text(entry.expired ? "书 · 已过期" : "书目已索引")
                }
        }
    }

    private var inline: some View {
        Text(entry.expired ? "\(countsLine) · 已过期" : countsLine)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(countsLine).font(.headline)
            if let q = entry.summary?.queries.first {
                Text(q).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
            } else {
                Text("等待 iPhone 摘要").font(.caption2).foregroundStyle(.secondary)
            }
            if entry.expired {
                Text("摘要已过期").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct SummaryWatchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SummaryWatchWidget", provider: WatchSummaryProvider()) { entry in
            WatchSummaryWidgetView(entry: entry)
        }
        .configurationDisplayName("文献摘要")
        .description("显示书目/页面计数与最近一条检索（摘要，无原文）；点击打开手表摘要应用。")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryCorner, .accessoryInline])
    }
}

struct LiteratureSearchWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        SummaryWatchWidget()
        DailyQuoteWatchWidget() // 今日一句 + 阅读进度 complication
    }
}
