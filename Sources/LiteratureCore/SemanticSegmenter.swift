import Foundation

// MARK: - 段级切分（AI 混合检索）

public struct SemanticSegment: Equatable, Sendable {
    /// 页内 0 起段序。
    public let paraIndex: Int
    /// 页原文 UTF-16 段起点。
    public let utf16Start: Int
    /// 页原文 UTF-16 段长度（码元数）。
    public let utf16Length: Int
    /// 原文段文本（verbatim，不清洗）。
    public let text: String

    public init(paraIndex: Int, utf16Start: Int, utf16Length: Int, text: String) {
        self.paraIndex = paraIndex
        self.utf16Start = utf16Start
        self.utf16Length = utf16Length
        self.text = text
    }
}

public enum SemanticSegmenter {
    /// 行聚合断段阈值（UTF-16 码元）。
    public static let maxParagraphChars = 600
    /// 短段并入阈值：不足并入下一段；页尾余段并入前段。
    public static let minParagraphChars = 40
    /// 空行块采用阈值：平均块 ≥200 字符才采用空行块切分。
    static let blankBlockAdoptAverageChars = 200

    /// 页原文 → 段列表（确定性；空页/全空白页返回空数组）。
    public static func segments(ofPageText text: String) -> [SemanticSegment] {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return [] }

        let blocks = blankLineBlocks(in: units)
        if blocks.count > 1 {
            let total = blocks.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
            let average = Double(total) / Double(blocks.count)
            if average >= Double(blankBlockAdoptAverageChars) {
                return finalize(spans: blocks, units: units)
            }
        }

        var spans: [Range<Int>] = []
        var segmentStart: Int? = nil
        var accumulated = 0
        var lineStart = 0
        var cursor = 0
        while cursor <= units.count {
            let atEnd = cursor == units.count
            let ch: UInt16 = atEnd ? 0x0A : units[cursor]
            if ch == 0x0A {
                let lineLength = cursor - lineStart
                let isBlank = units[lineStart..<cursor].allSatisfy {
                    $0 == 0x20 || $0 == 0x09 || $0 == 0x0D
                }
                if !isBlank {
                    if segmentStart == nil { segmentStart = lineStart }
                    accumulated += lineLength + 1 // 含换行符
                    if accumulated >= maxParagraphChars {
                        spans.append(segmentStart!..<min(cursor + 1, units.count))
                        segmentStart = nil
                        accumulated = 0
                    }
                }
                lineStart = cursor + 1
            }
            if atEnd { break }
            cursor += 1
        }
        if let s = segmentStart {
            spans.append(s..<units.count) // 页尾余段（去留由收尾规则裁夺）
        }
        return finalize(spans: spans, units: units)
    }

    // MARK: 内部（同文件私有；纯函数）

    /// `\n{2,}` 空行块扫描：返回非空白块区间（UTF-16 偏移，升序不重叠）。
    static func blankLineBlocks(in units: [UInt16]) -> [Range<Int>] {
        var blocks: [Range<Int>] = []
        var blockStart: Int? = 0
        var i = 0
        while i < units.count {
            if units[i] == 0x0A {
                var j = i
                while j < units.count, units[j] == 0x0A { j += 1 }
                if j - i >= 2 { // `\n{2,}` 空行串 → 收上一块、下一块从 j 起
                    if let s = blockStart {
                        appendIfNotBlank(units[s..<i], to: &blocks)
                    }
                    blockStart = j
                }
                i = j
            } else {
                i += 1
            }
        }
        if let s = blockStart {
            appendIfNotBlank(units[s..<units.count], to: &blocks)
        }
        return blocks
    }

    private static func appendIfNotBlank(_ slice: ArraySlice<UInt16>, to blocks: inout [Range<Int>]) {
        guard slice.contains(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D && $0 != 0x0A }) else { return }
        blocks.append(slice.startIndex..<slice.endIndex)
    }

    /// 收尾：短段并入下一段、页尾余段并入前段，再统一编号（paraIndex 0 起）。
    /// 合并 = 连续 span 取并区间（有序不重叠，坐标仍是页原文切片）。
    static func finalize(spans: [Range<Int>], units: [UInt16]) -> [SemanticSegment] {
        var merged = spans.filter { !$0.isEmpty }
        guard !merged.isEmpty else { return [] }
        var i = 0
        while merged.count > 1, i < merged.count - 1 {
            if (merged[i].upperBound - merged[i].lowerBound) < minParagraphChars {
                merged[i + 1] = merged[i].lowerBound..<merged[i + 1].upperBound
                merged.remove(at: i)
            } else {
                i += 1
            }
        }
        if merged.count > 1 {
            let lastSpan = merged[merged.count - 1]
            if (lastSpan.upperBound - lastSpan.lowerBound) < minParagraphChars {
                let last = merged.removeLast()
                merged[merged.count - 1] = merged[merged.count - 1].lowerBound..<last.upperBound
            }
        }
        return merged.enumerated().map { index, span in
            SemanticSegment(
                paraIndex: index,
                utf16Start: span.lowerBound,
                utf16Length: span.upperBound - span.lowerBound,
                text: String(decoding: units[span.lowerBound..<span.upperBound], as: UTF16.self))
        }
    }
}
