import SwiftUI
import AppKit
import LiteratureSearchUI

/// Guard states that keep the reading chrome permanently visible
/// (docs/VISUAL-DESIGN.md contract): `guardInfo != nil` ⇒ the
/// whole floating bar never retreats — "守卫信息永不隐退" is structural, not
/// a special case inside the fade logic.
enum GuardInfo: Equatable {
    case staleReference
    case ocrNotice
    case pairingDenied
}

private let chromeDividerHeight: CGFloat = 14
private let keyboardActivityWindow: TimeInterval = 2

/// Floating navigation chrome over the PDF area (Sioyek-style retreat,
/// docs/VISUAL-DESIGN.md): `surface` material + 1px `stroke` hairline + `small`
/// radius, pinned 8pt below the top of the PDF area.
struct ReadingChrome: View {
    let guardInfo: GuardInfo?
    let sourceBadge: String
    let isOCRSource: Bool
    let title: String
    let pageTrackText: String
    let ocrPage: Int?
    let physicalPage: Int
    @Binding var showOriginalForOCR: Bool
    @Binding var docQuery: String
    @Binding var docSearchToken: Int
    @Binding var docSearchCursor: Int
    @Binding var docSearchCount: Int
    @Binding var matchCursor: Int
    let pageMatchTotal: Int
    let aiSectionVisible: Bool
    @Binding var aiSectionExpanded: Bool
    /// 专注阅读：toggle 专注模式（RootView 切 detailOnly 列可见性）。
    @Binding var focusReading: Bool
    let onOpenMetadata: () -> Void
    let onBookStep: (Int) -> Void
    let onClose: () -> Void
    var pdfAreaHovered: Binding<Bool>
    /// 缩略图栏收起/展开（左缘内嵌 PDFThumbnailView，常驻可见）。
    @Binding var showThumbnails: Bool
    /// 目录侧栏：收起/展开；outlineAvailable = 当前文档有书签（无目录书
    /// 按钮整块不渲染）。
    @Binding var showOutline: Bool
    let outlineAvailable: Bool
    /// 侧边批注面板收起/展开（右缘内嵌抽屉；偏好由面板侧
    /// @AppStorage("showAnnotations") 落）。
    @Binding var showAnnotations: Bool
    /// 双页对开：单页连续 ⇄ 双页连续（偏好随阅读位置常驻持久）。
    @Binding var twoPageSpread: Bool
    /// TTS：朗读中状态 + 朗读此页/停止动作（纯本地 AVSpeechSynthesizer）。
    let ttsSpeaking: Bool
    let onSpeakPage: () -> Void
    let onStopSpeak: () -> Void
    /// 历史回跳：栈空禁用态（按钮 disabled 随栈空/满）+ 前后导航动作。
    /// Option 点击「返回上一位置」= 锁定/取消当前页锚点（Sioyek 经验）。
    let canGoBack: Bool
    let canGoForward: Bool
    let anchorActive: Bool
    let onHistoryBack: () -> Void
    let onHistoryForward: () -> Void
    let onToggleAnchor: () -> Void
    /// 概览弹窗（⌘O：当前 PDF 页面九宫格，点击跳页并关闭）。
    @Binding var showOverview: Bool
    /// 快照托盘（会话内浮动窗计数/标题镜像＋前置/全部关闭动作）。
    let snapshotCount: Int
    let snapshotTitles: [String]
    let onRaiseSnapshot: (Int) -> Void
    let onCloseAllSnapshots: () -> Void
    /// 窗口期就地说明（红条旁）——非 nil 且当前处于
    /// staleReference 守卫时，在红条下方追加一行「指纹提示属预期状态」。
    /// 缺省 nil（其余调用面零改动）。
    var windowPeriodNote: String? = nil

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue

