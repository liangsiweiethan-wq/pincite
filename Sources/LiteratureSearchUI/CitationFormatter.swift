import Foundation

// MARK: - Citation formatting (著作类多体例注册表)
//
// Supports 21 book-style citation formats across Chinese and international styles.
// Rendering uses only citation-shaped filenames, metadata, and physical page numbers;
// it never reads book contents. Missing metadata is omitted rather than invented.

public enum CitationStyle: String, CaseIterable {
    case faxueYinzhuShouce  // Chinese legal citation handbook style
    case zhongguoFaxue      // Chinese legal journal style
    case faxueYanjiu        // Chinese legal journal style
    case beidaFabao         // Chinese legal database style
    case gbt7714            // GB/T 7714-2015
    case zhongwaiFaxue     // Chinese legal journal style
    case zhengfaLuntan      // Chinese legal journal style
    case falvKexue          // Chinese legal journal style
    case bijiaofaYanjiu     // Chinese legal journal style
    case bluebook           // The Bluebook
    case oscola             // OSCOLA
    case apa7               // APA 7th
    case mla9               // MLA 9th
    case chicago18Notes     // Chicago 18 (notes)
    case chicago18AuthorDate// Chicago 18 (author-date)
    case harvard            // Harvard
    case vancouver          // Vancouver
    case ieee               // IEEE
    case aglc               // AGLC
    case mcgill             // McGill Guide
    case ama                // AMA 11th

    public var displayName: String {
        switch self {
        case .faxueYinzhuShouce: return "中文引注手册体例"
        case .zhongguoFaxue: return "中文期刊体例 A"
        case .faxueYanjiu: return "中文期刊体例 B"
        case .beidaFabao: return "中文检索平台体例"
        case .gbt7714: return "GB/T 7714-2015"
        case .zhongwaiFaxue: return "中文期刊体例 C"
        case .zhengfaLuntan: return "中文期刊体例 D"
        case .falvKexue: return "中文期刊体例 E"
        case .bijiaofaYanjiu: return "中文期刊体例 F"
        case .bluebook: return "Bluebook (21st ed.)"
        case .oscola: return "OSCOLA (4th ed.)"
        case .apa7: return "APA 7th"
        case .mla9: return "MLA 9th"
        case .chicago18Notes: return "Chicago 18 (notes)"
        case .chicago18AuthorDate: return "Chicago 18 (author-date)"
        case .harvard: return "Harvard"
        case .vancouver: return "Vancouver"
        case .ieee: return "IEEE"
        case .aglc: return "AGLC 4"
        case .mcgill: return "McGill Guide"
        case .ama: return "AMA 11th"
        }
    }
}

// MARK: - 著作元数据解析（保守，绝不编造）

public struct BookCitationMeta {
    public var author: String?
    public var title: String
    public var publisher: String?
    public var year: String?
    public var edition: String?
    /// Journal-shaped filenames may already contain the citation title; zhFamily
    /// output preserves that order without adding another title wrapper.
    public var journalForm: Bool

    public init(author: String?, title: String, publisher: String? = nil,
                year: String? = nil, edition: String? = nil, journalForm: Bool = false) {
        self.author = author
        self.title = title
        self.publisher = publisher
        self.year = year
        self.journalForm = journalForm
        self.edition = edition
    }

    /// 从文件名 + 元数据解析著作引注字段。解析失败时 title = cleanFileName，
    /// 其余字段一律 nil。规则保守：年份取边界独立的尾部出现；版次仅认词尾
    /// token；出版社仅在高度确信（社/书局/Press 词尾或含 CJK 的短括注）时提取。
    public static func parse(fileName: String, title: String?, author: String?) -> BookCitationMeta {
        parsePipeline(base: CitationFormatter.cleanFileName(fileName), title: title,
                      author: author, unpackBrackets: true)
    }

    static func parsePipeline(base: String, title: String?, author: String?,
                              unpackBrackets: Bool) -> BookCitationMeta {
        var author = author?.trimmingCharacters(in: .whitespacesAndNewlines)
        if author?.isEmpty == true { author = nil }

        // 四步各剥一类字段，顺序即判定优先级（作者/书名 → 年份 → 版次 → 出版社）；
        // 每步只动自己那一类，尾部逗号类残留只在步骤之间清（清早了会让出版社
        // 锚定正则提前命中，判定顺序即行为）。
        let split = splitAuthorTitle(remainder: base, author: author)
        author = split.author
        var publisher = split.publisher
        let hasJournalPattern = split.hasJournalPattern

        // 第⓪步：元数据 title/author 皆空、文件名无 CJK 时，
        // 先按常见英文书命名拆括号组。作者组只认串尾那一组；版次组见 unpackAuthorEditionBrackets。
        // 拆出的 author/title/edition 参加后续常规管道（年份/版次/出版社仍在
        // 余文上跑，英文书名里的年份照旧剥离）。
        var remainderForSteps = split.remainder
        var parsedAuthor = author
        var parsedTitle: String? = nil
        var bracketEdition: String? = nil
        if unpackBrackets, author == nil, title?.isEmpty != false,
           !CitationFormatter.containsCJK(base),
           let unpacked = unpackAuthorEditionBrackets(split.remainder) {
            parsedAuthor = unpacked.author
            parsedTitle = unpacked.title
            bracketEdition = unpacked.edition
            remainderForSteps = unpacked.remainder
        }
        if let p = parsedAuthor { author = p }

        let (afterYear, year) = stripYear(remainder: remainderForSteps)
        let (afterEdition, edition) = stripEdition(remainder: afterYear)
        var remainder = trimTrailingSeparators(afterEdition)
        let (afterPublisher, extractedPublisher) = stripPublisher(remainder: remainder)
        if let p = extractedPublisher { publisher = p }
        remainder = trimTrailingSeparators(afterPublisher)
        let finalEdition = edition ?? bracketEdition

        // 英文书：元数据 title 非空、无 CJK 且文件名无 CJK 时采用（沿用旧规则）。
        let englishTitle: String? = {
            guard let t = title, !t.isEmpty else { return nil }
            guard !CitationFormatter.containsCJK(t), !CitationFormatter.containsCJK(base) else { return nil }
            return t
        }()
        var finalTitle = englishTitle ?? parsedTitle ?? remainder
        if finalTitle.isEmpty { finalTitle = base }
        if hasJournalPattern, finalTitle.hasSuffix("年") {
            finalTitle = String(finalTitle.dropLast())
        }
        if hasJournalPattern {
            // 论文形态：title 含「…，载《刊名》」语序，zhFamily 直接用
            // finalTitle 不再加书名号（由调用形态保证可读），页码照旧。
            return BookCitationMeta(author: author, title: finalTitle,
                                    publisher: publisher, year: year,
                                    edition: finalEdition, journalForm: true)
        }
        return BookCitationMeta(author: author, title: finalTitle,
                                publisher: publisher, year: year, edition: finalEdition)
    }

