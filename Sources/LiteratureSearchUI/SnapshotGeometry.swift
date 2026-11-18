import Foundation
import CoreGraphics

// MARK: - 快照裁剪几何纯函数（UI 逻辑层）

public enum SnapshotGeometry {
    /// 选区在页 bounds 内的归一化比例矩形（各分量 clamp 0-1；交集语义）。
    /// 零面积/负面积（不相交或退化选区）返回 nil 拒绝——不造空快照。
    public static func cropRatio(pageBounds: CGRect, selectionRect: CGRect) -> CGRect? {
        guard pageBounds.width > 0, pageBounds.height > 0 else { return nil }
        let crop = selectionRect.intersection(pageBounds)
        guard !crop.isNull, crop.width > 0, crop.height > 0 else { return nil }
        let x = (crop.minX - pageBounds.minX) / pageBounds.width
        let y = (crop.minY - pageBounds.minY) / pageBounds.height
        let w = crop.width / pageBounds.width
        let h = crop.height / pageBounds.height
        // 交集语义下 0-1 天然成立；clamp 是对浮点边界（如 -1e-9）的降级处理。
        return CGRect(x: min(max(x, 0), 1), y: min(max(y, 0), 1),
                      width: min(max(w, 0), 1), height: min(max(h, 0), 1))
    }

    /// 比例换算目标像素尺寸：`round(页像素 × 比例)`，每维下限 1（不造
    /// 零尺寸位图）。四舍五入语义在此断言固定（测试断言）。
    public static func cropedImageSize(pagePixel: CGSize, ratio: CGRect) -> CGSize {
        func dimension(_ pixels: CGFloat, _ fraction: CGFloat) -> CGFloat {
            guard pixels > 0, fraction > 0 else { return 1 }
            return max((pixels * fraction).rounded(), 1)
        }
        return CGSize(width: dimension(pagePixel.width, ratio.width),
                      height: dimension(pagePixel.height, ratio.height))
    }
}
