import Foundation

// MARK: - 对照工作台换算纯函数

public enum WorkbenchMapping {
    /// 页数比例换算：`round(sourcePage * targetCount / sourceCount)` 再
    /// clamp 到 1...targetCount。等页数恒等；单页书边界恒 1。
    ///
    /// 非法输入（counts < 1 或 sourcePage < 1）安全收敛到 1（floor 值，
    /// 不抛不崩——App 层调用点已守卫 currentPage ≥ 1，这里只是降级处理）。
    /// 换算纯度：同输入同输出，无隐藏状态，无副作用。
    public static func linkedPage(for sourcePage: Int, sourceCount: Int, targetCount: Int) -> Int {
        guard sourceCount >= 1, targetCount >= 1, sourcePage >= 1 else { return 1 }
        let raw = (Double(sourcePage) * Double(targetCount) / Double(sourceCount)).rounded()
        return Int(min(max(raw, 1), Double(targetCount)))
    }
}
