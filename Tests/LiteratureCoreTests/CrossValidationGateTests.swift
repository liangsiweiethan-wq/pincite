import Foundation
@testable import LiteratureCore

// 交叉验证门的五条断言（大小写差异不算分歧，页数不等也不等于全分歧）。
enum CrossValidationGateSuite {
    static var tests: [TestDesc] {
        var t: [TestDesc] = []
        t.append(TestDesc(suite: "CrossValidationGate", name: "identicalPagesPassWithZeroSuspicious") {
            let pages = ["The Fictional Order", "Chapter Two", "rights and duties"]
            let v = CrossValidationGate.judge(pageA: pages, pageB: pages)
            guard case .pass(let sus) = v.verdict else { try failTest("应 pass") }
            try expectTrue(sus.isEmpty && v.divergedRatio == 0)
        })
        t.append(TestDesc(suite: "CrossValidationGate", name: "fullWidthAndCaseAreNotDivergence") {
            let a = ["The Fictional Order", "ＲＩＧＨＴＳ ａｎｄ ｄｕｔｉｅｓ"]
            let b = ["the  fictional   order", "rights and DUTIES"]
            let v = CrossValidationGate.judge(pageA: a, pageB: b)
            guard case .pass = v.verdict else { try failTest("全角/case/空白差不应判分歧") }
        })
        t.append(TestDesc(suite: "CrossValidationGate", name: "pageCountMismatchCountsAllExtraPages") {
            let a = ["p1", "p2", "p3", "p4"]
            let b = ["p1", "p2"]
            let v = CrossValidationGate.judge(pageA: a, pageB: b)
            guard case .circuitBroken(let sus) = v.verdict else { try failTest("50% 分歧应熔断") }
            try expectTrue(sus == [2, 3], "多出页下标应 [2,3]: \(sus)")
            try expectTrue(abs(v.divergedRatio - 0.5) < 0.0001)
        })
        t.append(TestDesc(suite: "CrossValidationGate", name: "exactlyFivePercentIsPassBoundary") {
            // 20 页恰 1 页分歧 = 5% = 阈值边界（>阈才熔断）。
            var a = (0..<20).map { "page \($0)" }
            var b = a
            b[19] = "changed page"
            a[19] = "page 19"
            let v = CrossValidationGate.judge(pageA: a, pageB: b)
            guard case .pass(let sus) = v.verdict else { try failTest("恰 5% 应 pass") }
            try expectTrue(sus == [19])
        })
        t.append(TestDesc(suite: "CrossValidationGate", name: "overFivePercentCircuitBreaks") {
            let a = (0..<20).map { "page \($0)" }
            var b = a
            b[18] = "changed eighteen"
            b[19] = "changed nineteen"
            let v = CrossValidationGate.judge(pageA: a, pageB: b)
            guard case .circuitBroken(let sus) = v.verdict else { try failTest("10% 应熔断") }
            try expectTrue(sus == [18, 19])
        })
        return t
    }
}
