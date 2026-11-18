import Foundation
@testable import LiteratureCore

// MARK: - Quote suite (Daily quote engine: splitting, heuristics, balancing, determinism, idempotency)

enum QuoteSuite {
    @discardableResult
    static func addBook(_ store: IndexStore, id: String, name: String,
                        pages: [String], status: String = "ok") throws -> IndexStore.BookRow {
        let book = IndexStore.BookRow(
            id: id, realPath: "/tmp/lit-tests/\(name)", rootPath: "/tmp/lit-tests",
            relPath: name, fileName: name,
            firstFingerprint: "fp-\(id)", fingerprint: "fp-\(id)", fileSize: 1, mtime: 0,
            pageCount: pages.count, status: status, indexedAt: 0)
        try store.upsertBook(book)
        var rows: [IndexStore.PageRow] = []
        for (i, text) in pages.enumerated() {
            let n = normalizeForSearch(text)
            rows.append(IndexStore.PageRow(bookID: id, pageNumber: i + 1, textOriginal: text,
                                           textNorm: n.text, normStarts: n.starts, normEnds: n.ends))
        }
        try store.replacePages(bookID: id, rows)
        return book
    }

    static var tests: [TestDesc] {
        [
            // 1. 句切分完整性（中英文句号/省略号边界）
            TestDesc(suite: "Quote", name: "sentenceSplittingIntegrity") {
                let zhText = "法学是关于正义与不正义的学问。法律的目的是维护社会秩序！难道还有任何疑虑吗？"
                let zhSentences = QuoteExtractor.splitSentences(from: zhText)
                try expectEqual(zhSentences.count, 3)
                try expectEqual(zhSentences[0], "法学是关于正义与不正义的学问。")
                try expectEqual(zhSentences[1], "法律的目的是维护社会秩序！")
                try expectEqual(zhSentences[2], "难道还有任何疑虑吗？")

                let enText = "The Fictional Order is fundamental. Does justice demand complete equality? Certainly!"
                let enSentences = QuoteExtractor.splitSentences(from: enText)
                try expectEqual(enSentences.count, 3)
                try expectEqual(enSentences[0], "The Fictional Order is fundamental.")
                try expectEqual(enSentences[1], "Does justice demand complete equality?")
                try expectEqual(enSentences[2], "Certainly!")

                // Chinese quotes kept intact with closing quotes
                let quoteText = "正如学者所言：“法律不是静止的条文，而是活生生的秩序。”此言影响深远。"
                let quoteSentences = QuoteExtractor.splitSentences(from: quoteText)
                try expectEqual(quoteSentences.count, 2)
                try expectEqual(quoteSentences[0], "正如学者所言：“法律不是静止的条文，而是活生生的秩序。”")
                try expectEqual(quoteSentences[1], "此言影响深远。")

                // Ellipsis boundary: Chinese …… inside a sentence must NOT split
                let zhEllipsis = "规范的有效性……在法哲学中历来是核心争议点。正义原则必须得到实质保障。"
                let zhEllipsisSentences = QuoteExtractor.splitSentences(from: zhEllipsis)
                try expectEqual(zhEllipsisSentences.count, 2)
                try expectTrue(zhEllipsisSentences[0].contains("……"), "ellipsis inside sentence is preserved")
                try expectEqual(zhEllipsisSentences[0], "规范的有效性……在法哲学中历来是核心争议点。")
                try expectEqual(zhEllipsisSentences[1], "正义原则必须得到实质保障。")

                // Ellipsis boundary: English ... inside a sentence must NOT split
                let enEllipsis = "The rule of law... as defined by example scholars, consists of distinct constitutional principles. Another sentence follows."
                let enEllipsisSentences = QuoteExtractor.splitSentences(from: enEllipsis)
                try expectEqual(enEllipsisSentences.count, 2)
                try expectTrue(enEllipsisSentences[0].contains("..."), "English ellipsis is preserved")
                try expectEqual(enEllipsisSentences[0], "The rule of law... as defined by example scholars, consists of distinct constitutional principles.")
                try expectEqual(enEllipsisSentences[1], "Another sentence follows.")

                // Numbers / decimals must not split (e.g. 1.5 or Art. 12)
                let numText = "According to Art. 12, the value is 1.5 times the standard. This concludes the article."
                let numSentences = QuoteExtractor.splitSentences(from: numText)
                try expectEqual(numSentences.count, 2)
                try expectEqual(numSentences[0], "According to Art. 12, the value is 1.5 times the standard.")
                try expectEqual(numSentences[1], "This concludes the article.")

                // Incomplete tail without terminal punctuation is omitted
                let incomplete = "这是第一句完整的话。而这里是一段没有句号截断的未完成残句"
                let incSentences = QuoteExtractor.splitSentences(from: incomplete)
                try expectEqual(incSentences.count, 1)
                try expectEqual(incSentences[0], "这是第一句完整的话。")
            },

            // 2. 长度与禁字符过滤
            TestDesc(suite: "Quote", name: "lengthAndForbiddenCharacterFiltering") {
                // Too short (< 40 characters)
                let shortSentence = "法律是社会的规范。"
                try expectFalse(QuoteExtractor.isValidQuote(shortSentence), "short sentence (<40 chars) must be rejected")

                // Valid length (40 - 160 characters), English-only per the
                // book-level directive (CJK sentences are rejected
                // regardless of length — see englishOnlyExcludesCJKSentences).
                let validSentence = "Law is the embodiment of human reason; it must preserve order in form and promote justice in substance."
                try expectTrue(validSentence.count >= QuoteExtractor.minSentenceLength && validSentence.count <= QuoteExtractor.maxSentenceLength)
                try expectTrue(QuoteExtractor.isValidQuote(validSentence), "valid length English sentence must be accepted")

                // Too long (> 160 characters)
                let longSentence = String(repeating: "法律与规范维护正义，权利与义务构成了法治秩序的基础核心。", count: 8)
                try expectTrue(longSentence.count > QuoteExtractor.maxSentenceLength)
                try expectFalse(QuoteExtractor.isValidQuote(longSentence), "long sentence (>160 chars) must be rejected")

                // Forbidden replacement character U+FFFD
                let corruptSentence = "法律是人类理性的体现\u{FFFD}不仅应当在形式上维护秩序，更应当在实质上促进正义与公平。"
                try expectFalse(QuoteExtractor.isValidQuote(corruptSentence), "sentence containing U+FFFD must be rejected")

                // Line breaks folded into spaces
                let multiline = "法律是人类社会的普遍规范，\r\n它具有普遍约束力和强制力，\n是实现实质正义的重要制度工具。"
                let folded = QuoteExtractor.foldWhitespace(multiline)
                try expectFalse(folded.contains("\n"))
                try expectFalse(folded.contains("\r"))
                try expectTrue(folded.contains("普遍规范， 它具有"))
            },

            // 3. 同书限额与书间均衡（书级英文判定基准下三本书均为 ASCII ≥80% 西文原书；
            //    中译文书排除见 test 6 bookLevelEnglishGating）
            TestDesc(suite: "Quote", name: "perBookLimitAndInterBookBalancing") {
                let dir = Fixtures.makeTempDir("quote-balance")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)

                // Book 1: 15 pages, 2 candidate sentences per page (total 30 candidates, exceeds maxQuotesPerBook 12)
                var book1Pages: [String] = []
                for _ in 1...15 {
                    let s1 = "The Fictional Order as a system of norms provides the foundation for understanding legal order in modern constitutional states."
                    let s2 = "Justice requires not merely formal equality before the law but the substantive elimination of arbitrary distinctions in adjudication."
                    book1Pages.append("\(s1)\n\(s2)")
                }
                try addBook(store, id: "book1", name: "book1.pdf", pages: book1Pages)

                // Book 2: 4 pages, 1 sentence per page (total 4 candidates, < 12)
                var book2Pages: [String] = []
                for _ in 1...4 {
                    let s = "State power under a constitution is strictly limited, and the rule-of-law principle demands that every exercise of authority rest on a legal basis."
                    book2Pages.append(s)
                }
                try addBook(store, id: "book2", name: "book2.pdf", pages: book2Pages)

                // Book 3: 10 pages, 2 candidate sentences per page (total 20 candidates, exceeds 12)
                var book3Pages: [String] = []
                for _ in 1...10 {
                    let s1 = "Das Recht und die Norm begründen eine objektive Ordnung für den modernen Verfassungsstaat."
                    let s2 = "Rechtspflicht und Gesetz sind zentrale Kategorien der reinen Rechtslehre in der Rechtsphilosophie."
                    book3Pages.append("\(s1)\n\(s2)")
                }
                try addBook(store, id: "book3", name: "book3.pdf", pages: book3Pages)

                // Extract up to 25 quotes
                let extracted = try QuoteExtractor.extract(from: store, limit: 25)
                try expectTrue(extracted.count <= 25)

                // Rule: max 12 per book
                let book1Count = extracted.filter { $0.bookID == "book1" }.count
                let book2Count = extracted.filter { $0.bookID == "book2" }.count
                let book3Count = extracted.filter { $0.bookID == "book3" }.count

                try expectTrue(book1Count <= QuoteExtractor.maxQuotesPerBook, "book1 capped at 12")
                try expectEqual(book2Count, 4, "all 4 quotes from book2 included thanks to round-robin balance")

                // English-only: book3 is German and
                // must be excluded from the pool entirely.
                try expectEqual(book3Count, 0, "German book excluded by English-prose filter")

                // Inter-book balance: both English books are present
                try expectTrue(book1Count > 0 && book2Count > 0, "all English books represented")

                // Per-page limit: at most 2 per page
                var pageCounts: [String: Int] = [:]
                for q in extracted {
                    pageCounts["\(q.bookID)-\(q.pageNumber)", default: 0] += 1
                }
                for (_, count) in pageCounts {
                    try expectTrue(count <= QuoteExtractor.maxQuotesPerPage, "max 2 quotes per page")
                }

                // Academic concept keyword bonus prioritization
                let conceptSentence = "The Recht and the Norm together ground an objective legal order for the modern constitutional state."
                let plainSentence = "We examine in this chapter the various circumstances and discuss all details that may arise in practice."
                try expectTrue(QuoteExtractor.score(for: conceptSentence) > QuoteExtractor.score(for: plainSentence),
                               "concept words give bonus score over plain text of similar length")
            },

            // 4. 当日确定性（同日期两次选择结果一致；不同日期可不同——抽 3 个日期至少 2 个不同）
            TestDesc(suite: "Quote", name: "dailyDeterminism") {
                let dir = Fixtures.makeTempDir("quote-determinism")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)

                // Seed diverse quotes across multiple pages and books
                var pages: [String] = []
                for i in 1...20 {
                    let s = "Sample excerpt \(i) of the pool: the nature of legal authority and its claim to legitimacy remains a central question for jurisprudence."
                    pages.append(s)
                }
                try addBook(store, id: "detBook", name: "detBook.pdf", pages: pages)

                let extracted = try QuoteExtractor.extract(from: store, limit: 12)
                try expectEqual(extracted.count, 12)

                // Date 1: same date twice produces identical quote
                let date1 = Date(timeIntervalSince1970: 1790000000) // 2026-09-21
                let q1a = QuoteExtractor.today(store: store, date: date1)
                let q1b = QuoteExtractor.today(store: store, date: date1)
                try expectNotNil(q1a)
                try expectNotNil(q1b)
                try expectEqual(q1a, q1b, "same date produces identical quote")

                // 3 different dates: at least 2 distinct quotes
                let date2 = Date(timeIntervalSince1970: 1790086400) // 2026-09-22
                let date3 = Date(timeIntervalSince1970: 1790172800) // 2026-09-23

                let q1 = try expectNotNil(QuoteExtractor.today(store: store, date: date1))
                let q2 = try expectNotNil(QuoteExtractor.today(store: store, date: date2))
                let q3 = try expectNotNil(QuoteExtractor.today(store: store, date: date3))

                let distinctSentences = Set([q1.sentence, q2.sentence, q3.sentence])
                try expectTrue(distinctSentences.count >= 2, "3 different dates produce at least 2 distinct quotes")

                // Empty pool returns nil
                let emptyDir = Fixtures.makeTempDir("quote-empty")
                defer { Fixtures.cleanup(emptyDir) }
                let emptyStore = try Fixtures.openStore(in: emptyDir)
                try expectNil(QuoteExtractor.today(store: emptyStore, date: date1), "empty pool returns nil")
            },

