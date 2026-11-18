import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LiteratureCore
import LiteratureSearchUI

@main
struct LiteratureSearchAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                // 刷新控制台 store 注入环境（顶栏窗口期横幅与
                // 详情栏红条旁就地说明的观察源；store 本体仍由 AppState 持有）。
                .environmentObject(state.refreshConsole)
                .onAppear {
                    // AppDelegate 会话退出钩子的 state 注入点（weak，
                    // 无环）；随后一次性会话还原守卫。深链让位不在此判定——
                    // pendingDeepLink 全文件无
                    // 赋值点属死代码且 .search 不设 selectedHit 兜不住；让位
                    // 改走唯一真通路＝onOpenURL 内 skipSessionRestore（先到
                    // 先烧守卫），onAppear/onOpenURL 谁先到都成立：
                    // 深链先到 → 守卫已烧，onAppear 还原自然让位；
                    // onAppear 先到 → 还原已执行（sessionRestoreAttempted），
                    // 深链照常在其上处理（先到先得，两不覆盖）。
                    appDelegate.state = state
                    Task { await state.restoreSessionOnce() }
                }
                .onOpenURL { url in
                    guard let link = DeepLink.parse(url) else { return }
                    // 深链优先：先烧还原
                    // 守卫再处理深链。幂等——守卫已烧时零副作用。
                    state.skipSessionRestore()
                    handleDeepLink(link)
                }
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            // Scene.commands 不继承
            // WindowGroup 内容树环境值——app 域 11 键必须显式传
            // `registry: state.keybindings`，否则用户覆盖/禁绑在菜单上静默失效
            //（与设置页诊断面板同源，显示不再矛盾）。
            CommandGroup(after: .newItem) {
                Button(L10n.chooseFolder) { state.chooseFolder() }
                    .registeredShortcut("openFolder", registry: state.keybindings)
            }
            CommandMenu(L10n.navMenu) {
                Button(L10n.navSearch) { state.sidebarSection = .search }
                    .registeredShortcut("navSearch", registry: state.keybindings)
                Button(L10n.navHistory) { state.sidebarSection = .history }
                    .registeredShortcut("navHistory", registry: state.keybindings)
                Button(L10n.navCoverage) { state.sidebarSection = .coverage }
                    .registeredShortcut("navCoverage", registry: state.keybindings)
                Button(L10n.navLibrary) { state.sidebarSection = .library }
                    .registeredShortcut("navLibrary", registry: state.keybindings)
                Button(L10n.navQuote) { state.sidebarSection = .quote }
                    .registeredShortcut("navQuote", registry: state.keybindings)
                Divider()
                Button(L10n.columnSidebarTooltip) { state.toggleColumn(.sidebar) }
                    .registeredShortcut("columnSidebar", registry: state.keybindings)
                Button(L10n.columnResultsTooltip) { state.toggleColumn(.results) }
                    .registeredShortcut("columnResults", registry: state.keybindings)
                Button(L10n.columnDetailTooltip) { state.toggleColumn(.detail) }
                    .registeredShortcut("columnDetail", registry: state.keybindings)
                Divider()
                Button(L10n.focusSearch) { state.focusSearchRequest += 1 }
                    .registeredShortcut("focusSearch", registry: state.keybindings)
                Button(L10n.paletteTitle) { state.palettePresented.toggle() }
                    .registeredShortcut("commandPalette", registry: state.keybindings)
                Button(L10n.closeDetail) { state.closePDF() }
                    // 语义键豁免：.cancelAction 是系统 cancel 角色（ESC
                    // 别名），非实键绑定，不进注册表。
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    /// Deep-link routing: search prefills and runs; quote opens the daily-quote
    /// section (cold-start buffer uses the same switch).
    private func handleDeepLink(_ link: DeepLink) {
        switch link {
        case .search(let query):
            state.sidebarSection = .search
            state.query = query
            state.search()
        case .quote:
            state.openTodayQuote()
        case .open(let doc, let page, let highlight):
            // 定位书/页（书缺显式 toast；page=nil 书级打开不开页）。
            // hl 定位批注行（行缺显式 toast；以行 pageNumber 打开）。
            Task { await state.deepLinkOpen(doc: doc, page: page, highlight: highlight) }
        case .collection(let id):
            // 定位收藏行（缺行显式 toast；命中切收藏页置选中）。
            state.deepLinkCollection(id: id)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// AppState 引用（App 启动 onAppear 注入）——退出钩子据此写
    /// 会话账本。weak 防环（App 结构持有 state 真源）。
    weak var state: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    /// 退出钩子：会话账本整体落库一次（Sumatra 退出整体序列化的
    /// 对应物；无常驻进程、无轮询定时器）。写失败不问题
    /// 退出、向 stderr 记录（AppState.persistSession 内处理）。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        state?.persistSession()
        return .terminateNow
    }
}
