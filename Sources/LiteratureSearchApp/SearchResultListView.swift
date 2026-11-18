import SwiftUI
import AppKit
import LiteratureCore
import LiteratureSearchUI

/// Two-phase results:  phase one lists EVERY matching work
/// (fast aggregate, sorted by hit count), version-grouped so 异版/年版
/// duplicates of one book appear ONCE; expanding a group loads its COMPLETE
/// hit list on demand (phase two). Each row shows its citation and copies
/// in the selected citation style.
struct SearchResultListView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue
    /// 跳过前置页开关（与 SearchView 开关同一 UserDefaults 键；
    /// 默认关 = 原样显示，过滤零发生）。
    @AppStorage("search.skipFrontMatter") private var skipFrontMatter = false

    /// Per-group expanded version (defaults to the primary). Keyed by group id.
    @State private var selectedVersionIDs: [String: String] = [:]
    /// 命中页预览 sheet。
    @State private var showPreview = false
    /// 期刊等级规则表（用户自备 journal_tiers.json；列表出现时
    /// 装载一次进内存，行级查表零 I/O。无数据 = 全体不显示，如实）。
    @State private var journalTiers = JournalTierStore(directory: AppSupportPaths.appDirectory())

    private var theme: DS.Theme { .storage(dsTheme) }

    /// 锚点行目标（视图层纯判定，零 store 访问）：学习开＋锚点在＋
    /// bookID 在当前 bookResults（主行或异版行）＋页码 ∈ [1, pageCount]。
    /// 任一不满足即隐。
    private var lastSelectionAnchorTarget: SearchService.BookHitSummary? {
        guard SearchMemoryStore.habitLearningEnabled,
              let anchor = state.lastSelectionAnchor else { return nil }
        for group in state.bookResults {
            for summary in [group.primary] + group.others where summary.bookID == anchor.bookID {
                guard anchor.page >= 1, anchor.page <= max(1, summary.pageCount) else { return nil }
                return summary
            }
        }
        return nil
    }

    /// 页级前置页过滤（查询后过滤——匹配语义零接触；关闭态
    /// 原样透传）。返回 (可见命中, 被屏蔽数)。
    func frontMatterFiltered(_ hits: [SearchHit], bookID: String) -> (visible: [SearchHit], blocked: Int) {
        guard skipFrontMatter else { return (hits, 0) }
        let bodyStart = state.frontMatterBodyStart(bookID: bookID)
        let (visible, blocked) = FrontMatterFilter.partition(hits, page: { $0.physicalPage },
                                                             bodyStartPage: bodyStart)
        return (visible, blocked.count)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Spacing.sm) {
                summaryHeader
                    .padding(.bottom, DS.Spacing.sm)
                // 「上次选择」锚点行（结果列表头部独立行——不计结果
                // 数、不参与任何排序；失效即隐，判定纯视图层零 store 访问）。
                if let anchorTarget = lastSelectionAnchorTarget {
                    LastSelectionAnchorRow(anchor: state.lastSelectionAnchor!, summary: anchorTarget) {
                        Task { await state.select(anchor: state.lastSelectionAnchor!) }
                    }
                }
                // 书内/全库两级分区：全库分区在上（现行书目分组），
                // 书内分区在其下（最小面：上下叠放，不做 Tab 切换——实施
                // 报告说明）。无打开书时书内分区隐藏（不显示空壳）。
                if state.bookScopeBookID != nil {
                    bookScopeSection
                }
                ForEach(state.bookResults) { group in
                    let selectedID = selectedVersionIDs[group.id] ?? group.primary.bookID
                    let filtered = frontMatterFiltered(state.bookFullHits[selectedID] ?? [],
                                                       bookID: selectedID)
                    BookResultRow(
                        group: group,
                        selectedVersionID: selectedID,
                        expanded: state.expandedGroupIDs.contains(selectedID),
                        isLoading: state.loadingBookID == selectedID,
                        truncated: state.bookFullTruncated.contains(selectedID),
                        hits: filtered.visible,
                        blockedCount: filtered.blocked,
                        journalTiers: journalTiers,
                        toggle: { toggleGroup(group, selectedID: selectedID) },
                        selectVersion: { bid in selectVersion(group, bookID: bid) })
                }
                if let error = state.searchError {
                    StatusRow(systemImage: "exclamationmark.circle.fill",
                              text: error, color: DS.Color.error(theme, scheme))
                        .padding(.horizontal, DS.Spacing.xs)
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.bottom, DS.Spacing.sm)
        }
        // 命中页预览（sheet）。
        .sheet(isPresented: $showPreview) {
            SnippetHighlightsView()
        }
    }

    /// 书内分区条＋命中行（行样式照: 435 既有 snippet 行）。
    @ViewBuilder
    private var bookScopeSection: some View {
        let theme = DS.Theme.storage(dsTheme)
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "text.book.closed")
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    .accessibilityHidden(true) // 装饰：分区标（纪律）
                Text(L10n.scopeSectionBook)
                    .font(.subheadline)
                Text(L10n.bookScopeCount(state.bookScopeHits.count, state.bookScopeTotal))
                    .font(.caption)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                Spacer(minLength: DS.Spacing.xs)
            }
            if state.bookScopeHits.isEmpty {
                Text(L10n.scopeSectionBookEmpty)
                    .font(.caption)
                    .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            }
            // 书内分区同走前置页过滤；被屏蔽计数与零可见解释联动。
            let scope = frontMatterFiltered(state.bookScopeHits,
                                            bookID: state.bookScopeBookID ?? "")
            if scope.blocked > 0 {
                Text(L10n.frontMatterBlockedCount(scope.blocked))
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            }
            ForEach(Array(scope.visible.enumerated()), id: \.offset) { _, hit in
                HitRow(hit: hit, isSelected: state.selectedHit == hit,
                       citation: CitationFormatter.citation(fileName: hit.fileName, title: hit.title,
                                                            physicalPage: hit.physicalPage,
                                                            style: state.citationStyle,
                                                            printedPage: state.printedPage(
                                                                bookID: hit.bookID,
                                                                physical: hit.physicalPage))) {
                    Task { await state.select(hit: hit) }
                }
            }
        }
        .padding(DS.Spacing.xs)
        .background(DS.Color.paper(theme, scheme), in: RoundedRectangle(cornerRadius: DS.Radius.small))
    }

    private func toggleGroup(_ group: BookVersionGroup, selectedID: String) {
        if state.expandedGroupIDs.contains(selectedID) {
            state.expandedGroupIDs.remove(selectedID)
        } else {
            state.expandedGroupIDs.insert(selectedID)
            if state.bookFullHits[selectedID] == nil {
                state.loadAllHitsForBook(selectedID)
            }
        }
    }

    /// Switching versions inside an expanded group: the selected version
    /// becomes the one whose complete hits are listed.
    private func selectVersion(_ group: BookVersionGroup, bookID: String) {
        let previous = selectedVersionIDs[group.id] ?? group.primary.bookID
        selectedVersionIDs[group.id] = bookID
        if state.expandedGroupIDs.contains(previous) {
            state.expandedGroupIDs.remove(previous)
            state.expandedGroupIDs.insert(bookID)
        }
        if state.bookFullHits[bookID] == nil {
            state.loadAllHitsForBook(bookID)
        }
    }

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(state.query)
                .font(DS.Font.displayGroup)
                .lineLimit(1)
            Text("\(L10n.resultSummaryHits) \(state.totalMatchingPages) \(L10n.pageUnit) · \(state.bookResults.count) \(L10n.booksUnit)（点开书目查看该书全部命中）")
                .font(.subheadline)
                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
                citationStyleMenu
                Button(L10n.copyAllBookCitations) {
                    state.copyBookCitations(state.bookResults.map {
                        ($0.primary.fileName, $0.primary.title, $0.primary.author, $0.primary.language)
                    })
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state.bookResults.isEmpty)
                Button(L10n.copyAllBibtex) {
                    state.copyBooksBibtex(state.bookResults.map {
                        ($0.primary.fileName, $0.primary.title, $0.primary.author, $0.primary.language)
                    })
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state.bookResults.isEmpty)
                Button(L10n.collapseAll) {
                    state.expandedGroupIDs.removeAll()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state.expandedGroupIDs.isEmpty)
                // 命中页预览入口（全库结果头部；形照既有行风格）。
                Button(L10n.previewOpen) {
                    state.loadPreviewHits()
                    showPreview = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state.bookResults.isEmpty)
                .help(L10n.previewOpen)
            }
            Text(L10n.bibliographyStyleNote)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
        }
        .padding(.horizontal, DS.Spacing.xs)
    }

    // MARK: 体例选择（分组菜单）

    /// Grouped style picker, driven by CitationFormatRegistry (sections
    /// 1:1 with descriptor.group).
    private var citationStyleMenu: some View {
        Menu {
            ForEach(citationStyleSections()) { section in
                Section(header: Text(section.name)) {
                    ForEach(section.styles, id: \.self) { style in
                        Button {
                            state.citationStyle = style
                        } label: {
                            HStack {
                                Text(style.displayName)
                                if style == state.citationStyle {
                                    Image(systemName: "checkmark")
                                        .accessibilityHidden(true) // 装饰：选中态由文字述
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            Text("\(L10n.citationStyleLabel)：\(state.citationStyle.displayName)")
                .font(.callout)
        }
        .controlSize(.small)
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private struct StyleSection: Identifiable {
        let id: String
        let name: String
        let styles: [CitationStyle]
    }

    private func citationStyleSections() -> [StyleSection] {
        let names: [CitationFormatGroup: String] = [
            .chinese: L10n.styleGroupChinese,
            .englishIntl: L10n.styleGroupEnglish,
            .other: L10n.styleGroupOther,
        ]
        return CitationFormatGroup.allCases.compactMap { group in
            let styles = CitationFormatRegistry.styles(in: group)
            guard !styles.isEmpty, let name = names[group] else { return nil }
            return StyleSection(id: name, name: name, styles: styles)
        }
    }
}

/// One matching work (version group): primary identity + counts + citation
/// line; a badge expands the inline version list when the library holds
/// 异版/年版 duplicates; expanding the row loads the selected version's
/// complete hit list. Right-click copies the book citation.
private struct BookResultRow: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue
    let group: BookVersionGroup
    let selectedVersionID: String
    let expanded: Bool
    let isLoading: Bool
    let truncated: Bool
    let hits: [SearchHit]
    /// 前置页被屏蔽数（关闭态恒 0）。
    let blockedCount: Int
    /// 期刊等级规则表（列表装载一次，行级内存查表）。
    let journalTiers: JournalTierStore
    let toggle: () -> Void
    let selectVersion: (String) -> Void
    /// Inline version list visibility (per row, independent of hit expansion).
    @State private var versionsShown = false

    private var summary: SearchService.BookHitSummary { group.primary }

    /// 期刊等级徽章匹配标题（title 优先，文件名去扩展名降级处理；
    /// 数据缺/零命中 → nil = 不显示，如实）。
    private var journalTierText: String? {
        let display = summary.title ?? (summary.fileName as NSString).deletingPathExtension
        return journalTiers.lookup(displayTitle: display)?.tier
    }

    /// 阅读进度徽章（position 存在且 pageCount>0 才出；无位置
    /// 记录不出徽章——不出"0%"。两 store 皆内存查表，行级零 I/O）。
    private var readingProgressText: String? {
        guard let position = state.readingPositions.position(for: selectedVersionID),
              summary.pageCount > 0 else { return nil }
        let page = Swift.min(Swift.max(position.page, 1), summary.pageCount)
        let percent = Int((Double(page) / Double(summary.pageCount) * 100).rounded(.down))
        return L10n.readingProgressBadge(page, summary.pageCount, Swift.min(percent, 100))
    }

    /// BookHitSummary carries no source field; the spine/badge fall back to
    /// the loaded full-hit list, defaulting to native before phase two loads.
    private var spineSource: String {
        state.bookFullHits[selectedVersionID]?.first?.source ?? "native"
    }

    var body: some View {
        let theme = DS.Theme.storage(dsTheme)
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            HStack(alignment: .top, spacing: DS.Spacing.xs) {
                Button(action: toggle) {
                    VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                        HStack(spacing: DS.Spacing.xs) {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                                .frame(width: 12)
                                .accessibilityHidden(true) // 装饰：展开态经 accessibilityValue 述
                            Text(summary.title ?? summary.fileName)
                                .font(DS.Font.displayGroup)
                                .lineLimit(1)
                            if let author = summary.author {
                                Text(author).font(.caption)
                                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: DS.Spacing.xs)
                            if isLoading {
                                ProgressView().controlSize(.mini)
                            }
                            let loaded = state.bookFullHits[selectedVersionID]
                            CapsuleBadge(text: {
                                if expanded, let full = loaded, !truncated {
                                    return L10n.hitsBadgeLoaded(actual: full.count,
                                                                candidate: summary.matchingPages,
                                                                total: summary.pageCount)
                                }
                                return L10n.hitsBadgeCollapsed(actual: summary.matchingPages,
                                                               total: summary.pageCount)
                            }(), color: DS.Color.inkSecondary(theme, scheme))
                        }
                        CapsuleBadge(text: HitRouter.sourceBadgeText(spineSource),
                                     color: spineSource == "ocr" ? DS.Color.ocr(theme, scheme)
                                                                 : DS.Color.ink(theme, scheme))
                        // 内联徽章组（期刊等级＝用户自备数据，
                        // 阅读进度＝位置记录存在才出；数据缺各自的如实不显示）。
                        if journalTierText != nil || readingProgressText != nil {
                            HStack(spacing: DS.Spacing.xs) {
                                if let tier = journalTierText {
                                    CapsuleBadge(text: tier,
                                                 color: DS.Color.inkSecondary(theme, scheme))
                                }
                                if let progress = readingProgressText {
                                    CapsuleBadge(text: progress,
                                                 color: DS.Color.inkSecondary(theme, scheme))
                                }
                            }
                        }
                        CitationLine(text: CitationFormatter.bookCitation(fileName: summary.fileName,
                                                                          title: summary.title))
                        if !group.others.isEmpty {
                            versionBadge(theme: theme)
                        }
                    }
                    .padding(DS.Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 展开按钮的展开/收起状态对 VoiceOver 可闻。
                .accessibilityValue(expanded ? L10n.groupExpandedState : L10n.groupCollapsedState)
                // 与展开 Button 平级的外置 ⓘ（消嵌套可点区）：书目详情入口。
                Button {
                    state.openBookDetail(bookID: summary.bookID)
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                }
                .buttonStyle(.borderless)
                .help(L10n.bookDetailTitle)
                .accessibilityLabel(L10n.bookDetailInfoHint)
                .padding(.top, DS.Spacing.xs)
            }
            .bookSpine(source: spineSource)
            .contextMenu {
                Button(L10n.copyBookCitationCurrent) {
                    state.copyString(CitationFormatter.bookCitation(fileName: summary.fileName,
                                                                    title: summary.title))
                }
                Button(L10n.copyBibtex) {
                    state.copyString(CitationFormatter.bibtex(fileName: summary.fileName,
                                                              title: summary.title,
                                                              author: summary.author,
                                                              language: summary.language))
                }
                Divider()
                Button(L10n.bookDetailOpen) {
                    state.openBookDetail(bookID: summary.bookID)
                }
                Divider()
                Button(L10n.favoriteBook) {
                    state.favoriteBook(bookID: summary.bookID, fileName: summary.fileName,
                                       title: summary.title)
                }
            }
            if versionsShown && !group.others.isEmpty {
                versionList(theme: theme)
            }
            if expanded {
                if truncated {
                    StatusRow(systemImage: "exclamationmark.triangle.fill",
                              text: L10n.bookHitsTruncated(state.bookHitsLimit),
                              color: DS.Color.warning(theme, scheme))
                        .padding(.leading, DS.Spacing.lg)
                }
                // 被屏蔽计数单独显示；零可见时解释文案联动。
                if blockedCount > 0 {
                    VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                        Text(L10n.frontMatterBlockedCount(blockedCount))
                            .font(.caption2)
                            .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                        if hits.isEmpty {
                            Text(L10n.frontMatterZeroHitHint(blockedCount))
                                .font(.caption2)
                                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                        }
                    }
                    .padding(.leading, DS.Spacing.lg)
                }
                if !hits.isEmpty {
                    Button(L10n.copyBookHitsCitationsLoaded(hits.count)) {
                        let text = hits.map {
                            CitationFormatter.citation(fileName: $0.fileName, title: $0.title,
                                                       physicalPage: $0.physicalPage,
                                                       style: state.citationStyle,
                                                       printedPage: state.printedPage(
                                                            bookID: $0.bookID,
                                                            physical: $0.physicalPage))
                        }.joined(separator: "\n")
                        state.copyString(text)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.leading, DS.Spacing.lg)
                }
                ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                    HitRow(hit: hit, isSelected: state.selectedHit == hit,
                           // 异版聚合组内命中行：引注取本版自己的映射
                           // 经统一服务（不跨版换算；聚合键与计数零改动）。
                           citation: CitationFormatter.citation(fileName: hit.fileName, title: hit.title,
                                                                physicalPage: hit.physicalPage,
                                                                style: state.citationStyle,
                                                                printedPage: state.printedPage(
                                                                    bookID: hit.bookID,
                                                                        physical: hit.physicalPage))) {
                        Task { await state.select(hit: hit) }
                    }
                    .padding(.leading, DS.Spacing.lg)
                }
            }
        }
    }

    private func versionBadge(theme: DS.Theme) -> some View {
        Button {
            // 动效门：展开列表随选中态 crossfade 落位，Reduce Motion
            // 下直接切换（无动画）。
            withAnimation(reduceMotion ? nil : .easeInOut(duration: DS.Motion.hoverDuration)) {
                versionsShown.toggle()
            }
        } label: {
            CapsuleBadge(text: L10n.otherVersions(group.others.count),
                         color: DS.Color.inkTertiary(theme, scheme))
        }
        .buttonStyle(.plain)
        .help(L10n.chooseVersionTitle)
        .accessibilityLabel(L10n.chooseVersionTitle)
    }

    /// Inline pick list: one row per OTHER version (the primary is already
    /// the row's head); each shows its clean name + own hit count + page
    /// count, and selecting it loads THAT version's hits.
    private func versionList(theme: DS.Theme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.chooseVersionTitle)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                .padding(.leading, DS.Spacing.lg)
            let all = [group.primary] + group.others
            ForEach(all, id: \.bookID) { version in
                Button {
                    if version.bookID != selectedVersionID {
                        selectVersion(version.bookID)
                    }
                } label: {
                    HStack(spacing: DS.Spacing.xs) {
                        Image(systemName: version.bookID == selectedVersionID ? "checkmark.circle.fill" : "circle")
                            .font(.caption2)
                            .foregroundStyle(version.bookID == selectedVersionID
                                             ? DS.Color.ink(theme, scheme)
                                             : DS.Color.inkTertiary(theme, scheme))
                            .accessibilityHidden(true) // 装饰：选中态经 accessibilityValue 述
                        Text(CitationFormatter.cleanFileName(version.fileName))
                            .font(.callout)
                            .lineLimit(1)
                        Spacer(minLength: DS.Spacing.xs)
                        CapsuleBadge(text: L10n.hitsBadgeCollapsed(actual: version.matchingPages,
                                                                   total: version.pageCount),
                                     color: DS.Color.inkSecondary(theme, scheme))
                        // 对照工作台入口（主＝组当前选中版本、对照＝
                        // 该行版本；同一 bookID 自对照在 AppState 内拒绝并提示，
                        // 不建窗）。
                        Button(L10n.workbenchButton) {
                            Task { await state.openWorkbench(primaryBookID: selectedVersionID,
                                                secondaryBookID: version.bookID) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(L10n.workbenchCompareHint)
                        .accessibilityLabel(L10n.workbenchCompareHint)
                    }
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.vertical, DS.Spacing.xxs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 版本选中状态对 VoiceOver 可闻。
                .accessibilityValue(version.bookID == selectedVersionID
                                    ? L10n.versionSelectedState : L10n.versionUnselectedState)
            }
        }
    }
}

private struct HitRow: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme
    /// 增强对比度级别（代表面接入；全量接入列后续批）。
    @Environment(\.dsContrastLevel) private var contrastLevel
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue
    @AppStorage("readingSerif") private var readingSerif = true
    let hit: SearchHit
    let isSelected: Bool
    let select: () -> Void
    /// 上下文展开态（行内；只影响本行）。
    @State private var contextShown = false
    /// 提速：引注文本由调用方算好传入（init 物化）——此前是计算属性，
    /// LazyVStack 每次行重建（滚动/选中态变化）都重跑 BookCitationMeta.parse
    private let citation: String

    init(hit: SearchHit, isSelected: Bool, citation: String, select: @escaping () -> Void) {
        self.hit = hit
        self.isSelected = isSelected
        self.citation = citation
        self.select = select
    }

    var body: some View {
        let theme = DS.Theme.storage(dsTheme)
        Button(action: select) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                HStack(spacing: DS.Spacing.xs) {
                    if hit.source == "ocr" {
                        CapsuleBadge(text: HitRouter.sourceBadgeText(hit.source),
                                     color: DS.Color.ocr(theme, scheme))
                    }
                    // 三轨文本的印刷页经统一取页
                    // 服务（page_map > pages 列），不再走单参重载直读 pages 列。
                    Text(HitRouter.threeTrackPageText(
                        for: hit,
                        printed: state.printedPage(bookID: hit.bookID,
                                                   physical: hit.physicalPage)))
                        .font(.caption)
                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme, contrastLevel))
                        .monospacedDigit()
                        .lineLimit(1)
                    Spacer(minLength: DS.Spacing.xs)
                    CapsuleBadge(text: "\(L10n.resultSummaryHits) \(hit.matches.count) \(L10n.matchCountSuffix)",
                                 color: DS.Color.inkSecondary(theme, scheme))
                        .monospacedDigit()
                }
                Text(hit.snippet)
                    .font(readingSerif ? DS.Font.readingSerif() : .callout)
                    .lineSpacing(readingSerif ? 6 : 0)
                    .tracking(readingSerif ? 0.2 : 0)
                    .lineLimit(2)
                CitationLine(text: citation)
                // 上下文展开区（命中句→页/节上下文；sioyek 动线
                // 形态启发，零代码采用）。auto_toc 缺失如实「无目录」。
                if contextShown {
                    contextExpansionBlock(theme: theme)
                }
            }
            // 扫读降噪：默认态去卡片化——无纸底无描边，行间 hairline 分隔
            // + 行高放宽；选中态保留 select 1px 描边 + 左 2pt 条双编码。
            .padding(.vertical, DS.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Hairline()
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: DS.Radius.small)
                        .stroke(DS.Color.select(theme, scheme), lineWidth: 1)
                }
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: DS.Radius.small)
                        .fill(DS.Color.select(theme, scheme))
                        .mask(Rectangle().frame(width: 2))
                }
            }
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: DS.Motion.hoverDuration), value: isSelected)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(L10n.copyCitationFaxue) {
                copy(CitationFormatter.citation(fileName: hit.fileName, title: hit.title,
                                                physicalPage: hit.physicalPage,
                                                style: .faxueYinzhuShouce,
                                                printedPage: state.printedPage(
                                                    bookID: hit.bookID,
                                                    physical: hit.physicalPage)))
            }
            Button(L10n.copyCitationZGF) {
                copy(CitationFormatter.citation(fileName: hit.fileName, title: hit.title,
                                                physicalPage: hit.physicalPage,
                                                style: .zhongguoFaxue,
                                                printedPage: state.printedPage(
                                                    bookID: hit.bookID,
                                                    physical: hit.physicalPage)))
            }
            Divider()
            Button(L10n.addToSynthesis) {
                state.compareSelectionIDs.insert(AppState.key(for: hit))
            }
            Divider()
            Button(L10n.contextToggle) {
                contextShown.toggle()
                if contextShown { state.toggleContext(for: hit) }
            }
            Divider()
            Button(L10n.favoritePage) {
                state.favoritePage(hit)
            }
        }
    }

    /// 上下文展开块：prev/page/next 页文本＋所在节（auto_toc；
    /// 无记录如实「无目录」，nil 不猜）。查询期零写库。
    @ViewBuilder
    private func contextExpansionBlock(theme: DS.Theme) -> some View {
        let key = AppState.key(for: hit)
        let context = state.hitContexts[key]
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            HStack(spacing: DS.Spacing.xs) {
                Text(L10n.contextSectionTitle).font(.caption2)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                if let label = context?.sectionLabel {
                    Text("\(L10n.contextSectionLabel)：\(label)")
                        .font(.caption2)
                        .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                        .lineLimit(1)
                } else if context != nil {
                    Text(L10n.contextNoTOC).font(.caption2)
                        .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                }
                Spacer(minLength: 0)
            }
            if let context {
// 命中词在 prev/page/next 上下文文本中高亮（书页基准）。中页直接用 hit 自带 originalUTF16
                // Range（与命中页文本同源，精确全现）；邻页字面定位并走
                // snippet 同款窗口（命中在窗口中央——全文＋lineLimit(6) 时
                // 高亮落在折叠区不可见，窗口化后基本可见）。
                let terms = hit.matches.map(\.displayTerm)
                let pageRanges = hit.matches.map(\.originalUTF16Range)
                if let prev = context.prevPage {
                    contextPageText(prev.text, label: "\(L10n.contextPrev) · \(prev.pageNumber)",
                                    highlightTerms: terms)
                }
                contextPageText(context.page.text, label: "\(L10n.contextToggle) · \(context.page.pageNumber)",
                                emphasized: true, highlightTerms: terms, exactRanges: pageRanges)
                if let next = context.nextPage {
                    contextPageText(next.text, label: "\(L10n.contextNext) · \(next.pageNumber)",
                                    highlightTerms: terms)
                }
            } else {
                Text(L10n.similarBooksLoading).font(.caption2)
                    .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            }
        }
        .padding(.leading, DS.Spacing.xs)
    }

    private func contextPageText(_ text: String, label: String, emphasized: Bool = false,
                                 highlightTerms: [String] = [],
                                 exactRanges: [Range<Int>]? = nil) -> some View {
        let theme = DS.Theme.storage(dsTheme)
        return VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).monospacedDigit()
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            Group {
                if highlightTerms.isEmpty && exactRanges == nil {
                    Text(text)
                } else {
                    let ranges: [Range<Int>] = exactRanges ?? highlightTerms.compactMap { term in
                        let ns = (text as NSString).range(of: term)
                        guard ns.location != NSNotFound, ns.length > 0 else { return nil }
                        return ns.location..<(ns.location + ns.length)
                    }
                    if ranges.isEmpty {
                        Text(text)
                    } else if let attr = SnippetHighlightsView.attributedString(
                        from: SnippetHighlighter.assemble(fullText: text, ranges: ranges),
                        theme: theme, scheme: scheme) {
                        Text(attr)
                    } else {
                        Text(text)
                    }
                }
            }
            .font(.caption)
            .lineSpacing(2)
            .lineLimit(6)
            .foregroundStyle(emphasized ? DS.Color.ink(theme, scheme)
                                        : DS.Color.inkSecondary(theme, scheme))
            .textSelection(.enabled)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// 「上次选择」锚点行——结果列表
