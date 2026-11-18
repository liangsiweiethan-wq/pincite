import Foundation

// MARK: - 五级分层匹配判定器（来源 reference-linker 深读）
public enum QuoteMatch {
    /// 半句线：最长连续窗 ≥ ⌈k/2⌉（k≥2 才有意义；k=1 直接落 withinWord）。
    public static let minSimilarity = 0.80
    /// 有界编辑距离硬上限（QuoteLocate/QuoteGround 同表）。
    public static let maxNeedleChars = 500
    public static let maxHaystackChars = 4000

    // MARK: 层级与结果

    public enum Level: Int, Equatable, Comparable, CaseIterable, Sendable {
        case fullSentence = 1
        case halfSentence = 2
        case phrase = 3
        case withinWord = 4
        case fuzzy = 5

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
        /// 如实分级标注（中文短标；UI/清单直用）。
        public var label: String {
            switch self {
            case .fullSentence: return "整句"
            case .halfSentence: return "半句"
            case .phrase: return "词组"
            case .withinWord: return "词内"
            case .fuzzy: return "模糊"
            }
        }
    }

    public struct Outcome: Equatable, Sendable {
        /// 证据支持的最高层级；nil = 五级全落空（如实 none）。
        public var level: Level?
        /// 层内证据强度 0...1（各层基准见 classify 注）。
        public var score: Double
        /// 如实分级标注（层级名＋依据计数）。
        public var detail: String

        public init(level: Level?, score: Double, detail: String) {
            self.level = level
            self.score = score
            self.detail = detail
        }
    }

    // MARK: 词元化

    /// 归一化分词：拉丁 [a-z0-9]+ 词 ＋ CJK 单字与相邻二字组（去重保序）。
    /// 中文引句无空白可切——二字组是词组级的可用近似（库内 bigram 桥同源）。
    public static func tokens(_ s: String) -> [String] {
        let normalized = normalizeForSearch(s).text
        var out: [String] = []
        var latin = ""
        var cjkRun: [Character] = []
        func flushLatin() {
            if !latin.isEmpty { out.append(latin); latin = "" }
        }
        func flushCJK() {
            if cjkRun.count == 1 {
                out.append(String(cjkRun[0]))
            } else if cjkRun.count >= 2 {
                out.append(String(cjkRun))                    // 整串（词内连续窗用）
                for i in 0..<(cjkRun.count - 1) {
                    out.append(String([cjkRun[i], cjkRun[i + 1]])) // 相邻二字组
                }
            }
            cjkRun = []
        }
        for ch in normalized {
            if ch == " " {
                flushLatin(); flushCJK()
            } else if QuoteExtractor.containsCJK(String(ch)) {
                flushLatin()
                cjkRun.append(ch)
            } else {
                flushCJK()
                latin.append(ch)
            }
        }
        flushLatin(); flushCJK()
        return out
    }

    /// 最长公共连续词元窗长度（引句窗须整体含于候选窗序；经典 DP O(k·n)）。
    static func longestContiguousWindow(_ quote: [String], _ candidate: [String]) -> Int {
        guard !quote.isEmpty, !candidate.isEmpty else { return 0 }
        // 候选词元索引表（词 → 出现位置）；窗比较只对引句词元出现位展开。
        var positions: [String: [Int]] = [:]
        for (i, t) in candidate.enumerated() { positions[t, default: []].append(i) }
        var best = 0
        for start in 0..<quote.count {
            guard let firsts = positions[quote[start]] else { continue }
            for p in firsts {
                var len = 1
                while start + len < quote.count,
                      positions[quote[start + len]]?.contains(p + len) == true {
                    len += 1
                }
                if len > best { best = len }
            }
        }
        return best
    }

    // MARK: 五级递进主入口

    public static func classify(quote: String, candidate: String) -> Outcome {
        let quoteTokens = tokens(quote)
        let candidateTokens = tokens(candidate)
        let k = quoteTokens.count
        guard k > 0 else {
            return Outcome(level: nil, score: 0, detail: "引句分词为空，无从分级")
        }
        guard !candidateTokens.isEmpty else {
            return Outcome(level: nil, score: 0, detail: "候选分词为空，五级全落空")
        }

        let foldedQuote = collapseSpaces(normalizeForSearch(quote).text)
        let foldedCandidate = collapseSpaces(normalizeForSearch(candidate).text)
        if !foldedQuote.isEmpty, foldedCandidate.contains(foldedQuote) {
            return Outcome(level: .fullSentence, score: 1.0, detail: "整句：折叠串整段含于候选")
        }

        let window = longestContiguousWindow(quoteTokens, candidateTokens)
        if k >= 2, window * 2 >= k {
            return Outcome(level: .halfSentence,
                           score: Double(window) / Double(k),
                           detail: "半句：最长连续窗 \(window)/\(k) ≥ 半句线")
        }
        if window >= 2 {
            return Outcome(level: .phrase,
                           score: Double(window) / Double(k),
                           detail: "词组：最长连续窗 \(window)/\(k)（< 半句线）")
        }

        let quoteSet = Set(quoteTokens)
        let hit = quoteSet.filter { candidateTokens.contains($0) }
        if !hit.isEmpty {
            return Outcome(level: .withinWord,
                           score: Double(hit.count) / Double(quoteSet.count),
                           detail: "词内：散点命中 \(hit.count)/\(quoteSet.count) 词元（无连续窗）")
        }

        if foldedQuote.count <= maxNeedleChars, foldedCandidate.count <= maxHaystackChars {
            let dist = QuoteGround.editDistance(foldedQuote, foldedCandidate)
            let sim = 1.0 - Double(dist) / Double(max(foldedQuote.count, 1))
            if sim >= minSimilarity {
                return Outcome(level: .fuzzy, score: sim,
                               detail: String(format: "模糊：编辑距离相似度 %.3f ≥ %.2f", sim, minSimilarity))
            }
            return Outcome(level: nil, score: sim,
                           detail: String(format: "五级全落空（模糊相似度 %.3f < %.2f）", sim, minSimilarity))
        }
        return Outcome(level: nil, score: 0,
                       detail: "超有界上限（needle \(foldedQuote.count)/haystack \(foldedCandidate.count)），模糊级不跑")
    }

    static func collapseSpaces(_ s: String) -> String {
        var out = ""
        var pendingSpace = false
        for ch in s {
            if ch == " " {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" "); pendingSpace = false }
                out.append(ch)
            }
        }
        return out
    }
}