    /// 旧解析入口（全库误判检查用）：与 `parse` 逐字相同，但**跳过**
    public static func legacyParse(fileName: String) -> BookCitationMeta {
        return parsePipeline(base: fileName, title: nil, author: nil, unpackBrackets: false)
    }

    /// 第⓪步：常见英文书命名的尾部括号组拆分。
    ///
    /// 形态：`书名 (版次) (人名, 人名, …)`。版次组见 unpackAuthorEditionBrackets。
    ///
    /// 判别从严（宁可不拆，不可拆错）：
    /// - 末尾括号组内按逗号分段，**每段都像人名**（2–4 个首字母大写的词，
    ///   可含 `W.` / `H. L. A.` 类缩写/首字母），且不含出版社/丛书词
    ///   （Press / University / Series / Handbook / Studies / Library /
    ///   Classics / Press 族）→ 作 author；
    /// - `(Second Edition)` / `(2nd ed.)` / `(Revised Edition)` 类 → edition；
    /// - 其他括号组原样留在 title。
    ///
    /// 只在括号组位于串尾时拆；作者组须在版本组之后（或紧跟书名）。返回 nil
    /// = 无可拆内容（调用方保持原行为）。
    static func unpackAuthorEditionBrackets(_ s: String) -> (remainder: String, title: String, author: String?, edition: String?)? {
        let body = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = allParenGroups(body)
        guard !groups.isEmpty else { return nil }

        // 作者组只认紧贴串尾的那一组：中段人名括注多为译者/编者（`Quill, Avery, A Sample
        // Notes (Sample Translator), Example Journal of Samples, 2001` 里是译者），
        // 拆了会把译者当作者（项目收紧）。其余括注原样留在书名里。
        var authorGroup: ParenGroup? = nil
        if let last = groups.last,
           body[last.range.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty,
           !hasNestedParens(last.inner),
           looksLikeAuthorList(last.inner.trimmingCharacters(in: .whitespaces)) {
            authorGroup = last
        }

        var editionGroup: ParenGroup? = nil
        if let author = authorGroup {
            let authorStartsInsideAnother = groups.contains {
                $0.range != author.range
                    && $0.range.lowerBound < author.range.lowerBound
                    && $0.range.upperBound >= author.range.upperBound
            }
            if authorStartsInsideAnother {
                // 嵌套括号：外层不是干净的 `(版次) (作者)` 形态，版次一律不拆。
            } else if let idx = groups.firstIndex(where: { $0.range == author.range }), idx > 0 {
                let inner = groups[idx - 1].inner.trimmingCharacters(in: .whitespaces)
                if looksLikeEnglishEdition(inner) { editionGroup = groups[idx - 1] }
            }
        } else if let last = groups.last,
                  body[last.range.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty {
            let inner = last.inner.trimmingCharacters(in: .whitespaces)
            if looksLikeEnglishEdition(inner) { editionGroup = last }
        }
        guard authorGroup != nil || editionGroup != nil else { return nil }

        // 切掉作者组与版次组（区间从右往左删，避免索引错位），其余留在正文。
        var removedRanges: [Range<String.Index>] = []
        if let g = authorGroup { removedRanges.append(g.range) }
        if let g = editionGroup { removedRanges.append(g.range) }
        var result = ""
        var cursor = body.startIndex
        for range in removedRanges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard range.lowerBound >= cursor else { continue }
            result += body[cursor..<range.lowerBound]
            cursor = range.upperBound
        }
        result += body[cursor...]
        result = collapseSpacesAndDanglingSeparators(result)
        guard !result.isEmpty else { return nil }
        return (result, result,
                authorGroup?.inner.trimmingCharacters(in: .whitespaces),
                editionGroup?.inner.trimmingCharacters(in: .whitespaces))
    }

    /// 括号组内还套着括号 → 不是干净作者/版次组（`(Example, H. J.
    /// (Example, H. J. etc.)` 这类截断+嵌套串）。
    static func hasNestedParens(_ inner: String) -> Bool {
        inner.contains("(") || inner.contains("（") || inner.contains(")") || inner.contains("）")
    }

    /// 删括号组后留下的双空格 / 悬空逗号 / 悬空句点（`… Philosophy . `）。
    static func collapseSpacesAndDanglingSeparators(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s*,\s*$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+([,.])"#, with: "$1", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct ParenGroup {
        let range: Range<String.Index>
        let inner: String
    }

    /// 全串**最外层**平衡括号组 `(...)` / `（...）`，按出现顺序返回。
    /// 栈扫描：嵌套的组不单独返回（其内文含 `(`，由调用方按嵌套拒绝）；
    /// 未闭合的 `(` 不产组（`… (Example, H. J. etc.)`
    /// 这类截断串里，内层 `(Example, H. J.)` 不是文件名级括注，绝不拆）。
    private static func allParenGroups(_ s: String) -> [ParenGroup] {
        let chars = Array(s)
        let indices = Array(s.indices)
        var stack: [Int] = []
        var result: [ParenGroup] = []
        for i in 0..<chars.count {
            let ch = chars[i]
            if ch == "(" || ch == "（" {
                stack.append(i)
            } else if ch == ")" || ch == "）" {
                guard let openIdx = stack.popLast() else { continue }
                if stack.isEmpty {
                    let inner = String(chars[(openIdx + 1)..<i])
                    let startIdx = indices[openIdx]
                    let endIdx = (i + 1 < indices.count) ? indices[i + 1] : s.endIndex
                    result.append(ParenGroup(range: startIdx..<endIdx, inner: inner))
                }
            }
        }
        return result
    }

    private static let nonAuthorWords: Set<String> = [
        "press", "university", "series", "handbook", "studies", "library",
        // 出版社常见的姓氏式社名（`(Example House)` = 示例出版社）。
        "examplehouse", "examplepress", "kluwer", "wolters", "beck", "nomos", "nijhoff",
        "routledge", "palgrave", "macmillan", "bloomsbury", "elsevier",
        "classics", "edition", "editions", "vol", "volume", "volume s",
        "revised", "rev", "trans", "translated", "editor", "editors", "ed",
        "publishing", "publications", "books", "papers", "lectures", "works",
        "collection", "introduction", "companion", "encyclopedia", "dictionary",
    ]

    /// 逗号分隔、每段都像人名（2–4 个首字母大写词，可含 `W.` 缩写），且不含
    /// 出版社/丛书词 → 作者组。
    static func looksLikeAuthorList(_ inner: String) -> Bool {
        guard !inner.isEmpty, !CitationFormatter.containsCJK(inner) else { return false }
        let parts = inner.components(separatedBy: CharacterSet(charactersIn: ","))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return false }
        let tokens = inner.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        for w in tokens where nonAuthorWords.contains(w) { return false }

        for part in parts {
            guard looksLikePersonName(part) else { return false }
        }
        return true
    }

