import Foundation

// MARK: - 自动目录生成（自动目录生成（核心层)）
//
// 无书签书（扫描/OCR 件为主）从已索引页文本检测章节起始页，生成值类型
// 目录存 DB（auto_toc 表），UI 层据此填充目录侧栏（运行时值树，绝不写
// 回只读原书）。检测只用 DB 内 text_norm——不触碰任何 PDF 文件。

public struct AutoTOCEntry: Equatable, Codable, Sendable {
    /// 1 起物理页。
    public var page: Int
    public var label: String
    /// 0=编 1=章 2=节 3=一级列举（层级用于侧栏缩进）。
    public var level: Int

    public init(page: Int, label: String, level: Int) {
        self.page = page
        self.label = label
        self.level = level
    }
}

public enum HeadingDetector {
    /// 章节标题模式（行首锚定）。顺序即优先级；level 随之。
    static let patterns: [(regex: NSRegularExpression, level: Int)] = [
        (try! NSRegularExpression(pattern: "^第[一二三四五六七八九十百千0-9０-９]+编[\\s　]"), 0),
        (try! NSRegularExpression(pattern: "^PART\\s+[IVXivx\\d]+\\b"), 0),
        (try! NSRegularExpression(pattern: "^第[一二三四五六七八九十百千0-9０-９]+章[\\s　]"), 1),
        (try! NSRegularExpression(pattern: "^Chapter\\s+\\d+\\b"), 1),
        (try! NSRegularExpression(pattern: "^第[一二三四五六七八九十百千0-9０-９]+节[\\s　]"), 2),
        (try! NSRegularExpression(pattern: "^Section\\s+\\d+\\b"), 2),
        (try! NSRegularExpression(pattern: "^[一二三四五六七八九十]{1,3}、\\S"), 3),
    ]

    /// 单页判定：取页首若干行，首个命中行即候选标题。
    /// 返回 (label, level) 或 nil。
    static func detectHeading(inPageText text: String) -> (label: String, level: Int)? {
        var inspected = 0
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            inspected += 1
            if inspected > 4 { break }   // 只看页首 4 个非空行
            for (regex, level) in patterns {
                let range = NSRange(line.startIndex..., in: line)
                if regex.firstMatch(in: line, range: range) != nil {
                    let label = String(line.prefix(60))
                    return (label, level)
                }
            }
            // 首行不命中即停（章节标题几乎总在页首；续页首行是正文）。
            break
        }
        return nil
    }

    /// 从命中行提取"干净"标题：模式匹配段 + 其后连续的 CJK/字母/空格
    /// （遇到数字/标点即止——页眉常见的页码尾巴"第一章 公平正义 5 6 2."
    /// 被裁掉），供展示与去重键共用。上限 40 字符。
    static func cleanLabel(line: String, matchLength: Int) -> String {
        let scalars = Array(line.unicodeScalars)
        var out: [Unicode.Scalar] = Array(scalars.prefix(matchLength))
        var i = matchLength
        while i < scalars.count, out.count < 40 {
            let c = scalars[i]
            let isCJK = (0x4E00...0x9FFF).contains(c.value) || (0x3400...0x4DBF).contains(c.value)
            let isLetter = CharacterSet.letters.contains(c)
            let isSpace = c == " " || c == "　"
            if isCJK || isLetter {
                out.append(c)
            } else if isSpace, let last = out.last, last != " " {
                out.append(c)   // 词间空格保留（连续空格与尾部截断）
            } else if !isSpace {
                break           // 数字/标点：页码尾巴起点，停
            }
            i += 1
        }
        while out.last == " " { out.removeLast() }
        return String(String.UnicodeScalarView(out))
    }

    /// 页眉去重键：模式匹配段 + 紧随其后的首个标题词（≤8 个 CJK/字母字
    /// 符，跳过空格）。"第一章 自由辨 意义上的…" → "第一章 自由辨"——
    /// 正文接排不再进入键，键跨续页稳定、跨章互异（章号在匹配段内）。
    static func headingKey(line: String, matchLength: Int) -> String {
        let scalars = Array(line.unicodeScalars)
        var out: [Unicode.Scalar] = Array(scalars.prefix(matchLength))
        var i = matchLength
        while i < scalars.count, out.last == " " || out.last == "　" { out.removeLast(); /* 尾空格稍后补回 */ break }
        while i < scalars.count, i - matchLength < 8 {
            let c = scalars[i]
            let isCJK = (0x4E00...0x9FFF).contains(c.value) || (0x3400...0x4DBF).contains(c.value)
            let isLetter = CharacterSet.letters.contains(c)
            if isCJK || isLetter { out.append(c) } else { break }
            i += 1
        }
        return String(String.UnicodeScalarView(out))
    }

    /// 整书目录抽取：逐页首行判定；目录页（一页命中 ≥5 行标题模式）跳过；
    /// 页眉去重键=headingKey（模式段+首标题词）。去重只作用于**连续同键段**
    /// （页眉节律 2-8 页不定，中间无他键介入即续页）；一旦出现不同键（真章
    /// 节推进），同键再次出现视为合法重入——多卷书各卷"第一章"免疫。
    public static func extract(pageTexts: [(page: Int, text: String)]) -> [AutoTOCEntry] {
        var out: [AutoTOCEntry] = []
        var lastKey: String? = nil
        for (page, text) in pageTexts {
            var firstOnPage: (label: String, level: Int, key: String)? = nil
            var matchCount = 0
            for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                for (regex, level) in patterns {
                    let range = NSRange(line.startIndex..., in: line)
                    if let m = regex.firstMatch(in: line, range: range) {
                        matchCount += 1
                        if firstOnPage == nil {
                            let clean = cleanLabel(line: line, matchLength: m.range.upperBound)
                            if !clean.isEmpty {
                                firstOnPage = (clean, level, headingKey(line: line, matchLength: m.range.upperBound))
                            }
                        }
                        break
                    }
                }
            }
            guard let first = firstOnPage else { continue }
            if matchCount >= 5 { continue }   // 目录页/索引页：跳过
            if let last = out.last, last.page == page { continue }
            if lastKey == first.key { continue }   // 连续同键 = 续页页眉
            out.append(AutoTOCEntry(page: page, label: String(first.label.prefix(24)), level: first.level))
            lastKey = first.key
        }
        return out
    }
}

