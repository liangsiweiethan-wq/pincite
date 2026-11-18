import SwiftUI
import LiteratureCore
import LiteratureSearchUI

/// Search-first content page: fixed search bar + filters + status bars +
/// summary header, then either the onboarding empty states, the zero-hit
/// explanation, or the grouped result list. Search bar never scrolls out of view.
struct SearchView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue
    /// 跳过前置页开关（记忆偏好；默认关 = 行为与现状逐字节一致）。
    @AppStorage("search.skipFrontMatter") private var skipFrontMatter = false
    @FocusState private var searchFieldFocused: Bool

    private var theme: DS.Theme { .storage(dsTheme) }

    // 输入候选/历史补全条（纯增量 UI；提交语义零改写——候选选中
    // 才把候选文本写入输入框，检索入口 state.search 原样）。候选合成走
    // SearchCompletionSource 纯函数（频次 desc → at desc → query asc 全序）；
    // 习惯学习关闭时整层不出现。
    @State private var completions: [SearchCompletionCandidate] = []
    @State private var completionIndex: Int?
    @State private var acceptedCompletionQuery: String?
    @State private var completionKeyMonitor: Any?

    /// 补全条可见性：学习开＋候选非空（无历史/无前缀时零渲染）。
    private var showsCompletions: Bool {
        SearchMemoryStore.habitLearningEnabled && !completions.isEmpty
    }

    var body: some View {
        // 呼吸感：区块间距 16 → 24（行内密度不动）。
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            searchField
                .padding(.horizontal, DS.Spacing.md)
                .padding(.top, DS.Spacing.md)
            if showsCompletions {
                completionStrip
                    .padding(.horizontal, DS.Spacing.md)
            }
            // 语法帮助一行（常显 caption2；分派基准如实写明）。
            Text(L10n.syntaxHelp)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                .padding(.horizontal, DS.Spacing.md)
            filterBar
                .padding(.horizontal, DS.Spacing.md)

            statusBar
                .padding(.horizontal, DS.Spacing.md)

            if libraryNotBuilt {
                ScrollView {
                    if state.indexError != nil, state.rootName != nil {
                        // Root chosen but indexing failed: recovery guidance
                        // replaces the 3-step onboarding (错误恢复).
                        IndexErrorRecoveryView()
                            .padding(.horizontal, DS.Spacing.md)
                    } else {
                        OnboardingStepsView()
                            .padding(.horizontal, DS.Spacing.md)
                    }
                }
            } else if state.searchedOnce, state.bookResults.isEmpty,
                      state.zeroHitExplanation != nil, state.searchError == nil {
                ScrollView {
                    ZeroHitView()
                        .padding(.horizontal, DS.Spacing.md)
                }
            } else if !state.searchedOnce {
                emptyStateB
            } else {
                SearchResultListView()
            }
        }
        // ⌘F lands here (delayed a beat — focus may not take effect while the
        // scene/window is still settling).
        .onChange(of: state.focusSearchRequest) { _ in
            DispatchQueue.main.async { searchFieldFocused = true }
        }
        // 输入变化即重算候选（纯函数，确定性输出）。
        .onChange(of: state.query) { _ in refreshCompletions() }
        .onChange(of: showsCompletions) { visible in
            if visible { installCompletionKeyMonitor() } else { removeCompletionKeyMonitor() }
        }
        .onAppear { refreshCompletions() }
        .onDisappear { removeCompletionKeyMonitor() }
        // 检索调试面板（sheet；只读诊断）。
        .sheet(isPresented: $state.showSearchDebug) {
            SearchDebugPanelView()
        }

        // 走查：内容页地面统一 desk token（纸卡/纸面输入框浮在桌面上），
        // 不再吃窗口系统默认灰底。
        .background(DS.Color.desk(theme, scheme))
    }

    // MARK: 补全条

    /// 候选重算：刚接受过的查询不再弹条（选中→回填→重查链路不自激发）；
    /// 继续输入即恢复。高亮序号越界即清。
    private func refreshCompletions() {
        guard SearchMemoryStore.habitLearningEnabled else {
            completions = []
            completionIndex = nil
            return
        }
        if state.query == acceptedCompletionQuery {
            completions = []
            completionIndex = nil
            return
        }
        completions = SearchCompletionSource.candidates(history: state.historyEntries,
                                                        prefix: state.query)
        if let i = completionIndex, i >= completions.count { completionIndex = nil }
    }

    /// 接受候选：文本回填＋走既有检索入口（提交语义零改写）；随后抑制
    /// 本查询的补全条重弹。
    private func acceptCompletion(_ candidate: SearchCompletionCandidate) {
        acceptedCompletionQuery = candidate.query
        completions = []
        completionIndex = nil
        state.query = candidate.query
        state.search()
    }

    /// 候选条（搜索框下；纸卡行式，高亮行描边。↑↓ 高亮、Enter 接受、
    /// Esc 收起——键盘监视只在条可见时安装，随可见性启停）。
    private var completionStrip: some View {
        let theme = DS.Theme.storage(dsTheme)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(completions.enumerated()), id: \.element.id) { index, candidate in
                CompletionRow(candidate: candidate,
                              isSelected: completionIndex == index,
                              showsDivider: index < completions.count - 1,
                              theme: theme,
                              scheme: scheme,
                              accessibilityLabel: completionAccessibilityLabel(candidate)) {
                    acceptCompletion(candidate)
                }
            }
            Text(L10n.completionNavHint)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.top, DS.Spacing.xxs)
        }
        .background(DS.Color.paper(theme, scheme),
                    in: RoundedRectangle(cornerRadius: DS.Radius.small))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.small)
            .stroke(DS.Color.stroke(theme, scheme), lineWidth: 1))
    }

    //VoiceOver 逐字可闻：类型＋文本＋频次。
    private func completionAccessibilityLabel(_ candidate: SearchCompletionCandidate) -> String {
        candidate.isPrefixExpansion
            ? L10n.completionA11yPrefix(candidate.query)
            : L10n.completionA11yHistory(candidate.query, candidate.hitCount)
    }

    /// 补全条键盘导航（↑↓ 高亮移动、Esc 收起；仅条可见时在装）。
    /// PageOverviewView ESC 本地监视器先例；只在检索框聚焦时接管，其余
    /// 按键原样放行。
    private func installCompletionKeyMonitor() {
        guard completionKeyMonitor == nil else { return }
        completionKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard searchFieldFocused, showsCompletions, !completions.isEmpty else { return event }
            switch event.keyCode {
            case 125: // ↓
                completionIndex = min((completionIndex ?? -1) + 1, completions.count - 1)
                return nil
            case 126: // ↑
                completionIndex = max((completionIndex ?? completions.count) - 1, 0)
                return nil
            case 53:  // Esc：收起补全条（检索框内容不动）
                completions = []
                completionIndex = nil
                return nil
            default:
                return event
            }
        }
    }

    private func removeCompletionKeyMonitor() {
        if let monitor = completionKeyMonitor {
            NSEvent.removeMonitor(monitor)
            completionKeyMonitor = nil
        }
    }

    /// Empty state A shows only when there is genuinely no indexed library.
    /// NOT keyed on rootName: the index may have been built from another
    /// session/CLI, and a missing folder-picker label must never hide results.
    private var libraryNotBuilt: Bool {
        (state.coverageStats?.booksOK ?? 0) == 0
    }

    private var searchField: some View {
        let theme = DS.Theme.storage(dsTheme)
        return HStack(spacing: DS.Spacing.xs) {
            TextField(L10n.searchPlaceholder, text: $state.query)
                .textFieldStyle(.dsTextField)
                .focused($searchFieldFocused)
                .onSubmit {
                    // 补全高亮在位时 Enter＝接受候选（回填＋检索）；
                    // 否则原样提交（检索语义零改写）。
                    if showsCompletions, let i = completionIndex, completions.indices.contains(i) {
                        acceptCompletion(completions[i])
                    } else {
                        state.search()
                    }
                }
            Button(L10n.favoriteSearch) {
                state.favoriteCurrentSearch()
            }
            .buttonStyle(.bordered)
            .disabled(state.query.trimmingCharacters(in: .whitespaces).isEmpty)
            .help(L10n.favoriteSearch)
            // 智能收藏入口（query＋过滤四件整体入库，打开现算）。
            Button(L10n.favoriteSearchSmart) {
                state.saveCurrentSearchAsSmartCollection()
            }
            .buttonStyle(.bordered)
            .disabled(state.query.trimmingCharacters(in: .whitespaces).isEmpty)
            .help(L10n.favoriteSearchSmart)
            Button(L10n.search) { state.search() }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, DS.Spacing.xs)
        .padding(.vertical, DS.Spacing.xxs)
        .background(DS.Color.paper(theme, scheme),
                    in: RoundedRectangle(cornerRadius: DS.Radius.small))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.small)
            .stroke(DS.Color.strokeStrong(theme, scheme), lineWidth: 1))
    }

    private var filterBar: some View {
        let theme = DS.Theme.storage(dsTheme)
        return VStack(spacing: 0) {
            Hairline()
            HStack(spacing: DS.Spacing.xs) {
                Text(L10n.filterLabel).font(.caption).foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                TextField(L10n.filterAuthor, text: $state.filterAuthor)
                    .textFieldStyle(.dsTextField)
                    .font(.caption)
                TextField(L10n.filterVersion, text: $state.filterVersion)
                    .textFieldStyle(.dsTextField)
                    .font(.caption)
                TextField(L10n.filterLanguage, text: $state.filterLanguage)
                    .textFieldStyle(.dsTextField)
                    .font(.caption)
                    .frame(width: 60)
                Menu {
                    Button(L10n.domainAll) { state.filterDomain = "" }
                    Button(L10n.domainBook) { state.filterDomain = "book" }
                    Button(L10n.domainPaper) { state.filterDomain = "paper" }
                } label: {
                    HStack(spacing: DS.Spacing.xxs) {
                        Text(state.filterDomain == "book" ? L10n.domainBook
                                : state.filterDomain == "paper" ? L10n.domainPaper
                                : L10n.domainAll)
                            .font(.caption)
                        Image(systemName: "chevron.down").font(.caption2)
                            .accessibilityHidden(true) // 装饰：菜单展开指示
                    }
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                }
                Menu {
                    Button(L10n.sourceFilterAll) { state.sourceFilter = "" }
                    Button(L10n.sourceFilterNative) { state.sourceFilter = "native" }
                    Button(L10n.sourceFilterOCR) { state.sourceFilter = "ocr" }
                } label: {
                    HStack(spacing: DS.Spacing.xxs) {
                        Text(state.sourceFilter == "ocr" ? L10n.sourceFilterOCR
                                : state.sourceFilter == "native" ? L10n.sourceFilterNative
                                : L10n.sourceFilterAll)
                            .font(.caption)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .accessibilityHidden(true) // 装饰：菜单展开指示
                    }
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    .padding(.horizontal, DS.Spacing.xs)
                    .padding(.vertical, DS.Spacing.xxs)
                    .background(Capsule().fill(DS.Color.paper(theme, scheme)))
                    .overlay(Capsule().stroke(DS.Color.stroke(theme, scheme), lineWidth: 1))
                }
                .fixedSize()
                // 前置页屏蔽开关（查询后过滤；默认关）。
                Toggle(L10n.frontMatterToggle, isOn: $skipFrontMatter)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    .help(L10n.bodyStartFieldHint)
                Text(L10n.filterUnknownNote).font(.caption2).foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }
            .padding(.horizontal, DS.Spacing.xs)
            .padding(.vertical, DS.Spacing.xxs)
            Hairline()
        }
    }


    @ViewBuilder
    private var statusBar: some View {
        let theme = DS.Theme.storage(dsTheme)
        return VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            if state.isSearching {
                HStack(spacing: DS.Spacing.xs) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.searchingStatus)
                        .font(.caption)
                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                }
            }
            if state.indexing, let p = state.progress {
                StatusRow(systemImage: "arrow.triangle.2.circlepath",
                          text: "\(L10n.indexingStatus) \(p.filesDone)/\(p.filesTotal)\(p.currentFile.map { " · \($0)" } ?? "")",
                          color: DS.Color.inkSecondary(theme, scheme))
            }
            if let notice = state.truncatedNotice, !state.hits.isEmpty {
                StatusRow(systemImage: "exclamationmark.triangle.fill",
                          text: notice, color: DS.Color.warning(theme, scheme))
            }
            if let error = state.indexError {
                StatusRow(systemImage: "exclamationmark.circle.fill",
                          text: error, color: DS.Color.error(theme, scheme))
            }
            if let error = state.searchError {
                StatusRow(systemImage: "exclamationmark.circle.fill",
                          text: error, color: DS.Color.error(theme, scheme))
            }
            if let error = state.policyConfigError {
                StatusRow(systemImage: "exclamationmark.triangle.fill",
                          text: error, color: DS.Color.warning(theme, scheme))
            }
            if let notice = state.lastFavoriteNotice {
                StatusRow(systemImage: "checkmark.circle.fill",
                          text: notice, color: DS.Color.success(theme, scheme))
            }

            // 调试面板入口（状态栏区小图标；诊断面，无写动作）。
            if state.searchedOnce {
                HStack(spacing: DS.Spacing.xs) {
                    Button {
                        state.showSearchDebug = true
                    } label: {
                        Label(L10n.debugPanelEntry, systemImage: "chart.bar.doc.horizontal")
                            .font(.caption2)
                            .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.debugPanelTitle)
                    .accessibilityLabel(L10n.debugPanelTitle)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Empty state B: library exists, no search yet — centered composition
    /// plus recent searches below.
    private var emptyStateB: some View {
        let theme = DS.Theme.storage(dsTheme)
        return ScrollView {
            VStack(spacing: DS.Spacing.lg) {
                EmptyStateView(systemImage: "text.magnifyingglass",
                               title: L10n.emptySearchTitle,
                               detail: L10n.emptySearchDetail)
                if !state.historyEntries.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text(L10n.recentSearches)
                            .font(.subheadline)
                            .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                        RecentHistoryStrip()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Horizontal chips of recent queries; tapping refills and runs the search.
/// Each chip carries a caption with time + hit count (HistoryEntry has both).
struct RecentHistoryStrip: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dsTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.xs) {
                ForEach(state.historyEntries, id: \.at) { entry in
                    Button {
                        state.query = entry.query
                        state.search()
                    } label: {
                        VStack(spacing: 1) {
                            Text(entry.query)
                                .font(.caption)
                                .lineLimit(1)
                            HStack(spacing: DS.Spacing.xxs) {
                                Text(entry.at, style: .date)
                                Text(entry.at, style: .time)
                                Text("· \(entry.hitCount)\(L10n.pageUnit)")
                            }
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}

/// 单条候选行（独立视图件——既收窄 SearchView 的类型检查表达式，
/// 也让行样式可独立走查）。高亮行描边、底部发丝线分隔；点击＝接受候选
/// （回填＋走既有检索入口，提交语义零改写）。
private struct CompletionRow: View {
    let candidate: SearchCompletionCandidate
    let isSelected: Bool
    let showsDivider: Bool
    let theme: DS.Theme
    let scheme: ColorScheme
    let accessibilityLabel: String
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: candidate.isPrefixExpansion ? "asterisk" : "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                    .accessibilityHidden(true) // 装饰：候选类型图标
                Text(candidate.query)
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundStyle(DS.Color.ink(theme, scheme))
                Spacer(minLength: 0)
                if !candidate.isPrefixExpansion {
                    Text("\(candidate.hitCount)\(L10n.pageUnit)")
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                }
            }
            .padding(.horizontal, DS.Spacing.xs)
            .padding(.vertical, DS.Spacing.xxs)
            .contentShape(Rectangle())
            .overlay(rowStroke)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(L10n.completionHint)
        .overlay(alignment: .bottom) {
            if showsDivider { Hairline() }
        }
    }

    /// 高亮描边（选中＝强描边；未选＝透明占位，行高恒定）。
    private var rowStroke: some View {
        RoundedRectangle(cornerRadius: DS.Radius.small).stroke(
            isSelected ? DS.Color.strokeStrong(theme, scheme) : SwiftUI.Color.clear,
            lineWidth: 1)
    }
}
