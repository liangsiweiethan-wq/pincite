import Foundation
@testable import LiteratureSearchUI

// MARK: - Citation format registry suite (著作类多体例切片; all synthetic)
//
// Pins:   1. 21 种著作类体例注册表分组正确，既有 2 个 rawValue 不变
//         2. BookCitationMeta 解析：年份/版次/出版社保守提取，缺字段省略不编造
//         3. 每种新格式对中文书与英文书各渲染一例
//         4. 旧体例经 meta 路径保持旧版输出形态（裸元数据退回文件名本体）

enum CitationFormatSuite {
    private static let zhFile = "丙丁：《样书二》（第二版），示范书局2002年版.pdf"
    private static let zhAuthor = "丙丁"

    private static var zhMeta: BookCitationMeta {
        BookCitationMeta.parse(fileName: zhFile, title: nil, author: zhAuthor)
    }

    private static let enFile = "Quill, A Sample Treatise, Example Press, 2001.pdf"
    private static let enTitle = "A Sample Treatise"
    private static let enAuthor = "Avery Quill"

    private static var enMeta: BookCitationMeta {
        BookCitationMeta.parse(fileName: enFile, title: enTitle, author: enAuthor)
    }

    /// 与 CitationFormatter.citation 同路径，但允许注入 author（公开 API 的
    /// citation 不接收 author，author 经 BookCitationMeta.parse 进入）。
    private static func cite(_ file: String, _ title: String?, page: Int?,
                             style: CitationStyle, author: String? = nil,
                             indirect: Bool = false) -> String {
        let meta = BookCitationMeta.parse(fileName: file, title: title, author: author)
        let body = CitationFormatRegistry.descriptor(for: style).template(meta, page)
        return (indirect ? "参见" : "") + body
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "CitationFormat", name: "registryCoversTwentyOneStylesInThreeGroups") {
                try expectEqual(CitationStyle.allCases.count, 21)
                try expectEqual(CitationFormatRegistry.all.count, 21)
                // 既有 2 个案列的 rawValue 是 UserDefaults 持久化键，逐字节不可变。
                try expectEqual(CitationStyle.faxueYinzhuShouce.rawValue, "faxueYinzhuShouce")
                try expectEqual(CitationStyle.zhongguoFaxue.rawValue, "zhongguoFaxue")
                try expectEqual(CitationFormatRegistry.styles(in: .chinese).count, 9)
                try expectEqual(CitationFormatRegistry.styles(in: .englishIntl).count, 12)
                try expectTrue(CitationFormatRegistry.styles(in: .other).isEmpty,
                               "bibtex 走独立 bibtex() 路径，不进注册表")
                for style in CitationStyle.allCases {
                    let d = CitationFormatRegistry.descriptor(for: style)
                    try expectFalse(d.l10nName.isEmpty, "\(style) has a display name")
                    try expectEqual(d.id, style)
                }
                try expectEqual(CitationFormatRegistry.descriptor(for: .apa7).group, .englishIntl)
                try expectEqual(CitationFormatRegistry.descriptor(for: .beidaFabao).group, .chinese)
            },

            TestDesc(suite: "CitationFormat", name: "metaParseExtractsYearEditionPublisher") {
                let m = zhMeta
                try expectEqual(m.author, "丙丁")
                try expectEqual(m.title, "样书二")
                try expectEqual(m.publisher, "示范书局")
                try expectEqual(m.year, "2002")
                try expectEqual(m.edition, "第二版")
            },

            TestDesc(suite: "CitationFormat", name: "metaParseIsConservative") {
                // 词内年份（前后贴字母/数字）绝不剥离。
                let w = BookCitationMeta.parse(fileName: "word1993word.pdf", title: nil, author: nil)
                try expectNil(w.year)
                try expectTrue(w.title.contains("1993"), "embedded year stays in the title")
                let isbn = BookCitationMeta.parse(fileName: "caseISBN199305712.pdf", title: nil, author: nil)
                try expectNil(isbn.year, "digits glued to the year block the boundary")
                // 无结构信息时 title = cleanFileName，其余全 nil。
                let bare = BookCitationMeta.parse(fileName: "某书.pdf", title: nil, author: nil)
                try expectEqual(bare.title, "某书")
                try expectNil(bare.author)
                try expectNil(bare.publisher)
                try expectNil(bare.year)
                try expectNil(bare.edition)
                // 英文书采用元数据 title（既有规则）。
                let en = BookCitationMeta.parse(fileName: "Quill_Treatise.pdf", title: "A Sample Treatise", author: nil)
                try expectEqual(en.title, "A Sample Treatise")
                // 尾部年份剥离（其后到串尾无数字）。
                let tail = BookCitationMeta.parse(fileName: "样书三2001.pdf", title: nil, author: nil)
                try expectEqual(tail.year, "2001")
                try expectEqual(tail.title, "样书三")
            },

