import Foundation

/// Represents an extracted high-value sentence from the library.
public struct Quote: Equatable, Sendable, Codable {
    public var id: Int64?
    public var bookID: String
    public var fileName: String
    public var pageNumber: Int
    public var sentence: String
    public var quoteDate: String?

    public init(id: Int64? = nil, bookID: String, fileName: String, pageNumber: Int, sentence: String, quoteDate: String? = nil) {
        self.id = id
        self.bookID = bookID
        self.fileName = fileName
        self.pageNumber = pageNumber
        self.sentence = sentence
        self.quoteDate = quoteDate
    }

    public init(bookID: String, fileName: String, pageNumber: Int, sentence: String) {
        self.id = nil
        self.bookID = bookID
        self.fileName = fileName
        self.pageNumber = pageNumber
        self.sentence = sentence
        self.quoteDate = nil
    }
}

/// High-value sentence extractor for the "Daily Quote" engine.
///
/// Scans status=ok books with non-empty normalized text, slices full sentences,
/// applies strict length, cleanliness and balancing heuristics, prioritizes
/// sentences containing academic concept keywords, and deterministically chooses
/// one quote per day based on a stable hash of YYYYMMDD.
public struct QuoteExtractor: Sendable {
    // MARK: - Heuristic Constants (written as constants for auditable inspection)

    public static let minSentenceLength: Int = 40
    public static let maxSentenceLength: Int = 160
    public static let maxQuotesPerBook: Int = 12
    public static let maxQuotesPerPage: Int = 2
    public static let defaultExtractionLimit: Int = 400
    public static let replacementCharacter: Character = "\u{FFFD}"

    /// 书级英文判定阈值：书内全部页 text_norm 的
    /// ASCII 字符占比 ≥ 80% 才判为英文书，只从英文书抽句——中文书整本
    /// 排除（含其中嵌的完整英文段，句级 CJK 拒绝挡不住这类段落）。
    public static let englishBookMinASCIIRatio: Double = 0.80

    /// Core academic / jurisprudence concept keywords (~20 words):
    /// Chinese foundational concepts and authoritative Western terms (German / Latinate).
    /// Hitting any of these words adds a priority bonus to the sentence score.
    public static let academicConceptKeywords: [String] = [
        "法律", "权利", "规范", "正义", "义务", "权力", "宪法", "秩序", "裁判", "法治", "效力", "责任",
        "Recht", "Norm", "Staat", "Rechtspflicht", "Gesetz", "Geltung", "Gerechtigkeit", "Verfassung", "Grundsatz"
    ]

    private static let closingPunctuation: Set<Character> = [
        "”", "’", "\"", "'", "」", "』", "）", ")", "]", "】", "›", "»"
    ]

    private static let abbreviations: Set<String> = [
        "art.", "abs.", "nr.", "dr.", "prof.", "s.", "vgl.", "bzw.", "ca.", "d.h.",
        "e.g.", "i.e.", "etc.", "vs.", "v.", "al.", "no.", "vol.", "p.", "pp."
    ]

    public init() {}

    // MARK: - Sentence Splitting & Cleanup