    /// 单个人名段：2–4 个词，每个词要么首字母大写，要么是 `W.`/`H.`/`L.` 缩写，
    /// 要么是 `&`（多人合著分隔，罕见但合法）。含 CJK 一律否。
    ///
    /// 从严补充（误判检查后）
    /// - 词须**全大写或首字母大写其余小写**（`JOHN DOE` 与 `J. Doe`
    ///   均收；`PENGUIN` 类全大写机构名靠词表/长度兜，不在此处猜）；
    /// - 末词不得以句点结尾（`Example, H. J. etc.` 的 `etc.` 不是人名）；
    /// - 词表拒绝地点/角色/来源词（`Porto Alegre`、`Open Access`、
    ///   `Example, H. J.` 这类截断名由「末词不带句点但作者组须在括号里」兜住）。
    static func looksLikePersonName(_ s: String) -> Bool {
        guard !CitationFormatter.containsCJK(s) else { return false }
        let words = s.split(separator: " ").map(String.init)
        guard (2...4).contains(words.count) else { return false }
        guard let last = words.last, !last.hasSuffix(".") else { return false }
        for word in words {
            if word == "&" { continue }
            if isInitialism(word) { continue }
            if nonNameWords.contains(word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,"))) { return false }
            guard let first = word.first, first.isUppercase else { return false }
            let rest = word.dropFirst()
            let allUpper = word.allSatisfy { $0.isUppercase || !$0.isLetter }
            let allLower = rest.allSatisfy { ch in
                ch.isLowercase || ch.isUppercase || ch == "'" || ch == "’" || ch == "-" || ch == "."
            }
            guard allUpper || allLower else { return false }
            guard !word.contains(".") || isInitialism(word) else { return false }
        }
        return true
    }

    /// 名字段里的地点/来源/角色词（出现即否）。
    private static let nonNameWords: Set<String> = [
        "open", "access", "unknown", "etc", "forthcoming", "anonymous", "editor",
        "trans", "edited", "editedby", "review", "reviews", "copy", "bibtex",
        "porto", "alegre", "são", "sao", "rio", "new", "york", "london",
    ]

    /// `W.` / `H. L. A.` 拆成词后单 token `W.` 属缩写。
    static func isInitialism(_ word: String) -> Bool {
        guard word.count == 2, word.last == "." else { return false }
        return word.first?.isUppercase == true
    }

    private static let englishEditionPattern =
        #"^(?:(?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|eleventh|twelfth|revised|enlarged|expanded|updated|new|2nd|3rd|4th|5th|6th|7th|8th|9th|10th)\s+)*edition$"#
        + #"|^(?:\d+(?:st|nd|rd|th))\s+ed(?:ition)?\.?$"#
        + #"|^(?:rev(?:ised)?|enlarged|expanded|updated)\.?\s+ed(?:ition)?\.?$"#

    static func looksLikeEnglishEdition(_ inner: String) -> Bool {
        let t = inner.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty,
              t.split(separator: " ").count <= 4,
              t.unicodeScalars.allSatisfy({ $0.isASCII || CharacterSet.whitespaces.contains($0) })
        else { return false }
        return t.range(of: englishEditionPattern, options: .regularExpression) != nil
            || t.range(of: #"^(?:revised|enlarged|expanded|updated|new|\d+(?:st|nd|rd|th))\s+ed\.$"#,
                       options: .regularExpression) != nil
    }

    private static func splitAuthorTitle(remainder: String, author: String?)
        -> (remainder: String, author: String?, publisher: String?, hasJournalPattern: Bool) {
        var remainder = remainder
        var author = author
        var publisher: String? = nil
        var hasJournalPattern = false
        if let colonR = remainder.range(of: "：") {
            let before = String(remainder[..<colonR.lowerBound]).trimmingCharacters(in: .whitespaces)
            let after = String(remainder[colonR.upperBound...])
            if let open = after.firstIndex(of: "《") {
                // 栈式配对：从《起扫描，遇《压栈遇》弹栈，首个清栈点即书名闭合。
                var depth = 0
                var close: String.Index? = nil
                var idx = open
                while idx < after.endIndex {
                    let ch = after[idx]
                    if ch == "《" { depth += 1 }
                    else if ch == "》" {
                        depth -= 1
                        if depth == 0 { close = idx; break }
                    }
                    idx = after.index(after: idx)
                }
                if let close {
                    var inner = String(after[after.index(after: open)..<close])
                    let tail = String(after[after.index(after: close)...])
                    // 书名号内嵌社名（文件名本身把社名包进书名号：书名号越界形态）
                    // → 内文再切：末段（分隔）以 社/馆/书局/Press 结尾即社名，挪出。
                    if let commaR = inner.range(of: "，", options: .backwards) {
                        let seg = String(inner[commaR.upperBound...]).trimmingCharacters(in: .whitespaces)
                        let looksPub = seg.hasSuffix("社") || seg.hasSuffix("馆")
                            || seg.hasSuffix("书局") || seg.hasSuffix("公司")
                            || seg.lowercased().hasSuffix("press")
                        if looksPub, seg.count <= 14,
                           CitationFormatter.containsCJK(String(inner[..<commaR.lowerBound])) {
                            inner = String(inner[..<commaR.lowerBound])
                            if publisher == nil { publisher = seg }
                        }
                    }
                    // 论文形态：内文含《》 或 tail 含「载《刊名》」。
                    let tailHasJournal = tail.contains("载《") && tail.contains("》")
                    if inner.contains("《") && inner.contains("》") || tailHasJournal {
                        // 保持「作者：《内文》tail」原语序，仅认作者与剥离年份/
                        // 版次/出版社由后续常规路径处理；title 取内文供模板。
                        if !before.isEmpty, !before.contains("《"), before.count <= 40 {
                            author = author ?? before
                        }
                        hasJournalPattern = true
                        remainder = inner + tail
                    } else if !before.isEmpty, !before.contains("《"), !before.contains("》"),
                              before.count <= 40 {
                        author = author ?? before
                        remainder = inner + tail
                    }
                }
            }
        }
        return (remainder, author, publisher, hasJournalPattern)
    }

    private static func stripYear(remainder: String) -> (remainder: String, year: String?) {
        var remainder = remainder
        var year: String? = nil
        let yearPat = #"(?<![0-9A-Za-z])(19|20)\d{2}(?![0-9A-Za-z])"#
        var matches: [Range<String.Index>] = []
        var start = remainder.startIndex
        while let r = remainder.range(of: yearPat, options: .regularExpression,
                                        range: start..<remainder.endIndex) {
            matches.append(r)
            start = r.upperBound
        }
        if let m = matches.last(where: { remainder[$0.upperBound...].allSatisfy({ !$0.isNumber }) })
            ?? matches.last {
            year = String(remainder[m])
            remainder.removeSubrange(m)
            // "出版社2001年版" → 年份剥离后残留的词尾"年版"随之移除。
            if let r = remainder.range(of: "年版$", options: .regularExpression) {
                remainder.removeSubrange(r)
            }
        }
        return (remainder, year)
    }

    private static func stripEdition(remainder: String) -> (remainder: String, edition: String?) {
        var remainder = remainder
        var edition: String? = nil
        let editionParens = #"[（(](?:第[0-9一二三四五六七八九十]+(?:修订)?版|修订版|增订版)[)）](?=[，,]?[^（）()]{0,30}$)"#
        let editionBare = #"(?:第[0-9一二三四五六七八九十]+(?:修订)?版|[0-9]+版|修订版|增订版)$"#
        if let r = remainder.range(of: editionParens, options: .regularExpression)
            ?? remainder.range(of: editionBare, options: .regularExpression) {
            var token = String(remainder[r])
            if token.hasPrefix("（") || token.hasPrefix("(") {
                token = String(token.dropFirst().dropLast())
            }
            edition = token
            remainder.removeSubrange(r)
        }
        return (remainder, edition)
    }

    private static func stripPublisher(remainder: String) -> (remainder: String, publisher: String?) {
        var remainder = remainder
        var publisher: String? = nil
        if let r = remainder.range(of: #"[（(][^（）()]{1,12}[)）]$"#, options: .regularExpression) {
            let inner = String(remainder[r]).dropFirst().dropLast()
            if CitationFormatter.containsCJK(String(inner)) || inner.lowercased().hasSuffix("press") {
                publisher = String(inner)
                remainder.removeSubrange(r)
            }
        } else if let r = remainder.range(of: #"[，,：:—–\-]([^，,：:—–\-]{2,30})$"#, options: .regularExpression) {
            let seg = String(remainder[r].dropFirst()).trimmingCharacters(in: .whitespaces)
            let before = remainder[..<r.lowerBound]
            let looksPublisher = seg.hasSuffix("社") || seg.hasSuffix("书局")
                || seg.hasSuffix("馆")   // 示例出版社/XX书馆
                || seg.hasSuffix("店")   // 生活·读书·新知示例书店
                || seg.hasSuffix("公司") // 吉林出版集团有限责任公司
                || seg.lowercased().hasSuffix("press")
            let lenOK = CitationFormatter.containsCJK(seg) ? seg.count <= 14 : seg.count <= 30
            if before.count >= 3, looksPublisher, lenOK {
                publisher = seg
                remainder.removeSubrange(r)
            }
        }
        return (remainder, publisher)
    }

    /// 清尾部残留的逗号类分隔符（年份/版次剥离后、出版社剥离后各清一次）。
    private static func trimTrailingSeparators(_ remainder: String) -> String {
        var s = remainder.trimmingCharacters(in: .whitespaces)
        while let last = s.last, "，,：:—–-·、".contains(last) {
            s.removeLast()
        }
        return s
    }
}

// MARK: - 格式注册表

public enum CitationFormatGroup: String, CaseIterable {
    case chinese
    case englishIntl
    case other
}

public struct CitationFormatDescriptor {
    public let id: CitationStyle
    public let l10nName: String
    public let group: CitationFormatGroup
    public let template: (BookCitationMeta, Int?) -> String

