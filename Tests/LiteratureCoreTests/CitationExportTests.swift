import Foundation
@testable import LiteratureSearchUI

// MARK: - Citation export suite (upgrade slice; all synthetic)
//
// Pins the batch-citation and BibTeX additions to CitationFormatter:
//   1. bibliography joins one book citation per line, in order
//   2. bibtex emits ONLY fields that actually exist (never fabricated)
//   3. cite keys: ASCII titles key directly; CJK-only titles get a stable
//      numeric djb2 key (same title ⇒ same key)

enum CitationExportSuite {
    static var tests: [TestDesc] {
        [
            TestDesc(suite: "CitationExport", name: "bibliographyJoinsOneCitationPerLine") {
                let books: [(fileName: String, title: String?)] = [
                    ("甲乙《样书一》2001.pdf", nil),
                    ("Quill_Treatise.pdf", "A Sample Treatise"),
                ]
                let text = CitationFormatter.bibliography(books, style: .faxueYinzhuShouce)
                let lines = text.components(separatedBy: "\n")
                try expectEqual(lines.count, 2)
                try expectTrue(lines[0].contains("样书一"), "CJK base keeps the cleaned file name")
                try expectTrue(lines[1] == "A Sample Treatise",
                               "clean English metadata title replaces the file name")

                try expectEqual(CitationFormatter.bibliography([], style: .zhongguoFaxue), "",
                                "empty bibliography is an empty string, not a placeholder")
            },

            TestDesc(suite: "CitationExport", name: "bibtexEmitsOnlyExistingFields") {
                let full = CitationFormatter.bibtex(fileName: "Quill_Treatise.pdf",
                                                    title: "A Sample Treatise",
                                                    author: "Avery Quill",
                                                    language: "en")
                try expectTrue(full.hasPrefix("@book{ASampleTreatise,"), "ASCII title derives the cite key")
                try expectTrue(full.contains("title = {A Sample Treatise}"))
                try expectTrue(full.contains("author = {Avery Quill}"))
                try expectTrue(full.contains("language = {en}"))
                try expectTrue(full.contains("note = {"), "provenance note always present")

                let sparse = CitationFormatter.bibtex(fileName: "甲乙《样书一》2001.pdf",
                                                      title: nil, author: nil, language: nil)
                try expectTrue(sparse.contains("title = {甲乙《样书一》2001}"), "cleaned base becomes the title")
                try expectFalse(sparse.contains("author"), "unknown author is omitted, never fabricated")
                try expectFalse(sparse.contains("language"), "unknown language is omitted")
                try expectTrue(sparse.hasPrefix("@book{lit"),
                               "no-ASCII-letter title falls back to a lit<hash> key")
            },

            TestDesc(suite: "CitationExport", name: "bibtexBatchKeysAreUnique") {
                // 同书异版副本（清理后 base 相同）与不同著作同键（ASCII 前缀雷同）
                // 两类场景都必须产出唯一的 .bib 键（稳定 -2/-3 后缀，输入序确定）。
                let books: [(fileName: String, title: String?, author: String?, language: String?)] = [
                    ("戊己：《样书三》2001.pdf", nil, nil, nil),
                    ("戊己：《样书三》2001_异版00000001.pdf", nil, nil, nil),
                    ("戊己：《样书三》2001_异版00000002.pdf", nil, nil, nil),
                    ("Quill：《样书一》，示例出版社2001年版.pdf", nil, nil, nil),
                    ("Marlowe：《样书二》，示范书局2002年版.pdf", nil, nil, nil),
                ]
                let text = CitationFormatter.bibtexBatch(books)
                let keys = text.components(separatedBy: "\n")
                    .filter { $0.hasPrefix("@book{") }
                    .map { $0.dropFirst("@book{".count).dropLast(",".count) }
                try expectEqual(keys.count, 5)
                try expectEqual(Set(keys).count, 5, "duplicate keys would make the .bib invalid")
                try expectTrue(text.contains(",\n  title = {戊己：《样书三》2001}"), "entry body intact")
            },

            TestDesc(suite: "CitationExport", name: "bibtexBatchOrderIsStable") {
                let books: [(fileName: String, title: String?, author: String?, language: String?)] = [
                    ("丙丁：《样书二》2002.pdf", nil, nil, nil),
                    ("丙丁：《样书二》2002_异版deadbeef.pdf", nil, nil, nil),
                ]
                let a = CitationFormatter.bibtexBatch(books)
                let b = CitationFormatter.bibtexBatch(books)
                try expectEqual(a, b, "same batch must serialize identically (stable -2 suffix)")
                try expectTrue(a.contains("@book{lit"), "base key first")
                try expectTrue(a.contains("@book{lit"),
                               "sanity") // 第二条带 -2 后缀（具体数字由 djb2 决定）
                try expectTrue(a.range(of: "-2,") != nil, "second occurrence gets the -2 suffix")
            },

            TestDesc(suite: "CitationExport", name: "bibtexCJKKeyIsStableAcrossCalls") {
                let a = CitationFormatter.bibtex(fileName: "丙丁《样书二》中文版.pdf",
                                                 title: nil, author: nil, language: nil)
                let b = CitationFormatter.bibtex(fileName: "丙丁《样书二》中文版.pdf",
                                                 title: nil, author: nil, language: nil)
                try expectEqual(a, b, "same input must yield a byte-identical entry")
                let key = a.components(separatedBy: "{")[1].components(separatedBy: ",").first ?? ""
                try expectTrue(key.hasPrefix("lit"), "key body is lit<digits>")
                try expectTrue(key.count <= "lit".count + 8, "numeric key is at most 8 digits")
            },
            TestDesc(suite: "CitationExport", name: "quotationKeepsSelectedTextVerbatim") {
                // 选中文本右键直接引文：引文原样（不截断/不改写），页号来自选区页，
                // **无括号包裹**（产品决策：括号妨碍直接粘贴）。
                let zh = CitationFormatter.quotation(quote: "  样书一是……  ", fileName: "甲乙《样书一》.pdf",
                                                     title: nil, physicalPage: 47, style: .faxueYinzhuShouce)
                try expectTrue(zh.hasPrefix("“样书一是……”，"), "quote trimmed, verbatim, comma-joined")
                try expectTrue(zh.contains("甲乙《样书一》，第47页。"), "CJK source without parentheses")
                try expectFalse(zh.contains("（甲乙") && zh.contains("）"), "no wrapping parentheses")

                let en = CitationFormatter.quotation(quote: "sample records remain distinct", fileName: "Quill_Treatise.pdf",
                                                     title: "A Sample Treatise", physicalPage: 3, style: .zhongguoFaxue)
                try expectEqual(en, "“sample records remain distinct”, A Sample Treatise, p. 3.")

                let noPage = CitationFormatter.quotation(quote: "x", fileName: "某书.pdf", title: nil,
                                                         physicalPage: nil, style: .faxueYinzhuShouce)
                try expectTrue(noPage.hasSuffix("，某书。"), "missing page stays honest")
            },
        ]
    }
}
