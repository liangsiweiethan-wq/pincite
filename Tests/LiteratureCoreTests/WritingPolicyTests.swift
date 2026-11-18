import Foundation
@testable import LiteratureCore

// MARK: -：读写约束矩阵（iPhone 只读 / iPad 可写）
//
// 约束单点断言固定：未来改约束必须先改这里（WritingPolicy 注释互引）。

enum WritingPolicySuite {
    static var tests: [TestDesc] {
        [
            TestDesc(suite: "WritingPolicy", name: "idiomMatrixPadWritablePhoneReadOnly") {
                // 约束矩阵：iPad 可写、iPhone（及其他 idiom）只读。
                try expectTrue(WritingPolicy.isWritable(idiomIsPad: true), "iPad 必须可写")
                try expectFalse(WritingPolicy.isWritable(idiomIsPad: false), "iPhone 必须只读")
            },

            TestDesc(suite: "WritingPolicy", name: "decisionNotePinsBoundaries") {
                // 约束记录防误删：双边界原文必须在位。
                let note = WritingPolicy.decisionNote
                try expectTrue(note.contains("iPhone 只读"), "iPhone 只读边界必须在位")
                try expectTrue(note.contains("原件 PDF 全平台只读"), "原件只读约束必须在位")
            },
        ]
    }
}
