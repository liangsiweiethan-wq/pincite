import SwiftUI
import AppKit
import PDFKit
import LiteratureCore
import LiteratureSearchUI

// MARK: - 双文档对照工作台

/// AppKit 对照台窗口（会话内持有，关闭即记账出账；单工作台——一次一对
/// 文档，重开顶替旧窗）。线程契约照 SnapshotWindowController/ReadingPosition
/// Store 先例：窗口只在主线程触碰（assert 守护），不加 @MainActor 保持与
/// AppState 非隔离层的同步调用通道。
final class WorkbenchWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    /// 主文档 bookID（AppState 单工作台顶替/出账按此键）。
    let primaryBookID: String
    /// 闭窗回调，携带**正在关闭的窗对象**
    /// 顶替路径旧窗的 windowWillClose 异步落地时新 controller 已占槽位，
    /// 无身份比对的回调会把新槽位清掉；调用方据 window === 槽位窗判定。
    private let onClose: (NSWindow) -> Void

    /// primaryHit/secondaryHit 由 AppState.openWorkbench 合成（既有
    /// synthesizedHit 管线，双指纹守卫在视图层 loadAndJump 原样生效）。
    /// state 在 init 期注入环境（NSHostingView 无环境继承，rootView 带
    /// environmentObject 一次成型——避免事后换 rootView 重置窗格 @State）。
    init(primaryHit: SearchHit, secondaryHit: SearchHit, state: AppState,
         onClose: @escaping (NSWindow) -> Void) {
        assert(Thread.isMainThread, "WorkbenchWindowController must init on the main thread")
        let content = WorkbenchContentView(primaryHit: primaryHit,
                                           secondaryHit: secondaryHit)
            .environmentObject(state)
        let hosting = NSHostingView(rootView: content)
        self.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        self.primaryBookID = primaryHit.bookID
        window.title = L10n.workbenchWindowTitle
        window.minSize = NSSize(width: 900, height: 560)
        // 悬垂纪律照 SnapshotWindowController：isReleasedWhenClosed=false＋
        // delegate 出账；本控制器由 AppState 强持有（单工作台槽位）。
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.contentView = hosting
        self.onClose = onClose
        super.init()
        window.delegate = self
    }

    func show() {
        assert(Thread.isMainThread, "show must run on the main thread")
        window.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onClose(closing)
        }
    }
}

/// 对照台内容：HSplitView 双 `PDFDetailView`，各自 PDFReaderState（per-
/// instance 先例＝DetailChromeView `@State readerState`）；主视图页变化 →
/// linkedPage 换算 → 对照视图跳页（单向联动）。
struct WorkbenchContentView: View {
    @EnvironmentObject private var state: AppState
    let primaryHit: SearchHit
    let secondaryHit: SearchHit
    /// 各自阅读器桥（per-instance：两个独立实例，互不共享栈/目录/选区态）。
    @State private var primaryReaderState = PDFReaderState()
    @State private var secondaryReaderState = PDFReaderState()
    /// 联动点火闸。装载后的首个 currentPage
    /// 变化＝各自 restoreSavedPage 的还原落页（还原本身会产生 0→存档页的
    /// 一次跳变），不驱动联动——否则主格还原会覆写对照格刚还原的自身进度
    /// 并经 persistPosition 落盘，违背「进度各自记互不覆写」。首个变化只
    /// 点火不驱动，之后的页变化（用户翻页）才换算驱动。
    @State private var linkPrimed = false

