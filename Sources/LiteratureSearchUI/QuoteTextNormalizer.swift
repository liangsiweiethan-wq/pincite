import Foundation

// MARK: - 选区引文规整（纯函数；无 PDFKit 依赖，可合成测试）
//
// 已知问题：在阅读器里从单词中间拖选，右键「复制引文」得到被切断的
// 「“…empts to prove”」「“…But this sh”」；跨行选区还残留硬换行。
//
// 本规整器只做三件事，**不删改任何文字**：
//   1. 补全被切断的整词：选区起点前一个字符与起点字符都是拉丁字母/数字 →
//      向左扩到词首；终点同理向右扩到词尾。CJK 边界不扩（中文词界不可靠，
//      不乱猜）。
//   2. 选区内换行：两侧都是 CJK → 直接去掉；否则换成一个空格。
//   3. 连续空白压成一个（含 tab / 多空格）。
// 行尾连字符（`transla-\ntion`）不猜——保留原样（合并与否会改变原文，
// 属改写，不在本函数权限内）。

public enum QuoteTextNormalizer {
    /// 把页面全文 + 选区 UTF-16 范围规整成引文文本。
    ///
    /// - Parameters:
    ///   - pageText: 选区所在页的全文（`PDFPage.string`）。
    ///   - utf16Range: 选区在该页文本中的 UTF-16 范围（越界时按页文本夹紧）。
    /// - Returns: 规整后的引文；范围非法（空/越界到无交集）时返回 nil，
    ///   调用方据此退回未经规整的选区原文。
    public static func normalize(pageText: String, utf16Range: Range<Int>) -> String? {
        let ns = pageText as NSString
        let total = ns.length
        guard total > 0 else { return nil }
        var lower = max(0, utf16Range.lowerBound)
        var upper = min(total, utf16Range.upperBound)
        guard lower < upper else { return nil }

        var hasWordBoundaryLeft = false
        if lower > 0, let here = scalarAt(ns, index: lower),
           let prev = scalarBefore(ns, index: lower),
           isWordScalar(here), isWordScalar(prev) {
            while lower > 0, let prev = scalarBefore(ns, index: lower), isWordScalar(prev) {
                lower -= 1
            }
            hasWordBoundaryLeft = true
        }
        if upper > 0, let last = scalarBefore(ns, index: upper), isWordScalar(last) {
            while upper < total, let next = scalarAt(ns, index: upper), isWordScalar(next) {
                upper += 1
            }
        }

        let selected = ns.substring(with: NSRange(location: lower, length: upper - lower))
        return collapse(selected, hasWordBoundaryLeft: hasWordBoundaryLeft)
    }

    /// 换行规则：两侧均 CJK → 去掉；否则换成空格。连续空白压成一个。
    /// 行尾连字符保持原样（不合并）。
    static func collapse(_ text: String, hasWordBoundaryLeft: Bool = false) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\r" || scalar == "\n" || scalar == "\t"
                || CharacterSet.whitespaces.contains(scalar) {
                // 整段连续空白（可能含换行）先整体收起来，再按两侧判定形态。
                var sawNewline = false
                var end = index
                while end < scalars.count {
                    let s = scalars[end]
                    guard s == "\r" || s == "\n" || s == "\t"
                        || CharacterSet.whitespaces.contains(s) else { break }
                    if s == "\r" || s == "\n" { sawNewline = true }
                    end += 1
                }
                let prev = scalars[..<index].last { !isWhitespace($0) }
                let next = scalars[end...].first { !isWhitespace($0) }
                if sawNewline, let p = prev, let n = next, isCJK(p), isCJK(n) {
                    // CJK 行间断行 → 直接去掉。
                    pendingSpace = false
                } else {
                    pendingSpace = !out.isEmpty
                }
                index = end
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(scalar)
            index += 1
        }
        let result = String(out).trimmingCharacters(in: .whitespacesAndNewlines)
        // 左边界已向左拓宽到词首时，选区里不会残留左空白；未拓宽（CJK/标点/
        // 词界）时两端空白都去掉——不删改任何文字，只去选区外缘的空白。
        _ = hasWordBoundaryLeft
        return result
    }

    // MARK: - 字符判定

    static func isWhitespace(_ s: Unicode.Scalar) -> Bool {
        s == "\r" || s == "\n" || s == "\t" || CharacterSet.whitespaces.contains(s)
    }

    /// 拉丁字母 / 阿拉伯数字（含重音字母等拉丁扩展区）。
    static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        if ("0"..."9").contains(s) { return true }
        if ("a"..."z").contains(s) || ("A"..."Z").contains(s) { return true }
        // 拉丁扩展（é/ü/ø 等）与组合附加符：与 ASCII 字母同类，参与整词补全。
        if (0x00C0...0x024F).contains(s.value) { return true }
        if (0x0300...0x036F).contains(s.value) { return true }
        return false
    }

    /// CJK 统一表意文字（含扩展 A 与兼容区）。
    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(s.value)
            || (0x3400...0x4DBF).contains(s.value)
            || (0xF900...0xFAFF).contains(s.value)
    }

    static func isWordChar(_ unit: unichar) -> Bool {
        guard let s = Unicode.Scalar(unit) else { return false }
        return isWordScalar(s)
    }

    private static func scalarAt(_ ns: NSString, index: Int) -> Unicode.Scalar? {
        guard index >= 0, index < ns.length else { return nil }
        return Unicode.Scalar(ns.character(at: index))
    }

    private static func scalarBefore(_ ns: NSString, index: Int) -> Unicode.Scalar? {
        guard index > 0, index <= ns.length else { return nil }
        return Unicode.Scalar(ns.character(at: index - 1))
    }
}
