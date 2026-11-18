import WidgetKit
import SwiftUI
import Foundation
import AppKit


private let quoteDeepLink = DeepLink.quote.build()

private func loadQuote() -> SharedQuoteState? {
    SharedQuoteStore(fileURL: SharedQuoteStore.quoteFileURL()).load()
}

/// Next local midnight: the quote changes per calendar day, so the timeline
/// only needs to advance at the start of the following day.
private func nextMidline(after date: Date) -> Date {
    let startOfToday = Calendar.current.startOfDay(for: date)
    return Calendar.current.date(byAdding: .day, value: 1, to: startOfToday)
        ?? date.addingTimeInterval(86400)
}

struct QuoteWidgetEntry: TimelineEntry {
    var date: Date
    var quote: SharedQuoteState?
}

struct QuoteWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuoteWidgetEntry {
        QuoteWidgetEntry(date: Date(), quote: sampleQuote)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuoteWidgetEntry) -> Void) {
        completion(QuoteWidgetEntry(date: Date(), quote: loadQuote()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuoteWidgetEntry>) -> Void) {
        let entry = QuoteWidgetEntry(date: Date(), quote: loadQuote())
        completion(Timeline(entries: [entry], policy: .after(nextMidline(after: entry.date))))
    }

    private var sampleQuote: SharedQuoteState {
        SharedQuoteState(sentence: "A new blank page gives each small idea room to grow.",
                         bookFileName: "A Sample Treatise.pdf", physicalPage: 1, date: "2001-01-01")
    }
}

/// 金环（细金描边小圆环）：呼应 AppIcon「开卷书 + 星芒」的细金环元素
private let widgetGoldRing = Color(red: 0.788, green: 0.635, blue: 0.153)

private struct GoldRing: View {
    var size: CGFloat = 10
    var body: some View {
        Circle()
            .stroke(widgetGoldRing, lineWidth: 1)
            .frame(width: size, height: size)
    }
}

struct DailyQuoteWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: QuoteWidgetEntry

    var body: some View {
        Group {
            if let quote = entry.quote {
                linked(content(quote))
            } else {
                linked(emptyContent)
            }
        }
        .modifier(WidgetContainerBackground())
    }

    @ViewBuilder
    private func linked<Content: View>(_ content: Content) -> some View {
        if let url = quoteDeepLink {
            Link(destination: url) { content }
        } else {
            content
        }
    }

    @ViewBuilder
    private func content(_ quote: SharedQuoteState) -> some View {
        switch family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 4) {
                Text("每日一句")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                // 小组件约 60 字截断。
                Text(String(quote.sentence.prefix(60)))
                    .font(.callout)
                    .lineLimit(4)
                Spacer()
                Text(shortBookName(quote.bookFileName))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(2)
        case .systemLarge:
            // 大组件：衬线完整
            // 句子 + 金环 + 出处 + 「点击翻译」提示，呼应 VISUAL-DESIGN.md 书房基调。
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    GoldRing(size: 9)
                    Text("每日一句")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // 大组件约 300 字截断（字符级），lineLimit 放宽展示完整长句。
                Text(String(quote.sentence.prefix(300)))
                    .font(.system(.title3, design: .serif))
                    .lineLimit(10)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(shortBookName(quote.bookFileName)) · 第\(quote.physicalPage)页")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("点击在应用中翻译")
                        .font(.caption2)
                        .foregroundStyle(widgetGoldRing)
                        .lineLimit(1)
                }
            }
            .padding(6)
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "text.quote")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("每日一句")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                // 中组件约 140 字截断（字符级）。
                Text(String(quote.sentence.prefix(140)))
                    .font(.callout)
                    .lineLimit(6)
                Spacer()
                Text("\(shortBookName(quote.bookFileName)) · 第\(quote.physicalPage)页")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(2)
        }
    }

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("每日一句")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("暂无摘录")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text("在应用中查看")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(2)
    }

    /// Book display name: strip a synthetic ".pdf" extension when the stem
    /// carries a CJK title (mirrors the app's cleanFileName convention).
    private func shortBookName(_ fileName: String) -> String {
        if fileName.hasSuffix(".pdf") {
            return String(fileName.dropLast(4))
        }
        return fileName
    }
}

struct DailyQuoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DailyQuoteWidget", provider: QuoteWidgetProvider()) { entry in
            DailyQuoteWidgetView(entry: entry)
        }
        .configurationDisplayName("每日一句")
        .description("显示从文献库英文原书抽取的当日长句及其出处；点击在应用中查看原书页面，并使用翻译、解释、语法拆解。大尺寸组件展示完整句子。小组件不自行抽取，也不展示原文全文。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
