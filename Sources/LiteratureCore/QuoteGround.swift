import Foundation

// MARK: - grounding 归一化核验（来源 seerai 深读）
public enum QuoteGround {
    /// 近似接受阈值（与 QuoteLocate.minSimilarity 同档；独立常量便于分层测试）。
    public static let minSimilarity = 0.80
    /// 有界 DP 硬上限（与 QuoteLocate 同值）。
    public static let maxNeedleChars = 500
    public static let maxHaystackChars = 4000

    // MARK: 结果形状

    public enum Verdict: String, Equatable, Sendable {
        case exact
        case fuzzy
        case none
    }

    public struct Result: Equatable, Sendable {
        public var verdict: Verdict
        /// 省略号切段数（quote 含 …/... 时 ≥2；无切段为 1）。
        public var segments: Int
        /// 依序命中的切段数（exact 时 = segments）。
        public var matchedSegments: Int
        /// fuzzy 路径的相似度（其余 nil）。
        public var similarity: Double?
        /// 命中路径标注（"canonical-contain" / "elision-in-order" /
        /// "dehyphenated" / "bounded-edit"）；none 时给拒绝原因。
        public var note: String

        public init(verdict: Verdict, segments: Int = 1, matchedSegments: Int = 0,
                    similarity: Double? = nil, note: String) {
            self.verdict = verdict
            self.segments = segments
            self.matchedSegments = matchedSegments
            self.similarity = similarity
            self.note = note
        }
    }

    // MARK: 归一化清单

    public static func canonicalFold(_ s: String) -> String {
        LatinProjection.transform(normalizeForSearch(s).text)
    }

    /// 剥引句尾部模型爱加的图表/页码引用（seerai TRAILING_REF 语义；
    /// 只作用于引句侧——原文侧永不剥）。剥 "(Fig. 2a)" "(p. 3)" "(see Table 1)"
    /// "（图 2）" 等括号尾巴，可叠多层；剥后去尾空格。
    public static func stripTrailingReference(_ quote: String) -> String {
        var s = quote
        // 半角/全角括号尾巴：内部不含括号、含至少一个字母数字/图/表/p 字样。
        let pattern = "[\\s]*[（(][^（）()]{0,40}[)）][\\s]*$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        while true {
            let range = NSRange(s.startIndex..., in: s)
            guard let m = regex.firstMatch(in: s, range: range),
                  m.range.location != NSNotFound else { break }
            let tail = String(s[Range(m.range, in: s)!])
            let inner = tail.trimmingCharacters(in: CharacterSet(charactersIn: " ()（）"))
            let probe = inner.lowercased()
            let looksLikeRef = probe.contains("fig") || probe.contains("table")
                || probe.contains("p.") || probe.contains("pp.")
                || probe.contains("图") || probe.contains("表")
                || probe.contains("see ") || probe.rangeOfCharacter(from: .decimalDigits) != nil
            guard looksLikeRef else { break }
            s = String(s[s.startIndex..<Range(m.range, in: s)!.lowerBound])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 省略号切段（… / U+2026 / 三个以上半角点）：切段后逐段折叠，
    /// 全部依序含于原文 → fuzzy（elision-in-order）。
    public static func elisionSegments(_ quote: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var dots = 0
        for ch in quote {
            if ch == "\u{2026}" || ch == "." {
                dots += 1
                if dots == 3 || ch == "\u{2026}" {
                    parts.append(current); current = ""; dots = 0
                }
            } else {
                if dots > 0 && dots < 3 {
                    current += String(repeating: ".", count: dots)
                }
                dots = 0
                current.append(ch)
            }
        }
        if dots > 0 { current += String(repeating: ".", count: dots) }
        parts.append(current)
        return parts.filter { !$0.isEmpty }
    }

    // MARK: 核验主入口

    public static func verify(quote: String, original: String) -> Result {
        let stripped = stripTrailingReference(quote)
        let segments = elisionSegments(stripped)
        let foldedQuote = canonicalFold(stripped)
        let foldedOriginal = canonicalFold(original)

        guard !foldedQuote.isEmpty else {
            return Result(verdict: .none, segments: segments.count, note: "引句折叠后为空，无从核验")
        }
        guard !foldedOriginal.isEmpty else {
            return Result(verdict: .none, segments: segments.count, note: "原文折叠后为空（无文字层？）")
        }

        if segments.count > 1 {
            var cursor = foldedOriginal.startIndex
            var matched = 0
            for part in segments {
                let folded = canonicalFold(part)
                guard !folded.isEmpty,
                      let r = foldedOriginal.range(of: folded, range: cursor..<foldedOriginal.endIndex) else {
                    break
                }
                matched += 1
                cursor = r.upperBound
            }
            if matched == segments.count {
                return Result(verdict: .fuzzy, segments: segments.count,
                              matchedSegments: matched, note: "elision-in-order")
            }
            return Result(verdict: .none, segments: segments.count, matchedSegments: matched,
                          note: "省略号切段未全部依序命中（\(matched)/\(segments.count)）")
        }

        if foldedOriginal.contains(foldedQuote) {
            return Result(verdict: .exact, segments: 1, matchedSegments: 1,
                          note: "canonical-contain")
        }

        let dehyphQuote = canonicalFold(stripped.replacingOccurrences(
            of: "-\\s+", with: "", options: .regularExpression))
        let dehyphOriginal = canonicalFold(original.replacingOccurrences(
            of: "-\\s+", with: "", options: .regularExpression))
        if !dehyphQuote.isEmpty, dehyphOriginal.contains(dehyphQuote) {
            return Result(verdict: .fuzzy, segments: 1, matchedSegments: 1,
                          note: "dehyphenated")
        }

        if foldedQuote.count <= maxNeedleChars, foldedOriginal.count <= maxHaystackChars {
            let dist = editDistance(foldedQuote, foldedOriginal)
            let sim = 1.0 - Double(dist) / Double(max(foldedQuote.count, 1))
            if sim >= minSimilarity {
                return Result(verdict: .fuzzy, segments: 1, matchedSegments: 1,
                              similarity: sim, note: "bounded-edit")
            }
            return Result(verdict: .none, segments: 1,
                          similarity: sim,
                          note: String(format: "编辑距离超阈值（similarity %.3f < %.2f）", sim, minSimilarity))
        }
        return Result(verdict: .none, segments: 1,
                      note: "超有界上限（needle \(foldedQuote.count)/haystack \(foldedOriginal.count)），跳过编辑距离")
    }

    /// 双行 Levenshtein（只算距离不回溯；调用方已钳规模 ≤500×4000）。
    static func editDistance(_ a: String, _ b: String) -> Int {
        let m = a.count, n = b.count
        guard m > 0 else { return n }
        guard n > 0 else { return m }
        let aa = Array(a), bb = Array(b)
        var prev = [Int](0...n)
        var curr = [Int](repeating: 0, count: n + 1)
        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let sub = prev[j - 1] + (aa[i - 1] == bb[j - 1] ? 0 : 1)
                curr[j] = min(sub, prev[j] + 1, curr[j - 1] + 1)
            }
            swap(&prev, &curr)
        }
        return prev[n]
    }
}
