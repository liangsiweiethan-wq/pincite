import SwiftUI
import LiteratureCore
import LiteratureSearchUI

// MARK: - 全库结果 snippet 高亮页（命中页预览）
//
// 入口在全库结果头部「命中页预览」；点击后 AppState 对当前查询跑
// searchDetailed（limit 200＋perBookLimit 4 防高频词刷屏），逐条按需读
// 命中页行全文并经 SnippetHighlighter（纯函数层）组装高亮段，视图只渲染
// 组装结果——渲染层零猜测（paperless highlights 形态）。
// OCR 命中的高亮坐标属其索引页行文本（SearchService.swift:18-20 既有
// 契约）：store.page 读到的 textOriginal 即该来源页文本，坐标天然落在
// 同一文本上，绝不映射到原件。总数与截断如实标注（沿用 truncatedNotice
// 基准）。组装失败（range 越界等）如实降级纯文本，不猜。

struct SnippetHighlightsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue
    @AppStorage("readingSerif") private var readingSerif = true

    private var theme: DS.Theme { .storage(dsTheme) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Spacing.sm) {
                if state.previewLoading {
                    HStack(spacing: DS.Spacing.xs) {
                        ProgressView().controlSize(.small)
                        Text(L10n.previewLoading).font(.caption)
                            .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    }
                }
                if let notice = state.previewTruncatedNotice {
                    StatusRow(systemImage: "exclamationmark.triangle.fill",
                              text: notice, color: DS.Color.warning(theme, scheme))
                }
                ForEach(state.previewRows) { row in
                    previewRow(row)
                }
                if !state.previewLoading && state.previewRows.isEmpty {
                    Text(L10n.previewEmpty).font(.callout)
                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
        }
    }

    /// 单条命中：高亮 snippet ＋ 书目/页码行（行样式照: 435 既有 snippet 行
    private func previewRow(_ row: AppState.PreviewRow) -> some View {
        let theme = DS.Theme.storage(dsTheme)
        return VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            HStack(spacing: DS.Spacing.xs) {
                if row.isOCR {
                    // OCR 来源徽章：中性 ink token（范围裁剪 6「不新增琥珀
                    // 色位点」——琥珀只保留既有四个白名单位，新视图不用）。
                    CapsuleBadge(text: HitRouter.sourceBadgeText("ocr"),
                                 color: DS.Color.inkSecondary(theme, scheme))
                }
                Text("\(row.fileName) · \(L10n.physicalPageShort)\(row.physicalPage)")
                    .font(.caption)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    .lineLimit(1)
                Spacer(minLength: DS.Spacing.xs)
                Text("\(row.matchCount) \(L10n.matchCountSuffix)")
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            }
            Group {
                if let attr = Self.attributedString(from: row.snippet, theme: theme, scheme: scheme) {
                    Text(attr)
                } else {
                    Text(row.snippet.text)   // 降级：纯文本（不高亮不猜）
                }
            }
            .font(readingSerif ? DS.Font.readingSerif() : .callout)
            .lineSpacing(readingSerif ? 6 : 0)
            .textSelection(.enabled)
        }
        .padding(.vertical, DS.Spacing.xs)
        .overlay(alignment: .bottom) { Hairline() }
    }

    /// AttributedString 组装（视图层薄封装；切段逻辑在 SnippetHighlighter
    /// 纯函数层，测试断言固定）。背景色用既有 select token（选中语义同源），
    /// 零 DesignSystem 改动、零新增琥珀位点。
    static func attributedString(from assembled: SnippetHighlighter.HighlightedSnippet,
                                 theme: DS.Theme, scheme: ColorScheme) -> AttributedString? {
        guard assembled.highlighted, !assembled.segments.isEmpty else { return nil }
        var out = AttributedString()
        for seg in assembled.segments {
            var chunk = AttributedString(seg.text)
            if seg.isHighlighted {
                chunk.backgroundColor = DS.Color.select(theme, scheme).opacity(0.30)
            }
            out += chunk
        }
        return out
    }
}
