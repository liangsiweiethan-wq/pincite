import Foundation

// MARK: - canvas 双态交接结算纯函数

public enum InkCanvasReconcile {

    /// pen-up 结算：返回应保留在画布上的全局下标集合。
    ///
    /// - Parameters:
    ///   - total: 结算时画布内笔迹总数（≥0）。
    ///   - baseline: 上次结算后画布内笔数（前缀，全部未落库，禁清）。
    ///   - persistedRelative: 新增段（baseline..<total）内**已成功落库**的
    ///     相对下标集合——只有这些笔从画布剔除。
    /// - Returns: 保留笔的全局下标（升序）。越界/非法输入 fail-closed：
    ///   baseline 越界按 0 处理（全量视为新增段），persistedRelative 越界
    ///   项忽略。
    public static func keepIndices(total: Int, baseline: Int,
                                   persistedRelative: Set<Int>) -> [Int] {
        guard total > 0 else { return [] }
        let safeBaseline = min(max(baseline, 0), total)
        var keep: [Int] = []
        keep.reserveCapacity(total)
        // 前缀（既有未落库笔）：一律保留。
        for i in 0..<safeBaseline { keep.append(i) }
        // 新增段：仅未落库（不在 persistedRelative）者保留。
        for offset in safeBaseline..<total where !persistedRelative.contains(offset - safeBaseline) {
            keep.append(offset)
        }
        return keep
    }

    /// 便捷判定：按上同语义，第 `globalIndex` 笔是否应保留。
    public static func shouldKeep(globalIndex: Int, total: Int, baseline: Int,
                                  persistedRelative: Set<Int>) -> Bool {
        keepIndices(total: total, baseline: baseline,
                    persistedRelative: persistedRelative).contains(globalIndex)
    }
}