    /// Folds internal line-breaks (\r\n, \r, \n) into spaces and collapses consecutive whitespace.
    public static func foldWhitespace(_ text: String) -> String {
        let replaced = text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        var result = ""
        var inWhitespace = false
        for ch in replaced {
            if ch.isWhitespace {
                if !inWhitespace {
                    result.append(" ")
                    inWhitespace = true
                }
            } else {
                result.append(ch)
                inWhitespace = false
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits text into complete sentences based on Chinese and English sentence boundaries (。/！/？/./!/?).
    /// Respects ellipses (…… / ...) and abbreviations (e.g., Art., 1.5) without premature cutting.
    public static func splitSentences(from text: String) -> [String] {
        let cleaned = foldWhitespace(text)
        guard !cleaned.isEmpty else { return [] }

        var sentences: [String] = []
        let chars = Array(cleaned)
        let n = chars.count
        var start = 0
        var i = 0

        while i < n {
            let ch = chars[i]
            var isBoundary = false

            if ch == "。" || ch == "！" || ch == "？" || ch == "!" || ch == "?" {
                isBoundary = true
            } else if ch == "." {
                // Check if part of ellipsis (.. or ...)
                let prevIsDot = (i > 0 && chars[i - 1] == ".")
                let nextIsDot = (i + 1 < n && chars[i + 1] == ".")
                if prevIsDot || nextIsDot {
                    isBoundary = false
                } else if (i > 0 && chars[i - 1].isNumber) && (i + 1 < n && chars[i + 1].isNumber) {
                    // Decimal point e.g. 1.2
                    isBoundary = false
                } else {
                    // Check abbreviation preceding this dot
                    var wordStart = i - 1
                    while wordStart >= 0 && !chars[wordStart].isWhitespace && !closingPunctuation.contains(chars[wordStart]) && chars[wordStart] != "." {
                        wordStart -= 1
                    }
                    wordStart += 1
                    let word = String(chars[wordStart...i]).lowercased()
                    if abbreviations.contains(word) {
                        isBoundary = false
                    } else if i + 1 < n && !chars[i + 1].isWhitespace && !closingPunctuation.contains(chars[i + 1]) {
                        // Period not followed by whitespace or closing quote is not sentence end
                        isBoundary = false
                    } else {
                        isBoundary = true
                    }
                }
            } else if ch == "…" || ch == "\u{2026}" {
                // Ellipsis handling:
                // If followed by 。 or ！ or ？, let that trailing punctuation mark the boundary.
                // If followed by space and another word, it marks the end of a thought.
                if i + 1 < n && (chars[i + 1] == "…" || chars[i + 1] == "\u{2026}") {
                    if i + 2 < n && (chars[i + 2] == "。" || chars[i + 2] == "！" || chars[i + 2] == "？") {
                        isBoundary = false
                    } else if i + 2 < n && chars[i + 2].isWhitespace {
                        isBoundary = true
                        i += 1
                    }
                }
            }

            if isBoundary {
                // Consume trailing closing quotes or stacked punctuation marks
                var end = i + 1
                while end < n && (closingPunctuation.contains(chars[end])
                                  || chars[end] == "。" || chars[end] == "！" || chars[end] == "？"
                                  || chars[end] == "!" || chars[end] == "?") {
                    end += 1
                }
                let candidate = String(chars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty {
                    sentences.append(candidate)
                }
                // Skip whitespaces preceding the next sentence
                while end < n && chars[end].isWhitespace {
                    end += 1
                }
                start = end
                i = end
            } else {
                i += 1
            }
        }

        // Tail fragment without terminal punctuation is incomplete, except if it ends with valid punctuation
        if start < n {
            let tail = String(chars[start..<n]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty {
                if let last = tail.last, ["。", "！", "？", ".", "!", "?", "”", "’", "\"", "'", "」", "』"].contains(last) {
                    sentences.append(tail)
                }
            }
        }

        return sentences
    }

    // MARK: - Validation & Scoring

    /// Validates sentence against character length, replacement character and
    /// script constraints. Daily Quote is English-only: any CJK character
    /// disqualifies the sentence.
    public static func isValidQuote(_ sentence: String) -> Bool {
        guard sentence.count >= minSentenceLength && sentence.count <= maxSentenceLength else {
            return false
        }
        guard !sentence.contains(replacementCharacter) else {
            return false
        }
        guard !containsCJK(sentence) else {
            return false
        }
        guard !looksLikeFootnote(sentence) else {
            return false
        }
        guard isEnglishProse(sentence) else {
            return false
        }
        return true
    }

    /// English-prose heuristic: quotes must come from English-language books —
    /// German/French Latin-script books pass the
    /// ASCII check but are not English). Requires English stop words and
    /// rejects sentences dominated by German stop words.
    public static let englishStopWords: [String] = ["the", "of", "and", "to", "in", "is", "that", "as", "for"]
    public static let germanStopWords: [String] = ["der ", "die ", "das ", "und ", "ist ", "nicht ", "mit ", "für "]

    public static func isEnglishProse(_ sentence: String) -> Bool {
        let lower = " " + sentence.lowercased() + " "
        let englishHits = englishStopWords.filter { lower.contains(" \($0) ") }.count
        guard englishHits >= 2 else { return false }
        let germanHits = germanStopWords.filter { lower.contains(" \($0)") }.count
        return germanHits == 0
    }

    /// Footnote/bibliography-entry patterns: quotes must be body-text
    /// sentences, never reference list entries.
    public static let footnotePublisherPatterns: [String] = [
        "Verlag", "Press,", "University", "eds.", "ed., ",
        "Vol.", "No. ", "Jg.", "Hrsg.", "DOI", "doi:",
        "https://", "http://", "©", "Copyright", "ISBN", "vgl.", "Cf. ",
    ]

    /// True if the sentence looks like a footnote/bibliography entry rather
    /// than body prose (publisher marks, page-range abbreviations, URLs).
    public static func looksLikeFootnote(_ sentence: String) -> Bool {
        if sentence.hasPrefix("See ") || sentence.hasPrefix("Cf. ") || sentence.hasPrefix("Vgl. ") { return true }
        for pat in footnotePublisherPatterns where sentence.localizedCaseInsensitiveContains(pat) {
            return true
        }
        // "S. 599" / "p. 12-13" page-reference form: period+space+digits
        if sentence.range(of: "[Ss]\\. \\d", options: .regularExpression) != nil { return true }
        if sentence.range(of: "[Pp]p?\\. \\d", options: .regularExpression) != nil { return true }
        // Bibliography entry: "Author, Title, Place Year." — year+period tail
        // with multiple comma-separated fields (Strong, Dordrecht 1974.)
        if sentence.range(of: ", (19|20)\\d\\d\\.", options: .regularExpression) != nil,
           sentence.components(separatedBy: ",").count >= 3 { return true }
        // Footnote string: ≥2 semicolon-separated number references ("II, 372; … 32, 35;")
        if sentence.range(of: "; \\d+; ", options: .regularExpression) != nil { return true }
        // Bibliography tail: "..., The Hague 1974." / "...(Dordrecht 2004)."
        if sentence.range(of: " (19|20)\\d\\d\\.$", options: .regularExpression) != nil { return true }
        // Number-list density: ≥3 ", <digit>" sequences ("II, 372; … 32, 35;")
        if sentence.ranges(of: ", \\d+").count >= 3 { return true }
        return false
    }

    /// True if the string contains any CJK ideograph (U+3400–4DBF ext-A,
    /// U+4E00–9FFF core, U+20000+ ext-B+, plus CJK punctuation).
    public static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            (0x2E80...0x2EFF).contains(scalar.value)      // CJK Radicals
            || (0x3000...0x303F).contains(scalar.value)   // CJK Symbols & Punctuation
            || (0x3400...0x4DBF).contains(scalar.value)   // CJK Ext A
            || (0x4E00...0x9FFF).contains(scalar.value)   // CJK Unified
            || (0xF900...0xFAFF).contains(scalar.value)   // CJK Compat
            || (0x20000...0x2FA1F).contains(scalar.value) // CJK Ext B–F / Compat Supp
        }
    }

    /// 书级英文判定：累计 ASCII 占比 ≥ 阈值即英文书。
    public static func isEnglishBook(asciiRatio: Double) -> Bool {
        asciiRatio >= englishBookMinASCIIRatio
    }

    /// Computes priority score for a sentence. Hitting academic concept keywords adds bonus points;
    /// sentence length serves as base score fallback.
    public static func score(for sentence: String) -> Int {
        var hits = 0
        let lower = sentence.lowercased()
        for kw in academicConceptKeywords {
            if kw.allSatisfy({ $0.isASCII }) {
                if lower.contains(kw.lowercased()) {
                    hits += 1
                }
            } else {
                if sentence.contains(kw) {
                    hits += 1
                }
            }
        }
        return (hits * 100) + sentence.count
    }

    // MARK: - Date & Hash Helpers

    public static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    public static func dateKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    public static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash
    }

    // MARK: - Extract & Selection

    private struct ScoredCandidate {
        let quote: Quote
        let score: Int
    }

    /// Extracts up to `limit` high-value sentences from the library into `daily_quotes`.
    /// Idempotent: deletes any existing rows for the given date, then inserts new rows.
    public static func extract(from store: IndexStore, limit: Int = defaultExtractionLimit, date: Date = Date()) throws -> [Quote] {
        var bookPages: [String: (fileName: String, pages: [Int: [(sentence: String, score: Int)]])] = [:]
        // 书级英文判定累计器：forEachCandidatePage 期间按 bookID 累计
        // text_norm 的 ASCII / 总（非空白）字符，抽取轮结束后按书判定。
        var bookASCIICount: [String: Int] = [:]
        var bookTotalCount: [String: Int] = [:]

        try store.forEachCandidatePage { page in
            // 书级英文累计（text_norm 基准，含全部页）。
            var ascii = 0
            var total = 0
            for scalar in page.textNorm.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                total += 1
                if scalar.isASCII { ascii += 1 }
            }
            bookASCIICount[page.bookID, default: 0] += ascii
            bookTotalCount[page.bookID, default: 0] += total

            // 每日一句不摘取中文文献中的英文部分。
            // 中文文献集中在论文域：按 ContentCategoryFolders.current.papers
            // 判定，配置为空时不跳过任何路径（中文书本身也不提取英文句）。
            if contentCategoryPathMatches(page.rootPath, ContentCategoryFolders.current.papers) { return }
            let rawSentences = splitSentences(from: page.textOriginal)
            var valid: [(sentence: String, score: Int)] = []
            for s in rawSentences {
                if isValidQuote(s) {
                    valid.append((sentence: s, score: score(for: s)))
                }
            }
            guard !valid.isEmpty else { return }

            // Take up to maxQuotesPerPage (2), highest score first
            valid.sort { $0.score > $1.score }
            let topPage = Array(valid.prefix(maxQuotesPerPage))

            if bookPages[page.bookID] == nil {
                bookPages[page.bookID] = (fileName: page.fileName, pages: [:])
            }
            bookPages[page.bookID]?.pages[page.pageNumber] = topPage
        }

        // 抽取轮结束后按书判定：非英文书（ASCII 占比 < 80%）的候选全部丢弃，
        // 中文书内嵌的英文段随之整本出局。
        for bookID in Array(bookPages.keys) {
            let ascii = bookASCIICount[bookID] ?? 0
            let total = max(bookTotalCount[bookID] ?? 0, 1)
            if !isEnglishBook(asciiRatio: Double(ascii) / Double(total)) {
                bookPages.removeValue(forKey: bookID)
            }
        }

        var bookQueues: [String: [ScoredCandidate]] = [:]
        let sortedBookIDs = bookPages.keys.sorted()

        for bookID in sortedBookIDs {
            guard let entry = bookPages[bookID] else { continue }
            var bookCandidates: [ScoredCandidate] = []
            for (pageNum, candidates) in entry.pages {
                for c in candidates {
                    bookCandidates.append(ScoredCandidate(
                        quote: Quote(bookID: bookID, fileName: entry.fileName, pageNumber: pageNum, sentence: c.sentence),
                        score: c.score
                    ))
                }
            }
            // Sort by score descending, with deterministic tie-breaking
            bookCandidates.sort {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.quote.pageNumber != $1.quote.pageNumber { return $0.quote.pageNumber < $1.quote.pageNumber }
                return $0.quote.sentence < $1.quote.sentence
            }
            bookQueues[bookID] = Array(bookCandidates.prefix(maxQuotesPerBook))
        }

        // Round-robin selection across books for inter-book balance ("书间均衡")
        var selectedQuotes: [Quote] = []
        var addedInRound = true
        while addedInRound && selectedQuotes.count < limit {
            addedInRound = false
            for bookID in sortedBookIDs {
                if selectedQuotes.count >= limit { break }
                if var queue = bookQueues[bookID], !queue.isEmpty {
                    let item = queue.removeFirst()
                    bookQueues[bookID] = queue
                    selectedQuotes.append(item.quote)
                    addedInRound = true
                }
            }
        }

        // Idempotent write: delete same day, then insert
        let dateStr = formatDate(date)
        for i in 0..<selectedQuotes.count {
            selectedQuotes[i].quoteDate = dateStr
        }
        try store.insertDailyQuotes(selectedQuotes, forDate: dateStr)

        return selectedQuotes
    }

    /// Deterministically selects 1 quote from the daily_quotes pool using a stable hash of YYYYMMDD.
    /// Returns nil if the pool is empty ("无摘录池").
    public static func today(store: IndexStore, date: Date = Date()) -> Quote? {
        guard let quotes = try? store.allDailyQuotes(), !quotes.isEmpty else {
            return nil
        }
        let key = dateKey(date)
        let hash = stableHash(key)
        let index = Int(hash % UInt64(quotes.count))
        return quotes[index]
    }

    public static func todayThrowing(store: IndexStore, date: Date = Date()) throws -> Quote? {
        let quotes = try store.allDailyQuotes()
        guard !quotes.isEmpty else { return nil }
        let key = dateKey(date)
        let hash = stableHash(key)
        let index = Int(hash % UInt64(quotes.count))
        return quotes[index]
    }

    public func extract(from store: IndexStore, limit: Int = defaultExtractionLimit, date: Date = Date()) throws -> [Quote] {
        try Self.extract(from: store, limit: limit, date: date)
    }

    public func today(store: IndexStore, date: Date = Date()) -> Quote? {
        Self.today(store: store, date: date)
    }
}
