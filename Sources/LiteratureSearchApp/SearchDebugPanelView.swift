import SwiftUI
import LiteratureCore
import LiteratureSearchUI

// MARK: - 检索调试面板（诊断面；无任何改索引/改配置的写动作）
struct SearchDebugPanelView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue

    private var theme: DS.Theme { .storage(dsTheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                diagnosticsSection
                renderParamsSection
            }
            .padding(DS.Spacing.md)
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(DS.Color.desk(theme, scheme))
    }

    // MARK: 渲染参数当前生效值（只读；面板无写动作纪律不破）

    @ViewBuilder
    private var renderParamsSection: some View {
        let theme = DS.Theme.storage(dsTheme)
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(L10n.debugRenderSection).font(.headline)
            let countLimit = ThumbnailRenderParams.cacheCountLimit
            keyValue(L10n.debugRenderCacheCount,
                     countLimit == 0 ? L10n.debugRenderUnlimitedDefault : "\(countLimit)")
            let costMB = ThumbnailRenderParams.cacheCostLimitMB
            keyValue(L10n.debugRenderCacheBytes,
                     costMB == 0 ? L10n.debugRenderUnlimitedDefault : "\(costMB) MB")
            let radius = ThumbnailRenderParams.prefetchRadius
            keyValue(L10n.debugRenderPrefetch,
                     radius == 0 ? L10n.debugRenderOffDefault : L10n.debugRenderPages(radius))
            keyValue(L10n.debugRenderPixel,
                     ThumbnailRenderParams.pixelTier == 1
                         ? L10n.debugRenderPixelHigh
                         : L10n.debugRenderPixelStandard)
            // 缩略图内存占用（估算基准，如实标注）：单页 RGBA 估算 × 上限档。
            let perThumb = ThumbnailRenderParams.perThumbnailBytes
            keyValue(L10n.debugRenderThumbBytes,
                     L10n.debugRenderBytesKB(perThumb / 1024))
            keyValue(L10n.debugRenderCapEstimate,
                     countLimit == 0
                         ? L10n.debugRenderCapNone
                         : L10n.debugRenderBytesMB(perThumb * countLimit / 1_048_576))
            keyValue(L10n.debugHabitLearning,
                     SearchMemoryStore.habitLearningEnabled ? L10n.debugPanelYes : L10n.debugPanelNo)
                        keyValue(L10n.debugRenderEngine,
                     SearchEngineRegistry.engineName(for:
                        UserDefaults.standard.string(forKey: SearchEngineRegistry.preferenceKey)))
        }
        .padding(DS.Spacing.sm)
        .background(DS.Color.paper(theme, scheme), in: RoundedRectangle(cornerRadius: DS.Radius.small))
    }

    // MARK: 最近一次查询分相

    @ViewBuilder
    private var diagnosticsSection: some View {
        let theme = DS.Theme.storage(dsTheme)
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(L10n.debugPanelLastQuery).font(.headline)
            if let diag = state.lastSearchDiagnostics {
                keyValue(L10n.debugPanelQuery, diag.normalizedQuery.isEmpty ? "—" : diag.normalizedQuery)
                if !diag.syntaxSummary.isEmpty {
                    keyValue(L10n.debugPanelAST, diag.syntaxSummary)
                }
                keyValue(L10n.debugPanelTermCandidates,
                         diag.termCandidates.isEmpty ? "—"
                             : diag.termCandidates.sorted { $0.key < $1.key }
                                 .map { "\($0.key)=\($0.value)" }.joined(separator: " · "))
                keyValue(L10n.debugPanelIntersection, "\(diag.intersectionCount)")
                keyValue(L10n.debugPanelPagesLoaded, "\(diag.pagesLoaded)")
                keyValue(L10n.debugPanelTotal, "\(diag.totalPageMatches)")
                keyValue(L10n.debugPanelCountCaliber,
                         diag.countCaliber == .wordLevel ? L10n.countCaliberWord : L10n.countCaliberCharacter)
                if !diag.routedTerms.isEmpty {
                    keyValue(L10n.debugPanelRoutedTerms,
                             diag.routedTerms.sorted { $0.key < $1.key }
                                 .map { "\($0.key)→\($0.value)" }.joined(separator: " · "))
                }
                if diag.countCaliber == .wordLevel {
                    Text(L10n.countCaliberWordNote).font(.caption2)
                        .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                }
                keyValue(L10n.debugPanelPhases,
                         String(format: "query=%.1fms · materialize=%.1fms · verify=%.1fms",
                                diag.queryMs, diag.materializeMs, diag.verifyMs))
                keyValue(L10n.debugPanelTruncated, diag.truncated ? L10n.debugPanelYes : L10n.debugPanelNo)
                if diag.regexTimedOut {
                    StatusRow(systemImage: "exclamationmark.triangle.fill",
                              text: L10n.debugPanelRegexTimeout,
                              color: DS.Color.warning(theme, scheme))
                }
                if let syntaxNote = syntaxNote(diag) {
                    Text(syntaxNote).font(.caption2)
                        .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                }
            } else {
                Text(L10n.debugPanelNoQuery).font(.callout)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }
        }
        .padding(DS.Spacing.sm)
        .background(DS.Color.paper(theme, scheme), in: RoundedRectangle(cornerRadius: DS.Radius.small))
    }

    /// 语法查询的如实标注（字段-only 的 0 页命中基准等）。
    /// 判据改 fieldOnlyQuery（diag.terms 是原串分词恒非空，旧判据永假）。
    private func syntaxNote(_ diag: QueryDiagnostics) -> String? {
        guard !diag.syntaxSummary.isEmpty else { return nil }
        if diag.fieldOnlyQuery {
            return L10n.debugPanelFieldOnlyNote
        }
        return nil
    }


    private func keyValue(_ key: String, _ value: String) -> some View {
        let theme = DS.Theme.storage(dsTheme)
        return HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
            Text(key).font(.caption).foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                .frame(width: 110, alignment: .leading)
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
        }
    }
}
