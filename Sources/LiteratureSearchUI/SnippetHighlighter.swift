import Foundation
// LiteratureCore 条件导入：macOS 上 UI 静态库独立编译（依赖 LiteratureCore
// 模块）；iOS/watchOS app target 把 core+UI 源码直接编入同一模块（无独立
// LiteratureCore 模块可解析，同模块类型天然可见）——canImport 分支即保证
// 两平台各取所需（iOSCompileGateSuite 白名单说明：说明扩展）。
#if canImport(LiteratureCore)
import LiteratureCore
#endif

// MARK: - snippet 高亮组装（纯字符串层；无 SwiftUI 依赖——
// L10n.swift 同目录先例，合成测试直接 import 验证）
//
// 数据全部来自既有 SearchHit.matches[].originalUTF16Range（页原文坐标）；
// 组装只做「窗口平移＋段切分」，渲染层零猜测（paperless highlights 形态，
// 调研记录）。OCR 命中的 range 属 OCR 页文本（SearchService.swift:18-20
// 既有契约），高亮坐标只落在对应来源文本上，绝不映射到原件。
//
// 窗口算法与 SearchService.snippet 同源（snippet 即由 snippetWindow 派生，
// 单一事实路径）——本文件不再复制一份窗口逻辑。

public enum SnippetHighlighter {
    /// 一个展示段：verbatim 子串＋是否命中高亮。
    public struct Segment: Equatable {
        public let text: String
        public let isHighlighted: Bool
    }

    /// 组装结果：snippet 文本（含省略号，与 SearchService.snippet 输出逐
    /// 字节一致）＋按序切段（高亮段可定位着色）。
    public struct HighlightedSnippet: Equatable {
        public let text: String
        public let segments: [Segment]
        /// range 越界/空串等无法安全组装时 false（调用方降级纯文本展示，
        /// 不猜）。
        public let highlighted: Bool
    }

    /// 从页原文＋命中 range 组装高亮 snippet。
    /// - fullText：页原文（hit 所属来源页的 text_original；OCR 命中传
    ///   OCR 页文本——调用方按 hit.source 选对文本）。
    /// - ranges：hit.matches[].originalUTF16Range（UTF-16，页原文坐标）。
    public static func assemble(fullText: String, ranges: [Range<Int>], context: Int = 40) -> HighlightedSnippet {
        let total = fullText.utf16.count
        // 越界钳制（部分越界＝窗口内部分保留的裁剪语义；全越界/空串 →
        // 空集降级纯文本）。snippetWindow 本体保持「越界即 nil」的既有
        // 契约不动（snippet(in:around:) 语义零漂移），钳制只在本组装层做。
        let clamped = ranges.compactMap { r -> Range<Int>? in
            let lo = max(0, r.lowerBound)
            let hi = min(total, r.upperBound)
            return lo < hi ? lo..<hi : nil
        }
        guard let window = SearchService.snippetWindow(in: fullText, around: clamped, context: context) else {
            return HighlightedSnippet(text: "", segments: [], highlighted: false)
        }
        // 窗口内的高亮区间（页坐标 → 窗口坐标），越界裁剪＋合并重叠。
        var clipped: [Range<Int>] = []
        for r in ranges {
            let lo = max(r.lowerBound, window.window.lowerBound)
            let hi = min(r.upperBound, window.window.upperBound)
            guard lo < hi, lo >= 0, hi <= total else { continue }
            clipped.append(lo..<hi)
        }
        guard !clipped.isEmpty else {
            // 窗口可组但无有效高亮（range 全越界）：如实降级。
            let start = String.Index(utf16Offset: window.window.lowerBound, in: fullText)
            let end = String.Index(utf16Offset: window.window.upperBound, in: fullText)
            let body = String(fullText[start..<end])
            let text = (window.ellipsisPrefix ? "…" : "") + body + (window.ellipsisSuffix ? "…" : "")
            return HighlightedSnippet(text: text, segments: [Segment(text: text, isHighlighted: false)],
                                      highlighted: false)
        }
        clipped.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = [clipped[0]]
        for r in clipped.dropFirst() {
            let last = merged[merged.count - 1]
            if r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        // 段切分：窗口起点 → 高亮1 → 间隔 → 高亮2 → … → 窗口终点。
        var segments: [Segment] = []
        var cursor = window.window.lowerBound
        func appendPlain(_ upTo: Int) {
            guard upTo > cursor else { return }
            let s = String.Index(utf16Offset: cursor, in: fullText)
            let e = String.Index(utf16Offset: upTo, in: fullText)
            segments.append(Segment(text: String(fullText[s..<e]), isHighlighted: false))
        }
        for r in merged {
            appendPlain(r.lowerBound)
            let s = String.Index(utf16Offset: r.lowerBound, in: fullText)
            let e = String.Index(utf16Offset: r.upperBound, in: fullText)
            segments.append(Segment(text: String(fullText[s..<e]), isHighlighted: true))
            cursor = r.upperBound
        }
        appendPlain(window.window.upperBound)
        let text = (window.ellipsisPrefix ? "…" : "")
            + segments.map(\.text).joined()
            + (window.ellipsisSuffix ? "…" : "")
        return HighlightedSnippet(text: text, segments: segments, highlighted: true)
    }

    public static func matchesCoreSnippet(fullText: String, ranges: [Range<Int>], context: Int = 40) -> Bool {
        assemble(fullText: fullText, ranges: ranges, context: context).text
            == SearchService.snippet(in: fullText, around: ranges, context: context)
    }
}
