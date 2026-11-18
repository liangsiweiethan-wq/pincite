import Foundation
#if os(macOS)
import Darwin

// MARK: - APFS clonefile 近零拷贝

public enum FileClone {
    /// 测试注入点（密闭化说明）：非 nil 时以钩子代真 clonefile(3)（生产恒
    /// nil 走真调用；断言回退路径不依赖真实文件系统错误注入）。
    static var cloneHook: ((String, String) -> Int32)?

    /// APFS clonefile(3) 近零拷贝；clonefile 任何非零返回（ENOTSUP/EXDEV/
    /// EPERM/…）均回退 FileManager.copyItem。返回 true＝走了 clone（诊断
    /// 基准）；false＝走了回退拷贝。失败（连回退都失败）抛错。
    /// - 来源与目标都必须是普通文件路径；父目录由调用方先行创建。
    @discardableResult
    public static func cloneOrCopy(from: URL, to: URL) throws -> Bool {
        let src = from.path
        let dst = to.path
        let srcStat = statPair(at: src)
        let rc = cloneHook.map { $0(src, dst) } ?? clonefile(src, dst, 0)
        if rc == 0 {
            // 后置校验：目的件 size＋mtime 与源一致（防半克隆假成功；
            // size 挡不住同尺寸内容损坏，mtime 同比对）。
            if srcStat == nil || Self.statMatch(dst: statPair(at: dst), src: srcStat) {
                return true
            }
            // 校验不符：删半成品走回退。
            try? FileManager.default.removeItem(atPath: dst)
        }
        try FileManager.default.copyItem(atPath: src, toPath: dst)
        if let expected = srcStat, !Self.statMatch(dst: statPair(at: dst), src: expected) {
            throw NSError(domain: "FileClone", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "clone-or-copy stat mismatch: src=\(src) " +
                    "expected=\(expected) got=\(String(describing: statPair(at: dst)))"])
        }
        return false
    }

    /// size 精确＋mtime ±2s 容差的一致性判定（容差防文件系统时间精度
    /// 漂移假阳；size 变化即判不符）。
    private static func statMatch(dst: (size: Int64, mtime: Double)?,
                                  src: (size: Int64, mtime: Double)?) -> Bool {
        guard let d = dst, let s = src else { return false }
        guard d.size == s.size else { return false }
        return abs(d.mtime - s.mtime) < 2.0
    }

    /// (size, mtime) 对（clonefile/copyItem 均保留 mtime；比对可同时挡
    /// 半成品与源件中途变更两态）。
    private static func statPair(at path: String) -> (size: Int64, mtime: Double)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { return nil }
        return (size, mtime)
    }
}
#endif