    public init(id: CitationStyle, l10nName: String, group: CitationFormatGroup,
                template: @escaping (BookCitationMeta, Int?) -> String) {
        self.id = id
        self.l10nName = l10nName
        self.group = group
        self.template = template
    }
}

public enum CitationFormatRegistry {
    public static let all: [CitationFormatDescriptor] = [
        .init(id: .faxueYinzhuShouce, l10nName: CitationStyle.faxueYinzhuShouce.displayName,
              group: .chinese, template: CitationFormatter.zhFamily),
        .init(id: .zhongguoFaxue, l10nName: CitationStyle.zhongguoFaxue.displayName,
              group: .chinese, template: CitationFormatter.zhFamily),
        .init(id: .faxueYanjiu, l10nName: CitationStyle.faxueYanjiu.displayName,
              group: .chinese, template: CitationFormatter.zhFamily),
        .init(id: .beidaFabao, l10nName: CitationStyle.beidaFabao.displayName,
              group: .chinese, template: CitationFormatter.beidaFabao),
        .init(id: .gbt7714, l10nName: CitationStyle.gbt7714.displayName,
              group: .chinese, template: CitationFormatter.gbt7714),
        .init(id: .zhongwaiFaxue, l10nName: CitationStyle.zhongwaiFaxue.displayName,
              group: .chinese, template: CitationFormatter.zhFamily),
        .init(id: .zhengfaLuntan, l10nName: CitationStyle.zhengfaLuntan.displayName,
              group: .chinese, template: CitationFormatter.zhFamily),
        .init(id: .falvKexue, l10nName: CitationStyle.falvKexue.displayName,
              group: .chinese, template: CitationFormatter.zhFamily),
        .init(id: .bijiaofaYanjiu, l10nName: CitationStyle.bijiaofaYanjiu.displayName,
              group: .chinese, template: CitationFormatter.zhFamily),
        .init(id: .bluebook, l10nName: CitationStyle.bluebook.displayName,
              group: .englishIntl, template: CitationFormatter.bluebook),
        .init(id: .oscola, l10nName: CitationStyle.oscola.displayName,
              group: .englishIntl, template: CitationFormatter.oscola),
        .init(id: .apa7, l10nName: CitationStyle.apa7.displayName,
              group: .englishIntl, template: CitationFormatter.apa7),
        .init(id: .mla9, l10nName: CitationStyle.mla9.displayName,
              group: .englishIntl, template: CitationFormatter.mla9),
        .init(id: .chicago18Notes, l10nName: CitationStyle.chicago18Notes.displayName,
              group: .englishIntl, template: CitationFormatter.chicago18Notes),
        .init(id: .chicago18AuthorDate, l10nName: CitationStyle.chicago18AuthorDate.displayName,
              group: .englishIntl, template: CitationFormatter.chicagoAuthorDate),
        .init(id: .harvard, l10nName: CitationStyle.harvard.displayName,
              group: .englishIntl, template: CitationFormatter.harvard),
        .init(id: .vancouver, l10nName: CitationStyle.vancouver.displayName,
              group: .englishIntl, template: CitationFormatter.vancouver),
        .init(id: .ieee, l10nName: CitationStyle.ieee.displayName,
              group: .englishIntl, template: CitationFormatter.ieee),
        .init(id: .aglc, l10nName: CitationStyle.aglc.displayName,
              group: .englishIntl, template: CitationFormatter.aglc),
        .init(id: .mcgill, l10nName: CitationStyle.mcgill.displayName,
              group: .englishIntl, template: CitationFormatter.mcgill),
        .init(id: .ama, l10nName: CitationStyle.ama.displayName,
              group: .englishIntl, template: CitationFormatter.ama),
    ]

