import Foundation
@testable import LiteratureSearchUI

// MARK: - 阅读导航历史栈合成套件（ReadingHistoryStack）
//
// 纯 Foundation 去抖栈：同位置连续小跳不入栈（≤3 页 且 ≤30 秒）、超页距/
// 超时间距入栈、back/forward 对称互压、新导航清空 forward、非法页拒写。
// 时间全部显式注入（at:），测试确定可复现。

enum ReadingHistorySuite {
    static var tests: [TestDesc] {
        [
            TestDesc(suite: "ReadingHistory", name: "smallNearbyJumpsAreDebounced") {
                var stack = ReadingHistoryStack()
                let t0 = Date(timeIntervalSince1970: 1_000)
                stack.recordJump(from: 10, at: t0)
                try expectTrue(stack.canGoBack)
                try expectEqual(stack.back.count, 1)
                // 3 页内 + 30 秒内的连续小跳：不记新点。
                stack.recordJump(from: 12, at: t0.addingTimeInterval(5))
                stack.recordJump(from: 13, at: t0.addingTimeInterval(10))
                stack.recordJump(from: 9, at: t0.addingTimeInterval(15))
                try expectEqual(stack.back.count, 1, "≤3 页且 ≤30 秒的小幅移动不应产生新栈点")
            },
            TestDesc(suite: "ReadingHistory", name: "pageDistanceBeyondThresholdRecords") {
                var stack = ReadingHistoryStack()
                let t0 = Date(timeIntervalSince1970: 1_000)
                stack.recordJump(from: 10, at: t0)
                stack.recordJump(from: 14, at: t0.addingTimeInterval(5))
                try expectEqual(stack.back.count, 2, "超过 3 页（4 页差）应记新点")
                try expectEqual(stack.back.last?.page ?? 0, 14)
            },
            TestDesc(suite: "ReadingHistory", name: "timeBeyondThresholdRecords") {
                var stack = ReadingHistoryStack()
                let t0 = Date(timeIntervalSince1970: 1_000)
                stack.recordJump(from: 10, at: t0)
                // 同页但隔 31 秒：时间阈值超限，记新点。
                stack.recordJump(from: 11, at: t0.addingTimeInterval(31))
                try expectEqual(stack.back.count, 2, "超过 30 秒应记新点")
            },
            TestDesc(suite: "ReadingHistory", name: "invalidPageRejected") {
                var stack = ReadingHistoryStack()
                stack.recordJump(from: 0)
                stack.recordJump(from: -5)
                try expectFalse(stack.canGoBack, "非法页（<1）不得入栈")
            },
            TestDesc(suite: "ReadingHistory", name: "backForwardAreSymmetric") {
                var stack = ReadingHistoryStack()
                let t0 = Date(timeIntervalSince1970: 1_000)
                stack.recordJump(from: 10, at: t0)
                stack.recordJump(from: 50, at: t0.addingTimeInterval(40))
                // 位于 80：back 弹 50，80 入 forward；back 仍留 10（标准
                // 浏览器历史语义：可继续回跳到更早点）。
                let backTarget = try expectNotNil(stack.goBack(from: 80))
                try expectEqual(backTarget, 50)
                try expectTrue(stack.canGoBack, "回跳后仍可继续回跳到 10")
                try expectTrue(stack.canGoForward)
                try expectEqual(stack.forward.last?.page ?? 0, 80)
                // 前进：弹 80，当前 50 入 back。
                let fwdTarget = try expectNotNil(stack.goForward(from: 50))
                try expectEqual(fwdTarget, 80)
                try expectTrue(stack.canGoBack)
                try expectEqual(stack.back.last?.page ?? 0, 50)
            },
            TestDesc(suite: "ReadingHistory", name: "newJumpClearsForward") {
                var stack = ReadingHistoryStack()
                let t0 = Date(timeIntervalSince1970: 1_000)
                stack.recordJump(from: 10, at: t0)
                _ = stack.goBack(from: 30)
                try expectTrue(stack.canGoForward)
                // 回跳后的新导航分支：forward 作废；10 已被 goBack 弹出，
                // 60 成为唯一回跳点。
                stack.recordJump(from: 60, at: t0.addingTimeInterval(60))
                try expectFalse(stack.canGoForward, "新跳转应清空前进栈")
                try expectEqual(stack.back.count, 1)
            },
            TestDesc(suite: "ReadingHistory", name: "emptyStacksReturnNil") {
                var stack = ReadingHistoryStack()
                try expectNil(stack.goBack(from: 10), "空栈回跳返回 nil")
                try expectNil(stack.goForward(from: 10), "空栈前进返回 nil")
                try expectFalse(stack.canGoBack)
                try expectFalse(stack.canGoForward)
            },
            TestDesc(suite: "ReadingHistory", name: "debounceResumesFromNavigationLanding") {
                var stack = ReadingHistoryStack()
                let t0 = Date(timeIntervalSince1970: 1_000)
                stack.recordJump(from: 10, at: t0)
                stack.recordJump(from: 50, at: t0.addingTimeInterval(40))
                // 回跳落地于 50：以落地点为去抖基准，紧邻小跳（≤3 页 ≤30 秒）
                // 不记新点——back 只剩 10。
                _ = stack.goBack(from: 90)
                stack.recordJump(from: 52, at: t0.addingTimeInterval(5))
                try expectEqual(stack.back.count, 1,
                                "回跳落地点附近的小跳不应记新点（去抖基准已更新）")
            },
        ]
    }
}
