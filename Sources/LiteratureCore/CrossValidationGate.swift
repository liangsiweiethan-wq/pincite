import Foundation


// MARK: - 判定结果结构（verdict 枚举 + ratio 字段）
struct CrossValidationVerdict {
    enum Verdict: Equatable {
        case pass(suspiciousPages: [Int])          // 分歧页清单作低置信标记
        case circuitBroken(suspiciousPages: [Int]) // 熔断：超 5% 阈值
    }
    let verdict: Verdict
    let divergedRatio: Double // 分歧页数 / 总页数（两组页数均为 0 时记 0）
}

// MARK: - 双引擎 OCR 交叉验证门判定器
struct CrossValidationGate {
    static let divergeThreshold = 0.05

    /// 归一化：去空白 + 全角转半角 + case 折叠
    static func normalizeForDiff(_ s: String) -> String {
        let halfWidth = s.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 0x3000: return " "
            case 0xFF01...0xFF5E:
                return Character(UnicodeScalar(scalar.value - 0xFEE0)!)
            default:
                return Character(scalar)
            }
        }
        return String(halfWidth)
            .filter { !$0.isWhitespace }
            .lowercased()
    }

    /// 逐页比对并给出判定。页数不等时，页数差记为全分歧页（多出的页下标全部计分歧）。
    static func judge(pageA: [String], pageB: [String]) -> CrossValidationVerdict {
        let countA = pageA.count
        let countB = pageB.count
        let common = min(countA, countB)
        let total = max(countA, countB)

        var suspicious: [Int] = []
        for i in 0..<common {
            if normalizeForDiff(pageA[i]) != normalizeForDiff(pageB[i]) {
                suspicious.append(i)
            }
        }
        // 页数差的部分整页记为分歧
        if common < total {
            suspicious.append(contentsOf: common..<total)
        }

        let ratio = total == 0 ? 0.0 : Double(suspicious.count) / Double(total)
        let verdict: CrossValidationVerdict.Verdict = ratio > divergeThreshold
            ? .circuitBroken(suspiciousPages: suspicious)
            : .pass(suspiciousPages: suspicious)
        return CrossValidationVerdict(verdict: verdict, divergedRatio: ratio)
    }
}

// MARK: - 测试（Pinning Tests）
enum CrossValidationGateTests {

    private static func check(_ name: String, _ cond: Bool) {
        assert(cond, "❌ FAILED: \(name)")

    }

    static func runAll() {
        let unequal = CrossValidationGate.judge(
            pageA: ["a", "b", "c"],
            pageB: ["a", "b"])
        check("页数不等等于全分歧",
              unequal.verdict == .circuitBroken(suspiciousPages: [2])
              && abs(unequal.divergedRatio - 1.0 / 3.0) < 1e-9)

        let identical = CrossValidationGate.judge(
            pageA: ["Hello", "World"],
            pageB: ["Hello", "World"])
        check("全同零分歧",
              identical.verdict == .pass(suspiciousPages: [])
              && identical.divergedRatio == 0.0)

        let baseA = (0..<20).map { "page\($0)" }
        var baseB = baseA
        baseB[7] = " DIFFERENT "
        let boundary = CrossValidationGate.judge(pageA: baseA, pageB: baseB)
        check("恰好5%边界判定为pass",
              boundary.verdict == .pass(suspiciousPages: [7])
              && abs(boundary.divergedRatio - 0.05) < 1e-9)

        var overB = baseB
        overB[13] = "ALSO#DIFFERENT"
        let over = CrossValidationGate.judge(pageA: baseA, pageB: overB)
        check("超5%熔断",
              over.verdict == .circuitBroken(suspiciousPages: [7, 13])
              && abs(over.divergedRatio - 0.10) < 1e-9)

        let tolerant = CrossValidationGate.judge(
            pageA: ["Ｈｅｌｌｏ　Ｗｏｒｌｄ１２３！",
                     "  Some Page  "],
            pageB: ["hello world123!",
                     "some\npage"])
        check("全角半角与case不算分歧",
              tolerant.verdict == .pass(suspiciousPages: [])
              && tolerant.divergedRatio == 0.0)
    }
}

// 入口（脚本场景）：
// CrossValidationGateTests.runAll
