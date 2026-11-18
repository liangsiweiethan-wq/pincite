import Foundation
@testable import LiteratureCore

// MARK: -（设计取舍）：拼音别名启用改由音节判定门控

enum PinyinSyllableGateSuite {

    /// 门控测试共用小库（六书，各自投影面互不串扰）：
    /// - bk-primary  fileName "falv-report.pdf"＋title "Falv Report"——投影含
    ///   字面 "falv"（主形态命中锚；合成面：真实投影经 CFStringTransform
    ///   不产生 v，此书 fileName 直落拉丁字母原样进投影）。
    static func makeGateLibrary() throws -> (IndexStore, URL) {
        let dir = Fixtures.makeTempDir("pinyin-gate")
        let store = try Fixtures.openStore(in: dir)
        try IndexingRegressionSuite.addBook(store, id: "bk-primary", fileName: "falv-report.pdf",
                                       title: "Falv Report", author: nil,
                                       pages: ["primary projection page"])
        try IndexingRegressionSuite.addBook(store, id: "bk-alias", fileName: "sample-law.pdf",
                                       title: "法律样本", author: "丙丁",
                                               pages: ["sample archive records"])
        try IndexingRegressionSuite.addBook(store, id: "bk-van", fileName: "van-exampleton.pdf",
                                       title: "Van Exampleton", author: nil,
                                       pages: ["example manifesto"])
        try IndexingRegressionSuite.addBook(store, id: "bk-yuan", fileName: "yuanli.pdf",
                                       title: "元理", author: nil, pages: ["元理正文"])
        try IndexingRegressionSuite.addBook(store, id: "bk-quan", fileName: "quanguan.pdf",
                                       title: "全观", author: nil, pages: ["全观正文"])
        try IndexingRegressionSuite.addBook(store, id: "bk-ehall", fileName: "vexley-hall.pdf",
                                        title: "Vexley Hall", author: nil,
                                        pages: ["library hall records"])
        try store.backfillPinyinIfNeeded()
        return (store, dir)
    }

