import SwiftUI
import AppKit
import LiteratureCore
import LiteratureSearchUI

/// AI toolbar + inline preview/compare area for the selected hit. Every guard,
struct AIPreviewPanel: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dsTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let hit: SearchHit
    /// 「存为批注」回调（DetailChromeView 注入）——回答文本入参，
    /// 返回结果文案（成功/失败均明确提示）。nil = 不渲染按钮（闭包未接线）。
    var onSaveAsAnnotation: ((String) -> String)?

    /// 存为批注的结果提示（answerCard 内联展示，自动消隐）。
    @State private var saveNotice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            toolbar
            // 预览卡/答案/回执主体内部滚动，长答案不再
            // 下推详情栏其余区块；工具行不滚动。守卫文案与确认门逐字不动。
            ScrollView {
                panelContent
            }
            inputRow
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.top, DS.Spacing.xs)
    }

    @ViewBuilder
    private var panelContent: some View {
        // 本面板只在 state.aiConfigured 时由 DetailChromeView 渲染
        // （未配置时详情栏 AI 块整块隐藏），此处不再重复未配置分支。
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            if state.aiTranscript.isEmpty && state.aiPreview == nil && state.compareQueue.isEmpty {
                Text(state.aiMessage).font(.caption).foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }
            // 对话流：已确认的问答成对成泡（用户右/AI 左）；引用脚注只
            // 来自该次发送的 selections / 已接受引用决定（见 AppState 派生）。
            ForEach(state.aiTranscript) { turn in
                chatBubble(turn)
            }
            if let preview = state.aiPreview {
                previewCard(preview) { Task { await state.sendAIConfirmed() } } cancel: { state.cancelAIPreview() }
            }
            ForEach(state.compareQueue) { preview in
                previewCard(preview) { Task { await state.sendComparePreview(preview) } } cancel: {
                    state.compareQueue.removeAll { $0.id == preview.id }
                }
            }
            if let answer = state.aiAnswer {
                answerCard(answer)
            }
            // 结果卡（评分卡／速读卡／报告卡）。
            if let outcome = state.rcsOutcome {
                RCSScorecardView(outcome: outcome, ledgerText: state.rcsLedger.summaryText)
            }
            if let card = state.speedReadCard {
                SpeedReadCardView(
                    card: card,
                    anchorText: { speedReadAnchorText($0) },
                    budgetNote: state.speedReadDroppedChars > 0
                        ? L10n.speedReadBudgetDropped(state.speedReadDroppedChars) : nil)
            }
            if let outcome = state.reviewOutcome {
                ReviewSelfCheckReportView(outcome: outcome,
                                          ledgerText: state.reviewLedger.summaryText,
                                          onAdopt: { state.adoptReviewOutcome() },
                                          onDiscard: { state.discardReviewOutcome() })
            }
            ForEach(Array(state.aiDecisions.enumerated()), id: \.offset) { _, decision in
                decisionLine(decision)
            }
            if !state.compareResults.isEmpty {
                Text(L10n.compareSectionTitle).font(DS.Font.displaySection)
                ForEach(state.compareResults) { result in
                    VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                        Text(HitRouter.previewProvenanceText(result.preview.selection))
                            .font(.caption)
                            .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                        Text(result.answer).font(.callout)
                        ForEach(Array(result.decisions.enumerated()), id: \.offset) { _, decision in
                            decisionLine(decision)
                        }
                    }
                    .padding(DS.Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Color.paper(theme, scheme),
                                in: RoundedRectangle(cornerRadius: DS.Radius.medium))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.medium)
                        .stroke(DS.Color.stroke(theme, scheme), lineWidth: 1))
                }
            }
        }
    }

    /// 进行中的答案卡（发送完成前内联显示；完成后同一内容已成泡进对话
    @ViewBuilder
    private func answerCard(_ answer: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            HStack(spacing: DS.Spacing.xs) {
                Spacer()
                if let onSaveAsAnnotation {
                    Button {
                        presentSaveNotice(onSaveAsAnnotation(answer))
                    } label: {
                        Image(systemName: "note.text.badge.plus")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .help(L10n.annotationSaveAIAnswer)
                    .accessibilityLabel(L10n.annotationSaveAIAnswer)
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(answer, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .accessibilityLabel(L10n.copyAnswer)
            }
            Text(answer)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let saveNotice {
                Text(saveNotice)
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
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

    /// 存为批注回执消隐（与列表 flash 同款节奏）。
    private func presentSaveNotice(_ text: String) {
        saveNotice = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if saveNotice == text { saveNotice = nil }
        }
    }

    /// 速读卡页码锚点显示（bookId→书目名；页码标签走
    /// PageNumberService 声明制，未知显式「页码未知」，绝不猜）。
    private func speedReadAnchorText(_ anchor: SpeedReadAnchor) -> String {
        let name = state.bookNames[anchor.bookID] ?? anchor.bookID
        if let label = state.rcsPageLabelText(bookID: anchor.bookID, physicalPage: anchor.page) {
            return "\(name) \(label)"
        }
        return "\(name) \(L10n.pageUnknownLabel)"
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            HStack(spacing: DS.Spacing.xxs) {
                Button(L10n.quickTranslateZH) { state.aiQuestion = L10n.quickTranslateZH; state.aiActivePurpose = .translate }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(L10n.quickTranslateZH)
                Button(L10n.quickTranslateEN) { state.aiQuestion = L10n.quickTranslateEN }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(L10n.quickTranslateEN)
                Button(L10n.quickSummarize) { state.aiQuestion = L10n.quickSummarize; state.aiActivePurpose = .summarize }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(L10n.quickSummarize)
                Button(L10n.quickExplain) { state.aiQuestion = L10n.quickExplain; state.aiActivePurpose = .explain }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(L10n.quickExplain)
                Spacer()
            }
            HStack(spacing: DS.Spacing.xs) {
                Button(L10n.askAI) { Task { await state.makeAIPreview(for: hit) } }
                    .buttonStyle(.borderedProminent)
                    .tint(DS.Color.ink(theme, scheme))
                    .disabled(!state.aiConfigured)
                Button("\(L10n.addToCompare) (\(state.compareSelectionIDs.count))") {
                    let key = AppState.key(for: hit)
                    if state.compareSelectionIDs.contains(key) {
                        state.compareSelectionIDs.remove(key)
                    } else {
                        state.compareSelectionIDs.insert(key)
                    }
                }
                .buttonStyle(.bordered)
                Button("\(L10n.synthesisButton) (\(state.compareSelectionIDs.count))") { Task { await state.buildSynthesisPreview() } }
                    .buttonStyle(.bordered)
                    .disabled(!state.aiConfigured || state.compareSelectionIDs.count < 2)
                    .help(L10n.synthesisNeedsTwo)
                // 入口：逐块评分／四段速读／综述（选中证据块 ≥1；
                // 各自预览计划披露后仍走既有确认门，零自动发送）。
                Button("\(L10n.rcsButton) (\(state.compareSelectionIDs.count))") { Task { await state.buildRCSPreview() } }
                    .buttonStyle(.bordered)
                    .disabled(!state.aiConfigured || state.compareSelectionIDs.isEmpty)
                    .accessibilityLabel(L10n.rcsButton)
                Button("\(L10n.speedReadButton) (\(state.compareSelectionIDs.count))") {
                    state.aiActivePurpose = .speedRead
                    Task { await state.buildSpeedReadPreview() }
                }
                    .buttonStyle(.bordered)
                    .disabled(!state.aiConfigured || state.compareSelectionIDs.isEmpty)
                    .accessibilityLabel(L10n.speedReadButton)
                Button("\(L10n.reviewButton) (\(state.compareSelectionIDs.count))") { Task { await state.buildReviewPreview() } }
                    .buttonStyle(.bordered)
                    .disabled(!state.aiConfigured || state.compareSelectionIDs.isEmpty)
                    .accessibilityLabel(L10n.reviewButton)
                Spacer()
            }
        }
    }

    /// 底部输入行：问题输入 + 清空对话（transcript 仅内存，清空只影响
    /// 本会话展示）。零请求说明从工具行移到此处置顶可见，文案逐字不动。
    /// 新增「停止」按钮——生成中（aiSending）可取消进行中的
    /// AI 请求；取消后状态干净（可重新发送），见 AppState.cancelAISend。
    private var inputRow: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            HStack(spacing: DS.Spacing.xs) {
                TextField(L10n.aiQuestionPlaceholder, text: $state.aiQuestion)
                    .textFieldStyle(.dsTextField)
                    .font(.caption)
                Button(L10n.aiStopGenerating) { state.cancelAISend() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!state.aiSending)
                    .accessibilityLabel(L10n.aiStopGenerating)
                Button(L10n.aiClearChat) { state.clearAIChat() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(state.aiTranscript.isEmpty)
                    .accessibilityLabel(L10n.aiClearChat)
            }
            if state.aiSending {
                Text(L10n.aiStopGenerating + "…")
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }
            Text(L10n.zeroRequestsNote).font(.caption2).foregroundStyle(DS.Color.inkSecondary(theme, scheme))
        }
    }

    // MARK: conversation bubbles

    /// 对话泡：用户右对齐墨色实底白字；AI 左对齐纸卡 + Markdown 渲染 +
    /// mini 复制按钮 + 引用脚注（不加任何新的琥珀强调色调用点）。
    @ViewBuilder
    private func chatBubble(_ turn: AppState.AIChatTurn) -> some View {
        switch turn.role {
        case .user:
            HStack(spacing: 0) {
                Spacer(minLength: DS.Spacing.lg)
                Text(turn.text)
                    .font(.callout)
                    .foregroundStyle(DS.Color.paper(theme, scheme))
                    .padding(DS.Spacing.sm)
                    .background(DS.Color.ink(theme, scheme),
                                in: RoundedRectangle(cornerRadius: DS.Radius.medium))
                    .accessibilityLabel(L10n.aiChatUserBubble)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                HStack(spacing: DS.Spacing.xs) {
                    Text(L10n.aiChatAssistantBubble)
                        .font(.caption)
                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(turn.text, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .accessibilityLabel(L10n.copyAnswer)
                }
                Text(markdownAttributed(turn.text))
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                citationFooter(turn.citations)
            }
            .padding(DS.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Color.paper(theme, scheme),
                        in: RoundedRectangle(cornerRadius: DS.Radius.medium))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.medium)
                .stroke(DS.Color.stroke(theme, scheme), lineWidth: 1))
        }
    }

    @ViewBuilder
    private func citationFooter(_ citations: [AppState.AICitation]) -> some View {
        if citations.isEmpty {
            Text(L10n.aiCitationNone)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
        } else {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                ForEach(Array(citations.enumerated()), id: \.offset) { _, citation in
                    let valid = state.isCitationValid(citation)
                    if valid {
                        Text(L10n.aiCitationLine(citation.fileName, citation.page))
                            .font(.caption2)
                            .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    } else {
                        Text(L10n.aiCitationLine(citation.fileName, citation.page) + L10n.aiCitationStaleSuffix)
                            .font(.caption2)
                            .foregroundStyle(DS.Color.error(theme, scheme))
                    }
                }
            }
        }
    }

    /// 系统 Markdown 渲染（macOS 12+；零外部依赖），解析失败回退纯文本。
    private func markdownAttributed(_ text: String) -> AttributedString {
        if let rendered = try? AttributedString(markdown: text) {
            return rendered
        }
        return AttributedString(text)
    }

    /// The confirmation-gate card: OCR-amber tint signals "this is what will
    /// be sent". All provenance fields stay fully visible; the confirm button
    /// stays borderedProminent.
    ///
    /// 过程折叠：多证据综合（synthesisPassageLimit=16）的证据列表
    /// 改为 DisclosureGroup 折叠展示，默认收起（摘要行给条数），展开后逐条
    /// 来源页码与片段完整可见——确认门语义不变：发送的仍是全部 selection，
    /// 折叠只是视觉收纳。流式（SSE）预留：生成过程分段展示时，此折叠模式
    /// 即未来"已生成段/待生成段"的容器，届时在 answerCard 侧复用同一交互。
    @State private var evidenceExpanded = false

    private func previewCard(_ preview: AIPreview,
                             send: @escaping () -> Void,
                             cancel: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack {
                Text(L10n.aiPreviewTitle).font(DS.Font.displayGroup)
                Spacer()
                Image(systemName: "paperplane")
                    .font(.caption)
                    .foregroundStyle(DS.Color.ocr(theme, scheme))
                    .accessibilityHidden(true) // 装饰：标题旁的发送信号图形
            }
            Text("服务: \(preview.serviceHost)   模型: \(preview.model)")
                .font(.caption)
                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            // 端上档预览目标显示（数据不出本机＋性能预期）。
            // 低1：判别改用结构化 preview.onDevice（串比对脆弱）。
            if preview.onDevice {
                Text(L10n.aiOnDevicePrivacyNote)
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                Text(L10n.aiOnDevicePerfNote)
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }
            if let planSummary = preview.planSummary {
                DisclosureGroup {
                    Text(planSummary)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                } label: {
                    Text(L10n.rcsPlanDisclosureTitle)
                        .font(.caption)
                }
            }
            if preview.selections.count > 1 {
                // 多证据综合：默认收起（PaperQA2 式溯源展开可见）。
                DisclosureGroup(isExpanded: $evidenceExpanded) {
                    ForEach(Array(preview.selections.enumerated()), id: \.offset) { idx, sel in
                        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                            Text("[\(idx + 1)] \(HitRouter.previewProvenanceText(sel))")
                                .font(.caption)
                                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                            Text(sel.snippet)
                                .font(.caption)
                                .lineLimit(2)
                                .padding(DS.Spacing.xxs)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(DS.Color.desk(theme, scheme),
                                            in: RoundedRectangle(cornerRadius: DS.Radius.small))
                        }
                    }
                } label: {
                    Text(evidenceExpanded
                         ? L10n.synthesisEvidenceExpanded
                         : L10n.synthesisEvidenceCollapsed(preview.selections.count))
                        .font(.subheadline)
                }
            } else {
                Text(HitRouter.previewProvenanceText(preview.selection))
                    .font(.caption)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                Text(preview.selection.snippet)
                    .font(.callout)
                    .padding(DS.Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Color.desk(theme, scheme),
                                in: RoundedRectangle(cornerRadius: DS.Radius.small))
            }
            HStack(spacing: DS.Spacing.sm) {
                Button(L10n.aiConfirmSend) { send() }
                    .buttonStyle(.borderedProminent)
                    .tint(DS.Color.ink(theme, scheme))
                Button(L10n.aiCancelSend) { cancel() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(DS.Spacing.sm)
        .background(DS.Color.paper(theme, scheme),
                    in: RoundedRectangle(cornerRadius: DS.Radius.large))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.large)
            .stroke(DS.Color.ocr(theme, scheme), lineWidth: 1))
        .dsAppear()
    }

    private func decisionLine(_ decision: ReferenceDecision) -> some View {
        switch decision {
        case .accepted(let bookID, let page):
            return HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DS.Color.success(theme, scheme))
                Text("引用已接受: \(bookID) 物理页 \(page)")
                    .font(.caption)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }
        case .rejected(let bookID, let page, let reason):
            return HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(DS.Color.error(theme, scheme))
                Text("引用已拒绝: \(bookID) 页 \(page) — \(reason)")
                    .font(.caption)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }
        }
    }
}
