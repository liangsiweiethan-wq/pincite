import Foundation
@testable import LiteratureCore

// MARK: - 空闲计时器单元测试（不依赖真 socket）

enum LocalAPIIdleTimerSuite {
    /// 线程安全计数器（fire 回调在注入队列，计数读写在测试线程）。
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// 轮询等待条件成立（超时返回 false，不挂死 runner）。
    @discardableResult
    static func waitUntil(seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    static func makeTimer(interval: TimeInterval, counter: Counter) -> LocalAPIIdleTimer {
        LocalAPIIdleTimer(interval: interval,
                          queue: DispatchQueue(label: "lit-idle-timer-test-\(UUID().uuidString)"),
                          onFire: { counter.bump() })
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "LocalAPIIdleTimer", name: "firesOnceAfterInterval") {
                let counter = Counter()
                let timer = makeTimer(interval: 0.1, counter: counter)
                timer.reset()
                let wait = perfLimit(2, relaxed: 6, "idle timer wait")
                try expectTrue(waitUntil(seconds: wait) { counter.value >= 1 },
                               "interval 到点必须 fire（\(wait)s 内）")
                Thread.sleep(forTimeInterval: 0.2)
                try expectEqual(counter.value, 1, "一次性语义：不重复 fire")
                timer.cancel()
            },
            TestDesc(suite: "LocalAPIIdleTimer", name: "resetPostponesFire") {
                let counter = Counter()
                let timer = makeTimer(interval: 0.1, counter: counter)
                // t=0 reset；t=60/120/180ms 再 reset——无推迟早在 t≈100ms fire。
                timer.reset()
                Thread.sleep(forTimeInterval: 0.06)
                timer.reset()
                Thread.sleep(forTimeInterval: 0.06)
                timer.reset()
                Thread.sleep(forTimeInterval: 0.06)
                try expectEqual(counter.value, 0,
                                "连续 reset 必须推迟 fire（t≈180ms 仍不得 fire）")
                let wait = perfLimit(2, relaxed: 6, "idle timer wait")
                try expectTrue(waitUntil(seconds: wait) { counter.value >= 1 },
                               "最后一次 reset 起 interval 到点应 fire")
                timer.cancel()
            },
            TestDesc(suite: "LocalAPIIdleTimer", name: "cancelStopsFire") {
                let counter = Counter()
                let timer = makeTimer(interval: 0.1, counter: counter)
                timer.reset()
                timer.cancel()
                Thread.sleep(forTimeInterval: 0.35)
                try expectEqual(counter.value, 0, "cancel 后不得 fire")
                // 未武装 cancel 无害（幂等）。
                timer.cancel()
                try expectEqual(counter.value, 0)
            },
        ]
    }
}
