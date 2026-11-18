import Foundation

// MARK: - 三级引句定位（来源 ai-guided-reader 深读）
public enum QuoteLocate {
    /// needle 硬上限（归一化后字符数）。
    public static let maxNeedleChars = 500
    /// haystack 硬上限（归一化后字符数；防 DP 内存炸页——超限跳过近似层）。
    public static let maxHaystackChars = 4000
    /// 近似层接受阈值：similarity = 1 - dist/needleLen ≥ 阈值才承认。
    public static let minSimilarity = 0.80

    // MARK: 结果形状

    public enum Level: String, Equatable, Sendable {
        case exact
        case approximate
        case pageOnly
        case notFound
    }

    /// 定位结果（页内锚定；一切"未定位"都以 reason 字串如实标注，不猜）。
    public struct Location: Equatable, Sendable {
        public var level: Level
        /// 原文 UTF-16 偏移区间（exact/approximate 非 nil；pageOnly/notFound 恒 nil）。
        public var originalUTF16Range: Range<Int>?
        /// 归一化文本内的字符区间（与 norm.text 对齐；未命中为 nil）。
        public var normalizedRange: Range<Int>?
        /// 近似层相似度（1 - dist/needleLen）；exact 恒 1.0；其余 nil。
        public var similarity: Double?
        /// 降级/未命中原因（如实标注；命中为 nil）。
        public var reason: String?

        public init(level: Level, originalUTF16Range: Range<Int>? = nil,
                    normalizedRange: Range<Int>? = nil, similarity: Double? = nil,
                    reason: String? = nil) {
            self.level = level
            self.originalUTF16Range = originalUTF16Range
            self.normalizedRange = normalizedRange
            self.similarity = similarity
            self.reason = reason
        }
    }

    /// SearchHit→页内文本→字符偏移的层层锚定。
    /// hit 提供书/页锚点，pageOriginal＋norm 提供页内定位域；本函数不改
    /// hit 任何字段，只产出独立 Location。
    public struct Anchor: Equatable, Sendable {
        public var bookID: String
        public var physicalPage: Int
        public var location: Location

        public init(bookID: String, physicalPage: Int, location: Location) {
            self.bookID = bookID
            self.physicalPage = physicalPage
            self.location = location
        }
    }

    public static func anchor(quote: String, hit: SearchHit,
                              pageOriginal: String, norm: NormalizedText?) -> Anchor {
        Anchor(bookID: hit.bookID, physicalPage: hit.physicalPage,
               location: locate(quote: quote, pageOriginal: pageOriginal, norm: norm))
    }

    // MARK: 三级定位主入口

    public static func locate(quote: String, pageOriginal: String,
                              norm: NormalizedText?) -> Location {
        guard let norm, !norm.text.isEmpty else {
            return Location(level: .pageOnly, reason: "norm blob 缺损（空），降级页级定位")
        }
        let needle = normalizeForSearch(quote).text
        guard !needle.isEmpty else {
            return Location(level: .notFound, reason: "引句归一化后为空（无可定位内容）")
        }

        if let r = norm.text.range(of: needle) {
            if let original = norm.originalUTF16Range(r) {
                return Location(level: .exact, originalUTF16Range: original,
                                normalizedRange: charRange(of: r, in: norm.text),
                                similarity: 1.0)
            }
        }

        if needle.count > maxNeedleChars {
            return Location(level: .pageOnly,
                            reason: "引句超 needle 上限（\(needle.count)>\(maxNeedleChars)），跳过近似层，降级页级")
        }
        if norm.text.count > maxHaystackChars {
            return Location(level: .pageOnly,
                            reason: "页文超 haystack 上限（\(norm.text.count)>\(maxHaystackChars)），跳过近似层，降级页级")
        }
        if let align = boundedAlign(needle: Array(needle), haystack: Array(norm.text)) {
            let (start, end, dist) = align
            let sim = 1.0 - Double(dist) / Double(needle.count)
            if sim >= minSimilarity,
               let original = norm.originalUTF16Range(
                norm.text.index(norm.text.startIndex, offsetBy: start)..<norm.text.index(
                    norm.text.startIndex, offsetBy: end)) {
                return Location(level: .approximate, originalUTF16Range: original,
                                normalizedRange: start..<end, similarity: sim)
            }
        }

        return Location(level: .notFound,
                        reason: "精确与近似（≥\(minSimilarity)）两级均未命中该页")
    }

    /// String.Index 区间 → 字符下标区间（normalizedRange 记账用）。
    static func charRange(of r: Range<String.Index>, in s: String) -> Range<Int> {
        s.distance(from: s.startIndex, to: r.lowerBound)..<s.distance(from: s.startIndex, to: r.upperBound)
    }

    // MARK: 有界编辑距离对齐（半全局：needle 必须整段对齐，haystack 两端自由）

    /// 返回 (haystack 起点, haystack 终点, 编辑距离)。整矩阵 UInt16 回溯：
    /// 硬上限已把规模钳在 500×4000 = 2e6 格（UInt16 距离必不溢出：距离
    /// ≤ max(needle,窗口) ≤ 500 < 65535），内存 ~4MB 峰值一次性。
    /// 半全局语义：dp[0][j]=0（haystack 前缀自由）；终点 = dp[m][j] 最小者；
    /// 回溯到 i==0 行即起点。
    static func boundedAlign(needle: [Character], haystack: [Character])
        -> (start: Int, end: Int, distance: Int)? {
        let m = needle.count, n = haystack.count
        guard m > 0, n > 0, m <= maxNeedleChars, n <= maxHaystackChars else { return nil }

        var dp = [[UInt16]](repeating: [UInt16](repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m { dp[i][0] = UInt16(i) }
        // dp[0][j] = 0（起点自由）
        for i in 1...m {
            for j in 1...n {
                let sub = dp[i - 1][j - 1] + (needle[i - 1] == haystack[j - 1] ? 0 : 1)
                let del = dp[i - 1][j] + 1
                let ins = dp[i][j - 1] + 1
                dp[i][j] = min(sub, del, ins)
            }
        }
        // 终点自由：末行最小格
        var bestJ = n
        var best = dp[m][n]
        for j in 0...n where dp[m][j] < best {
            best = dp[m][j]; bestJ = j
        }
        // 回溯：优先走对角（子stitution/匹配），起点 = 回溯停住的 j
        var i = m, j = bestJ
        while i > 0 {
            if j > 0, dp[i][j] == dp[i - 1][j - 1] + (needle[i - 1] == haystack[j - 1] ? 0 : 1) {
                i -= 1; j -= 1
            } else if dp[i][j] == dp[i - 1][j] + 1 {
                i -= 1
            } else {
                j -= 1
            }
        }
        return (j, bestJ, Int(best))
    }
}
