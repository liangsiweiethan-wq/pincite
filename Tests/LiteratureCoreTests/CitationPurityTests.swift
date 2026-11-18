import Foundation
@testable import LiteratureSearchUI

// MARK: - 纯引注回归（全合成）
//
// 所有标为「引用/引注」的出口只含纯出处
//（作者：《书名》，出版社年份版，第N页），绝不混入原文片段。
// 覆盖路径：命中行右键 / 批量引注 / 收藏复制引注 / 每日一句出处 /
// PDF 右键纯引注项（同走 CitationFormatter.citation）。

enum CitationPuritySuite {
    private static let snippet = FictionalCorpus.sampleSentences[0]
    private static let fileName = "甲乙著《样书一》，示例出版社2001年版.pdf"

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "CitationPurity", name: "citationNeverContainsSnippetText") {
                for style in CitationStyle.allCases {
                    let out = CitationFormatter.citation(
                        fileName: fileName, title: nil, physicalPage: 8, style: style)
                    try expectFalse(out.contains(snippet),
                                    "\(style.rawValue) 引注混入了原文片段")
                    try expectFalse(out.contains("“") || out.contains("\""),
                                    "\(style.rawValue) 引注混入了引文引号")
                }
            },
            TestDesc(suite: "CitationPurity", name: "citationNeverContainsSnippetEvenWithTitle") {
                let out = CitationFormatter.citation(
                    fileName: "Quill, Avery, A Sample Treatise, Example Press, 2001.pdf",
                    title: "A Sample Treatise", physicalPage: 100,
                    style: .apa7, indirect: true)
                try expectFalse(out.lowercased().contains("cognitive model"),
                                "英文引注混入了原文片段")
                try expectTrue(out.hasPrefix("参见") || !out.isEmpty, "引注不应为空")
            },
            TestDesc(suite: "CitationPurity", name: "quotationIsTheOnlySnippetBearingPath") {
                // 直接引文路径允许含原文，但必须经显式 quote 参数进入。
                let q = CitationFormatter.quotation(
                    quote: snippet, fileName: fileName, title: nil,
                    physicalPage: 8, style: .faxueYinzhuShouce)
                try expectTrue(q.contains(snippet), "引文路径应保留原文")
                let pure = CitationFormatter.citation(
                    fileName: fileName, title: nil, physicalPage: 8,
                    style: .faxueYinzhuShouce)
                try expectFalse(pure.contains(snippet), "引注路径不得含原文")
            },
            TestDesc(suite: "CitationPurity", name: "bookCitationIsPureSourceToo") {
                let out = CitationFormatter.bookCitation(
                    fileName: fileName, title: nil, style: .zhongguoFaxue)
                try expectFalse(out.contains(snippet), "书目引注不得含原文")
            },
        ]
    }
}
