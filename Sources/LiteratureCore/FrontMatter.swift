import Foundation


public enum FrontMatterFilter {

    /// 书级 meta 键。
    public static func metaKey(_ bookID: String) -> String { "body_start_page:" + bookID }

    /// 读书级正文起始物理页（nil = 未设置/坏值——不屏蔽）。
    public static func readBodyStartPage(store: IndexStore, bookID: String) -> Int? {
        guard let raw = try? store.metaValue(metaKey(bookID)),
              !raw.isEmpty,
              let page = Int(raw), page >= 1 else { return nil }
        return page
    }

    /// 写书级正文起始物理页（nil = 清除；写空串使 read 判 nil）。
    public static func writeBodyStartPage(_ page: Int?, store: IndexStore, bookID: String) throws {
        if let page {
            guard page >= 1 else {
                throw FrontMatterError("正文起始页须 ≥1（物理页基准）：\(page)")
            }
            try store.setMetaValue(metaKey(bookID), String(page))
        } else {
            try store.setMetaValue(metaKey(bookID), "")
        }
    }

    /// 单页可见性：body_start 之前 = 前置页（屏蔽）；body_start 本身及之后
    /// 可见；未设置（nil）全可见（默认关 = 现状）。
    public static func isVisible(page: Int, bodyStartPage: Int?) -> Bool {
        guard let body = bodyStartPage, body >= 1 else { return true }
        return page >= body
    }

    /// 命中页序列过滤 + 被屏蔽计数（显示层单一入口——被屏蔽数单独显示、
    /// 零命中解释器联动共用本拆分）。
    public static func partition<H>(_ hits: [H], page: (H) -> Int,
                                    bodyStartPage: Int?) -> (visible: [H], blocked: [H]) {
        var visible: [H] = []
        var blocked: [H] = []
        for hit in hits {
            if isVisible(page: page(hit), bodyStartPage: bodyStartPage) {
                visible.append(hit)
            } else {
                blocked.append(hit)
            }
        }
        return (visible, blocked)
    }
}

public struct FrontMatterError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}


/// 探测器
public enum BodyStartDetector {

    public struct Detection: Equatable, Sendable {
        /// 候选正文起始物理页（nil = 无把握）。
        public var bodyStartPage: Int?
        /// 命中的信号（人审抽检用）。
        public var signals: [String]

        public init(bodyStartPage: Int?, signals: [String]) {
            self.bodyStartPage = bodyStartPage
            self.signals = signals
        }
    }

    /// 页尾独立数字（1-4 位）行。
    private static func trailingPrintedNumber(_ text: String) -> Int? {
        guard let last = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { !$0.isEmpty }) else { return nil }
        guard last.count <= 4, let n = Int(last), n >= 1, n <= 2_000 else { return nil }
        return n
    }

    /// 目录页判定：点线引导行（连续点线 ≥6 点当量）行数 ≥3。
    /// 中文省略号「…」计 3 点当量（中文目录主流引导符）；`.`/`·` 各计 1。
    static func looksLikeTOC(_ text: String) -> Bool {
        let dotted = text.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { line in
                var run = 0
                for ch in line {
                    switch ch {
                    case "…": run += 3
                    case ".", "·": run += 1
                    default: run = 0
                    }
                    if run >= 6 { return true }
                }
                return false
            }.count
        return dotted >= 3
    }

    /// ISBN 特征（版权页）。ISBN-10/13 宽匹配（连字符/空格容忍）。
    static func looksLikeCopyrightPage(_ text: String) -> Bool {
        guard let range = text.range(of: "ISBN", options: .caseInsensitive) else { return false }
        let tail = String(text[range.lowerBound...].prefix(40))
        return tail.range(of: "[0-9Xx][0-9Xx\\-\\s]{8,}", options: .regularExpression) != nil
    }

    /// 扫描前 scanLimit 页（离线批处理基准——探测书级页号属性，非文献数据
    /// 生产：不产页码数据表，只写书级 meta 键，边界内）。
    public static func detect(pageTexts: [String], scanLimit: Int = 40) -> Detection {
        let limit = min(scanLimit, pageTexts.count)
        guard limit > 0 else {
            return Detection(bodyStartPage: nil,
                             signals: pageTexts.isEmpty ? ["输入为空（无页可扫）"] : [])
        }
        var signals: [String] = []
        var copyrightPage: Int?
        var tocPages: Set<Int> = []
        var seenPrintedAboveOne = false

        for i in 1...limit {
            let text = pageTexts[i - 1]
            if looksLikeCopyrightPage(text) {
                if copyrightPage == nil { copyrightPage = i }
            }
            if looksLikeTOC(text) {
                tocPages.insert(i)
            }
            if let printed = trailingPrintedNumber(text) {
                if printed > 1 {
                    seenPrintedAboveOne = true
                } else if printed == 1, seenPrintedAboveOne || copyrightPage != nil || !tocPages.isEmpty {
                    // 印刷页码从 1 重启（有前置页证据佐证）→ 最强信号，直接采用。
                    signals.append("印刷页码从 1 重启于物理页 \(i)")
                    return Detection(bodyStartPage: i, signals: signals)
                }
            }
        }
        // 回退：版权页/目录之后第一个非目录页。
        if let cp = copyrightPage {
            signals.append("版权页（ISBN）于物理页 \(cp)")
            var candidate = cp + 1
            while tocPages.contains(candidate) { candidate += 1 }
            if candidate <= pageTexts.count {
                signals.append("回退候选 = 版权页后首个非目录页")
                return Detection(bodyStartPage: candidate, signals: signals)
            }
        }
        if !tocPages.isEmpty {
            signals.append("仅目录页特征（物理页 \(tocPages.sorted())）——不足以定正文起点")
        }
        return Detection(bodyStartPage: nil, signals: signals)
    }
}
