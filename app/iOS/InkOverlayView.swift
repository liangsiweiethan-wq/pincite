import UIKit

// MARK: - 笔迹叠绘层（Inkpad 纪律：路径复用、按页 bounds 重排）

final class InkOverlayView: UIView {
    private var strokes: [InkStroke] = []
    private var viewport = InkGeometry.PageViewport(originX: 0, originY: 0, width: 0, height: 0)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("storyboard 不用") }

    /// 更新笔迹与视口后重绘（调用方保证主线程）。
    func reload(strokes: [InkStroke], viewport: InkGeometry.PageViewport) {
        self.strokes = strokes
        self.viewport = viewport
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard viewport.width > 0, viewport.height > 0 else { return }
        for stroke in strokes where stroke.deletedAt == nil {
            let path = UIBezierPath()
            let points = stroke.points.map {
                InkGeometry.viewPoint(fromPageRelative: $0, in: viewport)
            }
            guard let first = points.first else { continue }
            path.move(to: CGPoint(x: first.x, y: first.y))
            for p in points.dropFirst() {
                path.addLine(to: CGPoint(x: p.x, y: p.y))
            }
            let shape = CAShapeLayer()
            shape.path = path.cgPath
            shape.strokeColor = UIColor(hexString: stroke.color)?.cgColor
            shape.lineWidth = max(stroke.lineWidth, 1)
            shape.fillColor = UIColor.clear.cgColor
            shape.lineCap = .round
            shape.lineJoin = .round
            layer.addSublayer(shape)
        }
    }
}

extension UIColor {
    convenience init?(hexString: String) {
        var value: UInt64 = 0
        let body = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        guard body.count == 6, Scanner(string: body).scanHexInt64(&value) else { return nil }
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
