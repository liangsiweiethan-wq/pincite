import Foundation

// MARK: - 批注删除撤销窗口（纯值类型）
//
// 无 SwiftUI 依赖、无存储访问：窗口常量、deadline 换算、过期与顶替判定
// 全部是纯函数（固定参数注入 Date 可测）。存储侧（softDelete/restore）在
// HighlightStore+Aggregation（Core）；呈现与调度在 AppState/RootView。
//
// 语义写死：窗口 5 秒；同一时刻只存在一条 notice——新删除顶替旧 notice
// （旧软删保持墓碑态，不随之恢复）；窗口过期**不做二次硬删**（墓碑永久
// 保留是删除可传播的同步正确语义，AnnotationBundle 含墓碑导出为既有设计）。
// 5 秒窗口是本版自定规格，符合 iOS HIG 惯例。

public enum AnnotationUndo {
    /// 撤销窗口秒数（集中一处定义；UI 呈现与 AppState 到点清理共用）。
    public static let windowSeconds: TimeInterval = 5

    /// deadline 换算纯函数（issuedAt + window）。
    public static func deadline(from issuedAt: Date) -> Date {
        issuedAt.addingTimeInterval(windowSeconds)
    }

    /// 生成一条撤销 notice（AppState 收到删除请求时调用）。
    public static func makeNotice(highlightID: Int64, issuedAt: Date) -> AnnotationUndoNotice {
        AnnotationUndoNotice(highlightID: highlightID, issuedAt: issuedAt,
                             deadline: deadline(from: issuedAt))
    }
}

/// 一条待撤销的删除回执：软删行的 id + 窗口起止。Equatable 供「到点清理时
/// 校验仍是同一条」（新删除顶替后旧 task 不误清新 notice）。
public struct AnnotationUndoNotice: Equatable, Sendable {
    public let highlightID: Int64
    public let issuedAt: Date
    public let deadline: Date

    public init(highlightID: Int64, issuedAt: Date, deadline: Date) {
        self.highlightID = highlightID
        self.issuedAt = issuedAt
        self.deadline = deadline
    }

    /// 过期判定：恰在 deadline 即视为过期（窗口是半开的 [issuedAt, deadline)）。
    public func isExpired(at now: Date) -> Bool {
        now >= deadline
    }

    /// 顶替判定：任何 issuedAt 不早于自身的 notice 都将其顶替（同刻生成
    /// 亦视为顶替——后写者胜，避免同毫秒双 notice 并存）。
    public func isSuperseded(by newer: AnnotationUndoNotice) -> Bool {
        newer.issuedAt >= issuedAt
    }
}

// MARK: - 每日回顾区间换算（纯函数）

/// 每日回顾四档：昨日 / 近7日 / 近30日 / 自定义起止。区间一律闭开
/// `[from, to)`，按注入的 Calendar（含时区）取日界——测试注入固定时区
/// 即得稳定断言；App 层传 `Calendar.current`（本地日历日界）。
public enum DailyReviewRange {

    public enum Preset: Equatable {
        case yesterday
        case last7Days
        case last30Days
        /// 自定义起止（两个自然日；to 日全天含内）。
        case custom(startDay: Date, endDay: Date)
    }

    /// 档位 → 闭开区间。任何档位换算失败返回 nil（如实空态，不猜）。
    public static func range(for preset: Preset, now: Date, calendar: Calendar) -> (from: Date, to: Date)? {
        let todayStart = calendar.startOfDay(for: now)
        switch preset {
        case .yesterday:
            guard let dayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) else { return nil }
            return (dayStart, todayStart)
        case .last7Days:
            guard let dayStart = calendar.date(byAdding: .day, value: -6, to: todayStart) else { return nil }
            guard let end = calendar.date(byAdding: .day, value: 1, to: todayStart) else { return nil }
            return (dayStart, end)
        case .last30Days:
            guard let dayStart = calendar.date(byAdding: .day, value: -29, to: todayStart) else { return nil }
            guard let end = calendar.date(byAdding: .day, value: 1, to: todayStart) else { return nil }
            return (dayStart, end)
        case .custom(let startDay, let endDay):
            let from = calendar.startOfDay(for: startDay)
            guard let toExclusive = calendar.date(byAdding: .day, value: 1,
                                                  to: calendar.startOfDay(for: endDay)) else { return nil }
            guard from < toExclusive else { return nil }
            return (from, toExclusive)
        }
    }
}
