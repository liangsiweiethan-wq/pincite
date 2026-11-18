import SwiftUI
import PDFKit
import PencilKit

// MARK: - 阅读器 Chrome
//
// 装配纪律：WritingCapability.isWritable == false（iPhone）时
// 批注/涂画/调色板入口整体不构建——只读不是禁用态，是不存在。
// 「存到 Mac」（选区文本）全设备可用（与读写约束无关）。

struct ReaderChromeView: View {
    let book: IndexStore.BookRow
    let pdfURL: URL

    @EnvironmentObject var model: LibraryModel
    @EnvironmentObject var appModel: IOSAppModel
    @State private var pageNumber = 1
    @State private var pageCount = 0
    @State private var selectionText: String?
    @State private var annotating = false
    @State private var showPalette = false
    @State private var selection = InkToolSelection.paletteDefault
    @State private var session = InkSessionStack()
    @State private var shareMessage = ""
    @State private var exportURL: URL?
    /// 当前页在 PDFView 坐标系中的矩形（ReaderView 发布；叠绘渲染与
    /// canvas 采样共用—— 双态交接坐标地基）。
    @State private var pageViewport: InkGeometry.PageViewport?

    var body: some View {
        ZStack {
            ReaderView(pdfURL: pdfURL,
                       pageNumber: $pageNumber,
                       onSelectionChange: { selectionText = $0 },
                       onPageChange: { page in recordProgressAndMaybePush(page: page) },
                       onPageViewportChange: { _, viewport in pageViewport = viewport })
            if let strokes = model.strokes {
                InkOverlayLayer(book: book, pageNumber: pageNumber,
                                strokesStore: strokes, viewport: pageViewport,
                                session: session)
            }
            if WritingCapability.isWritable && annotating {
                AnnotationCanvasView(book: book, pageNumber: pageNumber,
                                     selection: selection,
                                     pageViewport: pageViewport,
                                     session: $session,
                                     strokesStore: model.strokes)
            }
        }
        .safeAreaInset(edge: .bottom) { chromeBar }
        .onDisappear {
            // 离开阅读器补记最终页（同走 60s 节流，不绕过推送纪律）。
            recordProgressAndMaybePush(page: pageNumber)
        }
        .sheet(item: $exportURL) { url in
            ActivitySheetCompat(items: [url])
        }
    }

    /// 翻页/离开 → 记单槽进度 + 节流推送（60s 一次；显式事件，
    /// 无轮询）。进度是本机偏好数据：不进 annotations.db、不进
    /// 索引库、不写原件。页数取书目物理页数（IndexStore 同
    private func recordProgressAndMaybePush(page: Int) {
        let record = ReadingProgressRecord(
            bookID: book.id,
            bookTitle: book.title ?? book.fileName,
            bookFileName: book.fileName,
            page: page,
            pageCount: max(book.pageCount, page),
            updatedAt: Date())
        ReadingProgressRecorder.record(record)
        guard WatchCompanion.shouldPush(lastPush: ReadingProgressRecorder.lastCompanionPushAt,
                                        now: Date()) else { return }
        appModel.pushWatchCompanion(library: model)
    }