    public static func descriptor(for style: CitationStyle) -> CitationFormatDescriptor {
        all.first { $0.id == style } ?? all[0]
    }

    public static func styles(in group: CitationFormatGroup) -> [CitationStyle] {
        all.filter { $0.group == group }.map(\.id)
    }
}

// MARK: - 模板实现（模板内缺字段一律省略，绝不编造；无出版地字段）

extension CitationFormatter {

    /// 裸元数据：作者/出版社/年份皆无（仅版次不算结构化依据）→ 保留旧版
    /// "文件名本体"形态，保证旧输出逐字节兼容。
    static func isBare(_ m: BookCitationMeta) -> Bool {
        m.author == nil && m.publisher == nil && m.year == nil
    }

    static func bareText(_ m: BookCitationMeta, page: Int?) -> String {
        let t = m.title + (m.edition ?? "")
        if containsCJK(t) {
            return t + (page.map { "，第\($0)页。" } ?? "")
        }
        return t + (page.map { ", p. \($0)." } ?? "")
    }

    /// Shared Chinese citation-family rendering (author: title, publisher + year).
    static func zhFamily(_ m: BookCitationMeta, page: Int?) -> String {
        if isBare(m) { return bareText(m, page: page) }
        if m.journalForm {
            // 论文形态：title 已是「…，载《刊名》」原语序（书名号在内文自带），
            // 不再外套书名号；页码照常。
            var s = m.author.map { "\($0)：" } ?? ""
            s += m.title
            if let n = page { s += "，第\(n)页" }
            return s + "。"
        }
        if containsCJK(m.title) {
            var s = m.author.map { "\($0)：" } ?? ""
            s += "《\(m.title)》"
            if let e = m.edition { s += "（\(e)）" }
            if let p = m.publisher, let y = m.year { s += "，\(p)\(y)年版"
            } else if let y = m.year { s += "，\(y)年版"
            } else if let p = m.publisher { s += "，\(p)" }
            if let n = page { s += "，第\(n)页" }
            return s + "。"
        }
        var s = m.author.map { "\($0). " } ?? ""
        s += m.title
        if let e = m.edition { s += " (\(e))" }
        if let p = m.publisher, let y = m.year { s += ". \(p), \(y)"
        } else if let y = m.year { s += ", \(y)"
        } else if let p = m.publisher { s += ". \(p)" }
        if let n = page { return s + ", p. \(n)." }
        return s  // 书目级拉丁形态保持旧版无句点尾巴（如"..., 2001"）
    }

