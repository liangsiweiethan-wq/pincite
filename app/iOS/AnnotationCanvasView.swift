import SwiftUI
import PencilKit

// MARK: - PKCanvasView 涂画层

struct AnnotationCanvasView: UIViewRepresentable {
    let book: IndexStore.BookRow
    let pageNumber: Int
    let selection: InkToolSelection
    /// 当前页在 PDFView 坐标系中的矩形（ReaderView 发布；nil = 未布局，
    /// fail-closed 不采样）。原点在视图左上，y 向下（UIKit 惯例）。
    let pageViewport: InkGeometry.PageViewport?
    @Binding var session: InkSessionStack
    let strokesStore: InkStrokesStore?

    /// 橡皮划扫笔（不落库）宽度（视图点；hitTest 阈值见 eraserHitThreshold）。
    static let eraserSwipeWidth: CGFloat = 10
    /// 橡皮命中阈值（视图点）：划扫段到笔迹段距离 ≤ 阈值即整笔墓碑。
    static let eraserHitThreshold: Double = 14

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        // 「.pencilWithErrorFallback」为 iOS 27 SDK
        // 实名 = .pencilOnly（Pencil 优先、防手掌误触——语义同款，如实注记）。
        canvas.drawingPolicy = .pencilOnly
        canvas.backgroundColor = .clear
        canvas.delegate = context.coordinator
        canvas.tool = Self.tool(selection)
        // 已落库笔由叠绘层渲染，画布只承载未落库笔（基线从 0 起）。
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        canvas.tool = Self.tool(selection)
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// InkToolSelection → PKTool（纯映射的 UIKit 侧半边；纯函数本体与
    /// 测试在 Core InkToolSelection.toolPickerConfig）。橡皮映射为全透明
    /// pen：PencilKit 不做原生擦除（会破坏画布追加序与自有库整笔墓碑
    /// 语义），透明笔只负责收集「划掉」轨迹，pen-up 时按 hitTest 结算。
    static func tool(_ selection: InkToolSelection) -> PKTool {
        // hex → UIColor（与 ReaderChromeView.Color(hex:) 同规则）。
        var value: UInt64 = 0
        let body = selection.colorHex.hasPrefix("#") ? String(selection.colorHex.dropFirst()) : selection.colorHex
        Scanner(string: body).scanHexInt64(&value)
        let rgb = UIColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                          green: CGFloat((value >> 8) & 0xFF) / 255,
                          blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        switch selection.tool {
        case .marker:
            return PKInkingTool(.marker, color: rgb, width: selection.lineWidth * 2)
        case .eraser:
            let clear = UIColor(red: 0, green: 0, blue: 0, alpha: 0)
            return PKInkingTool(.pen, color: clear, width: eraserSwipeWidth)
        case .pen:
            return PKInkingTool(.pen, color: rgb, width: selection.lineWidth)
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: AnnotationCanvasView
        private var drawingInProgress = false
        /// 身份结算基线：上次 pen-up 结算后画布内保留的笔数（前缀全部未落库）。
        var settleBaseline = 0

        init(_ parent: AnnotationCanvasView) { self.parent = parent }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !drawingInProgress else { return }
            drawingInProgress = true
            // 笔迹开始（首笔变化）；落点在 pen-up（canvasViewDidEndUsingTool）。
        }

        /// 手势结束（pen-up）：橡皮划扫 → 命中墓碑；否则采样新笔 → 落库
        /// → 身份结算剔除已落库笔（转叠绘——双态交接）。
        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            drawingInProgress = false
            if parent.selection.tool == .eraser {
                eraseBySwipe(canvasView)
            } else {
                persistNewStrokes(canvasView)
            }
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            drawingInProgress = true
        }

        /// 采样一笔 PKStroke → 页相对抽稀点列（视口未就绪 = nil）。
        private func sampledPoints(_ stroke: PKStroke) -> [InkPoint]? {
            guard let vp = parent.pageViewport, vp.width > 0, vp.height > 0 else { return nil }
            let sampled = stroke.path.interpolatedPoints(by: .distance(6))
                .compactMap { point -> InkPoint? in
                    let rel = InkGeometry.pageRelative(viewX: Double(point.location.x),
                                                       viewY: Double(point.location.y), in: vp)
                    // 越界点夹回（store 校验 0-1 同基准；极小越界为浮点噪声）。
                    let clampedX = min(max(rel.x, 0), 1)
                    let clampedY = min(max(rel.y, 0), 1)
                    return InkPoint(x: clampedX, y: clampedY)
                }
            guard sampled.count >= 2 else { return nil }
            return InkGeometry.simplify(points: sampled)
        }

