import SwiftUI
import AppKit
import PDFKit
import LiteratureSearchUI

// MARK: - 快照窗口管理

/// AppKit 浮动快照窗管理器（会话内托盘）。线程契约照 ReadingPositionStore
/// 先例：窗口与数组只在主线程触碰（调用点=UI 动作/MainActor.run），不加
/// @MainActor 以保持与 AppState 非隔离层的同步调用通道；以断言守护。
final class SnapshotWindowController: NSObject, NSWindowDelegate, @unchecked Sendable {
    /// 本会话开着的快照窗（顺序＝创建序；托盘展示序）。
    private(set) var windows: [NSWindow] = []
    /// 窗口标题镜像（与 windows 同序；AppState 据此发布托盘列表）。
    private(set) var titles: [String] = []
    /// 托盘计数/标题变化回调（主线程；AppState 发布 @Published 用）。
    var onTrayChanged: ((_ count: Int, _ titles: [String]) -> Void)?
    /// 渲染失败如实回调（不静默；AppState 走既有瞬态回执）。
    var onError: ((String) -> Void)?

    /// 选区 → 独立浮动快照窗。page/cropRatio 来自选区所在页（页坐标系
    /// 比例矩形，SnapshotGeometry.cropRatio 产物）；异步渲染，失败回调
    /// onError（不静默不假称）。
    func makeSnapshot(page: PDFPage, cropRatio: CGRect,
                      sourceTitle: String, pageNumber: Int) {
        assert(Thread.isMainThread, "makeSnapshot must run on the main thread")
        // 渲染像素预算：整页长边 ~1600px（裁剪后清晰度足够对照阅读）。
        let pageBounds = page.bounds(for: .cropBox)
        let budget: CGFloat = 1600
        let longEdge = max(pageBounds.width, pageBounds.height)
        let scale = longEdge > 0 ? budget / longEdge : 1
        let pagePixel = CGSize(width: max(pageBounds.width * scale, 1),
                               height: max(pageBounds.height * scale, 1))
        let targetSize = SnapshotGeometry.cropedImageSize(pagePixel: pagePixel, ratio: cropRatio)
        let title = L10n.snapshotWindowTitle(sourceTitle, pageNumber)
        Task.detached(priority: .userInitiated) { [weak self] in
            // 后台段：只碰入参 PDFPage 与几何，不碰 self 窗口状态。
            let thumbnail = page.thumbnail(of: pagePixel, for: .cropBox)
            guard let full = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                await MainActor.run { [weak self] in
                    self?.onError?(L10n.snapshotRenderFailed)
                }
                return
            }
            let cropRect = CGRect(
                x: (cropRatio.minX * CGFloat(full.width)).rounded(.down),
                y: ((1 - cropRatio.maxY) * CGFloat(full.height)).rounded(.down),
                width: (cropRatio.width * CGFloat(full.width)).rounded(),
                height: (cropRatio.height * CGFloat(full.height)).rounded())
            // CGImage 坐标系原点左下：比例 y 翻转（页坐标原点左上）。
            let clamped = cropRect.intersection(
                CGRect(x: 0, y: 0, width: full.width, height: full.height))
            guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1,
                  let cropped = full.cropping(to: clamped) else {
                await MainActor.run { [weak self] in
                    self?.onError?(L10n.snapshotRenderFailed)
                }
                return
            }
            let targetPixelSize = CGSize(width: targetSize.width, height: targetSize.height)
            await MainActor.run { [weak self] in
                let image = NSImage(cgImage: cropped, size: targetPixelSize)
                self?.presentWindow(image: image, title: title)
            }
        }
    }

    /// 全部前置（托盘动作）。
    func raiseAll() {
        assert(Thread.isMainThread, "raiseAll must run on the main thread")
        for window in windows { window.makeKeyAndOrderFront(nil) }
    }

    /// 按序前置单个（托盘行「前置」）。
    func raise(at index: Int) {
        assert(Thread.isMainThread, "raise must run on the main thread")
        guard windows.indices.contains(index) else { return }
        windows[index].makeKeyAndOrderFront(nil)
    }

    /// 全部关闭（托盘动作；windowWillClose 逐窗出账）。
    func closeAll() {
        assert(Thread.isMainThread, "closeAll must run on the main thread")
        for window in windows { window.performClose(nil) }
    }

    // MARK: 私有：建窗

    private func presentWindow(image: NSImage, title: String) {
        assert(Thread.isMainThread, "presentWindow must run on the main thread")
        let content = SnapshotContentView(image: image, title: title)
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                                  width: max(hosting.fittingSize.width, 260),
                                                  height: max(hosting.fittingSize.height, 320)),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = hosting
        window.setFrameAutosaveName("SnapshotWindow")
        windows.append(window)
        titles.append(title)
        notifyTray()
        window.makeKeyAndOrderFront(nil)
    }

    private func notifyTray() {
        onTrayChanged?(windows.count, titles)
    }

    // MARK: NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        Task { @MainActor [weak self] in
            guard let self, let idx = self.windows.firstIndex(where: { $0 === window }) else { return }
            self.windows.remove(at: idx)
            self.titles.remove(at: idx)
            self.notifyTray()
        }
    }
}

/// 快照窗内容（最小面：图片＋标题行；pageTrack 三轨文本语义由调用方拼在
/// 标题里传入）。纯展示，零交互零写盘。
struct SnapshotContentView: View {
    @Environment(\.colorScheme) private var scheme
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue
    let image: NSImage
    let title: String

    var body: some View {
        let theme = DS.Theme.storage(dsTheme)
        VStack(spacing: DS.Spacing.xxs) {
            Text(title)
                .font(.caption)
                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                .lineLimit(1)
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.top, DS.Spacing.xxs)
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.bottom, DS.Spacing.xxs)
        }
        .background(DS.Color.paper(theme, scheme))
    }
}
