import SwiftUI
import LiteratureCore
import LiteratureSearchUI

//MARK: - AI 增强批结果卡（体检卡／ 评分卡／ 速读卡／ 报告卡）
//
// 约束：不重构 AI 面板信息架构、不碰 DesignSystem
// token、不新增琥珀色位点；卡片只读展示＋既有 NSPasteboard 复制通道；页码
// 显示走 L10n 已知值/「页码未知」，绝不猜（PageNumberService 声明制）。

//端上模型体检卡（设置页与档案表单复用）：逐项类型化状态＋恢复指引
/// ＋上下文窗（运行时读取值，不硬编码）。
struct OnDeviceHealthCard: View {
    @Environment(\.dsTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let status: OnDeviceModelStatus

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(L10n.aiOnDeviceHealthTitle).font(DS.Font.displayGroup)
            switch status.availability {
            case .available(let tokens):
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DS.Color.success(theme, scheme))
                    Text(L10n.aiOnDeviceContextTokens(tokens))
                        .font(.caption)
                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                }
            case .unavailable(let blocks):
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    HStack(alignment: .top, spacing: DS.Spacing.xs) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(DS.Color.error(theme, scheme))
                        Text(L10n.aiOnDeviceBlockLine(block.label, block.guidance))
                            .font(.caption)
                            .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    }
                }
            }
            Text(L10n.aiOnDevicePrivacyNote)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
        }
        .padding(DS.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.paper(theme, scheme),
                    in: RoundedRectangle(cornerRadius: DS.Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.medium)
            .stroke(DS.Color.stroke(theme, scheme), lineWidth: 1))
    }
}

//逐块评分结果卡：逐块页码/分数/摘要，落选块如实显示落选原因；
/// 账本汇总行（次数＋字节基准）。
struct RCSScorecardView: View {
    @Environment(\.dsTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let outcome: RCSOutcome
    let ledgerText: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(L10n.rcsCardTitle).font(DS.Font.displayGroup)
            if outcome.answer == nil {
                Text(L10n.rcsAllFilteredNote)
                    .font(.caption)
                    .foregroundStyle(DS.Color.error(theme, scheme))
            }
            ForEach(Array(outcome.results.enumerated()), id: \.offset) { _, result in
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    HStack(spacing: DS.Spacing.xs) {
                        Image(systemName: result.survived ? "checkmark.circle.fill" : "minus.circle.fill")
                            .foregroundStyle(result.survived
                                             ? DS.Color.success(theme, scheme)
                                             : DS.Color.inkSecondary(theme, scheme))
                        Text(L10n.rcsBlockScoreLine(result.block.index,
                                                    result.verdict?.relevanceScore ?? 0))
                            .font(.caption)
                        Text(result.block.anchorText)
                            .font(.caption2)
                            .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    }
                    if let verdict = result.verdict, !verdict.summary.isEmpty {
                        Text(verdict.summary)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let reason = result.failureReason {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    }
                }
                .padding(.vertical, 1)
            }
            if outcome.parseFailureCount > 0 {
                Text(L10n.rcsParseFailureCount(outcome.parseFailureCount))
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }
            Text(ledgerText)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
        }
        .padding(DS.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.paper(theme, scheme),
                    in: RoundedRectangle(cornerRadius: DS.Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.medium)
            .stroke(DS.Color.stroke(theme, scheme), lineWidth: 1))
        .dsAppear()
    }
}

//速读卡：固定四段＋逐段页码锚点（已知值显示，未知显式「页码未知」）；
/// 缺段如实「模型未给出该段」；复制走既有 NSPasteboard 通道（由容器提供）。
struct SpeedReadCardView: View {
    @Environment(\.dsTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let card: SpeedReadCard
    /// 页码锚点显示换算（bookId→书目名＋pageLabel/printedPage 已知值；
    /// AppState 注入，未知名回退 bookID）。
    let anchorText: (SpeedReadAnchor) -> String
    /// 预算裁剪回执（无裁剪为 nil）。
    let budgetNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(L10n.speedReadCardTitle).font(DS.Font.displayGroup)
            if let budgetNote {
                Text(budgetNote)
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }
            ForEach(Array(card.sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text(section.title).font(DS.Font.displaySection)
                    if section.isMissing {
                        Text(L10n.speedReadSectionMissing)
                            .font(.caption)
                            .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    } else {
                        Text(section.text)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !section.anchors.isEmpty {
                            Text(section.anchors.map(anchorText).joined(separator: "；"))
                                .font(.caption2)
                                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                        }
                    }
                }
            }
        }
        .padding(DS.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.paper(theme, scheme),
                    in: RoundedRectangle(cornerRadius: DS.Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.medium)
            .stroke(DS.Color.stroke(theme, scheme), lineWidth: 1))
        .dsAppear()
    }
}

//综述自检报告卡：逐轮处置摘要＋账本汇总＋最终稿；「采用/弃用」两钮
struct ReviewSelfCheckReportView: View {
    @Environment(\.dsTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let outcome: ReviewSelfCheckOutcome
    let ledgerText: String
    let onAdopt: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(L10n.reviewCardTitle).font(DS.Font.displayGroup)
            ForEach(Array(outcome.rounds.enumerated()), id: \.offset) { _, round in
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text(L10n.reviewRoundLabel(round.round)).font(DS.Font.displaySection)
                    if let verdicts = round.verdicts {
                        Text(L10n.reviewVerdictSummary(verdicts.count,
                                                       verdicts.filter { !$0.supported }.count))
                            .font(.caption)
                            .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    }
                    if !round.retrievedQueries.isEmpty {
                        Text(L10n.reviewRetrievedQueries(round.retrievedQueries.count,
                                                         round.supplementedBlocks))
                            .font(.caption)
                            .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    }
                    if let note = round.note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    }
                }
            }
            Text(ledgerText)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            // 低3：引用基准如实（脚注按确认草稿载荷解析）。
            Text(L10n.reviewCitationNote)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            Text(L10n.reviewFinalDraftLabel).font(DS.Font.displaySection)
            Text(outcome.finalDraft)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: DS.Spacing.sm) {
                Button(L10n.reviewAdopt) { onAdopt() }
                    .buttonStyle(.borderedProminent)
                    .tint(DS.Color.ink(theme, scheme))
                Button(L10n.reviewDiscard) { onDiscard() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(DS.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.paper(theme, scheme),
                    in: RoundedRectangle(cornerRadius: DS.Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.medium)
            .stroke(DS.Color.stroke(theme, scheme), lineWidth: 1))
        .dsAppear()
    }
}
