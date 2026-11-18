import Foundation

/// 阅读导航历史（Sioyek 经验）：详情栏内维护回跳/前进栈。纯 Foundation、
/// 无 SwiftUI——供 app 层与合成测试共用（测试 runner 只链接 Core + UI）。

public struct ReadingHistoryEntry: Equatable {
    /// 物理页（1 起）。
    public let page: Int
    /// 入栈时刻（去抖时间阈值的比较基准）。
    public let date: Date

    public init(page: Int, date: Date) {
        self.page = page
        self.date = date
    }
}

public struct ReadingHistoryStack: Equatable {
    /// 回跳栈（栈顶 = 最近一次记录点）。
    public private(set) var back: [ReadingHistoryEntry]
    /// 前进栈（goBack 之后可用；新跳转即清空）。
    public private(set) var forward: [ReadingHistoryEntry]
    /// 去抖阈值：距上次入栈点超过 pageThreshold 页才记新点。
    public var pageThreshold: Int
    /// 去抖阈值：距上次入栈点超过 timeThreshold 秒才记新点。
    public var timeThreshold: TimeInterval
    /// 上次入栈点（去抖基准；goBack/goForward 落地后同步更新）。
    private var lastRecorded: ReadingHistoryEntry?

    public init(pageThreshold: Int = 3, timeThreshold: TimeInterval = 30) {
        self.back = []
        self.forward = []
        self.pageThreshold = pageThreshold
        self.timeThreshold = timeThreshold
        self.lastRecorded = nil
    }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// 程序化跳页前的统一入栈口。去抖不通过则什么都不做（forward 也不清，
    /// 只有真正的新导航点才作废前进栈）。非法页（< 1）fail-closed 忽略。
    public mutating func recordJump(from page: Int, at date: Date = Date()) {
        guard page >= 1 else { return }
        if let last = lastRecorded,
           abs(page - last.page) <= pageThreshold,
           date.timeIntervalSince(last.date) <= timeThreshold {
            return
        }
        back.append(ReadingHistoryEntry(page: page, date: date))
        lastRecorded = back.last
        forward.removeAll()
    }

    /// 回跳：弹出最近记录点，当前页压入前进栈。栈空返回 nil（按钮禁用态
    @discardableResult
    public mutating func goBack(from current: Int, at date: Date = Date()) -> Int? {
        guard let entry = back.popLast() else { return nil }
        if current >= 1 {
            forward.append(ReadingHistoryEntry(page: current, date: date))
        }
        lastRecorded = entry
        return entry.page
    }

    /// 前进：goBack 的对称逆操作。
    @discardableResult
    public mutating func goForward(from current: Int, at date: Date = Date()) -> Int? {
        guard let entry = forward.popLast() else { return nil }
        if current >= 1 {
            back.append(ReadingHistoryEntry(page: current, date: date))
        }
        lastRecorded = entry
        return entry.page
    }
}