    /// Chinese database style: author: title, publisher, year, page N.
    static func beidaFabao(_ m: BookCitationMeta, page: Int?) -> String {
        if isBare(m) { return bareText(m, page: page) }
        if containsCJK(m.title) {
            var s = m.author.map { "\($0)：" } ?? ""
            s += "《\(m.title)》"
            if let p = m.publisher { s += ",\(p)" }
            if let y = m.year { s += ",\(y)" }
            if let n = page { s += ",第\(n)页" }
            return s + "。"
        }
        var s = m.author.map { "\($0), " } ?? ""
        s += m.title
        if let p = m.publisher { s += ", \(p)" }
        if let y = m.year { s += ", \(y)" }
        if let n = page { s += ", p. \(n)" }
        return s + "."
    }

    /// GB/T 7714-2015 著作：作者. 书名[M]. 版次. 出版社, 年份: N.
    /// （数据模型无出版地字段 → 直接略去，不占位。）
    static func gbt7714(_ m: BookCitationMeta, page: Int?) -> String {
        if isBare(m) { return bareText(m, page: page) }
        var s = m.author.map { "\($0). " } ?? ""
        s += "\(m.title)[M]."
        if let e = m.edition { s += " \(e)." }
        if let p = m.publisher { s += " \(p)" }
        if let y = m.year { s += (m.publisher != nil ? ", " : " ") + "\(y)" }
        if let n = page { s += ": \(n)" }
        return s + "."
    }

    /// Bluebook：Author, Title page (Year).（英文本位体例，CJK 元数据亦按原样渲染）
    static func bluebook(_ m: BookCitationMeta, page: Int?) -> String {
        if isBare(m) { return bareText(m, page: page) }
        var s = m.author.map { "\($0), " } ?? ""
        s += m.title
        if let n = page { s += " \(n)" }
        if let y = m.year { s += " (\(y))" }
        return s + "."
    }

    /// OSCOLA：Author, Title (Publisher Year) page.
    static func oscola(_ m: BookCitationMeta, page: Int?) -> String {
        if isBare(m) { return bareText(m, page: page) }
        var s = m.author.map { "\($0), " } ?? ""
        s += m.title
        let inner = [m.publisher, m.year].compactMap { $0 }.joined(separator: " ")
        if !inner.isEmpty { s += " (\(inner))" }
        if let n = page { s += " \(n)" }
        return s + "."
    }

    /// APA 7：Author (Year). Title (ed.). Publisher. 页码 → Title (p. N). Publisher.
    /// CJK 元数据用全角括号；页码与版次同现时节略版次（页码优先）。
    static func apa7(_ m: BookCitationMeta, page: Int?) -> String {
        if isBare(m) { return bareText(m, page: page) }
        let cjk = containsCJK(m.title)
        func parens(_ x: String) -> String { cjk ? "（\(x)）" : "(\(x))" }
        var s = ""
        if let a = m.author, let y = m.year { s = "\(a) (\(y)). " }
        else if let a = m.author { s = "\(a). " }
        else if let y = m.year { s = "(\(y)). " }
        s += m.title
        if let n = page { s += (cjk ? "" : " ") + parens("p. \(n)") }
        else if let e = m.edition { s += (cjk ? "" : " ") + parens(e) }
        s += "."
        if let p = m.publisher { s += " \(p)." }
        return s
    }

    /// MLA 9：Author. Title. Publisher, Year, p. N.
    static func mla9(_ m: BookCitationMeta, page: Int?) -> String {
        if isBare(m) { return bareText(m, page: page) }
        var s = m.author.map { "\($0). " } ?? ""
        s += m.title + "."
        if let p = m.publisher, let y = m.year { s += " \(p), \(y)"
        } else if let y = m.year { s += " \(y)"
        } else if let p = m.publisher { s += " \(p)" }
        if let n = page { s += ", p. \(n)" }
        return s + "."
    }

    /// Chicago 18 脚注式：作者：《书名》（出版社，年份），第N页。/
    /// Author, Title (Publisher, Year), N.
    static func chicago18Notes(_ m: BookCitationMeta, page: Int?) -> String {
        if isBare(m) { return bareText(m, page: page) }
        let inner = [m.publisher, m.year].compactMap { $0 }
        if containsCJK(m.title) {
            var s = m.author.map { "\($0)：" } ?? ""
            s += "《\(m.title)》"
            if !inner.isEmpty { s += "（\(inner.joined(separator: "，"))）" }
            if let n = page { s += "，第\(n)页" }
            return s + "。"
        }
        var s = m.author.map { "\($0), " } ?? ""
        s += m.title
        if !inner.isEmpty { s += " (\(inner.joined(separator: ", ")))" }
        if let n = page { s += ", \(n)" }
        return s + "."
    }

    /// Chicago 18 作者-年份式：（作者 年份, N）/ (Author Year, N)。
    static func chicagoAuthorDate(_ m: BookCitationMeta, page: Int?) -> String {
        if isBare(m) { return bareText(m, page: page) }
        // 公开 citation 路径不携带 author；无作者时以书名为 in-text 标签，
        // 避免输出只剩年份的无效引注。
        let label = m.author ?? m.title
        let pair = [label, m.year].compactMap { $0 }.joined(separator: " ")
        guard !pair.isEmpty else { return m.title }
        let cjk = containsCJK(m.title)
        let open = cjk ? "（" : "("
        let close = cjk ? "）" : ")"
        if let n = page { return "\(open)\(pair), \(n)\(close)" }
        return "\(open)\(pair)\(close)"
    }

    /// Harvard：(Author, Year, p. N) / 书目级 (Author, Year)。
    static func harvard(_ m: BookCitationMeta, page: Int?) -> String {
        if isBare(m) { return bareText(m, page: page) }
        // 无作者时以书名为 in-text 标签（同 chicagoAuthorDate）。
        let parts = [m.author ?? m.title, m.year].compactMap { $0 }
        guard !parts.isEmpty else { return m.title }
        let cjk = containsCJK(m.title)
        let open = cjk ? "（" : "("
        let close = cjk ? "）" : ")"
        var body = parts.joined(separator: ", ")
        if let n = page { body += ", p. \(n)" }
        return "\(open)\(body)\(close)"
    }