            // 5. 幂等（refresh 两次行数不变）
            TestDesc(suite: "Quote", name: "idempotentRefresh") {
                let dir = Fixtures.makeTempDir("quote-idempotent")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)

                var pages: [String] = []
                for _ in 1...10 {
                    let s = "Constitutional rights form the highest normative standard of the legal order, and no administrative act may violate them."
                    pages.append(s)
                }
                try addBook(store, id: "idemBook", name: "idem.pdf", pages: pages)

                let testDate = Date(timeIntervalSince1970: 1790345600)
                let firstRun = try QuoteExtractor.extract(from: store, limit: 8, date: testDate)
                let countAfterFirst = try store.dailyQuotesCount()
                try expectEqual(countAfterFirst, firstRun.count)

                // Second refresh on the same date
                let secondRun = try QuoteExtractor.extract(from: store, limit: 8, date: testDate)
                let countAfterSecond = try store.dailyQuotesCount()
                try expectEqual(countAfterSecond, countAfterFirst, "refresh twice maintains identical row count")
                try expectEqual(firstRun.map(\.sentence), secondRun.map(\.sentence), "extracted sentences remain identical")
            },

            TestDesc(suite: "QuoteSuite", name: "englishOnlyExcludesCJKSentences") {
                let cjk = "样书一是测试书目中的示例句。"
                try expectFalse(QuoteExtractor.isValidQuote(cjk),
                                "CJK sentence must be excluded (daily quote is English-only)")
                let mixed = "The Fictional Order involves 法律 norms and social rules that govern behavior."
                try expectFalse(QuoteExtractor.isValidQuote(mixed),
                                "mixed CJK/Latin sentence must also be excluded")
                let en = String(repeating: "The rule of recognition governs the validity of legal norms. ", count: 2)
                try expectTrue(QuoteExtractor.isValidQuote(en),
                               "pure English sentence within length bounds is eligible")
                try expectTrue(QuoteExtractor.containsCJK("法律"), "CJK detector sanity")
                try expectFalse(QuoteExtractor.containsCJK("Rechtsstaat für Suche"),
                                "Latin-1 diacritics are not CJK")
            },

            // 6. 书级英文判定：中译文书（含嵌英文段）整本排除，英文原书保留
            TestDesc(suite: "Quote", name: "bookLevelEnglishGating") {
                // 判定助手直测（阈值 0.80）
                try expectTrue(QuoteExtractor.isEnglishBook(asciiRatio: 0.80), "boundary ratio passes")
                try expectTrue(QuoteExtractor.isEnglishBook(asciiRatio: 0.95), "pure English book passes")
                try expectFalse(QuoteExtractor.isEnglishBook(asciiRatio: 0.79), "just below threshold fails")

                let dir = Fixtures.makeTempDir("quote-booklang")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)

                let englishSentence = "The Fictional Order as a social phenomenon has been debated by jurists for centuries without reaching any consensus."

                // Book A: 中译文书，页内嵌完整英文长段。句级 CJK 拒绝挡不住这种
                // 纯英文段落——必须靠书级 ASCII 占比（远低于 80%）整本排除。
                let zhPage = "本章讨论法律实证主义的核心命题与界限。\(englishSentence) 下一节将继续分析规范效力问题。"
                try addBook(store, id: "zhBook", name: "zh-translation.pdf", pages: [zhPage, zhPage, zhPage])

                // Book B: 英文原书（ASCII 占比 ≥80%），正常入池。
                try addBook(store, id: "enBook", name: "english-original.pdf",
                            pages: [englishSentence, englishSentence, englishSentence])

                // Book C: 英文为主但掺入足量中文（约 40 个 CJK 字，占比压到 ~75%），
                // 低于阈值——「近似英文书」也不合格。
                let chineseBlock = String(repeating: "法律规范", count: 10)
                let mixedPage = "\(englishSentence)\(chineseBlock)。"
                try addBook(store, id: "mixedBook", name: "mixed.pdf", pages: [mixedPage])

                let extracted = try QuoteExtractor.extract(from: store, limit: 20)
                try expectEqual(extracted.filter { $0.bookID == "zhBook" }.count, 0,
                                "Chinese translation book is excluded even though it embeds a full English sentence")
                try expectEqual(extracted.filter { $0.bookID == "mixedBook" }.count, 0,
                                "mixed book below the ASCII ratio is excluded")
                try expectEqual(extracted.filter { $0.bookID == "enBook" }.count, 3,
                                "English original book is kept")
            },
        ]
    }
}
