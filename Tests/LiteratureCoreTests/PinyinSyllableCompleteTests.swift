import Foundation
@testable import LiteratureCore

// MARK: - （设计取舍）：音节表补全回归断言

enum PinyinSyllableCompleteSuite {

    static let namedTwenty = [
        "ne", "nou", "nun", "lie", "lou", "tou", "can", "cang", "cou",
        "san", "sang", "sou", "rao", "ren", "rong", "zhou", "chou",
        "jiong", "qiong", "xiong",
    ]

    static var tests: [TestDesc] {
        [
            // 断言一：点名 20 音节逐个真断言——表里收了且可解析，缺一即红。
            TestDesc(suite: "PinyinSyllableComplete", name: "namedTwentySyllablesEachTrue") {
                for s in namedTwenty {
                    try expectTrue(PinyinSyllables.syllables.contains(s),
                                   "音节表必须显式收录「\(s)」")
                    try expectTrue(PinyinSyllables.isParseable(s),
                                   "音节「\(s)」必须可解析")
                }
            },

            // 断言二：表量级与词形不变式——总数断言固定 414；全表非空小写 ASCII
            // 字母（防再截断/防脏数据）。
            TestDesc(suite: "PinyinSyllableComplete", name: "tableScaleAndShapeInvariant") {
                try expectEqual(PinyinSyllables.syllables.count, 414,
                                "完整标准表总数断言固定 414（实得 \(PinyinSyllables.syllables.count)），增删须连测试一起改并重跑程序化验证出零 diff 证据")
                for s in PinyinSyllables.syllables {
                    try expectTrue(!s.isEmpty && s.allSatisfy { $0.isASCII && $0.isLowercase },
                                   "音节表词形必须为非空小写 ASCII 字母，违例：「\(s)」")
                }
            },

            // 断言三：程序化枚举发现的 4 个漏收
            // 高频音节——点名式补漏（20 个）未覆盖、全组合枚举揪出
            //（hang 航/kan 看/kang 康/ti 提）。逐个真断言＋代表合成词断言。
            TestDesc(suite: "PinyinSyllableComplete", name: "programmaticProofFoundFourOmissions") {
                for (s, word) in [("hang", "hangzhou"), ("kan", "kankan"),
                                  ("kang", "jiankang"), ("ti", "wenti")] {
                    try expectTrue(PinyinSyllables.syllables.contains(s),
                                   "音节表必须显式收录「\(s)」（程序化全组合枚举发现的漏收，已点名）")
                    try expectTrue(PinyinSyllables.isParseable(s),
                                   "音节「\(s)」必须可解析")
                    try expectTrue(PinyinSyllables.isParseable(word),
                                   "合成词「\(word)」必须可解析（\(s) 缺收时的用户面误假回归断言）")
                }
            },

            // 断言四：表↔判定器闭环——表内每个多字母音节必可独立解析、每个
            // 单字母音节必因长度门判假（防拼写坏行混入表内）。
            TestDesc(suite: "PinyinSyllableComplete", name: "tableEntriesParseableClosedLoop") {
                for s in PinyinSyllables.syllables {
                    try expectEqual(PinyinSyllables.isParseable(s), s.count >= 2,
                                    "表内音节「\(s)」与判定器闭环破裂（多字母必真、单字母必假）")
                }
            },

            TestDesc(suite: "PinyinSyllableComplete", name: "compoundWordsWithRestoredSyllables") {
                for (w, split) in [("nvren", "nv+ren"), ("lvzhou", "lv+zhou"),
                                   ("renkou", "ren+kou"), ("renminbi", "ren+min+bi"),
                                   ("nengren", "neng+ren"), ("zhoumo", "zhou+mo"),
                                   ("chouyan", "chou+yan"), ("cansai", "can+sai"),
                                   ("sangzi", "sang+zi"), ("soujiu", "sou+jiu"),
                                   ("ronghe", "rong+he"), ("raoluan", "rao+luan"),
                                   ("lieju", "lie+ju"), ("louceng", "lou+ceng"),
                                   ("touzi", "tou+zi"), ("jiongjing", "jiong+jing"),
                                   ("qiongren", "qiong+ren"), ("xiongmao", "xiong+mao"),
                                   ("jiong", "jiong"), ("qiong", "qiong"), ("xiong", "xiong")] {
                    try expectTrue(PinyinSyllables.isParseable(w),
                                   "「\(w)」（\(split)）必须可解析——修复前误假的音节表缺陷回归断言")
                }
                // 判定器与路由契约的联动面：可解析合成词走双形态并集（falv 断言
                // 在 PinyinSyllableGate，此处防补表破坏 nv/lv 系惯用形解析）。
                try expectTrue(PinyinSyllables.isParseable("nvhai"), "nv+hai 女孩")
                try expectTrue(PinyinSyllables.isParseable("lvse"), "lv+se 绿色")
            },

            // 断言六：假阳性回归断言——扩表后西文词仍不得进解析面
            // English-word regression cases: van/vex/vexley/calvic/davik/fexley;
            // 含新补 4 音节的复检——补 hang/kan/kang/ti 不得开新口子）。
            TestDesc(suite: "PinyinSyllableComplete", name: "englishWordsStayUnparseableAfterExpansion") {
                for w in ["rights", "law", "state", "mind", "van", "vex", "vexley",
                          "fexley", "calvic", "davik", "sudo", "linux", "system",
                          "python", "git", "hub", "sovereignty", "partition",
                          "titanic", "kangaroo", "hangover"] {
                    try expectFalse(PinyinSyllables.isParseable(w),
                                    "「\(w)」扩表后仍不得判为拼音（假阳性回归断言）")
                }
            },
        ]
    }
}
