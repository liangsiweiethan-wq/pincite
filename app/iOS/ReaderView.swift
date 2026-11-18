import SwiftUI
import PDFKit

// MARK: - PDF 阅读器
//
// 渲染只读约束：PDFView 不装任何写回入口（annotation 编辑/文件保存一概
// 无）；跳页用物理页 pdfDocument.page(at:)（见 docs/PAGE-BASIS.md，与桌面
// 物理页一致）。选区变化经 Coordinator 回调给 Chrome（「存到 Mac」用）。
//
// 叠绘挂载的坐标地基）：InkHostPDFView 在布局/翻页/
// 缩放后发布「当前页在 PDFView 坐标系中的矩形」（InkGeometry.PageViewport，
// UIKit 惯例原点左上 y 向下）——叠绘层按页渲染、PKCanvasView 采样共用
// 同一视口，双态交接坐标一致（画布整幅 vs 叠绘页矩形的错位根除）。
// 发布是纯读（convert/bounds），无任何写回。

struct ReaderView: UIViewRepresentable {
    let pdfURL: URL
    @Binding var pageNumber: Int
    /// 选区文本回调（nil = 无选区）。
    var onSelectionChange: ((String?) -> Void)?
    /// 翻页回调（进度记录用）。
    var onPageChange: ((Int) -> Void)?
    /// 当前页视口发布。主线程回调。
    var onPageViewportChange: ((Int, InkGeometry.PageViewport?) -> Void)?

    func makeUIView(context: Context) -> InkHostPDFView {
        let view = InkHostPDFView()
        view.document = PDFDocument(url: pdfURL)
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        // 渲染只读：不装任何写回入口（PDFView 默认无 annotation 编辑 UI，
        // 也不提供保存动作——文字选择保留给「存到 Mac」；原件文件本体零写入）。
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.pageChanged),
            name: .PDFViewPageChanged, object: view)
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.selectionChanged),
            name: .PDFViewSelectionChanged, object: view)
        view.onViewportChange = { [weak coordinator = context.coordinator] index, viewport in
            coordinator?.parent.onPageViewportChange?(index, viewport)
        }
        return view
    }

    func updateUIView(_ view: InkHostPDFView, context: Context) {
        context.coordinator.parent = self
        // 外部页码跳转（命中跳页）：物理页语义。
        if let doc = view.document,
           pageNumber > 0, pageNumber <= doc.pageCount,
           let current = view.currentPage,
           doc.index(for: current) != pageNumber - 1,
           let target = doc.page(at: pageNumber - 1) {
            view.go(to: target)   // 物理页（见 docs/PAGE-BASIS.md）
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: ReaderView
        init(_ parent: ReaderView) { self.parent = parent }

        @objc func pageChanged(_ note: Notification) {
            guard let view = note.object as? InkHostPDFView,
                  let doc = view.document,
                  let current = view.currentPage else { return }
            let index = doc.index(for: current) + 1   // 物理 1 起
            parent.pageNumber = index
            parent.onPageChange?(index)
            view.publishViewport()                    // 翻页即重发视口（叠绘重排）
        }

        @objc func selectionChanged(_ note: Notification) {
            guard let view = note.object as? PDFView else { return }
            parent.onSelectionChange?(view.currentSelection?.string)
        }
    }
}

/// PDFView 子类：布局后发布当前页视口。
/// layoutSubviews 覆盖滚动/缩放/翻页后的全部几何变化；节流 = 页索引与
/// 视口都没变就不回调（滚动微移按整数点抖动过滤）。
final class InkHostPDFView: PDFView {
    /// (物理页 1 起, 页矩形视口) 发布回调；nil 视口 = 无文档/无当前页。
    var onViewportChange: ((Int, InkGeometry.PageViewport?) -> Void)?

    private var lastPublishedIndex = -1
    private var lastPublishedViewport: InkGeometry.PageViewport?

    override func layoutSubviews() {
        super.layoutSubviews()
        publishViewport()
    }

    /// 计算并发布当前页视口（主线程；调用方保证）。纯读无写回。
    func publishViewport() {
        guard let onViewportChange else { return }
        guard let doc = document, let page = currentPage else {
            publishIfChanged(index: -1, viewport: nil, to: onViewportChange)
            return
        }
        let index = doc.index(for: page) + 1
        // PDFView 显示 cropBox；页矩形换到 PDFView 坐标（UIKit y 向下）。
        let rect = convert(page.bounds(for: .cropBox), from: page)
        guard rect.width > 1, rect.height > 1, rect.intersection(bounds).height > 0 else {
            publishIfChanged(index: index, viewport: nil, to: onViewportChange)
            return
        }
        let viewport = InkGeometry.PageViewport(
            originX: Double(rect.minX.rounded()),
            originY: Double(rect.minY.rounded()),
            width: Double(rect.width.rounded()),
            height: Double(rect.height.rounded()))
        publishIfChanged(index: index, viewport: viewport, to: onViewportChange)
    }

    private func publishIfChanged(index: Int, viewport: InkGeometry.PageViewport?,
                                  to sink: (Int, InkGeometry.PageViewport?) -> Void) {
        if index == lastPublishedIndex, viewport == lastPublishedViewport { return }
        lastPublishedIndex = index
        lastPublishedViewport = viewport
        sink(index, viewport)
    }
}
