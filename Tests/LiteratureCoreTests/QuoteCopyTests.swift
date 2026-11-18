import Foundation
@testable import LiteratureCore
@testable import LiteratureSearchUI

// MARK: - 阅读器复制引文（全合成）
//
// 本套件覆盖页标签采信、引文页码优先序、来源标记解析与整词补全。

enum QuoteCopySuite {
    private static let sampleFile =
        "A Sample Treatise (Revised Edition) (Avery Quill, Jordan Marlowe).pdf"

    /// 与 PDFDetailView.quoteMenuIfSelected 同基准的页码取值：
    /// printed → 声明页标签（阿拉伯/罗马）→ 物理页。
    private static func pickLabel(declared: Bool, label: String?) -> String? {
        guard declared, let label else { return nil }
        let t = label.trimmingCharacters(in: .whitespaces)
        let arabic = t.range(of: #"^\d+$"#, options: .regularExpression) != nil
        let roman = t.range(of: #"^[ivxlcdm]+$"#, options: [.regularExpression, .caseInsensitive]) != nil
        return (arabic || roman) ? t : nil
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "QuoteCopy", name: "pageLabelTrustedOnlyWhenDeclared") {
                let dir = Fixtures.makeTempDir("quote-labels")
                defer { Fixtures.cleanup(dir) }
                let labeled = dir.appendingPathComponent("labeled.pdf")
                try SyntheticPDFMaker.writeLabeledPDF(
                    pages: [.init(text: "Cover Page"), .init(text: "Body One")],
                    labelRules: [(0, "", "D", 1)],
                    to: labeled)
                try expectTrue(PageLabelDeclaration.declaresPageLabels(fileURL: labeled),
                               "declared /PageLabels must be seen")
                let plain = Fixtures.makePDF(pages: [.init(lines: ["alpha"]), .init(lines: ["beta"])],
                                             in: dir, named: "plain.pdf")
                try expectFalse(PageLabelDeclaration.declaresPageLabels(fileURL: plain),
                                "undeclared PDF must never be trusted (PDFKit fabricates 1,2,3)")
                // 缓存路径与直查同结果（同文档两次查询幂等）。
                let key = PageLabelDeclaration.documentKey(fileURL: labeled)
                try expectTrue(PageLabelDeclaration.cachedDeclaration(documentKey: key, fileURL: labeled))
                try expectTrue(PageLabelDeclaration.cachedDeclaration(documentKey: key, fileURL: labeled))
                let plainKey = PageLabelDeclaration.documentKey(fileURL: plain)
                try expectFalse(PageLabelDeclaration.cachedDeclaration(documentKey: plainKey, fileURL: plain))
                // 文件替换（mtime/大小变）→ 键变。
                try expectFalse(key == PageLabelDeclaration.documentKey(
                    fileURL: dir.appendingPathComponent("other.pdf")))
            },

            TestDesc(suite: "QuoteCopy", name: "labelShapesArabicRomanCover") {
                // 采信：阿拉伯 / 罗马（大小写）。
                try expectEqual(pickLabel(declared: true, label: "5"), "5")
                try expectEqual(pickLabel(declared: true, label: "684"), "684")
                try expectEqual(pickLabel(declared: true, label: "viii"), "viii")
                try expectEqual(pickLabel(declared: true, label: "XIV"), "XIV")
                // 不采信：装饰标签 / 空 / 混合 / 前导零 / 未声明。
                try expectNil(pickLabel(declared: true, label: "Cover"))
                try expectNil(pickLabel(declared: true, label: "Back5"))
                try expectNil(pickLabel(declared: true, label: ""))
                try expectNil(pickLabel(declared: true, label: "A-3"))
                try expectEqual(pickLabel(declared: true, label: "05"), "05",
                                "digits-only label is a page label (leading zero kept verbatim)")
                try expectNil(pickLabel(declared: false, label: "5"))
                try expectNil(pickLabel(declared: false, label: nil))
                // formatter 层同一基准（trustedLabel 私有，经 quotation 观测）。
                try expectTrue(CitationFormatter.quotation(
                    quote: "x", fileName: "A Book.pdf", title: "A Book", physicalPage: 22,
                    style: .apa7, pageLabel: "Cover").hasSuffix(", p. 22."),
                    "decorative label must fall back to the physical page")
                try expectTrue(CitationFormatter.quotation(
                    quote: "x", fileName: "A Book.pdf", title: "A Book", physicalPage: 22,
                    style: .apa7, pageLabel: "05").hasSuffix(", p. 05."),
                    "digits-only label passes through verbatim")
            },

            TestDesc(suite: "QuoteCopy", name: "quotationPagePrecedence") {
                let book = "A Sample Treatise.pdf"
                let title = "A Sample Treatise"
                // 印刷页 > 标签 > 物理页
                let printed = CitationFormatter.quotation(
                    quote: "q", fileName: book, title: title, physicalPage: 22,
                    style: .apa7, printedPage: 5, pageLabel: "9")
                try expectEqual(printed, "“q”, A Sample Treatise, p. 5.")
                // 无印刷页 → 标签
                let labeled = CitationFormatter.quotation(
                    quote: "q", fileName: book, title: title, physicalPage: 22,
                    style: .apa7, pageLabel: "5")
                try expectEqual(labeled, "“q”, A Sample Treatise, p. 5.")
                // 罗马数字标签：quotation 直接用（不经 Int）
                let roman = CitationFormatter.quotation(
                    quote: "q", fileName: book, title: title, physicalPage: 9,
                    style: .apa7, pageLabel: "viii")
                try expectEqual(roman, "“q”, A Sample Treatise, p. viii.")
                // 无标签 → 物理页（旧行为逐字节不变）
                let physical = CitationFormatter.quotation(
                    quote: "q", fileName: book, title: title, physicalPage: 22, style: .apa7)
                try expectEqual(physical, "“q”, A Sample Treatise, p. 22.")
                // 全无 → 不加码
                let none = CitationFormatter.quotation(
                    quote: "x", fileName: "某书.pdf", title: nil, physicalPage: nil,
                    style: .faxueYinzhuShouce)
                try expectTrue(none.hasSuffix("，某书。"))
                // 中文串的标签路径
                let zh = CitationFormatter.quotation(
                    quote: "样书一", fileName: "李维《样书一》第三版.pdf", title: nil,
                    physicalPage: 47, style: .faxueYinzhuShouce, pageLabel: "viii")
                try expectTrue(zh.contains("，第viii页。"), "CJK quote takes the roman label verbatim")
            },

            TestDesc(suite: "QuoteCopy", name: "citationTemplateTakesArabicLabelOnly") {
                // citation 走 21 体例共用模板（Int?）：阿拉伯标签转 Int 进模板。
                let arabic = CitationFormatter.citation(
                    fileName: "A Sample Treatise.pdf", title: "A Sample Treatise",
                    physicalPage: 22, style: .chicago18Notes, pageLabel: "5")
                try expectEqual(arabic, "A Sample Treatise, p. 5.")
                // 罗马标签无法进模板 → 回退物理页（报告已写明）。
                let roman = CitationFormatter.citation(
                    fileName: "A Sample Treatise.pdf", title: "A Sample Treatise",
                    physicalPage: 22, style: .chicago18Notes, pageLabel: "viii")
                try expectEqual(roman, "A Sample Treatise, p. 22.")
                // 印刷页仍然最高优先。
                let printed = CitationFormatter.citation(
                    fileName: "A Sample Treatise.pdf", title: "A Sample Treatise",
                    physicalPage: 22, style: .chicago18Notes, printedPage: 4, pageLabel: "5")
                try expectEqual(printed, "A Sample Treatise, p. 4.")
            },

            TestDesc(suite: "QuoteCopy", name: "fictionalSourceTaggedFileNameParses") {
                let m = BookCitationMeta.parse(fileName: sampleFile, title: nil, author: nil)
                try expectEqual(m.author, "Avery Quill, Jordan Marlowe")
                try expectEqual(m.title, "A Sample Treatise")
                try expectTrue((m.edition ?? "").lowercased().contains("revised edition"),
                               "edition bracket is recognised, got \(m.edition ?? "nil")")
                try expectNil(m.publisher)
                try expectNil(m.year)
            },

            TestDesc(suite: "QuoteCopy", name: "fictionalSampleRendersFixed") {
                let out = CitationFormatter.quotation(
                    quote: "A sample archive sentence was written specifically for testing purposes.",
                    fileName: sampleFile, title: nil, physicalPage: 22, style: .faxueYinzhuShouce,
                    pageLabel: "5")
                try expectEqual(
                    out,
                    "“A sample archive sentence was written specifically for testing purposes.”, "
                        + "Avery Quill, Jordan Marlowe. "
                        + "A Sample Treatise (Revised Edition), p. 5.")
            },

            TestDesc(suite: "QuoteCopy", name: "fileNameParseIsConservative") {
                // 丛书/出版社括注不拆（含机构/丛书词 → 留 title）。
                let series = BookCitationMeta.parse(
                    fileName: "Some Title (Sample Research Series).pdf", title: nil, author: nil)
                try expectNil(series.author)
                try expectTrue(series.title.contains("Sample Research Series"))
                let press = BookCitationMeta.parse(
                    fileName: "Some Title (Example Press).pdf", title: nil, author: nil)
                try expectNil(press.author)
                try expectTrue(press.title.contains("Example Press"))
                // 单段不像人名（无大写词/只有 1 词/5+ 词）。
                let lower = BookCitationMeta.parse(
                    fileName: "Some Title (example name).pdf", title: nil, author: nil)
                try expectNil(lower.author)
                let many = BookCitationMeta.parse(
                    fileName: "Some Title (a b c d e f g).pdf", title: nil, author: nil)
                try expectNil(many.author)
                // 中文文件名绝不走本解析（CJK 文件名不拆）。
                let zh = BookCitationMeta.parse(
                    fileName: "Example《样书三》（子虚译，示例出版社）.pdf",
                    title: nil, author: nil)
                try expectNil(zh.author)
                try expectTrue(zh.title.contains("样书三"))
                let meta = BookCitationMeta.parse(fileName: sampleFile, title: "Given Title", author: nil)
                try expectEqual(meta.title, "Given Title")
            },

            TestDesc(suite: "QuoteCopy", name: "fileNameParseWholeLibraryRegressions") {
                let g = BookCitationMeta.parse(
                    fileName: "A Sample Treatise "
                        + "(Example Series) (Alex Example).pdf",
                    title: nil, author: nil)
                try expectEqual(g.author, "Alex Example")
                try expectTrue(g.title.contains("(Example Series)"), "series bracket stays in the title")
                let caps = BookCitationMeta.parse(
                    fileName: "A SAMPLE ARCHIVE (AVERY QUILL).pdf",
                    title: nil, author: nil)
                try expectEqual(caps.author, "AVERY QUILL")
                try expectEqual(caps.title, "A SAMPLE ARCHIVE")
                let publisher = BookCitationMeta.parse(
                    fileName: "Example Author, Sample Translation Notes, Example Press (Example House), 2001.pdf",
                    title: nil, author: nil)
                try expectNil(publisher.author, "a publisher bracket is never an author")
                let nested = BookCitationMeta.parse(
                    fileName: "Quill, Avery, The interaction of sample and practice "
                        + "(Marlowe, J.) etc., Example Press, 2001.pdf",
                    title: nil, author: nil)
                try expectNil(nested.author)
                try expectTrue(nested.title.contains("Marlowe, J.) etc."))
                let midEdition = BookCitationMeta.parse(
                    fileName: "Example Author, The Sample Catalogue (Revised Edition), "
                        + "Example Press, 2002.pdf",
                    title: nil, author: nil)
                try expectNil(midEdition.edition, "a mid-string edition bracket stays in the title")
                try expectTrue(midEdition.title.contains("(Revised Edition)"))
                let translator = BookCitationMeta.parse(
                    fileName: "Quill, Avery, A Sample Treatise (Example Translator), "
                        + "Example Journal of Samples, 2001.pdf",
                    title: nil, author: nil)
                try expectNotEqual(translator.author, "Example Translator")
                try expectTrue(translator.title.contains("(Example Translator)"))
                let plain = BookCitationMeta.parse(
                    fileName: "Quill, Avery, Notes on Fictional Subjects, Example Press, 2002.pdf",
                    title: nil, author: nil)
                try expectNil(plain.author)
                try expectNil(plain.edition)
                let suffixEdition = BookCitationMeta.parse(
                    fileName: "A Study in Epistemology (Revised Edition).pdf", title: nil, author: nil)
                try expectEqual(suffixEdition.title, "A Study in Epistemology")
                try expectEqual(suffixEdition.edition, "Revised Edition")
                let shortEdition = BookCitationMeta.parse(
                    fileName: "A Study in Epistemology (2nd ed.).pdf", title: nil, author: nil)
                try expectEqual(shortEdition.edition, "2nd ed.")
            },

            TestDesc(suite: "QuoteCopy", name: "selectionWidenedToWholeWords") {
                let page = "An indexer attempts to keep each sample record valid within the limits "
                    + "of one archive beyond the ordinary range. But this should be enough."
                let ns = page as NSString
                // 选区左端落在 "attempts" 的 "empts"，右端落在 "should" 的 "sh"。
                let start = ns.range(of: "empts").location
                let shRange = ns.range(of: "sh", options: .backwards)
                let range = start..<(shRange.location + 2)
                let out = try expectNotNil(QuoteTextNormalizer.normalize(pageText: page, utf16Range: range))
                // 左边界补全到 "attempts" 词首（原文该词前面是空格，扩词时不吞空格）。
                try expectTrue(page.hasPrefix("An indexer "), "fixture sanity")
                try expectTrue(out.hasPrefix("attempts"), "left edge widened to word start, got: \(out.prefix(20))")
                try expectFalse(out.hasPrefix("empts"), "no mid-word cut at the left edge")
                try expectTrue(out.hasPrefix("attempts to keep each sample record"),
                               "left edge widened: the selected fragment begins at the word start")
                try expectTrue(out.contains("beyond the ordinary range. But this should"),
                               "body verbatim through the fragment end")
            },

            TestDesc(suite: "QuoteCopy", name: "cjkNeverWidenedAndNewlinesMerged") {
                let page = "这是一段中文，中间没有空格。\n样书一是规则体系。"
                let ns = page as NSString
                // 选区两端位于中文字符之间，边界不得扩张。
                let start = ns.range(of: "段中").location + 1
                let end = ns.range(of: "书一").location + 1
                let out = try expectNotNil(
                    QuoteTextNormalizer.normalize(pageText: page, utf16Range: start..<end))
                try expectEqual(out, "中文，中间没有空格。 样书",
                                "CJK edges are not widened; the newline between two CJK chars is dropped")
            },

            TestDesc(suite: "QuoteCopy", name: "newlineBetweenLatinWordsBecomesSpace") {
                let page = "the limits of human\nexperience beyond those limits"
                let ns = page as NSString
                let r = ns.range(of: "limits of human")
                let out = try expectNotNil(
                    QuoteTextNormalizer.normalize(pageText: page, utf16Range: r.location..<ns.length))
                try expectEqual(out, "limits of human experience beyond those limits")
            },

            TestDesc(suite: "QuoteCopy", name: "hyphenAtLineEndKeptVerbatim") {
                let page = "the transla-\ntion of the Sample"
                let ns = page as NSString
                let out = try expectNotNil(
                    QuoteTextNormalizer.normalize(pageText: page, utf16Range: 0..<ns.length))
                try expectEqual(out, "the transla- tion of the Sample",
                                "hyphen kept (never re-joined by guessing); the newline still becomes a space")
            },

            TestDesc(suite: "QuoteCopy", name: "whitespaceCollapsedAndInvalidRangeReturnsNil") {
                let page = "alpha   beta\t\tgamma"
                let ns = page as NSString
                let out = QuoteTextNormalizer.normalize(pageText: page, utf16Range: 0..<ns.length)
                try expectEqual(out, "alpha beta gamma")
                try expectNil(QuoteTextNormalizer.normalize(pageText: page, utf16Range: 5..<5))
                try expectNil(QuoteTextNormalizer.normalize(pageText: page, utf16Range: 0..<0))
                try expectNil(QuoteTextNormalizer.normalize(pageText: "", utf16Range: 0..<1))
            },

            TestDesc(suite: "QuoteCopy", name: "normalizedTextNeverDropsContent") {
                // 不删改文字：去掉空白后的字符序列与原文区间一致。
                let page = "We hold these sample claims for testing,\nthat all sample records remain distinct."
                let ns = page as NSString
                let out = try expectNotNil(
                    QuoteTextNormalizer.normalize(pageText: page, utf16Range: 0..<ns.length))
                let a = String(out.filter { !$0.isWhitespace })
                let b = String(page.filter { !$0.isWhitespace })
                try expectEqual(a, b, "normalisation must only touch whitespace/widening, never content")
            },
        ]
    }
}