            TestDesc(suite: "CitationFormat", name: "everyFormatRendersChineseAndEnglishBook") {
                for style in CitationStyle.allCases {
                    let d = CitationFormatRegistry.descriptor(for: style)
                    let zh = d.template(zhMeta, nil)
                    // author-date 体例的文献内引注按惯例只标（作者 年份），
                    // 不书名；其余体例必须出现书名。
                    if style == .chicago18AuthorDate || style == .harvard {
                        try expectTrue(zh.contains("丙丁"),
                                       "\(style) renders the Chinese author label")
                        try expectTrue(zh.contains("2002"), "\(style) renders the year")
                    } else {
                        try expectTrue(zh.contains("样书二"), "\(style) renders the Chinese title")
                    }
                    let en = d.template(enMeta, 100)
                    if style == .chicago18AuthorDate || style == .harvard {
                        try expectTrue(en.contains("Quill"), "\(style) renders the English author label")
                        try expectTrue(en.contains("2001"), "\(style) renders the year")
                    } else {
                        try expectTrue(en.contains("A Sample Treatise"), "\(style) renders the English title")
                    }
                    try expectTrue(en.contains("100"), "\(style) renders the page")
                }
            },

            TestDesc(suite: "CitationFormat", name: "chineseFamilyExactShapes") {
                let zhFull = "丙丁：《样书二》（第二版），示范书局2002年版，第12页。"
                try expectEqual(cite(zhFile, nil, page: 12, style: .faxueYinzhuShouce, author: zhAuthor), zhFull)
                try expectEqual(cite(zhFile, nil, page: 12, style: .zhongguoFaxue, author: zhAuthor), zhFull)
                try expectEqual(cite(zhFile, nil, page: 12, style: .faxueYanjiu, author: zhAuthor), zhFull)
                // 书目级（无页码）
                let bookMeta = BookCitationMeta.parse(fileName: zhFile, title: nil, author: zhAuthor)
                try expectEqual(CitationFormatRegistry.descriptor(for: .zhongguoFaxue).template(bookMeta, nil),
                                "丙丁：《样书二》（第二版），示范书局2002年版。")
            },

            TestDesc(suite: "CitationFormat", name: "beidaAndGbtExactShapes") {
                try expectEqual(cite(zhFile, nil, page: 12, style: .beidaFabao, author: zhAuthor),
                                "丙丁：《样书二》,示范书局,2002,第12页。")
                try expectEqual(cite(zhFile, nil, page: 12, style: .gbt7714, author: zhAuthor),
                                "丙丁. 样书二[M]. 第二版. 示范书局, 2002: 12.")
            },

            TestDesc(suite: "CitationFormat", name: "englishIntlExactShapesEnglishBook") {
                let cases: [(CitationStyle, String)] = [
                    (.bluebook, "Avery Quill, A Sample Treatise 100 (2001)."),
                    (.oscola, "Avery Quill, A Sample Treatise (Example Press 2001) 100."),
                    (.apa7, "Avery Quill (2001). A Sample Treatise (p. 100). Example Press."),
                    (.mla9, "Avery Quill. A Sample Treatise. Example Press, 2001, p. 100."),
                    (.chicago18Notes, "Avery Quill, A Sample Treatise (Example Press, 2001), 100."),
                    (.chicago18AuthorDate, "(Avery Quill 2001, 100)"),
                    (.harvard, "(Avery Quill, 2001, p. 100)"),
                    (.vancouver, "Avery Quill. A Sample Treatise. Example Press; 2001. p. 100."),
                    (.ieee, "Avery Quill, A Sample Treatise. Example Press, 2001, p. 100."),
                    (.aglc, "Avery Quill, A Sample Treatise (Example Press, 2001) 100."),
                    (.mcgill, "Avery Quill, A Sample Treatise (Example Press, 2001) at 100."),
                    (.ama, "Avery Quill. A Sample Treatise. Example Press; 2001: 100."),
                    (.gbt7714, "Avery Quill. A Sample Treatise[M]. Example Press, 2001: 100."),
                    (.beidaFabao, "Avery Quill, A Sample Treatise, Example Press, 2001, p. 100."),
                ]
                for (style, expected) in cases {
                    let got = cite(enFile, enTitle, page: 100, style: style, author: enAuthor)
                    try expectEqual(got, expected, "\(style)")
                }
            },

