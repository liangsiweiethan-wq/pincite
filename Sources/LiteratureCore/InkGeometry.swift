import Foundation

// MARK: - 笔迹几何纯函数（iOS 层 InkOverlayView / PKCanvasView

/// 单个采样点：页相对坐标 0-1（写入侧 clamp，越界点拒绝而非截断——
/// 由 store 层校验拒收）。
public struct InkPoint: Codable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum InkGeometry {
    // MARK: 坐标换算

    /// 页在视图中的矩形（点阵；PDFKit page.bounds(for: .cropBox) 转视图
    /// 坐标后的落位）。
    public struct PageViewport: Equatable {
        public var originX: Double
        public var originY: Double
        public var width: Double
        public var height: Double

        public init(originX: Double, originY: Double, width: Double, height: Double) {
            self.originX = originX
            self.originY = originY
            self.width = width
            self.height = height
        }
    }

    /// 页相对 (0-1) → 视图点阵。
    public static func viewPoint(fromPageRelative p: InkPoint,
                                 in viewport: PageViewport) -> (x: Double, y: Double) {
        (viewport.originX + p.x * viewport.width,
         viewport.originY + p.y * viewport.height)
    }

    /// 视图点阵 → 页相对 (0-1)。视口宽高为 0（未布局）时返回 (0,0)——
    /// 调用方（叠绘层）在布局前不渲染，不产生写入。
    public static func pageRelative(viewX: Double, viewY: Double,
                                    in viewport: PageViewport) -> InkPoint {
        guard viewport.width > 0, viewport.height > 0 else { return InkPoint(x: 0, y: 0) }
        return InkPoint(x: (viewX - viewport.originX) / viewport.width,
                        y: (viewY - viewport.originY) / viewport.height)
    }

    // MARK: 抽稀

    /// 抽稀后点数窗口。
    public static let minStrokePoints = 20
    public static let maxStrokePoints = 60
    /// 单笔 JSON 字节预算（store 层校验用同一常量）。
    public static let maxStrokeJSONBytes = 4_096

    /// 曲率抽稀：Douglas–Peucker（页相对 0-1 空间内以 epsilon 判偏移），
    /// 保留转折（曲率）点、丢弃共线点。结果超上限时等距重采样到
    /// maxPoints；输入点数 ≤ maxPoints 且无共线冗余时原样返回。
    public static func simplify(points: [InkPoint],
                                epsilon: Double = 0.002,
                                maxPoints: Int = InkGeometry.maxStrokePoints) -> [InkPoint] {
        guard points.count > 2, maxPoints >= 2 else { return points }
        var kept = Array(points.prefix(1))
        kept.append(contentsOf: rdp(points, epsilon: epsilon).dropFirst())
        if kept.count > maxPoints {
            kept = resample(points, target: maxPoints)
        }
        return kept
    }

    /// Douglas–Peucker 递归（迭代栈实现，避免深笔迹爆栈）。
    private static func rdp(_ points: [InkPoint], epsilon: Double) -> [InkPoint] {
        guard points.count > 2 else { return points }
        var keep = Array(repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }
            var maxDist = -1.0
            var maxIdx = start
            for i in (start + 1)..<end {
                let d = pointSegmentDistance(points[i], points[start], points[end])
                if d > maxDist { maxDist = d; maxIdx = i }
            }
            if maxDist > epsilon {
                keep[maxIdx] = true
                stack.append((start, maxIdx))
                stack.append((maxIdx, end))
            }
        }
        return points.enumerated().filter { keep[$0.offset] }.map(\.element)
    }

    /// 等距重采样（沿折线弧长取 target 个点，含首尾）。
    static func resample(_ points: [InkPoint], target: Int) -> [InkPoint] {
        guard points.count > 1, target >= 2 else { return points }
        var lengths: [Double] = [0]
        var total = 0.0
        for i in 1..<points.count {
            total += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
            lengths.append(total)
        }
        guard total > 0 else { return [points[0]] }
        var out: [InkPoint] = []
        var seg = 1
        for k in 0..<target {
            let want = total * Double(k) / Double(target - 1)
            while seg < points.count - 1, lengths[seg] < want { seg += 1 }
            let span = max(lengths[seg] - lengths[seg - 1], .leastNonzeroMagnitude)
            let t = min(max((want - lengths[seg - 1]) / span, 0), 1)
            out.append(InkPoint(
                x: points[seg - 1].x + (points[seg].x - points[seg - 1].x) * t,
                y: points[seg - 1].y + (points[seg].y - points[seg - 1].y) * t))
        }
        return out
    }

    /// 点到线段最短距离（0-1 空间）。
    static func pointSegmentDistance(_ p: InkPoint, _ a: InkPoint, _ b: InkPoint) -> Double {
        let abx = b.x - a.x, aby = b.y - a.y
        let apx = p.x - a.x, apy = p.y - a.y
        let ab2 = abx * abx + aby * aby
        let t = ab2 == 0 ? 0.0 : min(max((apx * abx + apy * aby) / ab2, 0), 1)
        return hypot(apx - abx * t, apy - aby * t)
    }

    // MARK: 命中测试（橡皮 = 整笔墓碑的判别）

    /// 视图点 (viewX, viewY) 是否落在笔迹（页相对点列，换算到视图点阵）
    public static func hitTest(viewX: Double, viewY: Double,
                               strokePoints: [InkPoint],
                               viewport: PageViewport,
                               thresholdPoints: Double) -> Bool {
        guard viewport.width > 0, viewport.height > 0, strokePoints.count >= 2 else { return false }
        // 阈值换算到页相对空间后逐段测（与抽稀同空间，避免逐点换算开销）。
        let relThresholdX = thresholdPoints / viewport.width
        let relThresholdY = thresholdPoints / viewport.height
        let relThreshold = max(relThresholdX, relThresholdY)
        let p = InkPoint(x: (viewX - viewport.originX) / viewport.width,
                         y: (viewY - viewport.originY) / viewport.height)
        for i in 1..<strokePoints.count {
            if pointSegmentDistance(p, strokePoints[i - 1], strokePoints[i]) <= relThreshold {
                return true
            }
        }
        return false
    }

    /// 序列化字节预算自检：点列 JSON（[[x,y],...]）是否 < maxStrokeJSONBytes。
    public static func fitsByteBudget(points: [InkPoint]) -> Bool {
        encodePoints(points).count < maxStrokeJSONBytes
    }

    /// points 列 JSON。
    public static func encodePoints(_ points: [InkPoint]) -> String {
        let inner = points.map { String(format: "[%.4f,%.4f]", $0.x, $0.y) }
        return "[" + inner.joined(separator: ",") + "]"
    }

    /// 反序列化（坏 JSON / 越界坐标 → nil，fail-closed 由 store 层转拒收）。
    public static func decodePoints(_ json: String) -> [InkPoint]? {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let pairs = raw as? [[Double]] else { return nil }
        var out: [InkPoint] = []
        for pair in pairs {
            guard pair.count == 2 else { return nil }
            let p = InkPoint(x: pair[0], y: pair[1])
            guard p.x >= 0, p.x <= 1, p.y >= 0, p.y <= 1 else { return nil }
            out.append(p)
        }
        return out
    }
}