    /// Vancouver：Author. Title. Publisher; Year. 页码为文献内页，纯文本无法
    /// 作上标，以"年份. p. N."回退表示（Vancouver 家族惯例的明文近似）。
    static func vancouver(_ m: BookCitationMeta, page: Int?) -> String {
        if isBare(m) { return bareText(m, page: page) }
        var s = m.author.map { "\($0). " } ?? ""
        s += m.title + "."
        if let p = m.publisher, let y = m.year { s += " \(p); \(y)."
        } else if let y = m.year { s += " \(y)."
        } else if let p = m.publisher { s += " \(p)." }
        if let n = page { s += " p. \(n)." }
        return s
    }

    /// IEEE：Author, Title. Publisher, Year, p. N.
    static func ieee(_ m: BookCitationMeta, page: Int?) -> String {
        if isBare(m) { return bareText(m, page: page) }
        var s = m.author.map { "\($0), " } ?? ""
        s += m.title + "."
        if let p = m.publisher, let y = m.year { s += " \(p), \(y)"
        } else if let y = m.year { s += " \(y)"
        } else if let p = m.publisher { s += " \(p)" }
        if let n = page { s += ", p. \(n)" }
        return s + "."
    }

    /// AGLC：同 OSCOLA，括号内用逗号：Author, Title (Publisher, Year) page.
    static func aglc(_ m: BookCitationMeta, page: Int?) -> String {
        if isBare(m) { return bareText(m, page: page) }
        var s = m.author.map { "\($0), " } ?? ""
        s += m.title
        let inner = [m.publisher, m.year].compactMap { $0 }.joined(separator: ", ")
        if !inner.isEmpty { s += " (\(inner))" }
        if let n = page { s += " \(n)" }
        return s + "."
    }

    /// McGill Guide：Author, Title (ed.) (Publisher, Year) at N.
    static func mcgill(_ m: BookCitationMeta, page: Int?) -> String {
        if isBare(m) { return bareText(m, page: page) }
        var s = m.author.map { "\($0), " } ?? ""
        s += m.title
        if let e = m.edition { s += " (\(e))" }
        let inner = [m.publisher, m.year].compactMap { $0 }.joined(separator: ", ")
        if !inner.isEmpty { s += " (\(inner))" }
        if let n = page { s += " at \(n)" }
        return s + "."
    }

    /// AMA 11th（Vancouver 家族）：Author. Title. Publisher; Year: N.
    static func ama(_ m: BookCitationMeta, page: Int?) -> String {
        if isBare(m) { return bareText(m, page: page) }
        var s = m.author.map { "\($0). " } ?? ""
        s += m.title + "."
        if let p = m.publisher, let y = m.year { s += " \(p); \(y)"
        } else if let y = m.year { s += " \(y)"
        } else if let p = m.publisher { s += " \(p)" }
        if let n = page { s += ": \(n)" }
        return s + "."
    }
}


private extension Substring {
    func trimmingTrailingSpaces() -> Substring {
        var t = self
        while let last = t.last, last == " " || last == "\t" || last == "\n" || last == "\r" {
            t = t.dropLast()
        }
        return t
    }