    /// 增强对比度级别（双通道合成，DSContrastInjection 注入）。
    @Environment(\.dsContrastLevel) private var contrastLevel
    @State private var visible = true
    @State private var chromeHovered = false
    @State private var hideTask: Task<Void, Never>?
    @State private var escMonitor: Any?
    @State private var keyActivityMonitor: Any?
    @State private var lastKeyboardActivity = Date.distantPast
    @FocusState private var docSearchFocused: Bool

    private var theme: DS.Theme { .storage(dsTheme) }

    /// The single gate for auto-retreat: no guard info AND VoiceOver off.
    private var autoHideAllowed: Bool {
        guardInfo == nil && !NSWorkspace.shared.isVoiceOverEnabled
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                chromeCard(availableWidth: proxy.size.width)
                    .padding(.top, DS.Spacing.xs)
                    .padding(.horizontal, DS.Spacing.md)
                miniMatchCapsule
                    .opacity(visible ? 0 : 1)
                    .allowsHitTesting(!visible)
                    .accessibilityHidden(visible)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottomTrailing)
                    .padding(.trailing, DS.Spacing.sm)
                    .padding(.bottom, DS.Spacing.sm)
            }
        }
        .onHover { hovering in
            chromeHovered = hovering
            pointerActivityChanged()
        }
        .onAppear {
            pointerActivityChanged()
            installKeyboardMonitors()
        }
        .onDisappear {
            hideTask?.cancel()
            if let monitor = escMonitor {
                NSEvent.removeMonitor(monitor)
                escMonitor = nil
            }
            if let monitor = keyActivityMonitor {
                NSEvent.removeMonitor(monitor)
                keyActivityMonitor = nil
            }
        }
        .onChange(of: guardInfo) { _ in
            // Timer discipline: a guard appearing cancels any pending hide
            // instantly; a guard clearing re-times under the normal rules.
            hideTask?.cancel()
            if guardInfo != nil {
                visible = true
            } else {
                scheduleHideIfPointerAway()
            }
        }
        .onChange(of: pdfAreaHovered.wrappedValue || chromeHovered) { _ in
            pointerActivityChanged()
        }
        .onChange(of: docSearchFocused) { _ in
            // Focus leaving the bar re-times the retreat; focus entering
            // cancels it, mirroring the pointer-enter path.
            pointerActivityChanged()
        }
        // Reduce Motion (docs/VISUAL-DESIGN.md 注记): the retreat is opacity-only — no
        // translation/scale exists anywhere in this chrome — and with the
        // accessibility setting on even the opacity timing animation is
        // dropped (instant show/hide, opacity remains the sole channel).
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: visible)
    }

    // MARK: Fade logic

    private func pointerActivityChanged() {
        hideTask?.cancel()
        if pdfAreaHovered.wrappedValue || chromeHovered {
            visible = true
        } else {
            scheduleHideIfPointerAway()
        }
    }

    private func scheduleHideIfPointerAway() {
        hideTask?.cancel()
        guard autoHideAllowed,
              !(pdfAreaHovered.wrappedValue || chromeHovered),
              !docSearchFocused,
              Date().timeIntervalSince(lastKeyboardActivity) >= keyboardActivityWindow
        else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            visible = false
        }
    }

    // MARK: ESC — resign the doc-search field only, never close the chrome.
    //
    // A local .keyDown monitor (not .onExitCommand, which would swallow the
    // system cancel): ESC is consumed only when a text field holds the first
    // responder. ⌘G/⇧⌘G live on the chevron buttons' registeredShortcut and
    // are untouched.
    // 豁免：本 monitor 是系统 ESC 语义（first responder 退场），非
    // 实键绑定，不进 keybindings 注册表。

    private func installKeyboardMonitors() {
        guard escMonitor == nil, keyActivityMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53,
                  NSApp.keyWindow?.firstResponder is NSText else { return event }
            NSApp.keyWindow?.makeFirstResponder(nil)
            return nil
        }
        keyActivityMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            lastKeyboardActivity = Date()
            hideTask?.cancel()
            visible = true
            return event
        }
    }

    // MARK: Chrome card

    @ViewBuilder
    private func chromeCard(availableWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            if availableWidth >= DS.Layout.chromeWrapThreshold {
                HStack(spacing: DS.Spacing.xs) {
                    sourceCapsule
                    Text(title)
                        // 衬线落地：详情页头书名进 display serif 字阶。
                        .font(DS.Font.displayGroup)
                        .foregroundStyle(DS.Color.ink(theme, scheme, contrastLevel))
                        .lineLimit(1)
                    Spacer(minLength: DS.Spacing.xs)
                    modeButtons
                    closeButton
                }
                HStack(spacing: DS.Spacing.xs) {
                    Text(pageTrackText)
                        .font(.caption)
                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme, contrastLevel))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            } else {
                // 窄窗（< 阈值）：来源胶囊与页码轨合并一行（书名低优先级
                // 截断，守卫行保持独立），搜索行与导航行各自折行。
                HStack(spacing: DS.Spacing.xs) {
                    sourceCapsule
                    Text(pageTrackText)
                        .font(.caption)
                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme, contrastLevel))
                        .lineLimit(1)
                    Text(title)
                        // 衬线落地：详情页头书名进 display serif 字阶。
                        .font(DS.Font.displayGroup)
                        .lineLimit(1)
                        .layoutPriority(-1)
                    Spacer(minLength: DS.Spacing.xs)
                    modeButtons
                    closeButton
                }
            }
            if isOCRSource {
                ocrNoticeRow
            } else {
                Text(L10n.viewingOriginal)
                    .font(.caption)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }
            if guardInfo == .staleReference {
                StatusRow(systemImage: "exclamationmark.octagon.fill",
                          text: L10n.staleReference,
                          color: DS.Color.error(theme, scheme), font: .callout)
                // 红条旁就地说明：仅窗口期活跃时出现（调用方判定）。
                if let note = windowPeriodNote {
                    StatusRow(systemImage: "arrow.triangle.2.circlepath.circle",
                              text: note,
                              color: DS.Color.warning(theme, scheme), font: .caption)
                }
            }
            if guardInfo == .pairingDenied {
                StatusRow(systemImage: "exclamationmark.octagon.fill",
                          text: L10n.pairingDenied,
                          color: DS.Color.error(theme, scheme), font: .callout)
            }
            if availableWidth >= DS.Layout.chromeWrapThreshold {
                HStack(spacing: DS.Spacing.sm) {
                    docSearchControls
                    Spacer(minLength: DS.Spacing.xs)
                    matchControls
                }
            } else {
                // 窄窗（< 阈值）：搜索行与导航行各自折行，仍贴顶部 8px。
                docSearchControls
                matchControls
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xs)
        .background(DS.Color.surface(theme),
                    in: RoundedRectangle(cornerRadius: DS.Radius.small))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.small)
            .stroke(DS.Color.stroke(theme, scheme), lineWidth: 1))
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .accessibilityHidden(!visible)
        .accessibilityElement(children: .contain)
    }

    private var sourceCapsule: some View {
        CapsuleBadge(text: sourceBadge,
                     color: isOCRSource
                         ? DS.Color.ocr(theme, scheme)
                         : DS.Color.inkSecondary(theme, scheme))
            .accessibilityLabel(sourceBadge)
    }

    /// 模式按钮组（专注阅读 toggle 常驻；元数据/AI 折叠入口在专注模式下
    /// 隐藏——专注即收起一切非 PDF 内容）。缩略图 toggle 与朗读按钮组
    /// 为阅读辅助，专注模式下同样常驻。目录/双页对开同为阅读辅助，
    /// 与缩略图并列常驻（目录仅在文档有书签时渲染）。
    @ViewBuilder
    private var modeButtons: some View {
        HStack(spacing: DS.Spacing.xxs) {
            historyBackButton
            historyForwardButton
            overviewButton
            snapshotTrayButton
            focusButton
            outlineButton
            annotationButton
            thumbnailButton
            twoPageButton
            ttsControls
            if !focusReading {
                Button(action: onOpenMetadata) {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(L10n.metadataOpenButton)
                .accessibilityLabel(L10n.metadataOpenButton)
                if aiSectionVisible {
                    Button {
                        withAnimation(.easeInOut(duration: DS.Motion.duration)) { aiSectionExpanded.toggle() }
                    } label: {
                        Image(systemName: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(L10n.aiSectionTitle)
                    .accessibilityLabel(L10n.aiSectionTitle)
                }
            }
        }
    }

    /// 侧边批注面板 toggle（右缘内嵌抽屉；SF Symbol 系统批注类
    /// 图标 note.text；开合偏好由 DetailChromeView 侧 @AppStorage 落）。
    private var annotationButton: some View {
        Button {
            showAnnotations.toggle()
        } label: {
            Image(systemName: "note.text")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(L10n.annotationsToggle)
        .accessibilityLabel(L10n.annotationsToggle)
    }

    /// 历史回跳按钮组：返回（⌘[，栈空禁用；Option 点击或右键菜单 =
    /// 锁定/取消当前页锚点，锚定后图标变填充态给出常驻反馈）+ 前进（⌘]）。
    private var historyBackButton: some View {
        Button {
            if NSEvent.modifierFlags.contains(.option) {
                onToggleAnchor()
            } else {
                onHistoryBack()
            }
        } label: {
            Image(systemName: anchorActive ? "chevron.left.circle.fill" : "chevron.left")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!canGoBack)
        .registeredShortcut("historyBack", context: "reader")
        .help(L10n.historyBack)
        .accessibilityLabel(L10n.historyBack)
        .contextMenu {
            Button(anchorActive ? L10n.historyUnlockPosition : L10n.historyLockPosition) {
                onToggleAnchor()
            }
        }
    }

    private var historyForwardButton: some View {
        Button(action: onHistoryForward) {
            Image(systemName: "chevron.right")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!canGoForward)
        .registeredShortcut("historyForward", context: "reader")
        .help(L10n.historyForward)
        .accessibilityLabel(L10n.historyForward)
    }

    /// 概览弹窗入口（⌘O）：当前 PDF 页面缩略九宫格，点击跳页并关闭。
    private var overviewButton: some View {
        Button {
            showOverview.toggle()
        } label: {
            Image(systemName: "square.grid.3x3")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        // reader 域 ⌘O 与 app 域 openFolder 同键不同 context（注册表分域求值）。
        .registeredShortcut("overview", context: "reader")
        .help(L10n.overviewToggle)
        .accessibilityLabel(L10n.overviewToggle)
    }

    /// 快照托盘（overviewButton 邻位；count>0 显示计数徽标，点开
    /// popover 列本会话快照窗——行「前置」＋底部「全部关闭」；零窗如实空态）。
    /// 无键位绑定（托盘为点按面），不进注册表。
    @State private var showSnapshotTray = false

    private var snapshotTrayButton: some View {
        Button {
            showSnapshotTray.toggle()
        } label: {
            Image(systemName: "camera.on.rectangle")
                .overlay(alignment: .topTrailing) {
                    if snapshotCount > 0 {
                        Text("\(snapshotCount)")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                            .padding(2.5)
                            .background(Circle().fill(DS.Color.ink(theme, scheme)))
                            .offset(x: 7, y: -7)
                            .accessibilityHidden(true) // 装饰：计数入 accessibilityValue 述（纪律）
                    }
                }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityValue(snapshotCount > 0
                            ? L10n.snapshotTrayCount(snapshotCount)
                            : L10n.snapshotTrayEmpty)
        .help(L10n.snapshotTrayTitle)
        .accessibilityLabel(L10n.snapshotTrayTitle)
        .popover(isPresented: $showSnapshotTray, arrowEdge: .top) {
            SnapshotTrayList(titles: snapshotTitles,
                             onRaise: onRaiseSnapshot,
                             onCloseAll: onCloseAllSnapshots)
                .frame(width: 300)
        }
    }

    private var focusButton: some View {        Button {
            focusReading.toggle()
        } label: {
            Image(systemName: focusReading
                  ? "rectangle.compress.vertical"
                  : "rectangle.expand.vertical")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(focusReading ? L10n.focusReadingExit : L10n.focusReadingEnter)
        .accessibilityLabel(focusReading ? L10n.focusReadingExit : L10n.focusReadingEnter)
    }

    /// 缩略图 toggle（左缘内嵌 PDFThumbnailView，宽 120，可收起）。
    private var thumbnailButton: some View {
        Button {
            showThumbnails.toggle()
        } label: {
            Image(systemName: "sidebar.left")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(L10n.thumbnailsToggle)
        .accessibilityLabel(L10n.thumbnailsToggle)
    }

    /// 目录侧栏 toggle：当前文档无书签（readerState.outline 空）时整块
    /// 不渲染——无目录的书看不到「目录」按钮。
    @ViewBuilder
    private var outlineButton: some View {
        if outlineAvailable {
            Button {
                showOutline.toggle()
            } label: {
                Image(systemName: "list.bullet.indent")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(L10n.outlineToggle)
            .accessibilityLabel(L10n.outlineToggle)
        }
    }

    /// 双页对开 toggle：单页连续 ⇄ 双页连续；help/label 随态切换，
    /// 偏好点按即存（displayMode 变更无系统通知，不走翻页落盘）。
    private var twoPageButton: some View {
        Button {
            twoPageSpread.toggle()
        } label: {
            Image(systemName: twoPageSpread
                  ? "rectangle.split.2x1.fill"
                  : "rectangle.split.2x1")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(twoPageSpread ? L10n.twoPageExit : L10n.twoPageEnter)
        .accessibilityLabel(twoPageSpread ? L10n.twoPageExit : L10n.twoPageEnter)
    }

    /// 朗读按钮组：未朗读 = 「朗读此页」；朗读中 = 「停止」+ 状态 caption。
    @ViewBuilder
    private var ttsControls: some View {
        if ttsSpeaking {
            HStack(spacing: DS.Spacing.xxs) {
                Button(action: onStopSpeak) {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(L10n.ttsStop)
                .accessibilityLabel(L10n.ttsStop)
                Text(L10n.ttsSpeaking)
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    .accessibilityLabel(L10n.ttsSpeaking)
            }
        } else {
            Button(action: onSpeakPage) {
                Image(systemName: "speaker.wave.2")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(L10n.ttsSpeak)
            .accessibilityLabel(L10n.ttsSpeak)
        }
    }

    private var closeButton: some View {
        Button(L10n.closePDF, action: onClose)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(L10n.closePDFButton)
    }

    /// OCR 说明行（琥珀 caption，合法琥珀位）+ 原件/OCR 切换按钮。
    @ViewBuilder
    private var ocrNoticeRow: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text(showOriginalForOCR
                 ? L10n.viewingOriginalPage(physicalPage)
                 : L10n.viewingOCRPage(ocrPage ?? 0))
                .font(.caption)
                .foregroundStyle(DS.Color.ocr(theme, scheme))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Spacing.xs)
            Button(showOriginalForOCR ? L10n.backToOCRView : L10n.openOriginalPage) {
                showOriginalForOCR.toggle()
            }
            .font(.caption)
        }
    }

    // MARK: In-document search row (Sioyek-style; ⌘G/⇧⌘G preserved verbatim)

    @ViewBuilder
    private var docSearchControls: some View {
        HStack(spacing: DS.Spacing.xs) {
            TextField(L10n.docSearchPlaceholder, text: $docQuery)
                .textFieldStyle(.dsTextField)
                .font(.caption)
                .frame(minWidth: 120, maxWidth: 220)
                .focused($docSearchFocused)
                .onSubmit { docSearchToken += 1 }
            Button(L10n.docSearchRun) { docSearchToken += 1 }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(docQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            if docSearchCount > 0 {
                Text(L10n.docSearchOccurrence(min(docSearchCursor + 1, docSearchCount), docSearchCount))
                    .font(.caption)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    .monospacedDigit()
                Button {
                    docSearchCursor = (docSearchCursor - 1 + docSearchCount) % docSearchCount
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .registeredShortcut("docSearchPrev", context: "reader")
                .help(L10n.shortcutPrevMatch)
                .accessibilityLabel(L10n.docSearchPrevButton)
                Button {
                    docSearchCursor = (docSearchCursor + 1) % docSearchCount
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .registeredShortcut("docSearchNext", context: "reader")
                .help(L10n.shortcutNextMatch)
                .accessibilityLabel(L10n.docSearchNextButton)
            } else if !docQuery.isEmpty && docSearchToken > 0 {
                Text(L10n.docSearchNoMatch)
                    .font(.caption)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }
        }
    }

    // MARK: Match navigation (page-internal cycle + book-level stepping)

    @ViewBuilder
    private var matchControls: some View {
        let total = pageMatchTotal
        let clamped = min(matchCursor, total - 1)
        HStack(spacing: DS.Spacing.xs) {
            Text(L10n.pageMatchCounter(clamped + 1, total))
                .font(.caption)
                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                .monospacedDigit()
            Button {
                matchCursor = (clamped - 1 + total) % total
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(total <= 1)
            .accessibilityLabel(L10n.prevMatchButton)
            Button {
                matchCursor = (clamped + 1) % total
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(total <= 1)
            .accessibilityLabel(L10n.nextMatchButton)
            // 页内循环与书级步进之间用系统竖分隔条（浮层控件内部，同菜单
            // 内部保留系统 Divider 的豁免）。
            Divider().frame(height: chromeDividerHeight)
            Button(L10n.prevHit) { onBookStep(-1) }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button(L10n.nextHit) { onBookStep(1) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    // MARK: Resident mini capsule ("命中 k/N") shown while the chrome fades

    private var miniMatchCapsule: some View {
        let total = pageMatchTotal
        let clamped = min(matchCursor, total - 1)
        return Button {
            // Same restore path as pointer-enter: cancel the retreat, show.
            hideTask?.cancel()
            visible = true
        } label: {
            Text(L10n.pageMatchCounter(clamped + 1, total))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.vertical, DS.Spacing.xxs)
                .background(DS.Color.surface(theme), in: Capsule())
                .overlay(Capsule().stroke(DS.Color.stroke(theme, scheme), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.showReadingChrome)
    }
}

/// 快照托盘 popover（本会话快照窗列表：行「前置」＋「全部关闭」；
/// 零窗如实空态）。纯展示——窗口生命周期全在 SnapshotWindowController。
private struct SnapshotTrayList: View {
    @Environment(\.colorScheme) private var scheme
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue
    let titles: [String]
    let onRaise: (Int) -> Void
    let onCloseAll: () -> Void

    var body: some View {
        let theme = DS.Theme.storage(dsTheme)
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(L10n.snapshotTrayTitle)
                .font(.caption)
                .foregroundStyle(DS.Color.ink(theme, scheme))
            if titles.isEmpty {
                Text(L10n.snapshotTrayEmpty)
                    .font(.caption)
                    .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            } else {
                ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                    Button {
                        onRaise(index)
                    } label: {
                        HStack(spacing: DS.Spacing.xs) {
                            Image(systemName: "photo")
                                .font(.caption2)
                                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                                .accessibilityHidden(true) // 装饰：行文字语义自述（纪律）
                            Text(title)
                                .font(.caption)
                                .foregroundStyle(DS.Color.ink(theme, scheme))
                                .lineLimit(1)
                            Spacer(minLength: DS.Spacing.xs)
                            Text(L10n.snapshotTrayRaise)
                                .font(.caption2)
                                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(title)
                    .accessibilityHint(L10n.snapshotTrayRaise)
                }
                Divider()
                Button(L10n.snapshotCloseAll) { onCloseAll() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(DS.Spacing.sm)
    }
}
