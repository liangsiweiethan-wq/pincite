import Foundation
@testable import LiteratureSearchUI

//MARK: - 删除撤销窗口 + 每日回顾区间换算套件（纯函数层）
//
// 断言固定：isExpired 边界（恰 5s 过期、差 1ms 不过期）、顶替语义（新 notice
// 生成时旧 notice 立即判顶替，含同刻生成后写者胜）、deadline 换算、
// DailyReviewRange 四档日界（固定 TimeZone 注入下稳定）与自定义档校验。

enum AnnotationUndoSuite {

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "AnnotationUndo", name: "isExpiredBoundaryAtExactlyFiveSeconds") {
                let issued = Date(timeIntervalSince1970: 1_000)
                let notice = AnnotationUndo.makeNotice(highlightID: 7, issuedAt: issued)
                try expectFalse(notice.isExpired(at: issued.addingTimeInterval(4.999)))
                try expectFalse(notice.isExpired(at: issued.addingTimeInterval(5) - 0.001),
                                "差 1ms 不过期")
                try expectTrue(notice.isExpired(at: issued.addingTimeInterval(5)),
                               "恰 5s 即过期（窗口半开 [issuedAt, deadline)）")
                try expectTrue(notice.isExpired(at: issued.addingTimeInterval(5.001)))
            },

            TestDesc(suite: "AnnotationUndo", name: "deadlineConversionIsPureAddition") {
                let issued = Date(timeIntervalSince1970: 500)
                try expectEqual(AnnotationUndo.deadline(from: issued),
                                issued.addingTimeInterval(5))
                let notice = AnnotationUndo.makeNotice(highlightID: 1, issuedAt: issued)
                try expectEqual(notice.deadline, issued.addingTimeInterval(5))
                try expectEqual(AnnotationUndo.windowSeconds, 5,
                                "窗口常量集中一处定义（写死 5 秒）")
                try expectEqual(notice.highlightID, Int64(1))
            },

            TestDesc(suite: "AnnotationUndo", name: "newerNoticeSupersedesOldImmediately") {
                let t0 = Date(timeIntervalSince1970: 1_000)
                let old = AnnotationUndo.makeNotice(highlightID: 1, issuedAt: t0)
                // 新删除在旧窗口期内到达（issuedAt+2s 早于 deadline）。
                let newer = AnnotationUndo.makeNotice(highlightID: 2,
                                                      issuedAt: t0.addingTimeInterval(2))
                try expectFalse(old.isExpired(at: newer.issuedAt),
                                "旧 notice 在被顶替时刻尚未自然过期")
                try expectTrue(old.isSuperseded(by: newer),
                               "新 notice 生成时旧 notice 立即判顶替（旧软删保持墓碑态）")
                try expectFalse(newer.isSuperseded(by: old), "顶替是单向的")
                // 同刻生成：后写者胜（避免同毫秒双 notice 并存）。
                let twin = AnnotationUndo.makeNotice(highlightID: 3, issuedAt: newer.issuedAt)
                try expectTrue(newer.isSuperseded(by: twin))
                try expectTrue(twin.isSuperseded(by: newer),
                               "同刻互相顶替 = 后写者胜，语义由 AppState 单变量赋值保证")
            },

            TestDesc(suite: "AnnotationUndo", name: "reviewRangeYesterdayUsesLocalDayBounds") {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "UTC")!
                // now = 12:00 UTC → 昨日 = [09-29 00:00, 09-30 00:00)。
                let now = Date(timeIntervalSince1970: 1_791_768_000) // 00:00Z
                let range = try expectNotNil(
                    DailyReviewRange.range(for: .yesterday, now: now, calendar: calendar))
                try expectEqual(calendar.startOfDay(for: range.from), range.from)
                try expectEqual(calendar.dateComponents([.day], from: range.from, to: range.to).day, 1)
                let yesterdayStart = calendar.date(byAdding: .day, value: -1,
                                                   to: calendar.startOfDay(for: now))!
                try expectEqual(range.from, yesterdayStart)
                try expectEqual(range.to, calendar.startOfDay(for: now))
            },

            TestDesc(suite: "AnnotationUndo", name: "reviewRangeLast7AndLast30IncludeToday") {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "UTC")!
                let now = Date(timeIntervalSince1970: 1_791_768_000)
                let todayStart = calendar.startOfDay(for: now)
                let r7 = try expectNotNil(
                    DailyReviewRange.range(for: .last7Days, now: now, calendar: calendar))
                let expected7Start = calendar.date(byAdding: .day, value: -6, to: todayStart)!
                try expectEqual(r7.from, expected7Start, "近7日含今天共 7 个自然日")
                try expectEqual(r7.to, calendar.date(byAdding: .day, value: 1, to: todayStart)!)
                let r30 = try expectNotNil(
                    DailyReviewRange.range(for: .last30Days, now: now, calendar: calendar))
                let expected30Start = calendar.date(byAdding: .day, value: -29, to: todayStart)!
                try expectEqual(r30.from, expected30Start, "近30日含今天共 30 个自然日")
                try expectEqual(r30.to, calendar.date(byAdding: .day, value: 1, to: todayStart)!)
            },

            TestDesc(suite: "AnnotationUndo", name: "reviewRangeCustomValidatesAndCoversEndDay") {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "UTC")!
                let start = Date(timeIntervalSince1970: 1_790_937_600) // 00:00Z
                let end = Date(timeIntervalSince1970: 1_791_715_200)   // 00:00Z
                let range = try expectNotNil(
                    DailyReviewRange.range(for: .custom(startDay: start, endDay: end),
                                           now: end, calendar: calendar))
                try expectEqual(range.from, calendar.startOfDay(for: start))
                // to = end 次日 0 点（end 日全天含内，闭开区间）。
                try expectEqual(range.to,
                                calendar.date(byAdding: .day, value: 1,
                                              to: calendar.startOfDay(for: end))!)
                // 非法区间（start 晚于 end）→ nil，如实不猜。
                let invalid = DailyReviewRange.range(
                    for: .custom(startDay: end, endDay: start), now: end, calendar: calendar)
                try expectNil(invalid)
            },
        ]
    }
}
