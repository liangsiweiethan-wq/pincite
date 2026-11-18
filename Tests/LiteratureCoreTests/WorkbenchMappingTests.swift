import Foundation
@testable import LiteratureCore

// MARK: -：WorkbenchMapping 换算纯函数套件
//
// 契约：等页数恒等；比例换算（10/20 页→第 5→第 10）；clamp
// 上/下界；1 页书；0/负输入拒绝；sourcePage 超界；换算纯度（同输入同输出、
// 无隐藏状态）。sessions 表 workbench 行 round-trip 不重复。

enum WorkbenchMappingSuite {
    static var tests: [TestDesc] {
        [
            TestDesc(suite: "WorkbenchMapping", name: "equalPageCountIsIdentity") {
                try expectEqual(WorkbenchMapping.linkedPage(for: 5, sourceCount: 10, targetCount: 10), 5)
                try expectEqual(WorkbenchMapping.linkedPage(for: 1, sourceCount: 30, targetCount: 30), 1)
                try expectEqual(WorkbenchMapping.linkedPage(for: 30, sourceCount: 30, targetCount: 30), 30)
            },

            TestDesc(suite: "WorkbenchMapping", name: "ratioMappingTaskSheetExample") {
                try expectEqual(WorkbenchMapping.linkedPage(for: 5, sourceCount: 10, targetCount: 20), 10)
                try expectEqual(WorkbenchMapping.linkedPage(for: 1, sourceCount: 10, targetCount: 20), 2)
                try expectEqual(WorkbenchMapping.linkedPage(for: 10, sourceCount: 10, targetCount: 20), 20)
            },

            TestDesc(suite: "WorkbenchMapping", name: "roundingSemanticsPinned") {
                // 3 * 10 / 20 = 1.5 → 2（四舍五入）。
                try expectEqual(WorkbenchMapping.linkedPage(for: 3, sourceCount: 20, targetCount: 10), 2)
                // 5 * 10 / 20 = 2.5 → 3（.rounded 银行家舍入回避—— rounds half away from zero）。
                try expectEqual(WorkbenchMapping.linkedPage(for: 5, sourceCount: 20, targetCount: 10), 3)
            },

            TestDesc(suite: "WorkbenchMapping", name: "clampsToBounds") {
                try expectEqual(WorkbenchMapping.linkedPage(for: 12, sourceCount: 10, targetCount: 5), 5)
                try expectEqual(WorkbenchMapping.linkedPage(for: 1, sourceCount: 10, targetCount: 3), 1)
            },

            TestDesc(suite: "WorkbenchMapping", name: "singlePageBooksAlwaysOne") {
                try expectEqual(WorkbenchMapping.linkedPage(for: 1, sourceCount: 1, targetCount: 1), 1)
                try expectEqual(WorkbenchMapping.linkedPage(for: 1, sourceCount: 100, targetCount: 1), 1)
                try expectEqual(WorkbenchMapping.linkedPage(for: 50, sourceCount: 100, targetCount: 1), 1)
            },

            TestDesc(suite: "WorkbenchMapping", name: "invalidInputsCollapseToOne") {
                try expectEqual(WorkbenchMapping.linkedPage(for: 0, sourceCount: 10, targetCount: 10), 1)
                try expectEqual(WorkbenchMapping.linkedPage(for: -2, sourceCount: 10, targetCount: 10), 1)
                try expectEqual(WorkbenchMapping.linkedPage(for: 5, sourceCount: 0, targetCount: 10), 1)
                try expectEqual(WorkbenchMapping.linkedPage(for: 5, sourceCount: 10, targetCount: 0), 1)
                try expectEqual(WorkbenchMapping.linkedPage(for: 5, sourceCount: -10, targetCount: 10), 1)
            },

            TestDesc(suite: "WorkbenchMapping", name: "mappingIsPure") {
                for page in [1, 4, 7, 13] {
                    let a = WorkbenchMapping.linkedPage(for: page, sourceCount: 17, targetCount: 23)
                    let b = WorkbenchMapping.linkedPage(for: page, sourceCount: 17, targetCount: 23)
                    try expectEqual(a, b)
                    try expectTrue(a >= 1 && a <= 23)
                }
            },

            TestDesc(suite: "WorkbenchMapping", name: "monotonicAcrossLargeBooks") {
                var last = 0
                for page in stride(from: 1, through: 600, by: 37) {
                    let mapped = WorkbenchMapping.linkedPage(for: page, sourceCount: 600, targetCount: 450)
                    try expectTrue(mapped >= last, "换算随 sourcePage 单调不减")
                    try expectTrue(mapped >= 1 && mapped <= 450)
                    last = mapped
                }
            },
        ]
    }
}