    private var chromeBar: some View {
        VStack(spacing: 4) {
            if !shareMessage.isEmpty {
                Text(shareMessage).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text(L10n.iosReaderPage(pageNumber, max(pageCount, pageNumber)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
// 选区四色高亮（iPad 可写；选区存在时才可用——遵循
// view_source='original' 语义，写 annotations.db）。
                if WritingCapability.isWritable {
                    ForEach(InkToolSelection.primaryColors, id: \.self) { hex in
                        Button {
                            addHighlight(colorHex: hex)
                        } label: {
                            Circle().fill(Color(hex: hex)).frame(width: 18, height: 18)
                        }
                        .buttonStyle(.borderless)
                        .disabled(selectionText == nil)
                    }
                }
                // 「存到 Mac」 ：选区文本经 WebDAV inbox 回 Mac。
                Button {
                    shareSelectionToMac()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .disabled(selectionText == nil)
                // 批注/涂画入口：只由 WritingCapability 决定装配。
                if WritingCapability.isWritable {
                    // 撤销/重做：方向感知——撤销画笔
                    // = 补墓碑、撤销擦除 = 解墓碑（InkSessionStack.undoOp）。
                    Button {
                        undoInk()
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(session.undoOps.isEmpty)
                    Button {
                        redoInk()
                    } label: {
                        Image(systemName: "arrow.uturn.forward.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(session.redoOps.isEmpty)
                    Button {
                        annotating.toggle()
                        showPalette = annotating
                    } label: {
                        Image(systemName: annotating ? "pencil.tip.crop.circle.badge.checkmark" : "pencil.tip")
                    }
                    .buttonStyle(.borderless)
                }
                Button {
                    exportBundle()
                } label: {
                    Image(systemName: "square.and.arrow.down.on.square")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            if WritingCapability.isWritable && annotating && showPalette {
                AnnotationPaletteView(selection: $selection)
            }
        }
    }

    // MARK: 动作

    /// 撤销：方向感知回退——draw 补墓碑、erase 解墓碑。
    private func undoInk() {
        guard let store = model.strokes, let op = session.undoOp() else { return }
        inkStoreOp(kind: op.kind, strokeUUID: op.strokeUUID, reverse: false)
    }

    /// 重做：与撤销反向——draw 解墓碑恢复、erase 补墓碑再删。
    private func redoInk() {
        guard let store = model.strokes, let op = session.redoOp() else { return }
        inkStoreOp(kind: op.kind, strokeUUID: op.strokeUUID, reverse: true)
    }

    private func inkStoreOp(kind: InkSessionOpKind, strokeUUID: String, reverse: Bool) {
        guard let store = model.strokes else { return }
        do {
            let tombstoning = reverse ? (kind == .erase) : (kind == .draw)
            if tombstoning {
                _ = try store.tombstone(strokeUUID: strokeUUID)
            } else {
                _ = try store.untombstone(strokeUUID: strokeUUID)
            }
        } catch {
            shareMessage = L10n.iosAnnotationFailed(String(describing: error))
        }
    }

    /// 选区四色高亮 → user_highlights（anchor 取选区文本；独立批注库）。
    private func addHighlight(colorHex: String) {
        guard let text = selectionText, let highlights = model.highlights else { return }
        let color = HighlightColor(rawValue: mapColor(hex: colorHex)) ?? .yellow
        do {
            _ = try highlights.add(bookID: book.id, pageNumber: pageNumber,
                                   utf16Start: 0, utf16End: max(text.utf16.count, 1),
                                   color: color, note: "",
                                   anchorText: String(text.prefix(200)),
                                   viewSource: HighlightStore.viewSourceOriginal)
            shareMessage = L10n.iosHighlightSaved
        } catch {
            shareMessage = L10n.iosAnnotationFailed(String(describing: error))
        }
    }

    /// 四色（涂画侧 palette）映射到批注四色语义（yellow/green/blue/red）。
    private func mapColor(hex: String) -> String {
        switch hex {
        case InkToolSelection.primaryColors[1]: return HighlightColor.green.rawValue
        case InkToolSelection.primaryColors[2]: return HighlightColor.blue.rawValue
        case InkToolSelection.primaryColors[3]: return HighlightColor.red.rawValue
        default: return HighlightColor.yellow.rawValue
        }
    }

    /// 选段 → ShareCapture 队列 → WebDAV inbox（手动立即发送）。
    private func shareSelectionToMac() {
        guard let text = selectionText else { return }
        do {
            let capture = ShareCapture(
                text: text,
                sourceLines: ["book: \(book.title ?? book.fileName)", "page: \(pageNumber)"])
            try ShareCapture.enqueue(capture)
            shareMessage = L10n.iosShareQueued
            Task { await flushShareQueue() }
        } catch {
            shareMessage = L10n.iosShareFailed(String(describing: error))
        }
    }

    /// WebDAV 在位时手动发送队列（禁轮询——只在此显式动作触发）。
    private func flushShareQueue() async {
        let cfg = WebDAVSettingsStore().load()
        let storage = SecurityFrameworkKeyStorage(service: SecurityFrameworkKeyStorage.webdavService)
        guard let config = cfg, !config.username.isEmpty,
              let password = try? storage.readKey(account: config.username), !password.isEmpty else {
            await MainActor.run { shareMessage = L10n.iosShareQueuedOffline }
            return
        }
        let username = config.username
        do {
            let client = try WebDAVClient(serverBase: WebDAVClient.validatedBase(config.serverBase),
                                          username: username, password: password)
            let sent = try await ShareCapture.flush(client: client)
            await MainActor.run {
                shareMessage = sent.isEmpty ? L10n.iosShareNothingToSend : L10n.iosShareSent(sent.count)
            }
        } catch {
            await MainActor.run { shareMessage = L10n.iosShareFailed(String(describing: error)) }
        }
    }

    /// 整库导出（含墓碑）→ 出站分享（数据出口）。
    private func exportBundle() {
        do {
            exportURL = try model.exportAnnotationBundle()
            shareMessage = ""
        } catch {
            shareMessage = L10n.iosAnnotationFailed(String(describing: error))
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

// MARK: - 叠绘装配

/// InkOverlayView 的 SwiftUI 桥：按页取活动笔迹 → 页视口渲染。
struct InkOverlayLayer: UIViewRepresentable {
    let book: IndexStore.BookRow
    let pageNumber: Int
    let strokesStore: InkStrokesStore
    let viewport: InkGeometry.PageViewport?
    /// 会话值（Equatable）作墓碑变化信号：undo/redo/擦除后重载。
    let session: InkSessionStack

    func makeUIView(context: Context) -> InkOverlayView {
        InkOverlayView(frame: .zero)
    }

    func updateUIView(_ overlay: InkOverlayView, context: Context) {
        guard let vp = viewport, vp.width > 0, vp.height > 0 else {
            context.coordinator.lastSession = session
            context.coordinator.lastPage = pageNumber
            context.coordinator.lastViewport = nil
            overlay.reload(strokes: [],
                           viewport: InkGeometry.PageViewport(originX: 0, originY: 0, width: 0, height: 0))
            return
        }
        if context.coordinator.lastPage == pageNumber,
           context.coordinator.lastSession == session,
           context.coordinator.lastViewport == vp {
            return   // 三元未变：零重取
        }
        context.coordinator.lastPage = pageNumber
        context.coordinator.lastSession = session
        context.coordinator.lastViewport = vp
        let strokes = (try? strokesStore.strokes(bookID: book.id, pageNumber: pageNumber)) ?? []
        overlay.reload(strokes: strokes, viewport: vp)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastPage = -1
        var lastSession = InkSessionStack()
        var lastViewport: InkGeometry.PageViewport?
    }
}

/// UIActivityViewController 桥（出站分享；范围裁剪允许出站方向）。
struct ActivitySheetCompat: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

extension Color {
    /// #RRGGBB → Color（涂画四色渲染用）。
    init(hex: String) {
        var value: UInt64 = 0
        let body = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        Scanner(string: body).scanHexInt64(&value)
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
