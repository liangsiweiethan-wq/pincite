import Foundation
@testable import LiteratureSearchUI

// MARK: -：角标字母分配 + armed 状态机套件
//
// 契约：labels(count:) 边界（1/25/26/27/52/53/60）；0 候选
// 空数组；分配序＝输入序稳定对应；FollowState 状态机全迁移路径（f 进/字母
// 消耗/ESC 出/模式互斥/armed 中按 m 忽略并保持——互斥语义进入即清）。

enum FollowBadgeSuite {
    static var tests: [TestDesc] {
        [
            TestDesc(suite: "FollowBadge", name: "labelsSingleLetterSegment") {
            try expectEqual(FollowBadgeLabels.labels(count: 1), ["a"])
            try expectEqual(FollowBadgeLabels.labels(count: 25).last, "y")
            try expectEqual(FollowBadgeLabels.labels(count: 26),
                            "abcdefghijklmnopqrstuvwxyz".map(String.init))
        },

        TestDesc(suite: "FollowBadge", name: "labelsDoubleLetterContractPinned") {
            try expectEqual(FollowBadgeLabels.labels(count: 0), [])
            let l27 = FollowBadgeLabels.labels(count: 27)
            try expectEqual(l27.count, 27)
            try expectEqual(l27[26], "aa")
            try expectEqual(FollowBadgeLabels.labels(count: 52)[51], "az")
            try expectEqual(FollowBadgeLabels.labels(count: 53)[52], "ba")
            try expectEqual(FollowBadgeLabels.labels(count: 60)[59], "bh",
                            "第 60 = bh（n=33：首字母 b、次字母 h）")
        },

        TestDesc(suite: "FollowBadge", name: "labelsStableAndBounded") {
            let first = FollowBadgeLabels.labels(count: 702)
            let second = FollowBadgeLabels.labels(count: 702)
            try expectEqual(first, second, "同输入同输出（纯）")
            try expectEqual(first[701], "zz", "双字母段末位")
            try expectEqual(FollowBadgeLabels.labels(count: 703)[702], "aa",
                            "超出 702 模 676 循环（边界如实注明）")
        },

        TestDesc(suite: "FollowBadge", name: "stateFollowCycle") {
            var state = FollowState()
            try expectFalse(state.isArmed)
            try expectNil(state.armedMode)
            state.arm(.follow)
            try expectTrue(state.isArmed)
            try expectEqual(state.armedMode, .follow)
            let consumed = try expectNotNil(state.consume())
            try expectEqual(consumed, .follow)
            try expectFalse(state.isArmed)
        },

        TestDesc(suite: "FollowBadge", name: "stateMarkModesCycle") {
            var state = FollowState()
            state.arm(.markSet)
            try expectEqual(state.armedMode, .markSet)
            try expectEqual(try expectNotNil(state.consume()), .markSet)
            state.arm(.markJump)
            try expectEqual(state.armedMode, .markJump)
            try expectEqual(try expectNotNil(state.consume()), .markJump)
            // 无 armed 时 consume 返回 nil（零副作用）。
            try expectNil(state.consume())
        },

        TestDesc(suite: "FollowBadge", name: "modesAreMutuallyExclusive") {
            var state = FollowState()
            state.arm(.markSet)
            state.arm(.follow)
            try expectEqual(state.armedMode, .follow, "进入 follow 清 markSet")
            state.arm(.markJump)
            try expectEqual(state.armedMode, .markJump, "进入 markJump 清 follow")
            // follow 轮换游标在进入/重进时归零。
            state = FollowState()
            state.arm(.follow)
            state.advanceRotation(candidateCount: 5)
            state.arm(.follow)
            try expectEqual(state.rotationIndex, 0, "重进归零（幂等）")
        },

        TestDesc(suite: "FollowBadge", name: "cancelReturnsToIdle") {
            var state = FollowState()
            state.arm(.follow)
            state.advanceRotation(candidateCount: 5)
            state.advanceRotation(candidateCount: 5)
            state.cancel()
            try expectFalse(state.isArmed)
            try expectEqual(state.rotationIndex, 0)
            state.arm(.markSet)
            state.cancel()
            try expectFalse(state.isArmed)
        },

        TestDesc(suite: "FollowBadge", name: "rotationCyclesAndGuards") {
            var state = FollowState()
            state.arm(.follow)
            try expectEqual(try expectNotNil(state.advanceRotation(candidateCount: 3)), 1)
            try expectEqual(try expectNotNil(state.advanceRotation(candidateCount: 3)), 2)
            try expectEqual(try expectNotNil(state.advanceRotation(candidateCount: 3)), 0, "循环回绕")
            try expectEqual(try expectNotNil(state.retreatRotation(candidateCount: 3)), 2)
            try expectEqual(try expectNotNil(state.retreatRotation(candidateCount: 3)), 1)
            // 单候选轮换恒 0。
            state.cancel(); state.arm(.follow)
            try expectEqual(try expectNotNil(state.advanceRotation(candidateCount: 1)), 0)
            // 空候选/非 armed 零变化。
            try expectNil(state.advanceRotation(candidateCount: 0))
            state.cancel()
            try expectNil(state.advanceRotation(candidateCount: 5))
            try expectNil(state.retreatRotation(candidateCount: 5))
        },
        ]
    }
}
