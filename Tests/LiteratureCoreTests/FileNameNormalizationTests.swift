import Foundation
@testable import LiteratureCore

// MARK: - 功能扩展：文件名规范化反查降级处理测试
//
// 断言面：去扩展名／`_` `.` `-` 归一空格／去方括号段
//（[1234.5678] arXiv ID、[another.org] 记名段）／压缩连续空白＋trim／空或纯
// 数字 → nil（不猜）。

enum FileNameNormalizationSuite {
    static var tests: [TestDesc] {
        [
            TestDesc(suite: "FileNameNormalization", name: "stripsExtensionAndNormalizesSeparators") {
                try expectEqual(FileNameNormalization.normalizedTitleGuess(from: "A_B-C.pdf"),
                                "A B C")
                try expectEqual(FileNameNormalization.normalizedTitleGuess(from: "Sample.Volume.pdf"),
                                "Sample Volume")
                try expectEqual(FileNameNormalization.normalizedTitleGuess(from: "no_extension"),
                                "no extension")
                try expectEqual(FileNameNormalization.normalizedTitleGuess(from: "已经很长  的 名.pdf"),
                                "已经很长 的 名", "既有空白压缩")
            },
            TestDesc(suite: "FileNameNormalization", name: "removesBracketedSegments") {
                // arXiv ID 段与记名段（含内部点号——归空格发生在去段前，段整块删除）。
                try expectEqual(
                    FileNameNormalization.normalizedTitleGuess(from: "Sample Volume [1234.5678].pdf"),
                    "Sample Volume")
                try expectEqual(
                    FileNameNormalization.normalizedTitleGuess(from: "Example_Book_[another.org].pdf"),
                    "Example Book")
                // 连续多段一次清干净。
                try expectEqual(
                    FileNameNormalization.normalizedTitleGuess(from: "T [a] [b].pdf"), "T")
                // 未闭合方括号保留原文（不猜配对；"[" 字面随段保留）。
                try expectEqual(
                    FileNameNormalization.normalizedTitleGuess(from: "T [2020.pdf"), "T [2020")
            },
            TestDesc(suite: "FileNameNormalization", name: "refusesEmptyAndPureDigitGuesses") {
                try expectNil(FileNameNormalization.normalizedTitleGuess(from: "   .pdf"),
                              "空白 → nil")
                try expectNil(FileNameNormalization.normalizedTitleGuess(from: "12345.pdf"),
                              "纯数字 → nil（不猜）")
                try expectNil(FileNameNormalization.normalizedTitleGuess(from: "[another.org].pdf"),
                              "去段后剩空 → nil")
                try expectEqual(FileNameNormalization.normalizedTitleGuess(from: "2020 年报告.pdf"),
                                "2020 年报告", "含非数字字符不算纯数字")
            },
            TestDesc(suite: "FileNameNormalization", name: "idempotentOnAlreadyCleanNames") {
                // App 层已传去扩展名文件名时规范化幂等无害（接线声明）。
                let once = FileNameNormalization.normalizedTitleGuess(from: "Ordinary Title.pdf")
                let twice = once.flatMap {
                    FileNameNormalization.normalizedTitleGuess(from: $0)
                }
                try expectEqual(once, "Ordinary Title")
                try expectEqual(twice, once)
            },
        ]
    }
}
