import Foundation

// MARK: - 功能扩展 文件名规范化反查降级处理

public enum FileNameNormalization {

    /// 文件名 → 书名猜测（保守规范化）：
    ///   1. 去扩展名；
    ///   2. `_` `.` `-` 归一为空格；
    /// 3. 去方括号段（外部标识段）；
    ///   4. 压缩连续空白 + 去首尾空白；
    ///   5. 结果为空或纯数字 → nil（不猜——纯数字文件名没有可查语义）。
    ///
    /// 未闭合方括号保留原文（只删完整 `[…]` 段，不猜配对）。
    public static func normalizedTitleGuess(from fileName: String) -> String? {
        var name = (fileName as NSString).deletingPathExtension
        name = name
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        // 逐段删除完整方括号段（可连续多段；未闭合段不动）。
        while let start = name.firstIndex(of: "["),
              let end = name.firstIndex(of: "]"), start < end {
            name.removeSubrange(start...end)
        }
        let squeezed = name.split(omittingEmptySubsequences: true,
                                  whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !squeezed.isEmpty else { return nil }
        // 纯数字 → nil（不猜）。
        if squeezed.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
            return nil
        }
        return squeezed
    }
}
