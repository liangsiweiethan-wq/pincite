import WidgetKit
import SwiftUI
import Foundation

// iOS widget — recent searches + coverage counters (same contract as macOS
// widget). Sources for DeepLink/SharedHistoryStore are compiled directly into
// this target (Foundation-only files). The widget NEVER searches and NEVER
// shows original text; taps deep-link into the iOS app.

private func deepLink(query: String) -> URL? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return DeepLink.search(query: trimmed).build()
}

struct PhoneEntry: TimelineEntry {
    var date: Date
    var queries: [(query: String, hitCount: Int)]
    var coverageLine: String?
}

struct PhoneProvider: TimelineProvider {
    func placeholder(in context: Context) -> PhoneEntry {
        PhoneEntry(date: Date(), queries: [("检索示例", 0)], coverageLine: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (PhoneEntry) -> Void) {
        completion(load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PhoneEntry>) -> Void) {
        let entry = load()
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: entry.date)
            ?? entry.date.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func load() -> PhoneEntry {
        let store = SharedHistoryStore(fileURL: SharedHistoryStore.sharedFileURL())
        let queries = store.history(limit: 6).map { ($0.query, $0.hitCount) }
        var coverageLine: String?
        if let c = store.coverage() {
            var line = "书 \(c.bookCount) · 页 \(c.pageCount)"
            if let noText = c.pagesWithoutText { line += " · 无文本页 \(noText)" }
            coverageLine = line
        }
        return PhoneEntry(date: Date(), queries: queries, coverageLine: coverageLine)
    }
}

struct PhoneWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: PhoneEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall: small
            case .systemLarge: large
            default: medium
            }
        }
        .containerBackgroundCompat()
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("最近检索").font(.caption2).foregroundStyle(.secondary)
            if let latest = entry.queries.first, let url = deepLink(query: latest.query) {
                Link(destination: url) {
                    Text(latest.query).font(.callout).lineLimit(1)
                }
                Text("在应用中打开").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("暂无历史").font(.caption).foregroundStyle(.secondary)
            }
            if let line = entry.coverageLine {
                Spacer()
                Text(line).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("最近检索").font(.caption2).foregroundStyle(.secondary)
                ForEach(Array(entry.queries.prefix(4).enumerated()), id: \.offset) { _, item in
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
                if entry.queries.isEmpty {
                    Text("暂无历史").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let line = entry.coverageLine {
                Text(line).font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 84, alignment: .leading)
            }
        }
        .padding(2)
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("最近检索").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(entry.queries.prefix(8).enumerated()), id: \.offset) { _, item in
                if let url = deepLink(query: item.query) {
                    Link(destination: url) {
                        HStack {
                            Text(item.query).lineLimit(1)
                            Spacer()
                            Text("\(item.hitCount)").foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
            if entry.queries.isEmpty {
                Text("暂无历史").font(.caption).foregroundStyle(.secondary)
            }
            if let line = entry.coverageLine {
                Spacer()
                Text(line).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension View {
    /// containerBackground is required by WidgetKit on iOS 17+; the deployment
    /// target is iOS 17 so this is unconditional.
    @ViewBuilder
    func containerBackgroundCompat() -> some View {
        containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
    }
}

struct RecentSearchesiOSWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RecentSearchesiOSWidget", provider: PhoneProvider()) { entry in
            PhoneWidgetView(entry: entry)
        }
        .configurationDisplayName("最近检索")
        .description("显示最近的检索历史与索引覆盖统计；点击在应用中打开。小组件不检索、不展示原文。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct LiteratureSearchiOSWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecentSearchesiOSWidget()
    }
}
