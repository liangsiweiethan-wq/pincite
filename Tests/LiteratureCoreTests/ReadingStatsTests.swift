import Foundation
@testable import LiteratureCore
import LiteratureSearchUI


enum ReadingStatsSuite {
    static func makeBook(_ id: String, title: String?, author: String?) -> IndexStore.BookRow {
        return IndexStore.BookRow(
            id: id, realPath: "/tmp/lit-tests/\(id).pdf", rootPath: "/tmp/lit-tests",
            relPath: "\(id).pdf", fileName: "\(id).pdf",
            title: title, author: author,
            firstFingerprint: "fp-\(id)", fingerprint: "fp-\(id)", fileSize: 1, mtime: 0,
            pageCount: 10, status: "ok", indexedAt: 0)
    }

    /// 固定时区（东八区）——跨日测试断言固定可复现。
    static let fixedZone = TimeZone(identifier: "Asia/Shanghai")!

    static var tests: [TestDesc] {
        [
            // ── accumulate：纯函数差分计时 ──
            TestDesc(suite: "ReadingStats", name: "accumulateFirstEventIsStartPointOnly") {
                let credit = ReadingStatsStore.accumulate(previous: nil, now: 1_000, capMinutes: 5)
                try expectEqual(credit, 0)
            },
            TestDesc(suite: "ReadingStats", name: "accumulateWithinCapCreditsMinutes") {
                let credit = ReadingStatsStore.accumulate(previous: 1_000, now: 1_000 + 180,
                                                          capMinutes: 5)
                try expectEqual(credit, 3.0)
            },
            TestDesc(suite: "ReadingStats", name: "accumulateBeyondCapTruncates") {
                let credit = ReadingStatsStore.accumulate(previous: 1_000, now: 1_000 + 600,
                                                          capMinutes: 5)
                try expectEqual(credit, 0)
                // 时钟回拨同样截断。
                let backwards = ReadingStatsStore.accumulate(previous: 2_000, now: 1_000,
                                                             capMinutes: 5)
                try expectEqual(backwards, 0)
            },
            TestDesc(suite: "ReadingStats", name: "dayKeyIsLocalYYYYMMDD") {
                // 2026-01-01T08:00:00Z 即 UTC+8 当日 16:00，dayKey 应为本地日期。
                let date = Date(timeIntervalSince1970: 1_767_254_400)
                try expectEqual(ReadingStatsStore.dayKey(for: date, timeZone: fixedZone),
                                "2026-01-01")
            },

            // ── 写路径：事件 → 行（跨日两行）──
            TestDesc(suite: "ReadingStats", name: "twoEventsOnTwoDaysProduceTwoRows") {
                let dir = Fixtures.makeTempDir("stats-crossday")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let stats = ReadingStatsStore(indexStore: store, timeZone: fixedZone)
                // day A （东八区 07:20）：首事件＝锚点不落行
                // 纯锚点事件 ＋ 3 分钟后翻页（+3 分钟）。
                let dayA = Date(timeIntervalSince1970: 1_767_223_200) // 20:00Z = 20+08
                let base = ReadingStatsStore.dayKey(for: dayA, timeZone: fixedZone)
                try stats.recordActiveEvent(bookID: "b1", now: dayA.timeIntervalSince1970)
                try stats.recordPageTurn(bookID: "b1", page: 2,
                                         now: dayA.timeIntervalSince1970 + 180)
                let rowsA = try stats.stats(day: base)
                try expectEqual(rowsA.count, 1)
                try expectEqual(rowsA.first?.minutes ?? -1, 3.0)
                try expectEqual(rowsA.first?.pages ?? -1, 1)
                // day B：纯锚点事件不落行（无 0/0 假行，空态保持），
                // 随后翻页才建立当日行。
                let dayB = Date(timeIntervalSince1970: dayA.timeIntervalSince1970 + 86_400)
                let baseB = ReadingStatsStore.dayKey(for: dayB, timeZone: fixedZone)
                try expectNotEqual(baseB, base)
                try stats.recordActiveEvent(bookID: "b1", now: dayB.timeIntervalSince1970)
                let rowsB = try stats.stats(day: baseB)
                try expectEqual(rowsB.count, 0)
                try expectTrue(try stats.dailyTotals(day: baseB) == nil,
                               "纯锚点日 dailyTotals 应为 nil（空态契约）")
                try stats.recordPageTurn(bookID: "b1", page: 5,
                                         now: dayB.timeIntervalSince1970 + 120)
                let rowsB2 = try stats.stats(day: baseB)
                try expectEqual(rowsB2.count, 1)
                try expectEqual(rowsB2.first?.pages ?? -1, 1)
                // 两天各一行：day 键格式 YYYY-MM-DD。
                try expectTrue(base.hasPrefix("2026-01-01"), "day key format: \(base)")
                try expectTrue(baseB.hasPrefix("2026-01-02"), "day key format: \(baseB)")
            },
            TestDesc(suite: "ReadingStats", name: "pageTurnWithinCapCreditsAndCounts") {
                let dir = Fixtures.makeTempDir("stats-pageturn")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let stats = ReadingStatsStore(indexStore: store, timeZone: fixedZone)
                let t0 = 1_767_223_200.0
                try stats.recordPageTurn(bookID: "b1", page: 1, now: t0)
                try stats.recordPageTurn(bookID: "b1", page: 2, now: t0 + 120) // 2 分钟
                try stats.recordPageTurn(bookID: "b1", page: 3, now: t0 + 240) // 2 分钟
                let day = ReadingStatsStore.dayKey(for: Date(timeIntervalSince1970: t0),
                                                   timeZone: fixedZone)
                let rows = try stats.stats(day: day)
                try expectEqual(rows.count, 1)
                try expectEqual(rows.first?.minutes ?? -1, 4.0)
                try expectEqual(rows.first?.pages ?? -1, 3)
            },
            // ── 纯锚点事件不落 0/0 假行（每日卡空态契约）──
            TestDesc(suite: "ReadingStats", name: "anchorOnlyEventsKeepDailyTotalsNil") {
                let dir = Fixtures.makeTempDir("stats-anchor-empty")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let stats = ReadingStatsStore(indexStore: store, timeZone: fixedZone)
                let t0 = 1_767_223_200.0
                let day = ReadingStatsStore.dayKey(for: Date(timeIntervalSince1970: t0),
                                                   timeZone: fixedZone)
                // 首个纯锚点事件（开视图首喂）：不落行——每日卡空态保持。
                try stats.recordActiveEvent(bookID: "b1", now: t0)
                try expectEqual(try stats.stats(day: day).count, 0)
                try expectTrue(try stats.dailyTotals(day: day) == nil,
                               "首锚点后 dailyTotals 应为 nil（不造数）")
                // 超限截断的纯锚点事件（间隔 > cap）：同样不落行。
                try stats.recordActiveEvent(bookID: "b1", now: t0 + 600)
                try expectEqual(try stats.stats(day: day).count, 0)
                try expectTrue(try stats.dailyTotals(day: day) == nil)
                // 随后真实翻页：行出现，分钟/页如实（足迹照记）。
                try stats.recordPageTurn(bookID: "b1", page: 3, now: t0 + 660)
                let rows = try stats.stats(day: day)
                try expectEqual(rows.count, 1)
                try expectEqual(rows.first?.minutes ?? -1, 1.0)
                try expectEqual(rows.first?.pages ?? -1, 1)
                try expectEqual(try stats.footprints(bookID: "b1").count, 1)
            },
            TestDesc(suite: "ReadingStats", name: "anchorEventWithinCapStillAccumulates") {
                let dir = Fixtures.makeTempDir("stats-anchor-credit")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let stats = ReadingStatsStore(indexStore: store, timeZone: fixedZone)
                let t0 = 1_767_223_200.0
                let day = ReadingStatsStore.dayKey(for: Date(timeIntervalSince1970: t0),
                                                   timeZone: fixedZone)
                // 首翻页建行（0 分钟 1 页）＋ cap 内纯锚点事件 → 分钟照常入账
                //（防修复过度抑制：有 credit 的锚点事件仍 UPDATE 叠加）。
                try stats.recordPageTurn(bookID: "b1", page: 1, now: t0)
                try stats.recordActiveEvent(bookID: "b1", now: t0 + 120)
                let rows = try stats.stats(day: day)
                try expectEqual(rows.count, 1)
                try expectEqual(rows.first?.minutes ?? -1, 2.0)
                try expectEqual(rows.first?.pages ?? -1, 1)
            },

            // ── footprint：upsert 幂等、read_count 叠加 ──
            TestDesc(suite: "ReadingStats", name: "footprintSamePageUpsertsSingleRow") {
                let dir = Fixtures.makeTempDir("stats-footprint")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let stats = ReadingStatsStore(indexStore: store)
                try stats.recordFootprint(bookID: "b1", page: 7, now: 100)
                try stats.recordFootprint(bookID: "b1", page: 7, now: 200)
                let rows = try stats.footprints(bookID: "b1")
                try expectEqual(rows.count, 1)
                try expectEqual(rows.first?.readCount ?? -1, 2)
                try expectEqual(rows.first?.lastReadAt ?? -1, 200)
            },
            TestDesc(suite: "ReadingStats", name: "footprintDifferentPagesEachRow") {
                let dir = Fixtures.makeTempDir("stats-footprint2")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let stats = ReadingStatsStore(indexStore: store)
                for page in [1, 2, 5, 9] {
                    try stats.recordFootprint(bookID: "b1", page: page, now: 100)
                }
                let rows = try stats.footprints(bookID: "b1")
                try expectEqual(rows.map(\.pageNumber), [1, 2, 5, 9])
                // 换书互不影响。
                try stats.recordFootprint(bookID: "b2", page: 1, now: 100)
                try expectEqual(try stats.footprints(bookID: "b1").count, 4)
                try expectEqual(try stats.footprints(bookID: "b2").count, 1)
            },

            TestDesc(suite: "ReadingStats", name: "migrationV8ToV9PreservesData") {
                let dir = Fixtures.makeTempDir("stats-migrate")
                defer { Fixtures.cleanup(dir) }
                // 按现行版本开库（迁移链幂等到最新），写 favorites/书/高亮后重开。
                let store = try Fixtures.openStore(in: dir)
                let favorites = FavoritesStore(indexStore: store)
                _ = try favorites.add(.search(query: "旧检索"))
                try store.upsertBook(makeBook("b1", title: "旧书", author: nil))
                let highlights = HighlightStore(indexStore: store)
                _ = try highlights.add(bookID: "b1", pageNumber: 3, utf16Start: 0, utf16End: 5,
                                       color: .yellow, note: "")
                let reopened = try Fixtures.openStore(in: dir)
                let tables = try reopened.db.prepare(
                    "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('reading_sessions','page_footprints') ORDER BY name;")
                var names: [String] = []
                while try tables.step() { names.append(tables.text(0)) }
                try expectEqual(names, ["page_footprints", "reading_sessions"])
                let ver = try reopened.db.prepare("SELECT value FROM meta WHERE key='index_schema_version';")
                _ = try ver.step()
                try expectEqual(ver.text(0), String(IndexStore.currentSchemaVersion))
                let favs = try FavoritesStore(indexStore: reopened).all()
                try expectEqual(favs.count, 1)
                try expectEqual(favs[0].target, FavoriteTarget.search(query: "旧检索"))
                let book = try reopened.book(byID: "b1")
                try expectEqual(book?.title, "旧书")
                let highlightRows = try HighlightStore(indexStore: reopened)
                    .highlightsForBook("b1")
                try expectEqual(highlightRows.count, 1)
            },

            // ── 只读副本：record* 零行零错（iOS 只读副本打开时统计静默跳过）──
            TestDesc(suite: "ReadingStats", name: "readOnlyReplicaWritesAreNoOp") {
                let dir = Fixtures.makeTempDir("stats-readonly")
                defer { Fixtures.cleanup(dir) }
                let rw = try Fixtures.openStore(in: dir)
                try rw.upsertBook(makeBook("b1", title: "旧书", author: nil))
                let replica = try Fixtures.openStore(in: dir,
                                                     options: .init(readOnlyReplica: true))
                let stats = ReadingStatsStore(indexStore: replica, timeZone: fixedZone)
                // 只读句柄上一切写 no-op：不抛错、零行。
                try stats.recordPageTurn(bookID: "b1", page: 1, now: 1_000)
                try stats.recordActiveEvent(bookID: "b1", now: 1_100)
                try stats.recordFootprint(bookID: "b1", page: 1, now: 1_200)
                let day = ReadingStatsStore.dayKey(for: Date(timeIntervalSince1970: 1_000),
                                                   timeZone: fixedZone)
                try expectEqual(try stats.stats(day: day).count, 0)
                try expectEqual(try stats.footprints(bookID: "b1").count, 0)
            },

            // ── 每日卡文案合成 ──
            TestDesc(suite: "ReadingStats", name: "composeCardContainsSentenceCitationStats") {
                let quote = Quote(bookID: "b1", fileName: "a.pdf", pageNumber: 33,
                                  sentence: "法是可以由国家强制力保障实施的行为规范。")
                // 7.5 分钟走 <10 一位小数路径（取整路径在 minutesText 专测）。
                let text = DailyCardComposer.composeDailyCardText(
                    quote: quote, citation: "《a.pdf》，第 33 页",
                    stats: ReadingStatsStore.DailyTotals(minutes: 7.5, pages: 8))
                try expectTrue(text.contains("法是可以由国家强制力保障实施的行为规范。"))
                try expectTrue(text.contains("出处："))
                try expectTrue(text.contains("今日阅读："))
                try expectTrue(text.contains("7.5 分钟"))
                try expectTrue(text.contains("翻页 8 次"))
            },
            TestDesc(suite: "ReadingStats", name: "composeCardWithoutStatsOmitsStatsLine") {
                let quote = Quote(bookID: "b1", fileName: "a.pdf", pageNumber: 33,
                                  sentence: "无统计日的整卡文案不含统计行。")
                let text = DailyCardComposer.composeDailyCardText(
                    quote: quote, citation: nil, stats: nil)
                try expectFalse(text.contains("今日阅读"))
                try expectFalse(text.contains("出处："))
                try expectTrue(text.hasPrefix("无统计日的整卡文案不含统计行。"))
                // 空句返回空串（调用方禁用朗读入口）。
                let empty = DailyCardComposer.composeDailyCardText(
                    quote: Quote(bookID: "b", fileName: "f", pageNumber: 1, sentence: "  "),
                    citation: nil, stats: nil)
                try expectEqual(empty, "")
            },
            TestDesc(suite: "ReadingStats", name: "minutesTextFormatsHonestNumbers") {
                try expectEqual(DailyCardComposer.minutesText(3.0), "3 分钟")
                try expectEqual(DailyCardComposer.minutesText(3.5), "3.5 分钟")
                try expectEqual(DailyCardComposer.minutesText(12.5), "13 分钟")
            },
            TestDesc(suite: "ReadingStats", name: "l10nDailyStatsLineParityWithCoreMinutesText") {
                // iOS 单模块直编形态下 L10n 与 Core 各写一份同规格式化——
                // 此测试锁两端基准不漂移（新样本两端同规即过）。
                for minutes in [0.0, 0.75, 3.0, 3.5, 9.5, 9.99, 10.0, 12.5, 100.0] {
                    let uiLine = L10n.dailyStatsLine(minutes: minutes, pages: 7)
                    let expected = "\(DailyCardComposer.minutesText(minutes)) · 翻页 7 次"
                    try expectEqual(uiLine, expected, "minutes=\(minutes)")
                }
            },

            //── ：高亮色记忆（Core 纯函数，非法值回退黄）──
            TestDesc(suite: "ReadingStats", name: "highlightColorRawValueRoundTrip") {
                for color in HighlightColor.allCases {
                    try expectEqual(HighlightColor.memorized(color.rawValue), color)
                }
            },
            TestDesc(suite: "ReadingStats", name: "highlightColorIllegalValueFallsBackToYellow") {
                try expectEqual(HighlightColor.memorized("purple"), .yellow)
                try expectEqual(HighlightColor.memorized(""), .yellow)
                try expectEqual(HighlightColor.memorized("YELLOW"), .yellow)
            },

            //── ：足迹徽标判定纯函数（Core 真实现）──
            TestDesc(suite: "ReadingStats", name: "footprintBadgePureFunction") {
                // 空集全不亮。
                for page in 1...5 {
                    try expectFalse(PageFootprintBadge.isViewed(page, footprints: []))
                }
                // 全集全亮。
                let all: Set<Int> = [1, 2, 3, 4, 5]
                for page in 1...5 {
                    try expectTrue(PageFootprintBadge.isViewed(page, footprints: all))
                }
                // 部分集合逐页断言。
                let partial: Set<Int> = [2, 4]
                try expectFalse(PageFootprintBadge.isViewed(1, footprints: partial))
                try expectTrue(PageFootprintBadge.isViewed(2, footprints: partial))
                try expectFalse(PageFootprintBadge.isViewed(3, footprints: partial))
                try expectTrue(PageFootprintBadge.isViewed(4, footprints: partial))
                try expectFalse(PageFootprintBadge.isViewed(5, footprints: partial))
            },
        ]
    }
}