    static var tests: [TestDesc] {
        [
            // 判定器本体断言。
            TestDesc(suite: "PinyinSyllableGate", name: "syllableTablePinsDesignAnchors") {
                for w in ["falv", "faludegailun", "quanli", "falu", "faludequanwei",
                          "lv", "nv", "lve", "nve", "lun", "yuanli", "nihao", "chongqing"] {
                    try expectTrue(PinyinSyllables.isParseable(w),
                                   "「\(w)」必须是合法全拼音节串（DP 完全可切分）")
                }
                for w in ["rights", "law", "state", "mind", "van", "vex", "vexley",
                          "vexley", "calvic", "davik", "fexley", "", "a", "norm2"] {
                    try expectFalse(PinyinSyllables.isParseable(w),
                                    "「\(w)」不得判为拼音（含空串/过短/含数字）")
                }
                // 判定器与投影基准互通：投影侧 falu（律→lu）同为可解析音节串。
                try expectTrue(PinyinSyllables.isParseable(PinyinNorm.transform("法律样本")),
                               "投影形态 falu… 必须可解析（门控不阻断存量投影面的别名启用）")
            },

            // 测试一：falv 达 falu 书（需求，门控不得回退）。
            TestDesc(suite: "PinyinSyllableGate", name: "falvReachesFaluBookViaUnion") {
                let (store, dir) = try makeGateLibrary()
                defer { Fixtures.cleanup(dir) }
                let ids = try store.bookIDsMatchingPinyin("falv")
                try expectTrue(ids.contains("bk-alias"),
                               "falv（fa+lv，可解析）必须经 v→u 别名命中 falu 投影书")
                // 主形态字面命中（bk-primary，及 example 的子串面）与别名命中并集去重。
                try expectTrue(ids.contains("bk-primary"), "主形态字面投影命中保留")
                try expectEqual(Set(ids).count, ids.count, "双形态并集必须去重")
            },

            // 测试二：van 不置前——不可解析词仅主形态，uan 系书零污染。
            TestDesc(suite: "PinyinSyllableGate", name: "vanNotAliasedNorPinned") {
                let (store, dir) = try makeGateLibrary()
                defer { Fixtures.cleanup(dir) }
                try expectFalse(PinyinSyllables.isParseable("van"),
                                "van 非合法拼音音节串（判定器断言，防门控放宽回潮）")
                try expectEqual(try store.bookIDsMatchingPinyin("van"), ["bk-van"],
                                "van 仅主形态命中，别名（uan）不得参与（并集不得误伤置前）")
                // 书目级全链路：uan 系书不得因 van 拼音命中被置前/拖入。
                let hits = try SearchService(store: store).matchingBooks("van")
                try expectTrue(!hits.contains { $0.bookID == "bk-yuan" || $0.bookID == "bk-quan" },
                               "van 不得拖入 uan 系书；实得 \(hits.map(\.bookID))")
                try expectTrue(hits.contains { $0.bookID == "bk-van" },
                               "van 西文主形态照常命中")
            },

            // 测试三：vexley 主形态直 hit（非可解析西文 v 词零别名、零冲淡）。
            TestDesc(suite: "PinyinSyllableGate", name: "vexleyPrimaryFormDirectHit") {
                let (store, dir) = try makeGateLibrary()
                defer { Fixtures.cleanup(dir) }
                try expectFalse(PinyinSyllables.isParseable("vexley"),
                                "vexley 非合法拼音音节串")
                try expectEqual(try store.bookIDsMatchingPinyin("vexley"), ["bk-ehall"],
                                "vexley 主形态直 hit；别名 fauley 不得参与或引入")
            },

            // 测试四：同书两形态去重——投影同时含 falv/falu 时恰一条。
            TestDesc(suite: "PinyinSyllableGate", name: "bothFormsDedupSameBook") {
                let dir = Fixtures.makeTempDir("pinyin-gate-dedup")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                try IndexingRegressionSuite.addBook(store, id: "bk-both", fileName: "falv-falu.pdf",
                                               title: "falv falu", author: nil,
                                               pages: ["both forms page"])
                try store.backfillPinyinIfNeeded()
                let ids = try store.bookIDsMatchingPinyin("falv")
                try expectEqual(ids, ["bk-both"],
                                "同书两形态命中必须去重为单条（主形态 collect 先行、别名 collect 见 seen 跳过）")
            },

            // 测试五：跨书排序——主形态命中恒排别名命中之前（输出全序锚）。
            TestDesc(suite: "PinyinSyllableGate", name: "crossBookOrderPrimaryBeforeAlias") {
                let dir = Fixtures.makeTempDir("pinyin-gate-order")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                try IndexingRegressionSuite.addBook(store, id: "bk-primary", fileName: "falv-report.pdf",
                                               title: "Falv Report", author: nil,
                                               pages: ["primary projection page"])
                try IndexingRegressionSuite.addBook(store, id: "bk-alias", fileName: "sample-law.pdf",
                                               title: "法律样本", author: "丙丁",
                                               pages: ["sample archive records"])
                try store.backfillPinyinIfNeeded()
                let ids = try store.bookIDsMatchingPinyin("falv")
                try expectEqual(ids, ["bk-primary", "bk-alias"],
                                "主形态命中在前、别名命中在后（collect 次序即输出次序；跨书排序断言）")
            },

            // 测试六：collect SQL 顺序契约——
            // 多主形态命中＋多别名命中时，输出全序＝主形态组（book_id ASC）
            // → 别名组（book_id ASC，已见去重）。插入次序刻意与字母序正交，
            // 组内一旦回到插入序/字典序即红。
            TestDesc(suite: "PinyinSyllableGate", name: "collectOrderMainGroupThenAliasGroupBookIdAsc") {
                let dir = Fixtures.makeTempDir("pinyin-gate-sqlorder")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                // 插入序 z→a→m→b；主形态书投影只含字面 falv（fileName 拉丁
                // 原样落投影），别名书投影只含 falu（汉字 ü→u 面）——两两互斥。
                try IndexingRegressionSuite.addBook(store, id: "z-main-falv", fileName: "z-falv-two.pdf",
                                               title: "Z Falv Two", author: nil, pages: ["main two"])
                try IndexingRegressionSuite.addBook(store, id: "a-main-falv", fileName: "a-falv-one.pdf",
                                               title: "A Falv One", author: nil, pages: ["main one"])
                try IndexingRegressionSuite.addBook(store, id: "m-alias-falu", fileName: "m-law-two.pdf",
                                               title: "法律甲", author: nil, pages: ["alias two"])
                try IndexingRegressionSuite.addBook(store, id: "b-alias-falu", fileName: "b-law-one.pdf",
                                               title: "法律乙", author: nil, pages: ["alias one"])
                try store.backfillPinyinIfNeeded()
                let ids = try store.bookIDsMatchingPinyin("falv")
                try expectEqual(ids, ["a-main-falv", "z-main-falv", "b-alias-falu", "m-alias-falu"],
                                "主形态组（book_id ASC）在前、别名组（book_id ASC）在后——collect ORDER BY 契约断言")
            },

            // 测试七（方案 A 固定契约）：非
            // isPinyinQuery 查询一律空集——中文/数字/含分隔符/单字符/空串，
            // 即使 transform 能投影成合法拼音串（"法律"→"falv"）也不得命中。
            TestDesc(suite: "PinyinSyllableGate", name: "nonPinyinQueryNeedleReturnsEmpty") {
                let (store, dir) = try makeGateLibrary()
                defer { Fixtures.cleanup(dir) }
                // 正对照：合法拼音词照常命中（库内 bk-primary 含字面 falv 投影）。
                let positive = try store.bookIDsMatchingPinyin("falv")
                try expectTrue(!positive.isEmpty,
                               "正对照：falv 必须照常命中（防测试库本身失效）")
                try expectEqual(try store.bookIDsMatchingPinyin("法律"), [] as [String],
                                "中文查询必须空集（修复前会经 transform→falv 借投影误命中）")
                for needle in ["123", "falv.pdf", "fa-lv", "fa 法", "a", ""] {
                    try expectEqual(try store.bookIDsMatchingPinyin(needle), [] as [String],
                                    "非拼音查询「\(needle)」必须空集（固定契约）")
                }
            },

            TestDesc(suite: "PinyinSyllableGate", name: "queryContractBoundaryFourClasses") {
                // 自建测试库（直调面空集闭环用）。
                let (store, dir) = try makeGateLibrary()
                defer { Fixtures.cleanup(dir) }
                try expectTrue(PinyinNorm.isPinyinQuery("FaLv"),
                               "大小写混合必须收——正常键盘态，拒绝即误伤")
                try expectEqual(PinyinNorm.transform("FaLv"), "falv",
                                "混合大小写经 transform 折叠为小写（收的门控＋折叠的投影配套）")
                // 拒绝类：谓词假＋直调面空集双断言。
                let rejects: [(String, String)] = [
                    ("ASCII 控制字符(BEL)", "fa\u{07}lv"),
                    ("ASCII 控制字符(TAB)", "fa\tlv"),
                    ("带调拼音", "nǚ"),
                    ("全角", "ｆａｌｖ"),
                    ("非 ASCII Unicode 字母", "café"),
                ]
                for (label, needle) in rejects {
                    try expectFalse(PinyinNorm.isPinyinQuery(needle),
                                    "「\(label)」形态必须拒——非键盘直出拼音形态（\(needle)），契约从窄")
                    try expectEqual(try store.bookIDsMatchingPinyin(needle), [] as [String],
                                    "「\(label)」查询经 bookIDsMatchingPinyin 直调必须空集（门控闭环）")
                }
                // transform 侧基准断言（doc comment 所载三条边界的机器可查形）：
                try expectEqual(PinyinNorm.transform("ｆａｌｖ"), "ｆａｌｖ",
                                "transform 不折叠全角（NFC 无宽度折叠）——正是门控必须拒全角的根由")
                try expectEqual(PinyinNorm.transform("fa\tlv"), "falv",
                                "transform 滤除控制字符（控制字符在投影面不存活）")
                try expectEqual(PinyinNorm.transform("nǚ"), "nu",
                                "transform 折带调为无调（nǚ→nu）——带调形若放行将与库存 u 面错位")
            },
        ]
    }
}
