import WidgetKit
import SwiftUI
import Foundation

// watchOS widget  — accessory families (circular / rectangular /
// corner / inline). COMPANION ONLY: the daily quote (sentence + source) and
// the reading progress line. Tapping opens the watch app via the
// literaturesearch://quote deep link (DeepLink.swift:14 — the watch app is
// the display surface; there is no search on the watch). Expired payloads
// are labelled, never hidden; a missing payload shows the empty state.

private func quoteDeepLink() -> URL? {
    DeepLink.quote.build()
}

private func loadCompanion() -> (WatchCompanionPayload, Bool)? {
    guard let data = WatchCompanionCache.load(),
          let payload = try? WatchCompanionCodec.decode(data) else { return nil }
    return (payload, payload.isExpired())
}

struct WatchCompanionEntry: TimelineEntry {
    var date: Date
    var payload: WatchCompanionPayload?
    var expired: Bool
}

struct WatchCompanionProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchCompanionEntry {
        WatchCompanionEntry(date: Date(), payload: nil, expired: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchCompanionEntry) -> Void) {
        completion(load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchCompanionEntry>) -> Void) {
        let entry = load()
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: entry.date)
            ?? entry.date.addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func load() -> WatchCompanionEntry {
        if let (payload, expired) = loadCompanion() {
            return WatchCompanionEntry(date: Date(), payload: payload, expired: expired)
        }
        return WatchCompanionEntry(date: Date(), payload: nil, expired: false)
    }
}

struct DailyQuoteWatchWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: WatchCompanionEntry

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
        .widgetURL(quoteDeepLink())
    }

    private var quote: WatchDailyQuote? { entry.payload?.dailyQuote }
    private var progress: WatchReadingProgress? { entry.payload?.progress }

    /// 句首字（circular/corning 的单字面；无句时占位）。
    private var firstCharacter: String {
        guard let sentence = quote?.sentence, let first = sentence.first else { return "—" }
        return String(first)
    }

    private var sourceLine: String {
        guard let q = quote else { return "等待 iPhone 推送" }
        return "\(q.bookTitle) · 第 \(q.physicalPage) 页"
    }

    private var progressLine: String? {
        guard let p = progress else { return nil }
        return "读到第 \(p.page) / \(max(p.pageCount, p.page)) 页"
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Text(firstCharacter).font(.headline)
                Text(progress.map { "\($0.page)" } ?? "")
                    .font(.caption2)
            }
        }
    }

    private var corner: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(firstCharacter)
                .font(.title3)
                .widgetLabel {
                    Text(entry.expired ? "一句 · 已过期" : "今日一句")
                }
        }
    }

    private var inline: some View {
        Text(entry.expired ? "\(sourceLine) · 已过期" : sourceLine)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let q = quote {
                Text(q.sentence).font(.caption2).lineLimit(1)
                Text(sourceLine).font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("等待 iPhone 推送").font(.caption2).foregroundStyle(.secondary)
            }
            if let line = progressLine {
                Text(line).font(.caption2).foregroundStyle(.secondary)
            }
            if entry.expired {
                Text("已过期（超 24 小时）").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct DailyQuoteWatchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DailyQuoteWatchWidget", provider: WatchCompanionProvider()) { entry in
            DailyQuoteWatchWidgetView(entry: entry)
        }
        .configurationDisplayName("今日一句")
        .description("显示今日一句与阅读进度（iPhone 推送，无原文）；点击打开手表摘要应用。")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryCorner, .accessoryInline])
    }
}
