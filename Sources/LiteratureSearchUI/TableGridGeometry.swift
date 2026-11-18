import Foundation
import CoreGraphics

// MARK: - 表格圈选几何纯函数（UI 逻辑层）

public struct TableWord: Equatable, Sendable {
    public let text: String
    public let rect: CGRect

    public init(text: String, rect: CGRect) {
        self.text = text
        self.rect = rect
    }
}

public enum TableGridGeometry {

    /// 行归并的垂直交并比阈值。
    public static let rowOverlapThreshold: CGFloat = 0.5
    /// 断列的水平间隙阈值 = 字高 × 该倍数（默认 1.5）。
    public static let columnGapFactor: CGFloat = 1.5

    /// 词序列 → 行列化表格（外层数组 = 行，内层 = 列；nil = 无有效输入）。
    public static func grid(words: [TableWord]) -> [[String]]? {
        let usable = words.filter { $0.rect.width > 0 && $0.rect.height > 0 && !$0.text.isEmpty }
        guard !usable.isEmpty else { return nil }

        // ── 行聚类：按中心 y 排序，与既有行的垂直区间 IoU 达标即归行 ──
        let sorted = usable.sorted { $0.rect.midY < $1.rect.midY }
        var rows: [[TableWord]] = []
        var rowTops: [CGFloat] = []
        var rowBottoms: [CGFloat] = []
        for word in sorted {
            var placed = false
            for i in rows.indices {
                if verticalIoU(word.rect, top: rowTops[i], bottom: rowBottoms[i]) >= rowOverlapThreshold {
                    rows[i].append(word)
                    rowTops[i] = min(rowTops[i], word.rect.minY)
                    rowBottoms[i] = max(rowBottoms[i], word.rect.maxY)
                    placed = true
                    break
                }
            }
            if !placed {
                rows.append([word])
                rowTops.append(word.rect.minY)
                rowBottoms.append(word.rect.maxY)
            }
        }
        // 行按行区间顶部回排（排序打乱了行间顺序）。PDFKit 页坐标 y 向上
        //（selection.bounds 实证测试 pdfKitSelectionBoundsYIsUpward）：页顶
        // 行 midY 大——行序取 rowTops **降序**（y 大=页顶=表格第一行）。
        let order = rows.indices.sorted { rowTops[$0] > rowTops[$1] }
        let orderedRows = order.map { rows[$0] }
        guard !orderedRows.isEmpty else { return nil }

        // ── 列聚类：行内按 minX 排序；间隙 > 1.5×字高断列 ──
        var table: [[String]] = []
        var columnCount = 0
        for row in orderedRows {
            let byX = row.sorted { $0.rect.minX < $1.rect.minX }
            let lineHeight = median(byX.map { $0.rect.height }) ?? 1
            var cells: [String] = []
            var current = byX[0].text
            for (prev, cur) in zip(byX, byX.dropFirst()) {
                let gap = cur.rect.minX - prev.rect.maxX
                if gap > columnGapFactor * lineHeight {
                    cells.append(current)
                    current = cur.text
                } else {
                    current += " " + cur.text
                }
            }
            cells.append(current)
            columnCount = max(columnCount, cells.count)
            table.append(cells)
        }
        // ragged 行右侧补空串（如实补空，不猜合并语义）。
        for i in table.indices where table[i].count < columnCount {
            table[i].append(contentsOf: Array(repeating: "", count: columnCount - table[i].count))
        }
        return table
    }

    /// 表格 → TSV（nil 入参/空表拒绝）。单元格内 \t/\n/\r 压成单个空格
    ///（连续空白折叠为一个），行间 \n、列间 \t。
    public static func tsv(from table: [[String]]?) -> String? {
        guard let table, !table.isEmpty, !table[0].isEmpty else { return nil }
        return table.map { row in
            row.map { flattenCell($0) }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    public static func tokenRanges(in text: String) -> [(token: String, range: NSRange)] {
        let ns = text as NSString
        let whitespace = CharacterSet.whitespacesAndNewlines
        var out: [(token: String, range: NSRange)] = []
        var start: Int? = nil
        var token = ""
        func flush(upto end: Int) {
            defer { start = nil; token = "" }
            if let s = start, !token.isEmpty {
                out.append((token, NSRange(location: s, length: end - s)))
            }
        }
        var i = 0
        while i < ns.length {
            let ch = ns.substring(with: NSRange(location: i, length: 1))
            if let uni = ch.unicodeScalars.first, whitespace.contains(uni) {
                flush(upto: i)
            } else {
                if start == nil { start = i }
                token += ch
            }
            i += 1
        }
        flush(upto: ns.length)
        return out
    }

    /// grid + tsv 一把出（nil = 无有效表格）。
    public static func tsv(from words: [TableWord]) -> String? {
        guard let table = grid(words: words) else { return nil }
        return tsv(from: table)
    }

    static func flattenCell(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        var lastWasSpace = false
        for scalar in text.unicodeScalars {
            if scalar == "\t" || scalar == "\n" || scalar == "\r" {
                if !lastWasSpace { out.unicodeScalars.append(" ") }
                lastWasSpace = true
            } else {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        return out
    }

    /// 垂直区间交并比（交集高 / 并集高）。
    static func verticalIoU(_ rect: CGRect, top: CGFloat, bottom: CGFloat) -> CGFloat {
        let intersection = min(rect.maxY, bottom) - max(rect.minY, top)
        guard intersection > 0 else { return 0 }
        let union = max(rect.maxY, bottom) - min(rect.minY, top)
        guard union > 0 else { return 0 }
        return intersection / union
    }

    static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let mid = s.count / 2
        return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
    }
}
