import SwiftUI
import LiteratureCore
import LiteratureSearchUI

struct DailyQuoteView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dsTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    /// 整卡朗读（本地 TTSSpeaker 实例，DetailChromeView: 46 同款
    /// 薄封装复用——speak/stop 语义零改动，只复用）。
    @StateObject private var cardSpeaker = TTSSpeaker()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                if state.quoteLoading && state.todayQuote == nil {
                    StatusRow(systemImage: "text.quote",
                              text: L10n.quotePreparing,
                              color: DS.Color.inkSecondary(theme, scheme),
                              font: .callout)
                        .padding(.top, DS.Spacing.lg)
                } else if let quote = state.todayQuote {
                    quoteCard(quote)
                    dailyStatsBlock
                    speakControls
                    actions(quote)
                    aiArea
                } else {
                    EmptyStateView(systemImage: "text.quote",
                                   title: L10n.quoteEmptyTitle,
                                   detail: L10n.quoteEmptyDetail)
                    .padding(.top, DS.Spacing.lg)
                }
                if !state.quoteAlternatives.isEmpty {
                    alternatives
                }
                if let reason = state.quoteBlockedReason {
                    StatusRow(systemImage: "exclamationmark.octagon.fill",
                              text: reason,
                              color: DS.Color.error(theme, scheme),
                              font: .callout)
                }
                if let notice = state.lastFavoriteNotice {
                    StatusRow(systemImage: "checkmark.circle.fill",
                              text: notice,
                              color: DS.Color.success(theme, scheme),
                              font: .caption)
                }
            }
            .padding(DS.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.Color.desk(theme, scheme))
        // 进入每日卡分区即刷新今日阅读统计（事件驱动写入发生在
        // 阅读器侧，这里只做读侧刷新；nil=当日无行 → 空态不造数）。
        .onAppear { state.refreshDailyReadingStats() }
    }

    /// 当日句卡：宋体大字号正文（readingSerif 放大，禁 bold 规则不适用），
    /// 出处行走 readingSerifMeta 下限 12.5pt。
    private func quoteCard(_ quote: Quote) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Text(quote.sentence)
                .font(DS.Font.readingSerif(size: 20))
                .foregroundStyle(DS.Color.ink(theme, scheme))
                .frame(maxWidth: .infinity, alignment: .leading)
            if let citation = citationText(for: quote) {
                Text(citation)
                    .font(DS.Font.readingSerifMeta)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }
        }
        .padding(DS.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.paper(theme, scheme),
                    in: RoundedRectangle(cornerRadius: DS.Radius.large))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.large)
            .stroke(DS.Color.stroke(theme, scheme), lineWidth: 1))
    }

    // MARK: 今日阅读块＋整卡朗读

    /// 今日阅读块：minutes/pages 如实数字；nil = 当日无任何行 → 显式空态，
    /// 不造数。
    @ViewBuilder
    private var dailyStatsBlock: some View {
        if let stats = state.dailyReadingStats {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "book")
                    .font(.callout)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                Text(L10n.dailyStatsTitle)
                    .font(.callout)
                    .foregroundStyle(DS.Color.ink(theme, scheme))
                Text(L10n.dailyStatsLine(minutes: stats.minutes, pages: stats.pages))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }
        } else {
            Text(L10n.dailyStatsEmpty)
                .font(.caption)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
        }
    }

    /// 整卡朗读：文案合成走 Core 纯函数 DailyCardComposer（摘录句＋出处＋
    /// 统计行，空统计不含统计行），经既有 TTSSpeaker.speak(text:) 朗读
    /// （CJK 判定走 isCJK 既有基准，零改动）；朗读中给停止钮。
    @ViewBuilder
    private var speakControls: some View {
        HStack(spacing: DS.Spacing.sm) {
            if cardSpeaker.speaking {
                Button(L10n.dailyCardStop) { cardSpeaker.stop() }
                    .buttonStyle(.bordered)
            } else {
                Button(L10n.dailyCardSpeak) { speakDailyCard() }
                    .buttonStyle(.bordered)
                    .disabled(state.todayQuote == nil)
            }
        }
    }

    private func speakDailyCard() {
        guard let quote = state.todayQuote else { return }
        let text = DailyCardComposer.composeDailyCardText(
            quote: quote,
            citation: citationText(for: quote),
            stats: state.dailyReadingStats)
        cardSpeaker.speak(text: text)
    }

    private func actions(_ quote: Quote) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Button(L10n.quoteOpenBook) { Task { await state.openQuoteInBook(quote) } }
                .buttonStyle(.borderedProminent)
                .tint(DS.Color.ink(theme, scheme))
                .disabled(state.quoteLoading)
            Button(L10n.favoriteQuote) { state.favoriteQuote() }
                .buttonStyle(.bordered)
            if state.aiConfigured {
                // 三按钮：翻译 / 解释 / 语法拆解，
                // 各走既有 AI 确认门（预填 prompt 不同，零请求保证不变）。
                Button(L10n.quoteTranslate) { Task { await state.makeQuoteAIPreview(quote, mode: .translate) } }
                    .buttonStyle(.bordered)
                Button(L10n.quoteExplain) { Task { await state.makeQuoteAIPreview(quote, mode: .explain) } }
                    .buttonStyle(.bordered)
                Button(L10n.quoteGrammar) { Task { await state.makeQuoteAIPreview(quote, mode: .grammar) } }
                    .buttonStyle(.bordered)
            }
        }
    }

    /// 预览/确认复用既有 AIPreviewPanel（问题栏按三按钮模式预填翻译/解释/
    /// 语法拆解 prompt，未确认前零请求）；answer/decisions 与详情栏共享同一
    /// 份 AppState。
    @ViewBuilder
    private var aiArea: some View {
        if state.aiConfigured, state.quoteHit != nil, let hit = state.quoteHit {
            AIPreviewPanel(hit: hit)
                .frame(maxHeight: 360, alignment: .top)
        }
    }

    /// 同池轮换备选（只读陈列：句 + 出处短行，不做截断隐藏）。
    private var alternatives: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text(L10n.quoteAlternativesTitle)
                .font(DS.Font.displaySection)
                .foregroundStyle(DS.Color.ink(theme, scheme))
            ForEach(state.quoteAlternatives, id: \.id) { quote in
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text(quote.sentence)
                        .font(.callout)
                        .foregroundStyle(DS.Color.ink(theme, scheme))
                        .lineLimit(3)
                    if let citation = citationText(for: quote) {
                        Text(citation)
                            .font(.caption)
                            .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, DS.Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 出处行：纯引注（CitationFormatter.citation，书名优先，未知回退
    /// 文件名）。 引句绑定取页：printed 可得→印刷页，否则物理页
    /// （现行行为；经 PageNumberService 统一取页，nil=未知不猜）。
    private func citationText(for quote: Quote) -> String? {
        CitationFormatter.citation(
            fileName: quote.fileName,
            title: state.quoteBooks[quote.bookID]?.title,
            physicalPage: quote.pageNumber,
            style: state.citationStyle,
            printedPage: state.printedPage(bookID: quote.bookID, physical: quote.pageNumber))
    }
}