            TestDesc(suite: "CitationFormat", name: "englishIntlExactShapesChineseBook") {
                let cases: [(CitationStyle, String)] = [
                    (.bluebook, "丙丁, 样书二 12 (2002)."),
                    (.oscola, "丙丁, 样书二 (示范书局 2002) 12."),
                    (.apa7, "丙丁 (2002). 样书二（p. 12）. 示范书局."),
                    (.mla9, "丙丁. 样书二. 示范书局, 2002, p. 12."),
                    (.chicago18Notes, "丙丁：《样书二》（示范书局，2002），第12页。"),
                    (.chicago18AuthorDate, "（丙丁 2002, 12）"),
                    (.harvard, "（丙丁, 2002, p. 12）"),
                    (.vancouver, "丙丁. 样书二. 示范书局; 2002. p. 12."),
                    (.ieee, "丙丁, 样书二. 示范书局, 2002, p. 12."),
                    (.aglc, "丙丁, 样书二 (示范书局, 2002) 12."),
                    (.mcgill, "丙丁, 样书二 (第二版) (示范书局, 2002) at 12."),
                    (.ama, "丙丁. 样书二. 示范书局; 2002: 12."),
                    (.gbt7714, "丙丁. 样书二[M]. 第二版. 示范书局, 2002: 12."),
                    (.beidaFabao, "丙丁：《样书二》,示范书局,2002,第12页。"),
                ]
                for (style, expected) in cases {
                    let got = cite(zhFile, nil, page: 12, style: style, author: zhAuthor)
                    try expectEqual(got, expected, "\(style)")
                }
            },

            TestDesc(suite: "CitationFormat", name: "missingFieldsAreOmittedNeverFabricated") {
                // 无作者/出版社/年份/版次 → 裸元数据退回文件名本体，无任何占位符。
                let apa = CitationFormatter.citation(fileName: "某书.pdf", title: nil,
                                                     physicalPage: nil, style: .apa7)
                try expectEqual(apa, "某书")
                try expectFalse(apa.contains("（") || apa.contains("("), "no empty parentheses")
                try expectFalse(apa.lowercased().contains("n.d."), "no fabricated year")
                try expectFalse(apa.contains("出版社"), "no fabricated publisher")
                // 有年份无出版社：出版社位省略，不留空槽。
                let gbt = CitationFormatter.citation(fileName: "样书三2001.pdf", title: nil,
                                                     physicalPage: 7, style: .gbt7714)
                try expectEqual(gbt, "样书三[M]. 2001: 7.")
                try expectFalse(gbt.contains("出版地"), "GB/T 无出版地字段 → 略去")
                // 有版次但无其他结构 → 旧版形态逐字节保留（版次贴回书名尾）。
                let legacy = CitationFormatter.citation(fileName: "甲乙《样书一》第四版.pdf",
                                                        title: nil, physicalPage: 47, style: .faxueYinzhuShouce)
                try expectEqual(legacy, "甲乙《样书一》第四版，第47页。")
                try expectEqual(CitationFormatter.bookCitation(fileName: "甲乙《样书一》第四版.pdf",
                                                               title: nil),
                                "甲乙《样书一》第四版")
                // 间接引用前缀经注册表路径仍生效。
                let indirect = cite(zhFile, nil, page: 9, style: .zhongguoFaxue,
                                    author: zhAuthor, indirect: true)
                try expectTrue(indirect.hasPrefix("参见"), indirect)
                try expectTrue(indirect.hasSuffix("第9页。"), indirect)
            },

            TestDesc(suite: "CitationFormat", name: "existingStylesKeepLegacyShapeViaMeta") {
                // Chinese journal style via the meta path: no year/edition keeps the legacy shape.
                try expectEqual(CitationFormatter.citation(fileName: "某书.pdf", title: nil,
                                                           physicalPage: 5, style: .zhongguoFaxue),
                                "某书，第5页。")
                try expectEqual(CitationFormatter.bookCitation(fileName: "某书.pdf", title: nil), "某书")
                // 英文元数据书名无字段时逐字节等于旧版。
                let en = CitationFormatter.citation(fileName: "Quill_Treatise.pdf", title: "A Sample Treatise",
                                                    physicalPage: 3, style: .zhongguoFaxue)
                try expectEqual(en, "A Sample Treatise, p. 3.")
                // 书目级英文体例保持旧版无句点尾巴（", 2001"）。
                let example = CitationFormatter.bookCitation(
                    fileName: "Avery Quill, A Sample Treatise, Example Press, 2001.pdf", title: nil)
                try expectTrue(example.hasSuffix("2001"), example)
            },

            TestDesc(suite: "CitationFormat", name: "zhColonBookTitleShape") {
                // 修：文件名「作者：《书名》，出版社+年版」主流形态。
                // 此前 title 捕获整串再套书名号=双重书名号；出版社词尾缺「馆」。
                let m = BookCitationMeta.parse(
                    fileName: "甲乙：《样书一》，示范书局2001年版.pdf",
                    title: nil, author: nil)
                try expectEqual(m.author, "甲乙")
                try expectEqual(m.title, "样书一")
                try expectEqual(m.publisher, "示范书局")
                try expectEqual(m.year, "2001")
                let cite = CitationFormatter.citation(
                    fileName: "甲乙：《样书一》，示范书局2001年版.pdf",
                    title: nil, physicalPage: 18, style: .faxueYinzhuShouce)
                try expectEqual(cite, "甲乙：《样书一》，示范书局2001年版，第18页。")
            },
        ]
    }
}