        /// 橡皮「划掉即擦除」——划扫笔不落库；划扫路径逐段命中
        /// 测试本页活动笔迹，命中整笔墓碑（append-only）并入会话栈（.erase）。
        private func eraseBySwipe(_ canvasView: PKCanvasView) {
            guard let store = parent.strokesStore else { return }
            guard let vp = parent.pageViewport, vp.width > 0, vp.height > 0 else { return }
            let all = canvasView.drawing.strokes
            guard settleBaseline <= all.count else { settleBaseline = all.count; return }
            let swipes = Array(all[settleBaseline...])
            guard !swipes.isEmpty else { return }
            let activeStrokes = (try? store.strokes(bookID: parent.book.id,
                                                    pageNumber: parent.pageNumber)) ?? []
            guard !activeStrokes.isEmpty else {
                applySettlement(canvasView, keep: Array(all[..<settleBaseline]))
                return
            }
            for swipe in swipes {
                guard let points = sampledPoints(swipe), points.count >= 2 else { continue }
                for stroke in activeStrokes {
                    for p in points where InkGeometry.hitTest(
                        viewX: vp.originX + p.x * vp.width,
                        viewY: vp.originY + p.y * vp.height,
                        strokePoints: stroke.points,
                        viewport: vp,
                        thresholdPoints: AnnotationCanvasView.eraserHitThreshold) {
                        // 命中即整笔墓碑；tombstone 幂等（已墓碑 false 不重复记栈）。
                        if (try? store.tombstone(strokeUUID: stroke.strokeUUID)) == true {
                            parent.session.record(kind: .erase, strokeUUID: stroke.strokeUUID)
                        }
                        break
                    }
                }
            }
            // 划扫笔不落库：结算后画布 = 基线前缀（划扫段全剔除）。
            applySettlement(canvasView, keep: Array(all[..<settleBaseline]))
        }

        private func persistNewStrokes(_ canvasView: PKCanvasView) {
            guard let store = parent.strokesStore else { return }
            guard let vp = parent.pageViewport, vp.width > 0, vp.height > 0 else {
                return   // 页视口未就绪：不采样不落库（笔留画布，下轮 pen-up 重试）
            }
            let all = canvasView.drawing.strokes
            guard settleBaseline <= all.count else { settleBaseline = all.count; return }
            let newStrokes = Array(all[settleBaseline...])
            var persistedRelative: Set<Int> = []
            for (offset, stroke) in newStrokes.enumerated() {
                guard let simplified = sampledPoints(stroke) else { continue }
                let ink = InkStroke(
                    strokeUUID: UUID().uuidString,
                    bookID: parent.book.id,
                    pageNumber: parent.pageNumber,
                    deviceID: DeviceIdentity.deviceID(),
                    createdAt: Date().timeIntervalSince1970,
                    color: Self.hexFrom(rgb: stroke.ink.color),
                    lineWidth: parent.selection.lineWidth,
                    points: simplified)
                do {
                    if let rowid = try store.addStroke(ink) {
                        parent.session.record(ink.strokeUUID)
                        persistedRelative.insert(offset)
                        _ = rowid
                    }
                } catch {
                    // 落库失败：笔迹留在 canvas（身份结算保留——用户可见
                    // 未保存，不静默丢），下轮 pen-up 重试。
                }
            }
            // 身份结算——只有已落库笔剔除，未落库笔保留（禁计数比对）。
            let keepIndices = InkCanvasReconcile.keepIndices(
                total: all.count, baseline: settleBaseline,
                persistedRelative: persistedRelative)
            applySettlement(canvasView, keep: keepIndices.map { all[$0] })
        }

        /// 结算落位：按保留集重建画布并推进基线（保留集 == 全量时零写入，
        /// 不触发 PencilKit 重载抖动）。
        private func applySettlement(_ canvasView: PKCanvasView, keep: [PKStroke]) {
            guard keep.count != canvasView.drawing.strokes.count else {
                settleBaseline = canvasView.drawing.strokes.count
                return
            }
            canvasView.drawing = PKDrawing(strokes: keep)
            settleBaseline = keep.count
        }

        static func hexFrom(rgb: UIColor) -> String {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
            return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        }
    }
}