/// 头部独立分组样式的单行，**不计结果数、不参与任何排序**（检索比较器零
/// 触碰，输出零漂移）；点击经 AppState.select(anchor:) 合成 hit 走既有
/// select/openGuard 管线（双指纹守卫自动生效）。
struct LastSelectionAnchorRow: View {
    let anchor: SearchSelectionAnchor
    let summary: SearchService.BookHitSummary
    let onJump: () -> Void
    @Environment(\.colorScheme) private var scheme
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue

    var body: some View {
        let theme = DS.Theme.storage(dsTheme)
        Button(action: onJump) {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    .accessibilityHidden(true) // 装饰：锚点行图标（纪律）
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.anchorRowTitle)
                        .font(.caption)
                        .foregroundStyle(DS.Color.ink(theme, scheme))
                    Text("\(summary.title ?? summary.fileName) · P\(anchor.page)")
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                }
                Spacer(minLength: 0)
                Text(L10n.anchorRowJump)
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }
            .padding(.horizontal, DS.Spacing.xs)
            .padding(.vertical, DS.Spacing.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(DS.Color.paper(theme, scheme),
                    in: RoundedRectangle(cornerRadius: DS.Radius.small))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.small)
            .stroke(DS.Color.stroke(theme, scheme), lineWidth: 1))
        .accessibilityLabel(L10n.anchorRowA11y(summary.title ?? summary.fileName, anchor.page))
        .accessibilityHint(L10n.anchorRowHint)
        .help(L10n.anchorRowHelp)
    }
}