extension IndexStore {
    /// 单书目录重建（页数未变且已有目录则跳过；幂等）。返回是否重建。
    @discardableResult
    public func rebuildAutoTOCIfNeeded(bookID: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return try rebuildAutoTOCIfNeededLocked(bookID: bookID)
    }

    /// Caller must hold the lock（rebuildAutoTOCAll 循环内调用——嵌套
    private func rebuildAutoTOCIfNeededLocked(bookID: String) throws -> Bool {
        try createAutoTOCTableLocked()
        let pageCount = try pageCountLocked(bookID: bookID)
        let stamped = try autoTOCStampLocked(bookID: bookID)
        if let stamped, stamped == pageCount { return false }
        let rows = try db.prepare("SELECT page_number, text_norm FROM pages WHERE book_id = ? AND TRIM(text_norm) != '' ORDER BY page_number;")
        try rows.bindText(1, bookID)
        var pageTexts: [(page: Int, text: String)] = []
        while try rows.step() {
            pageTexts.append((Int(rows.int(0)), rows.text(1)))
        }
        let entries = HeadingDetector.extract(pageTexts: pageTexts)
        try replaceAutoTOCLocked(bookID: bookID, entries: entries, pageCount: pageCount)
        return true
    }

    /// 全库批生成（索引批末调用）：只处理缺目录或页数已变的书。
    @discardableResult
    public func rebuildAutoTOCAll() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        try createAutoTOCTableLocked()
        let books = try db.prepare("""
        SELECT b.id, b.page_count FROM books b
        LEFT JOIN auto_toc_state s ON s.book_id = b.id
        WHERE s.book_id IS NULL OR s.page_count != b.page_count;
        """)
        var ids: [(String, Int)] = []
        while try books.step() { ids.append((books.text(0), Int(books.int(1)))) }
        var rebuilt = 0
        for (id, _) in ids {
            if try rebuildAutoTOCIfNeededLocked(bookID: id) { rebuilt += 1 }
        }
        return rebuilt
    }

    /// 读某书自动目录（无则空数组）。
    public func autoTOC(for bookID: String) throws -> [AutoTOCEntry] {
        lock.lock(); defer { lock.unlock() }
        try createAutoTOCTableLocked()
        return try autoTOCLocked(bookID: bookID)
    }

    // MARK: 私有（调用方持锁）

    private func createAutoTOCTableLocked() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS auto_toc(
            book_id TEXT NOT NULL,
            page INTEGER NOT NULL,
            label TEXT NOT NULL,
            level INTEGER NOT NULL,
            PRIMARY KEY(book_id, page)
        );
        CREATE TABLE IF NOT EXISTS auto_toc_state(
            book_id TEXT PRIMARY KEY,
            page_count INTEGER NOT NULL
        );
        """)
    }

    private func autoTOCStampLocked(bookID: String) throws -> Int? {
        let stmt = try db.prepare("SELECT page_count FROM auto_toc_state WHERE book_id = ?;")
        try stmt.bindText(1, bookID)
        if try stmt.step() { return Int(stmt.int(0)) }
        return nil
    }

    private func autoTOCLocked(bookID: String) throws -> [AutoTOCEntry] {
        let stmt = try db.prepare("SELECT page, label, level FROM auto_toc WHERE book_id = ? ORDER BY page;")
        try stmt.bindText(1, bookID)
        var out: [AutoTOCEntry] = []
        while try stmt.step() {
            out.append(AutoTOCEntry(page: Int(stmt.int(0)), label: stmt.text(1), level: Int(stmt.int(2))))
        }
        return out
    }

    private func replaceAutoTOCLocked(bookID: String, entries: [AutoTOCEntry], pageCount: Int) throws {
        try db.exec("BEGIN IMMEDIATE;")
        do {
            let del = try db.prepare("DELETE FROM auto_toc WHERE book_id = ?;")
            try del.bindText(1, bookID)
            try del.run()
            let ins = try db.prepare("INSERT OR REPLACE INTO auto_toc(book_id, page, label, level) VALUES(?,?,?,?);")
            for e in entries {
                try ins.reset(); try ins.clearBindings()
                try ins.bindText(1, bookID)
                try ins.bindInt(2, Int64(e.page))
                try ins.bindText(3, e.label)
                try ins.bindInt(4, Int64(e.level))
                try ins.run()
            }
            let up = try db.prepare("INSERT OR REPLACE INTO auto_toc_state(book_id, page_count) VALUES(?,?);")
            try up.reset(); try up.clearBindings()
            try up.bindText(1, bookID)
            try up.bindInt(2, Int64(pageCount))
            try up.run()
            try db.exec("COMMIT;")
        } catch {
            db.tryExec("ROLLBACK;")
            throw error
        }
    }
}
