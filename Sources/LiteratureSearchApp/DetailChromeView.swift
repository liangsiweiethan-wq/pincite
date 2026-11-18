import SwiftUI
import PDFKit
import LiteratureCore
import LiteratureSearchUI

/// Detail pane: the guarded PDF view on a `desk` ground with the floating
/// ReadingChrome navigation bar on top (auto-retreat, guards never retreat),
/// the AI toolbar + inline preview panel, and the metadata editor. Guards and
struct DetailChromeView: View {
    @EnvironmentObject var state: AppState
    /// 刷新控制台（红条旁窗口期就地说明的观察源）。
    @EnvironmentObject private var refreshConsole: RefreshConsoleStore
    @Environment(\.dsTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var staleReference = false
    @State private var showOriginalForOCR = false
    /// Pointer inside the PDF area (drives ReadingChrome show/hide).
    @State private var pdfAreaHovered = false
    /// Which match on the current page is brought into view (1-based UI).
    @State private var matchCursor = 0
    // Sioyek 式本文内全文检索（完整匹配表，循环导航，⌘G/⇧⌘G）。
    @State private var docQuery = ""
    @State private var docSearchToken = 0
    @State private var docSearchCursor = 0
    @State private var docSearchCount = 0
    @State private var aiExpanded = false
    @State private var showMetadata = false
    /// 高亮列表面板（popover）。
    @State private var showHighlights = false
    /// 相似文档 popover。
@State private var showSimilar = false
    @State private var readerState = PDFReaderState()
    /// 缩略图栏（左缘内嵌，可收起；与 PDFView 同 document 实例联动）。
    @State private var showThumbnails = false
    /// 目录侧栏（左缘内嵌；readerState.outline 空时工具栏按钮与本栏均不渲染）。
    @State private var showOutline = false
    /// 侧边批注面板（右缘内嵌；工具条批注按钮开合）。开合状态存
    /// UserDefaults 记偏好。
    @AppStorage("showAnnotations") private var showAnnotations = false
    /// 双页对开偏好（单页连续 ⇄ 双页连续；随阅读位置按书常驻持久）。
    @State private var twoPageSpread = false
    /// TTS 朗读（纯本地 AVSpeechSynthesizer；只读页 text_original）。
    @StateObject private var tts = TTSSpeaker()
    /// 概览弹窗（⌘O：页面缩略九宫格；点击跳页即关闭）。
    @State private var showOverview = false

    private static let aiPanelMaxHeight: CGFloat = 360

    var body: some View {
        if let reason = state.openBlockedReason {
            VStack {
                Spacer()
                StatusRow(systemImage: "exclamationmark.octagon.fill", text: reason,
                          color: DS.Color.error(theme, scheme), font: .callout)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let hit = state.selectedHit {
            loadedPane(for: hit)
        } else {
            VStack {
                Spacer()
                EmptyStateView(systemImage: "doc.plaintext",
                               title: L10n.detailPlaceholderEmpty,
                               detail: L10n.detailPlaceholder)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadedPane(for hit: SearchHit) -> some View {
        let spec: HitRouter.OpenSpec? = showOriginalForOCR
            ? HitRouter.originalOpenSpec(for: hit)
            : HitRouter.primaryOpenSpec(for: hit)
        // 布局革命：PDF 是绝对主角——VStack(spacing: 0) + PDF 区
        // layoutPriority(1) 吃满全部剩余高度；AI 改可折叠 Section（默认折叠），
        // 未配置或专注阅读时整块不渲染；元数据进 sheet。
        // 布局验收点：AI 未配置时详情栏除 ReadingChrome 头部条外全是 PDF。
        return VStack(spacing: 0) {
            ZStack(alignment: .top) {
                pdfArea(for: hit, spec: spec)
                ReadingChrome(
                    guardInfo: guardInfo(for: hit, spec: spec),
                    sourceBadge: HitRouter.sourceBadgeText(hit.source),
                    isOCRSource: hit.source == "ocr",
                    title: hit.title ?? hit.fileName,
                    // 位置记忆显示：三轨文本的印刷页经统一服务取页
                    // （存储契约零改动，物理页仍是唯一存储基准）。
                    pageTrackText: HitRouter.threeTrackPageText(
                        for: hit,
                        printed: state.printedPage(bookID: hit.bookID, physical: hit.physicalPage)),
                    ocrPage: hit.ocrPage,
                    physicalPage: hit.physicalPage,
                    showOriginalForOCR: $showOriginalForOCR,
                    docQuery: $docQuery,
                    docSearchToken: $docSearchToken,
                    docSearchCursor: $docSearchCursor,
                    docSearchCount: $docSearchCount,
                    matchCursor: $matchCursor,
                    pageMatchTotal: max(hit.matches.count, 1),
                    aiSectionVisible: state.aiConfigured,
                    aiSectionExpanded: $aiExpanded,
                    focusReading: $state.focusReading,
                    onOpenMetadata: { showMetadata = true },
                    onBookStep: { stepThroughBookHits(hit, $0) },
                    onClose: {
                        showOriginalForOCR = false
                        state.closePDF()
                    },
                    pdfAreaHovered: $pdfAreaHovered,
                    showThumbnails: $showThumbnails,
                    showOutline: $showOutline,
                    outlineAvailable: !readerState.outline.isEmpty,
                    showAnnotations: $showAnnotations,
                    twoPageSpread: $twoPageSpread,
                    ttsSpeaking: tts.speaking,
                    onSpeakPage: { speakCurrentPage(hit) },
                    onStopSpeak: { tts.stop() },
                    canGoBack: readerState.history.canGoBack,
                    canGoForward: readerState.history.canGoForward,
                    anchorActive: readerState.anchorPage != nil,
                    onHistoryBack: { navigateHistory(.back) },
                    onHistoryForward: { navigateHistory(.forward) },
                    onToggleAnchor: { toggleAnchor(hit) },
                    showOverview: $showOverview,
                    snapshotCount: state.snapshotCount,
                    snapshotTitles: state.snapshotWindowTitles,
                    onRaiseSnapshot: { state.raiseSnapshot(at: $0) },
                    onCloseAllSnapshots: { state.closeAllSnapshots() },
                    windowPeriodNote: refreshConsole.windowPeriodActive
                        ? L10n.indexRefreshStaleWindowNote : nil)
                .popover(isPresented: $showOverview, arrowEdge: .top) {
                    // 概览弹窗：页面缩略九宫格；点击跳页（自动入历史栈）
                    // 并关闭。ESC/点击外部关闭；内容只弱引用 pdfView/document。
                    // 足迹集合快照注入（视图保持无 store 依赖）。
                    PageOverviewView(readerState: readerState,
                                     isPresented: $showOverview,
                                     onSelect: { page in
                                         showOverview = false
                                         readerState.jump(to: page)
                                     },
                                     footprints: state.readFootprints(bookID: hit.bookID))
                }
            }
            .layoutPriority(1)
            if state.aiConfigured && !state.focusReading {
                aiSection(for: hit)
                    .sheet(isPresented: Binding(get: { state.showAIProfilesSettings },
                                                set: { state.showAIProfilesSettings = $0 })) {
                        AIProfilesSettingsView(store: state.aiProfiles)
                    }
            }
        }
        .onChange(of: state.selectedHit?.bookID) { _ in
            showOriginalForOCR = false
            matchCursor = 0
            docQuery = ""
            docSearchToken = 0
            docSearchCount = 0
            docSearchCursor = 0
            tts.stop()
            // 换书收起目录侧栏（新书目录树在 finishLoad 重装前为空）。
            showOutline = false
            // 换书同时收起批注面板（旧书批注上下文失效）。
            showAnnotations = false
            // 阅读增强：历史栈按书隔离——换书即清空并载入新书的锁定锚点；
            // 概览弹窗随详情内容失效一并关闭。
            if let hit = state.selectedHit {
                readerState.history = ReadingHistoryStack()
                readerState.anchorPage = state.readingPositions.position(for: hit.bookID)?.anchorPage
            } else {
                readerState.history = ReadingHistoryStack()
                readerState.anchorPage = nil
            }
            showOverview = false
        }
        // displayMode 变更无系统通知，不依赖翻页/缩放落盘降级处理；页/缩放取
        // 当前视图实况，存量阅读位置不被占位值冲掉。
        .onChange(of: twoPageSpread) { newValue in
            applyTwoPageSpread(newValue, hit: hit)
        }
        // 文档落地后把工具栏 toggle 对齐到真实版式——优先按书存档的
        // 双页偏好（常驻恢复已应用到 PDFView），无档才回读视图实况。
        .onChange(of: readerState.loaded) { loaded in
            guard loaded else { return }
            if let saved = state.readingPositions.position(for: hit.bookID) {
                twoPageSpread = saved.twoPage
                // 锁定锚点按书常驻：落地时与存档对齐（换书 onChange 已预载，
                // 这里兜同书重开等路径）。
                readerState.anchorPage = saved.anchorPage
            } else if let view = readerState.pdfView {
                twoPageSpread = view.displayMode == .twoUpContinuous
            }
        }
        // 阅读视图出现/消失喂点（事件驱动计时首尾；翻页喂点在
        // PDFDetailView currentPage onChange，同一事件链不双记）。
        .onAppear {
            state.recordReadingActive(bookID: hit.bookID)
        }
        .onDisappear {
            state.recordReadingActive(bookID: hit.bookID)
            // 详情栏消失（关闭 PDF/切列）即停止朗读。
            tts.stop()
            // 阅读增强清理：浮层状态、历史栈（按书隔离，重开重建）、概览
            // 弹窗与 pdfView 弱引用归零——不泄漏 PDFView/document。
            readerState.selectionInfo = nil
            readerState.history = ReadingHistoryStack()
            readerState.anchorPage = nil
            readerState.pdfView = nil
            showOverview = false
        }
        .sheet(isPresented: $showMetadata) {
            metadataSheet
                .frame(minWidth: 520)
        }
    }

    @ViewBuilder
    private func aiSection(for hit: SearchHit) -> some View {
        VStack(spacing: 0) {
            Hairline()
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: DS.Motion.duration)) { aiExpanded.toggle() }
            } label: {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    Text(L10n.aiSectionTitle)
                        .font(DS.Font.displaySection)
                        .foregroundStyle(DS.Color.ink(theme, scheme))
                    Text(L10n.aiSectionExpandHint)
                        .font(.caption2)
                        .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                        .lineLimit(1)
                    Spacer(minLength: DS.Spacing.xs)
                    // AI 配置入口（多档案/按用途路由）。按钮在折叠头行内，
                    // 点击不改变折叠态。
                    Button(L10n.aiProfilesSettingsTitle) { state.showAIProfilesSettings = true }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                        .accessibilityLabel(L10n.aiProfilesSettingsTitle)
                    Image(systemName: aiExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.aiSectionTitle)
            if aiExpanded {
                // 「存为批注」闭包——有选区锚选区、无选区锚当前页，
                // 返回结果文案（成功/失败都明确提示，不静默）。
                AIPreviewPanel(hit: hit, onSaveAsAnnotation: { answer in
                    saveAIAnswerAsAnnotation(answer, hit: hit)
                })
                    .frame(maxHeight: DetailChromeView.aiPanelMaxHeight, alignment: .top)
                    .transition(.opacity)
            }
        }
    }

    /// PDF 区容器（docs/VISUAL-DESIGN.md）：`desk` 桌面色衬底铺满，PDFView 四周留
    /// `DS.Spacing.xxl`(32) 页边距；配对缺失的拒绝占位同样落在 desk 底上。
    /// 零命中/空态分支（body 层 EmptyStateView）不加 desk 底，保持原样。
    @ViewBuilder
    private func pdfArea(for hit: SearchHit, spec: HitRouter.OpenSpec?) -> some View {
        ZStack {
            DS.Color.desk(theme, scheme)
            if let spec {
                HStack(spacing: 0) {
                    // 缩略图栏：左缘内嵌，宽 120，可收起；与 PDFView 同
                    // document 实例联动（readerState 桥）。
                    if showThumbnails {
                        // 锁定锚点常驻标记：PDFThumbnailView 无公开 API 做
                        // 逐页角标，退而求其次在栏顶给常驻胶囊（圆点 + 页码），
                        // 点击跳回锚点页（入历史栈）。
                        VStack(spacing: 0) {
                            if let anchor = readerState.anchorPage {
                                Button {
                                    readerState.jump(to: anchor)
                                } label: {
                                    HStack(spacing: DS.Spacing.xxs) {
                                        Circle()
                                            .fill(DS.Color.ink(theme, scheme))
                                            .frame(width: 6, height: 6)
                                        Text(L10n.anchorBadge(anchor))
                                            .font(.caption2)
                                            .monospacedDigit()
                                    }
                                    .padding(.horizontal, DS.Spacing.xs)
                                    .padding(.vertical, DS.Spacing.xxs)
                                    .background(Capsule().fill(DS.Color.surface(theme)))
                                    .overlay(Capsule().stroke(DS.Color.stroke(theme, scheme), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, DS.Spacing.xxs)
                                .accessibilityLabel(L10n.anchorBadge(anchor))
                            }
                            PDFThumbnailRepresentable(readerState: readerState)
                                .frame(width: 120)
                                .background(DS.Color.desk(theme, scheme))
                        }
                        .frame(width: 120)
                        .background(DS.Color.desk(theme, scheme))
                    }
                    // 目录侧栏：左缘内嵌，宽 220，可滚动；树/跳页回调均经
                    // readerState 桥（无目录书恒为空数组，栏与按钮均不出现）。
                    if showOutline && !readerState.outline.isEmpty {
                        OutlineSidebarView(readerState: readerState)
                            .frame(width: 220)
                    }
                    // 批注抽屉（右缘内嵌，宽 260）——快速批注/跳页/
                    // 编辑全走 HighlightStore 与 readerState 桥，两视图来源
                    // 都进面板；写后经 highlightsVersion 版本号联动刷新。
                    if showAnnotations {
                        AnnotationSidebarView(readerState: readerState,
                                              bookID: hit.bookID,
                                              highlightStore: state.highlightStore,
                                              isOriginalView: showOriginalForOCR,
                                              highlightsVersion: $state.highlightsVersion)
                            .frame(width: 260)
                    }
                    PDFDetailView(spec: spec, isOriginalView: showOriginalForOCR,
                                  bookFileName: hit.fileName, bookTitle: hit.title,
                                  bookID: hit.bookID, highlightStore: state.highlightStore,
                                  favoritesStore: state.favoritesStore,
                                  staleReference: $staleReference, matchCursor: $matchCursor,
                                  docSearchText: docQuery,
                                  docSearchToken: $docSearchToken,
                                  docSearchCursor: $docSearchCursor,
                                  docSearchCount: $docSearchCount,
                                  highlightsVersion: $state.highlightsVersion,
                                  positionStore: state.readingPositions,
                                  restoreSavedPage: state.reselectedSameHit && !showOriginalForOCR,
                                  readerState: readerState,
                                  aiTranslateEnabled: state.aiConfigured,
                                  onTranslate: { text, toEnglish in
                                      // 划词翻译：预填 prompt 进既有 AI 确认门
                                      // （预览→逐次确认，零请求保证不变）；展开 AI
                                      // 区并退出专注阅读，保证预览卡可见。
                                      state.aiQuestion = toEnglish
                                          ? L10n.translatePromptEN(text)
                                          : L10n.translatePromptZH(text)
                                      state.focusReading = false
                                      withAnimation(reduceMotion ? nil : .easeInOut(duration: DS.Motion.duration)) { aiExpanded = true }
                                      Task { await state.makeAIPreview(for: hit) }
                                  },
                                  onCitationTarget: { state.smartJumpCitation($0) },
                                  // 自动目录回退：照 bookIDProvider 注入模式传闭包
                                  // （AppState 只读入口），Coordinator 不持 IndexStore。
                                  autoTOCProvider: { state.autoTOC(for: $0) },
                                  // marks 表＋大写标记跨书跳转（走既有
                                  // openBookPage 管线，openGuard/双指纹守卫生效）。
                                  marksStore: state.marksStore,
                                  onOpenBookPage: { bookID, page in Task { await state.openBookPage(bookID: bookID, pageNumber: page) } })
                    .padding(DS.Spacing.xxl)
                    .overlay(alignment: .bottomTrailing) {
                        Button {
                            showHighlights = true
                        } label: {
                            Image(systemName: "highlighter")
                        }
                        .buttonStyle(.bordered)
                        .tint(DS.Color.ink(theme, scheme))
                        .help(L10n.highlightsButton)
                        .accessibilityLabel(L10n.highlightsButton)
                        .popover(isPresented: $showHighlights) {
                            UserHighlightsListView(bookID: hit.bookID)
                                .frame(width: 380, height: 440)
                        }
                        // 相似文档（阅读器侧入口；popover 弹窗形态，
                        // 照 UserHighlightsListView 先例）。
                        Button {
                            state.loadSimilarBooks(bookID: hit.bookID)
                            showSimilar = true
                        } label: {
                            Image(systemName: "doc.text.magnifyingglass")
                        }
                        .buttonStyle(.bordered)
                        .tint(DS.Color.ink(theme, scheme))
                        .help(L10n.similarBooksTitle)
                        .accessibilityLabel(L10n.similarBooksTitle)
                        .popover(isPresented: $showSimilar) {
                            SimilarBooksListView(bookID: hit.bookID)
                                .frame(width: 380, height: 440)
                        }
                        .padding(DS.Spacing.xxl)
                    }
                }
            } else {
                VStack {
                    Spacer()
                    StatusRow(systemImage: "exclamationmark.octagon.fill",
                              text: L10n.pairingDenied,
                              color: DS.Color.error(theme, scheme), font: .callout)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .contentShape(Rectangle())
        .onHover { pdfAreaHovered = $0 }
    }

    /// TTS：朗读当前页（readerState.currentPage 优先，未落地回退命中页）；
    /// 文本 = 索引库 text_original 只读切片，空文本不启动。
    private func speakCurrentPage(_ hit: SearchHit) {
        let page = readerState.currentPage > 0 ? readerState.currentPage : hit.physicalPage
        guard let text = state.pageOriginalText(bookID: hit.bookID, pageNumber: page) else { return }
        tts.speak(text: text)
    }

    /// AI 回答存为批注（AIPreviewPanel answerCard「存为批注」回调，
    /// 仅已确认入对话的回答显示该按钮）。写入参数归一走 AnnotationPlan：
    /// 有选区 → 锚选区（add），无选区 → 锚当前页整页批注（addPageNote）；
    /// note = [AI] 前缀 + 回答全文（含引用行），颜色复用现有四色（黄），
    /// viewSource 跟随当前阅读视图。成功后 highlightsVersion+1 —— 批注面板
    /// 与书内列表即时刷新。失败返回明确文案（store 缺失/页码未落地不静默）。
    private func saveAIAnswerAsAnnotation(_ answer: String, hit: SearchHit) -> String {
        assert(Thread.isMainThread, "annotation writes must run on the main thread")
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return L10n.annotationAIEmpty }
        guard let store = state.highlightStore, !hit.bookID.isEmpty else {
            return L10n.annotationsStoreUnavailable
        }
        let selection = readerState.selectionInfo
        let selectionText = selection != nil ? readerState.pdfView?.currentSelection?.string : nil
        let viewSource = showOriginalForOCR ? HighlightStore.viewSourceOriginal : HighlightStore.viewSourceOCR
        guard let plan = AnnotationPlan.make(selectionPage: selection?.pageNumber,
                                             selectionRange: selection?.utf16Range,
                                             selectionText: selectionText,
                                             currentPage: readerState.currentPage,
                                             note: AnnotationPlan.aiNotePrefix + answer,
                                             viewSource: viewSource) else {
            return L10n.annotationsPageUnavailable
        }
        do {
            if plan.isPageNote {
                _ = try store.addPageNote(bookID: hit.bookID, pageNumber: plan.pageNumber,
                                          note: plan.note, viewSource: plan.viewSource)
            } else {
                _ = try store.add(bookID: hit.bookID, pageNumber: plan.pageNumber,
                                  utf16Start: plan.utf16Start, utf16End: plan.utf16End,
                                  color: .yellow, note: plan.note,
                                  anchorText: plan.anchorText, viewSource: plan.viewSource)
            }
            state.highlightsVersion &+= 1
            return L10n.annotationAISaved
        } catch {
            return L10n.annotationsStoreUnavailable
        }
    }

    /// 历史回跳/前进：弹栈取目标页，当前页自动压入对侧栈（栈内负责）；
    /// 越界/缺文档 fail-closed 不动。go(to:) 触发的 PageChanged 通知会照常
    /// 持久阅读位置并刷新阅读器桥 currentPage。
    private enum HistoryDirection { case back, forward }

    private func navigateHistory(_ direction: HistoryDirection) {
        guard let view = readerState.pdfView, let document = view.document else { return }
        let current = readerState.currentPage
        let target = direction == .back
            ? readerState.history.goBack(from: current)
            : readerState.history.goForward(from: current)
        guard let target, target >= 1, target <= document.pageCount,
              let page = document.page(at: target - 1) else { return }
        view.go(to: page)
    }

    /// 锁定高亮锚点：当前页与 nil 间切换，Option 点击返回键或右键菜单
    /// 触发；持久化走 ReadingPositionStore 同款 JSON（页/缩放/双页不动）。
    private func toggleAnchor(_ hit: SearchHit) {
        let current = readerState.currentPage
        guard current >= 1 else { return }
        let next: Int? = readerState.anchorPage == nil ? current : nil
        readerState.anchorPage = next
        state.readingPositions.save(anchorPage: next, for: hit.bookID)
    }

    /// 引文高亮：把引文文本写进文内搜索，标出并滚到首个命中，然后清掉
    /// 一次性请求（避免换书/重复触发）。只作用于本书。

    /// 双页对开落盘：改 PDFView.displayMode（nil/未加载则跳过），页/缩放
    /// 取当前视图实况与存量合并——只改 twoPage，不冲掉既有 page/scale。
    private func applyTwoPageSpread(_ twoPage: Bool, hit: SearchHit) {        let mode: PDFDisplayMode = twoPage ? .twoUpContinuous : .singlePageContinuous
        guard let view = readerState.pdfView, view.document != nil else { return }
        view.displayMode = mode
        let existing = state.readingPositions.position(for: hit.bookID)
        let page = view.currentPage
            .flatMap { view.document?.index(for: $0) }
            .map { $0 + 1 } ?? existing?.page ?? 1
        let scale = view.scaleFactor > 0 ? Double(view.scaleFactor) : existing?.scale ?? 1
        state.readingPositions.save(page: page, scale: scale, twoPage: twoPage, for: hit.bookID)
    }

    /// 守卫信息注入（docs/VISUAL-DESIGN.md，判定顺序写死）：staleReference 红条 →
    /// OCR 说明行 → 配对缺失拒绝；nil 才允许浮层自动隐退。
    private func guardInfo(for hit: SearchHit, spec: HitRouter.OpenSpec?) -> GuardInfo? {
        if staleReference { return .staleReference }
        if hit.source == "ocr" { return .ocrNotice }
        if spec == nil { return .pairingDenied }
        return nil
    }

    private func stepThroughBookHits(_ hit: SearchHit, _ delta: Int) {
        let full = state.bookFullHits[hit.bookID] ?? []
        let bookHits = state.sourceFilter.isEmpty ? full : full.filter { $0.source == state.sourceFilter }
        guard let idx = bookHits.firstIndex(where: { AppState.key(for: $0) == AppState.key(for: hit) })
        else { return }
        let next = idx + delta
        guard bookHits.indices.contains(next) else { return }
        Task { await state.select(hit: bookHits[next]) }
    }


    private var metadataSheet: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Text(L10n.metadataNote)
                .font(DS.Font.displaySection)
                .foregroundStyle(DS.Color.ink(theme, scheme))
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                HStack(spacing: DS.Spacing.xs) {
                    TextField(L10n.metaFieldTitle, text: $state.metaEditTitle).textFieldStyle(.dsTextField)
                    TextField(L10n.metaFieldAuthor, text: $state.metaEditAuthor).textFieldStyle(.dsTextField)
                }
                HStack(spacing: DS.Spacing.xs) {
                    TextField(L10n.metaFieldVersion, text: $state.metaEditVersion).textFieldStyle(.dsTextField)
                    TextField(L10n.metaFieldLanguage, text: $state.metaEditLanguage).textFieldStyle(.dsTextField)
                    Button(L10n.bookSaveMeta) { state.saveMetadataEdits() }
                    Button(L10n.importSidecar) { state.importSidecar() }
                }
                if let msg = state.metaEditMessage {
                    Text(msg).font(.caption).foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                }
            }
            .font(.callout)
        }
        .padding(DS.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


/// 相似文档列表（阅读器侧 popover；DEVONthink See Also 形态启发，
/// 单库限定天然成立）。数据由 AppState.loadSimilarBooks 装载（进程内缓存）。
struct SimilarBooksListView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dsTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let bookID: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(L10n.similarBooksTitle).font(DS.Font.displaySection)
            if state.similarLoading {
                Text(L10n.similarBooksLoading).font(.caption)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            } else if state.similarBooks.isEmpty {
                Text(L10n.similarBooksEmpty).font(.caption)
                    .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            }
            ForEach(state.similarBooks) { similar in
                HStack(spacing: DS.Spacing.xs) {
                    Text(similar.title ?? similar.fileName)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer(minLength: DS.Spacing.xs)
                    Text(L10n.similarScore(similar.score))
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                }
                .padding(.vertical, 1)
                .overlay(alignment: .bottom) { Hairline() }
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.md)
        .onAppear { state.loadSimilarBooks(bookID: bookID) }
    }
}