    var body: some View {
        VStack(spacing: 0) {
            workbenchHeader
            HSplitView {
                WorkbenchPane(hit: primaryHit, readerState: primaryReaderState,
                              isPrimary: true)
                WorkbenchPane(hit: secondaryHit, readerState: secondaryReaderState,
                              isPrimary: false)
            }
            .frame(maxHeight: .infinity)
        }
        // 装载态复位点火闸：每次（重）装载后重新等待首个落页。
        .onChange(of: primaryReaderState.loaded) { loaded in
            if loaded { linkPrimed = false }
        }
        .onChange(of: primaryReaderState.currentPage) { page in
            guard linkPrimed else {
                linkPrimed = true   // 首个变化＝装载/还原落页：只点火不驱动
                return
            }
            guard page >= 1, secondaryReaderState.loaded else { return }
            let target = WorkbenchMapping.linkedPage(
                for: page,
                sourceCount: max(primaryHit.pageCount, 1),
                targetCount: max(secondaryHit.pageCount, 1))
            secondaryReaderState.jump(to: target)
        }
    }

    private var workbenchHeader: some View {
        let theme = DS.Theme.storage(UserDefaults.standard.string(forKey: "dsTheme") ?? "")
        let scheme: ColorScheme = NSApp.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        return HStack(spacing: DS.Spacing.xs) {
            Image(systemName: "rectangle.split.2x1")
                .font(.caption)
                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                .accessibilityHidden(true) // 装饰：标题行文字语义自述
            Text(L10n.workbenchWindowTitle)
                .font(.caption)
                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            Text(L10n.workbenchLinkedHint)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                .lineLimit(1)
            Spacer(minLength: DS.Spacing.xs)
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xxs)
        .background(DS.Color.surface(theme))
        .overlay(alignment: .bottom) { Hairline() }
    }
}

/// 单侧窗格：pane 头（主/对照徽标＋书名）+ 独立 PDFDetailView。
/// doc 检索/游标/stale 各 pane 独立 @State（互不串）。
private struct WorkbenchPane: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue
    let hit: SearchHit
    @ObservedObject var readerState: PDFReaderState
    let isPrimary: Bool
    @State private var staleReference = false
    @State private var matchCursor = 0
    @State private var docQuery = ""
    @State private var docSearchToken = 0
    @State private var docSearchCursor = 0
    @State private var docSearchCount = 0

    var body: some View {
        let theme = DS.Theme.storage(dsTheme)
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.xxs) {
                CapsuleBadge(text: isPrimary ? L10n.workbenchPrimaryBadge : L10n.workbenchSecondaryBadge,
                             color: DS.Color.ink(theme, scheme))
                Text(hit.title ?? hit.fileName)
                    .font(.caption)
                    .foregroundStyle(DS.Color.ink(theme, scheme))
                    .lineLimit(1)
                Spacer(minLength: DS.Spacing.xs)
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xxs)
            .background(DS.Color.paper(theme, scheme))
            .overlay(alignment: .bottom) { Hairline() }
            if let spec = HitRouter.primaryOpenSpec(for: hit) {
                PDFDetailView(
                    spec: spec,
                    isOriginalView: false,
                    bookFileName: hit.fileName,
                    bookTitle: hit.title,
                    bookID: hit.bookID,
                    highlightStore: state.highlightStore,
                    favoritesStore: state.favoritesStore,
                    staleReference: $staleReference,
                    matchCursor: $matchCursor,
                    docSearchText: docQuery,
                    docSearchToken: $docSearchToken,
                    docSearchCursor: $docSearchCursor,
                    docSearchCount: $docSearchCount,
                    highlightsVersion: $state.highlightsVersion,
                    positionStore: state.readingPositions,
                    restoreSavedPage: true,
                    readerState: readerState,
                    aiTranslateEnabled: false,
                    onTranslate: nil,
                    onCitationTarget: isPrimary ? { state.smartJumpCitation($0) } : nil,
                    autoTOCProvider: { state.autoTOC(for: $0) },
                    marksStore: state.marksStore,
                    onOpenBookPage: { bookID, page in Task { await state.openBookPage(bookID: bookID, pageNumber: page) } })
                    .padding(DS.Spacing.sm)
            } else {
                VStack {
                    Spacer()
                    StatusRow(systemImage: "exclamationmark.octagon.fill",
                              text: L10n.pairingDenied,
                              color: DS.Color.error(theme, scheme), font: .callout)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