    func lastIndexOf(open: Character, before index: Index) -> Index? {
        var i = index
        while true {
            if self[i] == open { return i }
            if i == startIndex { return nil }
            i = self.index(before: i)
        }
    }
}

public enum CitationFormatter {
    /// Cleans a library file name into citation-ready base text:
    /// strips extension, edition hash suffixes and source marker parentheticals.
    public static func cleanFileName(_ name: String) -> String {
        var n = name
        // 只剥一个扩展名（`fileName` 已是 cleanFileName 产物时再调一次
        // 会剥掉第二个 `.pdf`——`X.pdf.pdf` 被削成 `X.pdf`；旧行为曾静默吞掉，
        // 相当于删除文字）。落盘名是 `X.pdf.pdf` 时保持一个 `.pdf` 在书名里。
        if let ext = [".pdf", ".PDF", ".Pdf"].first(where: { n.hasSuffix($0) }) {
            n = String(n.dropLast(ext.count))
        }
        if let r = n.range(of: "_异版[0-9A-Za-z]{6,8}$", options: .regularExpression) {
            n = n.replacingCharacters(in: r, with: "")
        }
        return n.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    /// Formats a page-level citation for a hit via the format registry.
    public static func citation(fileName: String, title: String?,
                                physicalPage: Int?, style: CitationStyle,
                                indirect: Bool = false,
                                printedPage: Int? = nil,
                                pageLabel: String? = nil) -> String {
        let meta = BookCitationMeta.parse(fileName: fileName, title: title, author: nil)
        let templatePage = printedPage ?? arabicPageLabel(pageLabel) ?? physicalPage
        let body = CitationFormatRegistry.descriptor(for: style).template(meta, templatePage)
        return (indirect ? "参见" : "") + body
    }

    /// 阿拉伯数字页标签 → Int；其他（罗马数字 / `Cover` / 空）→ nil。
    public static func arabicPageLabel(_ label: String?) -> Int? {
        guard let t = label?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        guard t.range(of: #"^\d+$"#, options: .regularExpression) != nil else { return nil }
        return Int(t)
    }

    /// Book-level citation (no page) — for a hit list header / whole-book ref.
    /// Calls without a style argument use the default Chinese handbook style.
    public static func bookCitation(fileName: String, title: String?) -> String {
        bookCitation(fileName: fileName, title: title, style: .faxueYinzhuShouce)
    }

    /// Book-level citation in a specific style (no page).
    public static func bookCitation(fileName: String, title: String?, style: CitationStyle) -> String {
        let meta = BookCitationMeta.parse(fileName: fileName, title: title, author: nil)
        return CitationFormatRegistry.descriptor(for: style).template(meta, nil)
    }

    // MARK: 批量与导出（引用升级切片）

    /// 直接引文（选中文本 → 引用）：引文 + 出处，**无括号包裹**（产品决策
    /// 括号妨碍直接粘贴进正文）。中文「"…"，书名，第N页。」，
    /// 英文「"…", Book, p. N.」。
    ///
    /// 引文文本只经 `QuoteTextNormalizer` 规整：补全被切断的整词、合并换行、
    /// 压缩连续空白；**不删改任何文字**（行尾连字符亦不合并）。本函数不再
    /// 自行裁切。
    ///
    /// 页标签：页码优先序 printedPage → pageLabel（阿拉伯/罗马数字
    /// 均直接进串）→ physicalPage。quote 之外不拼页码；页码取自首个选区页。
    public static func quotation(quote: String, fileName: String, title: String?,
                                 physicalPage: Int?, style: CitationStyle,
                                 printedPage: Int? = nil,
                                 pageLabel: String? = nil) -> String {
        let book = bookCitation(fileName: fileName, title: title)
        let q = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        if containsCJK(q) || containsCJK(book) {
            return "“\(q)”，\(book)\(pageSuffixZH(physicalPage: physicalPage, printedPage: printedPage, pageLabel: pageLabel))"
        }
        return "“\(q)”, \(book)\(pageSuffixEN(physicalPage: physicalPage, printedPage: printedPage, pageLabel: pageLabel))"
    }

    /// 中文页码尾巴：印刷页 → 声明页标签（原样）→ 物理页 → 无码。
    static func pageSuffixZH(physicalPage: Int?, printedPage: Int?, pageLabel: String?) -> String {
        if let n = printedPage { return "，第\(n)页。" }
        if let label = trustedLabel(pageLabel) { return "，第\(label)页。" }
        if let n = physicalPage { return "，第\(n)页。" }
        return "。"
    }

    /// 英文页码尾巴：印刷页 → 声明页标签（原样）→ 物理页 → 无码。
    static func pageSuffixEN(physicalPage: Int?, printedPage: Int?, pageLabel: String?) -> String {
        if let n = printedPage { return ", p. \(n)." }
        if let label = trustedLabel(pageLabel) { return ", p. \(label)." }
        if let n = physicalPage { return ", p. \(n)." }
        return "."
    }

    /// 只认阿拉伯数字或罗马数字标签（调用方已按声明政策校验；此处再兜一层，
    /// 防 `Cover`/`Back5` 这类装饰标签进引文）。
    static func trustedLabel(_ label: String?) -> String? {
        guard let t = label?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        let arabic = #"^\d+$"#
        let roman = #"^[ivxlcdm]+$"#
        if t.range(of: arabic, options: .regularExpression) != nil { return t }
        if t.range(of: roman, options: [.regularExpression, .caseInsensitive]) != nil {
            return t
        }
        return nil
    }

    /// Batch book citations, one per line. Both styles share the same book-form
    /// today; the style parameter stays so journal-type divergence can attach
    /// here later without changing call sites.
    public static func bibliography(_ books: [(fileName: String, title: String?)],
                                    style: CitationStyle) -> String {
        books.map { bookCitation(fileName: $0.fileName, title: $0.title) }
            .joined(separator: "\n")
    }

    /// BibTeX @book entry. Only fields that actually exist are emitted — a
    /// missing author/language is omitted, never fabricated (mirrors the
    /// citation rule: unknown stays unknown).
    public static func bibtex(fileName: String, title: String?,
                              author: String?, language: String?) -> String {
        entryBody(key: bibtexKey(from: displayTitle(fileName: fileName, title: title)),
                  fileName: fileName, title: title, author: author, language: language)
    }

    /// ibTeX with deterministic key disambiguation: a repeated key in
    /// the same batch gets a `-2`/`-3`… suffix in input order. Duplicate keys
    /// would make the exported .bib invalid, so uniqueness is guaranteed here.
    public static func bibtexBatch(_ books: [(fileName: String, title: String?,
                                              author: String?, language: String?)]) -> String {
        var counts: [String: Int] = [:]
        var entries: [String] = []
        for b in books {
            let base = bibtexKey(from: displayTitle(fileName: b.fileName, title: b.title))
            counts[base, default: 0] += 1
            let key = counts[base]! == 1 ? base : "\(base)-\(counts[base]!)"
            entries.append(entryBody(key: key, fileName: b.fileName, title: b.title,
                                     author: b.author, language: b.language))
        }
        return entries.joined(separator: "\n\n")
    }

    private static func displayTitle(fileName: String, title: String?) -> String {
        let base = cleanFileName(fileName)
        return (title?.isEmpty == false) ? title! : base
    }

    private static func entryBody(key: String, fileName: String, title: String?,
                                  author: String?, language: String?) -> String {
        let t = displayTitle(fileName: fileName, title: title)
        var fields = "  title = {\(t)}"
        if let author, !author.isEmpty { fields += ",\n  author = {\(author)}" }
        if let language, !language.isEmpty { fields += ",\n  language = {\(language)}" }
        fields += ",\n  note = {LiteratureSearch 全文检索库}"
        return "@book{\(key),\n\(fields)\n}"
    }

    /// ASCII-safe cite key from the title; titles without ASCII letters
    /// (CJK-only, pure digits) get a stable numeric key (djb2 of the UTF-8
    /// bytes — same title ⇒ same key).
    static func bibtexKey(from title: String) -> String {
        let ascii = title.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
        let hasASCIILetter = ascii.contains { (65...90).contains($0.value) || (97...122).contains($0.value) }
        if ascii.count >= 3, hasASCIILetter {
            return String(String.UnicodeScalarView(ascii))
        }
        return "lit\(djb2(title) % 100_000_000)"
    }

    static func djb2(_ s: String) -> UInt64 {
        var h: UInt64 = 5_381
        for b in s.utf8 { h = h &* 33 &+ UInt64(b) }
        return h
    }
}
