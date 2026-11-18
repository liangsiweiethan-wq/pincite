import Foundation

/// 完全虚构的书目素材词表。所有测试夹具必须引用本表或仿照其形态，
/// 不得使用任何真实书名、人名、出版社、期刊、年份组合或真实库数字。
/// 年份一律用 2001/2002 等整齐值；sha256/指纹用 0000…/deadbeef… 形态。
enum FictionalCorpus {
    // MARK: 中文书目（人名、书名、出版社全部虚构）
    struct ZhBook {
        let author: String
        let title: String
        let publisher: String
        let year: Int
        let sha256: String
    }

    static let zhBooks: [ZhBook] = [
        ZhBook(author: "甲乙", title: "样书一", publisher: "示例出版社", year: 2001, sha256: "0000000000000000000000000000000000000000000000000000000000000001"),
        ZhBook(author: "丙丁", title: "样书二", publisher: "示范书局", year: 2002, sha256: "0000000000000000000000000000000000000000000000000000000000000002"),
        ZhBook(author: "戊己", title: "样书三", publisher: "示例出版社", year: 2001, sha256: "deadbeef00000000000000000000000000000000000000000000000000000001"),
    ]

    // MARK: 英文书目
    struct EnBook {
        let author: String
        let title: String
        let publisher: String
        let year: Int
        let sha256: String
    }

    static let enBooks: [EnBook] = [
        EnBook(author: "Quill, Avery", title: "A Sample Treatise", publisher: "Example Press", year: 2001, sha256: "0000000000000000000000000000000000000000000000000000000000000003"),
        EnBook(author: "Marlowe, Jordan", title: "Notes on Fictional Subjects", publisher: "Sample House", year: 2002, sha256: "deadbeef00000000000000000000000000000000000000000000000000000002"),
    ]

    // MARK: 译者（虚构，人数与名字不得沿用任何真实条目）
    static let zhTranslators = ["子虚", "乌有"]
    static let zhTranslationNote = "子虚、乌有译，示例出版社 2001 年版"

    // MARK: 期刊（虚构）
    static let journals = ["《样刊研究》", "《示例学刊》"]
    static let additionalTitles = ["法律样本", "律学样本", "示例学科"]

    // MARK: 虚构目录路径（不得使用任何真实用户的目录习惯）
    static let paths = [
        "/Samples/Books/sample-one.pdf",
        "/Samples/Papers/sample-two.pdf",
        "/Samples/Entries/sample-three.pdf",
    ]

    // MARK: 自撰中性句子（用于引文抽取/校验测试，非任何真实原文）
    static let sampleSentences = [
        "这是一句为测试而自拟的中性句子，不来自任何真实出版物。",
        "This sentence was written specifically for testing purposes and comes from no real publication.",
    ]
}
