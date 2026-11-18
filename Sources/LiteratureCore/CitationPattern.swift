import Foundation

// MARK: - Citation Patterns and Smart Jump Target Resolution

public enum CitationTargetKind: Equatable, Hashable, Sendable {
    /// In-book jump target: 1-based physical/printed page number in current book.
    case sameBookPage(page: Int)
    /// External library citation: requires resolution across library books/pages.
    case externalCitation(author: String?, title: String?, year: Int?, page: Int?, rawText: String)
}

public struct CitationMatch: Equatable, Hashable, Sendable {
    /// UTF-16 offset range in the source page text.
    public let range: Range<Int>
    /// Matched text verbatim.
    public let matchedText: String
    /// Target kind (in-book page jump or external book/page search).
    public let target: CitationTargetKind
    /// Name of the pattern that identified this match.
    public let patternName: String

    public init(range: Range<Int>, matchedText: String, target: CitationTargetKind, patternName: String) {
        self.range = range
        self.matchedText = matchedText
        self.target = target
        self.patternName = patternName
    }
}

public struct CitationRule: @unchecked Sendable {
    public let name: String
    public let regex: NSRegularExpression
    public let extractor: @Sendable (NSTextCheckingResult, String) -> CitationTargetKind?

    public init(name: String, pattern: String, options: NSRegularExpression.Options = [],
                extractor: @escaping @Sendable (NSTextCheckingResult, String) -> CitationTargetKind?) {
        self.name = name
        // Patterns are compile-time constants; failure indicates a programmer error.
        self.regex = try! NSRegularExpression(pattern: pattern, options: options)
        self.extractor = extractor
    }
}

public enum CitationPattern {
    // MARK: - Declarative Pattern Table

    public static let commonChinesePrepositions = [
        "根据", "按照", "参见于", "参见", "引自", "见于", "关于", "正如", "例如", "如", "见"
    ]

    public static let rules: [CitationRule] = [
        // 1. 《书名》第X页 / 《书名》
        CitationRule(
            name: "bookWithPage",
            pattern: #"[《〈]([^》〉\r\n]+)[》〉](?:\s*(?:参见|见)?第\s*([0-9０-９一二三四五六七八九十百千]+)\s*页(?:以下)?)?"#
        ) { result, text in
            guard result.numberOfRanges > 1 else { return nil }
            let ns = text as NSString
            let titleRange = result.range(at: 1)
            guard titleRange.location != NSNotFound else { return nil }
            let title = ns.substring(with: titleRange).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }

            var page: Int? = nil
            if result.numberOfRanges > 2 {
                let pageRange = result.range(at: 2)
                if pageRange.location != NSNotFound {
                    let pageStr = ns.substring(with: pageRange)
                    page = parsePageNumber(pageStr)
                }
            }
            let raw = ns.substring(with: result.range)
            return .externalCitation(author: nil, title: title, year: nil, page: page, rawText: raw)
        },

