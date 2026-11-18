import Foundation
@testable import LiteratureCore

// MARK: - 无障碍审计套件
//
// 守卫本体纯函数化（A11yGuards，见 DesignGuardTests.swift）：本套件注入桩
// 文本做正反例锁定守卫行为；DesignGuardSuite 扫真文件。VoiceOver 与键盘实机
// 走查受无头环境限制，本套件只覆盖代码级规则。

enum A11yAuditSuite {
    static var tests: [TestDesc] {
        [
            TestDesc(suite: "A11yAudit", name: "motionGateFlagsAnimatedFileWithoutReduceMotion") {
                // 反例：有动画、无 reduceMotion → 违规。
                let bad = [("A.swift", "body {\n withAnimation(.easeInOut) { x = 1 }\n}")]
                try expectEqual(A11yGuards.motionGateViolations(bad), ["A.swift"])
                // 正例：同文件有 reduceMotion 门 → 过。
                let good = [("B.swift", "withAnimation(reduceMotion ? nil : .easeInOut) { x = 1 }")]
                try expectTrue(A11yGuards.motionGateViolations(good).isEmpty)
                // 注释行提及动画不算调用。
                let comment = [("C.swift", "// withAnimation was here\nlet a = 1")]
                try expectTrue(A11yGuards.motionGateViolations(comment).isEmpty)
            },

            TestDesc(suite: "A11yAudit", name: "contrastGateRequiresColorSchemeContrastInDesignSystem") {
                let missing = [("DesignSystem.swift", "enum DS {}")]
                try expectEqual(A11yGuards.contrastGateViolations(missing), ["DesignSystem.swift"])
                let present = [("DesignSystem.swift",
                                "@Environment(\\.colorSchemeContrast) private var c")]
                try expectTrue(A11yGuards.contrastGateViolations(present).isEmpty)
                // 缺文件本身即违规。
                try expectTrue(!A11yGuards.contrastGateViolations([]).isEmpty)
            },

            TestDesc(suite: "A11yAudit", name: "viewFileNamesListsEveryView") {
                let views = [("AlphaView.swift", "struct AlphaView: View { }"),
                             ("BetaView.swift", "struct BetaView: View { }")]
                try expectEqual(A11yGuards.viewFileNames(views), ["AlphaView.swift", "BetaView.swift"])
            },

            // 现有文件反证：ReadingChrome 同时含动画与 reduceMotion 门 → 过。
            TestDesc(suite: "A11yAudit", name: "readingChromeRealFilePassesMotionGate") {
                let dir = A11yGuardsTests_support.repoRoot.appendingPathComponent(
                    "Sources/LiteratureSearchApp/ReadingChrome.swift")
                let text = try String(contentsOf: dir, encoding: .utf8)
                try expectTrue(text.contains("withAnimation(") || text.contains(".animation("),
                               "precondition: ReadingChrome carries animations")
                try expectTrue(text.contains("reduceMotion"),
                               "precondition: ReadingChrome gates on reduceMotion")
                try expectTrue(A11yGuards.motionGateViolations([("ReadingChrome.swift", text)]).isEmpty,
                               "real file must pass the motion gate")
            },
        ]
    }
}

/// 路径支撑（DesignGuardSuite.repoRoot 为 internal，测试同 target 可用；
/// 经本包装避免套件间直接耦合命名）。
enum A11yGuardsTests_support {
    static var repoRoot: URL { DesignGuardSuite.repoRoot }
}
