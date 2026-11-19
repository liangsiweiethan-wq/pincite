import SwiftUI
import AppKit
import LiteratureCore
import LiteratureSearchUI

/// Three-column shell (approved redesign; 外壳换自绘
/// ColumnShell 以支持三栏独立收起与列宽不联动): sidebar navigation,
struct RootView: View {
    @EnvironmentObject var state: AppState
    /// Three-state theme (docs/VISUAL-DESIGN.md 三态注入契约): single source of truth is
    /// `@AppStorage("dsTheme")`; the content root is rebuilt via `.id(dsTheme)`
    /// and `NSWindow.appearance` is set alongside so system controls follow.
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var theme: DS.Theme { .storage(dsTheme) }
    /// 专注阅读 ESC 退出监视器（App 生命周期内常驻，等同 ReadingChrome 的做法）。
    @State private var escMonitor: Any?

    var body: some View {
        ColumnShell(sidebar: sidebar, content: content, detail: DetailChromeView())
        .navigationTitle(L10n.appTitle)
        .frame(minWidth: 1180, minHeight: 640)
        .id(dsTheme)
        .environment(\.dsTheme, theme)
        // 窗口期全局顶栏总提示（自动显隐——
        // RefreshConsoleStore.windowPeriodActive 三源合成，回调驱动零轮询）。
        .overlay(alignment: .top) {
            RefreshWindowPeriodBanner()
        }
        .environment(\.keybindings, state.keybindings)
        // 增强对比度双通道信号全树注入（SwiftUI 环境直读 +
        // NSWorkspace KVO 合成，取或）。
        .dsContrastInjection()
        // 三栏显隐切换（工具栏按钮，⌘1/⌘2/⌘3 见 App 入口）。
        .toolbar {
            ToolbarItemGroup {
                columnToggle(.sidebar, icon: "sidebar.left", tooltip: L10n.columnSidebarTooltip)
                columnToggle(.results, icon: "list.bullet", tooltip: L10n.columnResultsTooltip)
                columnToggle(.detail, icon: "doc.text", tooltip: L10n.columnDetailTooltip)
            }
        }
        .onAppear {
            applyAppearance()
            installFocusEscMonitor()
        }
        .onChange(of: dsTheme) { _ in applyAppearance() }
        .onChange(of: state.focusReading) { focus in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: DS.Motion.duration)) {
                if focus {
                    state.sidebarColumnVisible = false
                    state.resultsColumnVisible = false
                } else {
                    state.sidebarColumnVisible = true
                    state.resultsColumnVisible = true
                    state.detailColumnVisible = true
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { state.bookDetail != nil },
            set: { if !$0 { state.closeBookDetail() } })) {
            BookDetailView()
        }
        // 收藏回执：各入口（书目/命中页/每日一句/检索式）共用瞬态提示，
        // 数据在 AppState.lastFavoriteNotice（3 秒自消），此处仅呈现。
        // 批注删除撤销 toast 挂同一 overlay（底部胶囊 + 「撤销」
        // 按钮，形态照收藏回执；5 秒窗口语义在 AnnotationUndo/AppState）。
        .overlay(alignment: .bottom) {
            VStack(spacing: DS.Spacing.sm) {
                if state.annotationUndo != nil {
                    HStack(spacing: DS.Spacing.sm) {
                        Text(L10n.annotationDeletedToast)
                            .font(.callout)
                            .foregroundStyle(DS.Color.ink(theme, scheme))
                        Button(L10n.annotationUndoButton) {
                            state.undoAnnotationDelete()
                        }
                        .buttonStyle(.borderless)
                        .font(.callout.weight(.semibold))
                    }
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.vertical, DS.Spacing.sm)
                    .background(DS.Color.paper(theme, scheme), in: Capsule())
                    .overlay(Capsule().stroke(DS.Color.stroke(theme, scheme), lineWidth: 1))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .accessibilityLabel(L10n.annotationDeletedToast)
                }
                if let notice = state.lastFavoriteNotice {
                    Text(notice)
                        .font(.callout)
                        .foregroundStyle(DS.Color.ink(theme, scheme))
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.vertical, DS.Spacing.sm)
                        .background(DS.Color.paper(theme, scheme), in: Capsule())
                        .overlay(Capsule().stroke(DS.Color.stroke(theme, scheme), lineWidth: 1))
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.bottom, DS.Spacing.lg)
        }
        // ⌘K 命令面板：全窗 dim 背景（点击关闭）+ 居中浮层。
        .overlay {
            if state.palettePresented {
                Color.black.opacity(0.15)
                    .onTapGesture { state.palettePresented = false }
                    .overlay {
                        CommandPaletteView()
                    }
            }
        }
    }

    /// 工具栏三栏显隐按钮——可见时主色高亮，tooltip 带快捷键。
    private func columnToggle(_ column: AppState.Column, icon: String, tooltip: String) -> some View {
        let visible: Bool = {
            switch column {
            case .sidebar: return state.sidebarColumnVisible
            case .results: return state.resultsColumnVisible
            case .detail: return state.detailColumnVisible
            }
        }()
        return Button {
            state.toggleColumn(column)
        } label: {
            Image(systemName: icon)
                .foregroundStyle(visible ? DS.Color.select(theme, scheme) : DS.Color.inkSecondary(theme, scheme))
        }
        .buttonStyle(.borderless)
        .help(tooltip)
        .accessibilityLabel(tooltip)
    }

    /// 专注阅读 ESC 退出：无修饰键 ESC + 专注中 + 焦点不在文本框时消费
    /// 事件退出；文本框内 ESC 透传给 ReadingChrome 的既有监视器（收起搜索
    /// 激活态语义不变）。
    private func installFocusEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak state] event in
            guard let state, state.focusReading,
                  event.keyCode == 53,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSText) else { return event }
            state.focusReading = false
            return nil
        }
    }

    /// System controls (menus, scrollers, Form rows) only follow NSAppearance:
    /// paper tier keeps `.aqua`, graphite/obsidian force `.darkAqua`.
    private func applyAppearance() {
        let appearance: NSAppearance? = DS.Theme.storage(dsTheme) == .system
            ? nil
            : NSAppearance(named: .darkAqua)
        for window in NSApp.windows {
            window.appearance = appearance
        }
    }

    // MARK: Sidebar

    private struct RefreshWindowPeriodBanner: View {
        @EnvironmentObject var console: RefreshConsoleStore
        @EnvironmentObject var state: AppState
        @Environment(\.colorScheme) private var scheme
        @Environment(\.dsTheme) private var theme

        var body: some View {
            if console.windowPeriodActive {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle")
                        .foregroundStyle(DS.Color.warning(theme, scheme))
                    Text(L10n.indexRefreshWindowBannerTitle)
                        .font(.caption)
                        .foregroundStyle(DS.Color.ink(theme, scheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let progress = console.windowPeriodProgressText, !progress.isEmpty {
                        Text(progress)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    }
                    Button(L10n.indexRefreshWindowBannerOpen) {
                        state.sidebarSection = .library
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.xs)
                .background(DS.Color.paper(theme, scheme), in: RoundedRectangle(cornerRadius: DS.Radius.small))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.small)
                    .stroke(DS.Color.stroke(theme, scheme), lineWidth: 1))
                .padding(.top, DS.Spacing.xxs)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityLabel(L10n.indexRefreshWindowBannerTitle)
            }
        }
    }

    private var sidebar: some View {
        List(selection: $state.sidebarSection) {
            Section {
                ForEach(AppState.SidebarSection.allCases) { section in
                    Label(label(for: section), systemImage: icon(for: section))
                        // 衬线落地：导航侧栏标签进 display serif 字阶。
                        .font(DS.Font.displaySection)
                        .tag(section)
                }
            } footer: {
                libraryBadge
            }
        }
        .listStyle(.sidebar)
    }

    private func label(for section: AppState.SidebarSection) -> String {
        switch section {
        case .search: return L10n.navSearch
        case .history: return L10n.navHistory
        case .coverage: return L10n.navCoverage
        case .library: return L10n.navLibrary
        case .favorites: return L10n.navFavorites
        case .quote: return L10n.navQuote
        case .excerpts: return L10n.navExcerpts
        }
    }

    private func icon(for section: AppState.SidebarSection) -> String {
        switch section {
        case .search: return "magnifyingglass"
        case .history: return "clock"
        case .coverage: return "chart.pie"
        case .library: return "books.vertical"
        case .favorites: return "star"
        case .quote: return "text.quote"
        case .excerpts: return "note.text"
        }
    }

    @ViewBuilder
    private var libraryBadge: some View {
        if let stats = state.coverageStats {
            Text("\(state.bookNames.count) \(L10n.booksUnit) · \(stats.pages) \(L10n.pageUnit)")
                .font(.caption2)
                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.vertical, DS.Spacing.xxs)
                .background(DS.Color.paper(theme, scheme), in: Capsule())
                .overlay(Capsule().stroke(DS.Color.stroke(theme, scheme), lineWidth: 1))
        } else {
            Text(L10n.coverageNotBuilt)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
        }
    }

    // MARK: Content section switch

    @ViewBuilder
    private var content: some View {
        switch state.sidebarSection {
        case .search: SearchView()
        case .history: HistoryView()
        case .coverage: CoverageView()
        case .library: LibrarySettingsView()
        case .favorites: FavoritesView()
        case .quote: DailyQuoteView()
        case .excerpts: ExcerptBoardView()
        }
    }
}