        // 2. Author, Title (Year): e.g. Quill, A Sample Treatise (2001)
        CitationRule(
            name: "authorTitleYear",
            pattern: #"([A-Z][a-zA-Z\s\.\-]+),\s*([A-Za-z0-9\s:,\-\'\"]+?)\s*[\(\（](1[89]\d\d|20\d\d)[\)\）]"#
        ) { result, text in
            guard result.numberOfRanges > 3 else { return nil }
            let ns = text as NSString
            let author = ns.substring(with: result.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let title = ns.substring(with: result.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            let year = Int(ns.substring(with: result.range(at: 3)))
            let raw = ns.substring(with: result.range)
            return .externalCitation(author: author.isEmpty ? nil : author,
                                     title: title.isEmpty ? nil : title,
                                     year: year, page: nil, rawText: raw)
        },

        // 3. 参见第X页 / 第X页以下 / 第X页至第Y页
        CitationRule(
            name: "chinesePageRange",
            pattern: #"(?<![a-zA-Z0-9])(?:参见|见|见于)?第\s*([0-9０-９]+)\s*[-－—~～至]\s*([0-9０-９]+)\s*页"#
        ) { result, text in
            guard result.numberOfRanges > 1 else { return nil }
            let ns = text as NSString
            let pStr = ns.substring(with: result.range(at: 1))
            guard let page = parsePageNumber(pStr) else { return nil }
            return .sameBookPage(page: page)
        },

        // 4. 参见第X页 / 第X页以下 / 第X页
        CitationRule(
            name: "chineseSeePage",
            pattern: #"(?<![a-zA-Z0-9])(?:参见|见|见于)?第\s*([0-9０-９一二三四五六七八九十百千]+)\s*页(?:以下)?"#
        ) { result, text in
            guard result.numberOfRanges > 1 else { return nil }
            let ns = text as NSString
            let pStr = ns.substring(with: result.range(at: 1))
            guard let page = parsePageNumber(pStr) else { return nil }
            return .sameBookPage(page: page)
        },

        // 5. English page references: p. 42, pp. 100-105, page 15
        CitationRule(
            name: "englishPage",
            pattern: #"(?<![a-zA-Z])(?:see\s+)?(?:pp?\.?|pages?)\s*([0-9]+)(?:\s*[-–—]\s*[0-9]+)?"#,
            options: [.caseInsensitive]
        ) { result, text in
            guard result.numberOfRanges > 1 else { return nil }
            let ns = text as NSString
            let pStr = ns.substring(with: result.range(at: 1))
            guard let page = Int(pStr) else { return nil }
            return .sameBookPage(page: page)
        },

        // 6. Western Author (Year): e.g. Quill (2001), Marlowe et al. (2002)
        CitationRule(
            name: "westernAuthorYear",
            pattern: #"(?<![a-zA-Z])([A-Z][a-zA-Z\-]+(?:\s+and\s+[A-Z][a-zA-Z\-]+|\s+&\s+[A-Z][a-zA-Z\-]+|\s+et\s+al\.?)?)\s*[\(\（](1[89]\d\d|20\d\d)[\)\）]"#
        ) { result, text in
            guard result.numberOfRanges > 2 else { return nil }
            let ns = text as NSString
            let author = ns.substring(with: result.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let year = Int(ns.substring(with: result.range(at: 2)))
            let raw = ns.substring(with: result.range)
            return .externalCitation(author: author.isEmpty ? nil : author,
                                     title: nil, year: year, page: nil, rawText: raw)
        },

        // 7. Parenthetical Western (Author, Year): e.g. (Example, 1961)
        CitationRule(
            name: "parenWesternAuthorYear",
            pattern: #"[\(\（]([A-Z][a-zA-Z\-]+(?:\s+and\s+[A-Z][a-zA-Z\-]+|\s+&\s+[A-Z][a-zA-Z\-]+|\s+et\s+al\.?)?),?\s*(1[89]\d\d|20\d\d)[\)\）]"#
        ) { result, text in
            guard result.numberOfRanges > 2 else { return nil }
            let ns = text as NSString
            let author = ns.substring(with: result.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let year = Int(ns.substring(with: result.range(at: 2)))
            let raw = ns.substring(with: result.range)
            return .externalCitation(author: author.isEmpty ? nil : author,
                                     title: nil, year: year, page: nil, rawText: raw)
        },

        // 8. Chinese Author (Year): e.g. 李维（2021）, 根据张三(2019)
        CitationRule(
            name: "chineseAuthorYear",
            pattern: #"([\u4e00-\u9fa5]{2,6})\s*[\(\（](1[89]\d\d|20\d\d)[\)\）]"#
        ) { result, text in
            guard result.numberOfRanges > 2 else { return nil }
            let ns = text as NSString
            var author = ns.substring(with: result.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            for prep in commonChinesePrepositions {
                if author.hasPrefix(prep) {
                    author = String(author.dropFirst(prep.count))
                    break
                }
            }
            guard author.count >= 2 else { return nil }
            let year = Int(ns.substring(with: result.range(at: 2)))
            let raw = ns.substring(with: result.range)
            return .externalCitation(author: author, title: nil, year: year, page: nil, rawText: raw)
        },

        // 9. Parenthetical Chinese (Author, Year): e.g. （李维，2021）
        CitationRule(
            name: "parenChineseAuthorYear",
            pattern: #"[\(\（]([\u4e00-\u9fa5]{2,6}),?\s*(1[89]\d\d|20\d\d)[\)\）]"#
        ) { result, text in
            guard result.numberOfRanges > 2 else { return nil }
            let ns = text as NSString
            var author = ns.substring(with: result.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            for prep in commonChinesePrepositions {
                if author.hasPrefix(prep) {
                    author = String(author.dropFirst(prep.count))
                    break
                }
            }
            guard author.count >= 2 else { return nil }
            let year = Int(ns.substring(with: result.range(at: 2)))
            let raw = ns.substring(with: result.range)
            return .externalCitation(author: author, title: nil, year: year, page: nil, rawText: raw)
        },

        // 10. Western Author, Year without parens: e.g. Smith, 2020
        CitationRule(
            name: "westernAuthorCommaYear",
            pattern: #"(?<![a-zA-Z])([A-Z][a-zA-Z\-]+),\s*(1[89]\d\d|20\d\d)(?![0-9])"#
        ) { result, text in
            guard result.numberOfRanges > 2 else { return nil }
            let ns = text as NSString
            let author = ns.substring(with: result.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let year = Int(ns.substring(with: result.range(at: 2)))
            let raw = ns.substring(with: result.range)
            return .externalCitation(author: author.isEmpty ? nil : author,
                                     title: nil, year: year, page: nil, rawText: raw)
        }
    ]

    // MARK: - Scanner

    /// Scans the given page text and returns all non-overlapping citation matches
    /// sorted by UTF-16 offset order.
    public static func scan(text: String) -> [CitationMatch] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        var candidates: [CitationMatch] = []
        for rule in rules {
            let matches = rule.regex.matches(in: text, options: [], range: fullRange)
            for m in matches {
                guard let target = rule.extractor(m, text) else { continue }
                let range = m.range
                guard range.location != NSNotFound, range.length > 0 else { continue }
                let utf16Range = range.location..<(range.location + range.length)
                let matchedText = ns.substring(with: range)
                candidates.append(CitationMatch(range: utf16Range,
                                                matchedText: matchedText,
                                                target: target,
                                                patternName: rule.name))
            }
        }

        // Deduplicate overlapping candidate matches:
        // Prioritize longer matches; if lengths are equal, preserve earlier detection.
        candidates.sort { a, b in
            let lenA = a.range.count
            let lenB = b.range.count
            if lenA != lenB { return lenA > lenB }
            return a.range.lowerBound < b.range.lowerBound
        }

        var accepted: [CitationMatch] = []
        for cand in candidates {
            let overlaps = accepted.contains { existing in
                max(cand.range.lowerBound, existing.range.lowerBound) < min(cand.range.upperBound, existing.range.upperBound)
            }
            if !overlaps {
                accepted.append(cand)
            }
        }

        // Sort by document reading order (ascending start offset)
        accepted.sort { $0.range.lowerBound < $1.range.lowerBound }
        return accepted
    }

    // MARK: - Helpers

    /// Parses Arabic, full-width, or Chinese numeral page strings into an Int.
    public static func parsePageNumber(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        // 1. Direct standard integer
        if let direct = Int(trimmed) { return direct }

        // 2. Full-width ASCII digits: ０-９ (0xFF10-0xFF19)
        var halfWidth = ""
        var isAllDigits = true
        for ch in trimmed {
            if let scalar = ch.unicodeScalars.first, scalar.value >= 0xFF10 && scalar.value <= 0xFF19 {
                halfWidth.append(Character(UnicodeScalar(scalar.value - 0xFEE0)!))
            } else if ch.isNumber {
                halfWidth.append(ch)
            } else {
                isAllDigits = false
                break
            }
        }
        if isAllDigits, let parsed = Int(halfWidth) {
            return parsed
        }

        // 3. Chinese numerals (e.g. 一, 十二, 三十五, 一百二十)
        return chineseNumeralToInt(trimmed)
    }

    private static func chineseNumeralToInt(_ text: String) -> Int? {
        let charMap: [Character: Int] = [
            "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
        ]
        let unitMap: [Character: Int] = [
            "十": 10, "百": 100, "千": 1000
        ]

        var total = 0
        var currentSection = 0
        var currentDigit = 0
        var hasDigit = false

        for ch in text {
            if let digit = charMap[ch] {
                currentDigit = digit
                hasDigit = true
            } else if let unit = unitMap[ch] {
                if !hasDigit && unit == 10 {
                    // E.g. "十二" -> initial "十" implies 1 * 10
                    currentDigit = 1
                }
                currentSection += currentDigit * unit
                currentDigit = 0
                hasDigit = false
            } else {
                return nil
            }
        }
        total += currentSection + currentDigit
        return total > 0 ? total : nil
    }
}
