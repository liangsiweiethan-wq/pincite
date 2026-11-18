import Foundation
@testable import LiteratureCore

// MARK: - 阅读统计与索引库共享连接的串行化测试

enum ReadingStatsConcurrencySuite {
    private static let fixedZone = TimeZone(identifier: "Asia/Shanghai")!

    /// day 键按固定时区现算（不依赖 process 时区；与 ReadingStatsSuite 同基准）。
    private static func dayKey(_ t: TimeInterval) -> String {
        ReadingStatsStore.dayKey(for: Date(timeIntervalSince1970: t), timeZone: fixedZone)
    }

    /// 已知会随并发喂点变化的两张表，以及判定「行是否结算入账」的基准。
    private static func sessionsTotal(_ store: IndexStore, bookIDs: [String]) throws -> (minutes: Double, pages: Int) {
        let stmt = try store.db.prepare("SELECT book_id, minutes, pages FROM reading_sessions;")
        var minutes = 0.0
        var pages = 0
        while try stmt.step() {
            guard bookIDs.contains(stmt.text(0)) else { continue }
            minutes += stmt.double(1)
            pages += Int(stmt.int(2))
        }
        return (minutes, pages)
    }

    /// 并发执行 body 若干份，收集抛错文案（按线程安全方式）。
    private static func runConcurrent(_ workers: [() throws -> Void]) -> [String] {
        var errors: [String] = []
        let errLock = NSLock()
        let group = DispatchGroup()
        for worker in workers {
            DispatchQueue.global().async(group: group) {
                do { try worker() } catch {
                    errLock.lock(); errors.append("\(error)"); errLock.unlock()
                }
            }
        }
        group.wait()
        return errors
    }

    static var tests: [TestDesc] {
        [
            // ── 断言 1–3：ReadingStats 写（含读）‖ IndexStore 写，零失败且数值如实 ──
            TestDesc(suite: "ReadingStatsConcurrency", name: "concurrentStatsWriteAndIndexWriteNoFailure") {
                let dir = Fixtures.makeTempDir("f12-concurrent-writes")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let stats = ReadingStatsStore(indexStore: store)
                let n = 400
                // 固定 day（东八区 07:20 起）与 1 秒步长（cap=5 分钟
                // 以内，每步都入账）：book a 记「翻页 400 次＋400 页」——分钟净额
                // 按锚点差分累计＝每秒 1/60 分钟 × 399 步＝6.65 分钟（不是 399，
                // 那是把「秒步长」误当「分步长」算的；见 accumulate 纯函数基准）；
                // book b 只记 300 次视图锚点＝0 页。
                let t0 = 1_767_223_200.0
                let books = ["f12-a", "f12-b"]
                let day = dayKey(t0)
                let anchorCount = 300

                var workers: [() throws -> Void] = []
                workers.append {
                    for i in 0..<n {
                        try stats.recordPageTurn(bookID: books[0], page: 3, now: t0 + Double(i))
                    }
                }
                workers.append {
                    for i in 0..<anchorCount {
                        try stats.recordActiveEvent(bookID: books[1], now: t0 + Double(i))
                    }
                }
                workers.append {
                    for i in 0..<n {
                        try store.upsertBook(ReadingStatsSuite.makeBook("f12-bk\(i)", title: "t\(i)", author: nil))
                        _ = try store.book(byID: "f12-bk\(i)")
                        _ = try store.allBooks()
                    }
                }
                // 统计读并发（stats/footprints 也走同一连接）。
                workers.append {
                    for _ in 0..<n {
                        _ = try stats.stats(day: day)
                        _ = try stats.footprints(bookID: books[0])
                    }
                }

                let errors = runConcurrent(workers)
                // 断言 1：两侧零失败，且零 BUSY/事务边界错。
                try expectEqual(errors.count, 0, "共享连接 并发访问出现错误: \(errors.prefix(3))")
                for e in errors {
                    try expectFalse(e.contains("cannot start a transaction"),
                                    "共享连接 事务边界仍被交错: \(e)")
                    try expectFalse(e.contains("database is locked"), "共享连接 出现 BUSY: \(e)")
                }

                // 断言 2：翻页计数与分钟净额逐项如实（旧缺陷下整次翻页被丢弃）。
                let rows = try stats.stats(day: day)
                try expectEqual(rows.count, books.count)
                let rowA = try expectNotNil(rows.first { $0.bookID == "f12-a" }, "缺 f12-a 行")
                try expectEqual(rowA.pages, n, "f12-a 翻页计数")
                // 分钟净额＝锚点差分累计：now 每秒 +1、cap=5 分钟内每步都入账，
                // 每步 credit = 1秒/60 = 1/60 分钟；首事件只当锚点不计 →
                // 净额 (n−1)/60 分钟（浮点求和末位有 ~1e-13 噪声，用容差判）。
                let expectedMinutes = Double(n - 1) / 60.0
                try expectTrue(abs(rowA.minutes - expectedMinutes) < 1e-6,
                               "f12-a 分钟净额 \(rowA.minutes) 应为 \(expectedMinutes)")
                let rowB = try expectNotNil(rows.first { $0.bookID == "f12-b" }, "缺 f12-b 行")
                try expectEqual(rowB.pages, 0, "f12-b 只喂锚点：翻页 0")
                // 断言 3：足迹 upsert 幂等单行 + 每次翻页 read_count+1；无翻页书零足迹。
                let fpsA = try stats.footprints(bookID: "f12-a")
                try expectEqual(fpsA.count, 1, "f12-a 足迹应单行")
                try expectEqual(fpsA.first?.pageNumber, 3)
                try expectEqual(fpsA.first?.readCount, n, "f12-a read_count")
                try expectEqual(try stats.footprints(bookID: "f12-b").count, 0, "f12-b 零足迹")
            },

            // ── 断言 4–5：两书交错写，同日单行合并，翻页/足迹/分钟合计守恒 ──
            TestDesc(suite: "ReadingStatsConcurrency", name: "interleavedBooksTotalsConserved") {
                let dir = Fixtures.makeTempDir("f12-interleaved")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let stats = ReadingStatsStore(indexStore: store)
                let n = 300
                let t0 = 1_767_223_200.0
                let books = ["f12-x", "f12-y"]

                var workers: [() throws -> Void] = []
                for (offset, book) in books.enumerated() {
                    workers.append {
                        // 自书内首事件起 1 秒步长（cap 内）：该书写满 n 次翻页
                        // ＝翻页 n、分钟 (n−1)/60（首事件只当锚点；每秒 1/60 分）。
                        for i in 0..<n {
                            let now = t0 + Double(offset) * 0.5 + Double(i)
                            try stats.recordPageTurn(bookID: book, page: 1 + (i % 7), now: now)
                        }
                    }
                }
                workers.append {
                    for i in 0..<n {
                        try store.upsertBook(ReadingStatsSuite.makeBook("f12-ix\(i)", title: nil, author: nil))
                    }
                }
                let errors = runConcurrent(workers)
                try expectEqual(errors.count, 0, "共享连接 交错写出现错误: \(errors.prefix(3))")

                let day = dayKey(t0)
                let rows = try stats.stats(day: day)
                try expectEqual(rows.count, books.count, "同日两书各一行（单行合并）")
                var totalMinutes = 0.0
                var totalPages = 0
                for book in books {
                    let row = try expectNotNil(rows.first { $0.bookID == book }, "缺 \(book) 行")
                    try expectEqual(row.pages, n, "\(book) 翻页计数")
                    totalMinutes += row.minutes
                    totalPages += row.pages
                }
                // 断言 5：并发交错下每次运行确定性成立的几条——翻页总数守恒；
                // 每书分钟净额 (n−1)/60 分钟（本实例锚点差分：首事件不计、其后
                // 每秒 1/60 分钟入账；两书 offset 差 0.5 秒不互相串锚）；合计
                // 与逐行全等（浮点噪声 ~1e-13）。
                let expectedPerBook = Double(n - 1) / 60.0
                try expectEqual(totalPages, n * books.count, "翻页总数守恒")
                for row in rows {
                    try expectTrue(abs(row.minutes - expectedPerBook) < 1e-6,
                                   "\(row.bookID) 分钟净额 \(row.minutes) 应为 \(expectedPerBook)")
                }
                // 合计＝每书净额之和（两书各自 (n−1)/60，容差判浮点）。
                try expectTrue(abs(totalMinutes - expectedPerBook * Double(books.count)) < 1e-6,
                               "分钟合计 \(totalMinutes) 应为 \(expectedPerBook * Double(books.count))")
                // 合计读路径（每日卡数据源）与逐书行一致。
                let daily = try expectNotNil(stats.dailyTotals(day: day), "dailyTotals 非空")
                try expectEqual(daily.pages, totalPages)
                try expectTrue(abs(daily.minutes - totalMinutes) < 1e-9,
                               "dailyTotals 合计与逐书行求和一致: \(daily.minutes) vs \(totalMinutes)")
                // 足迹总量守恒：每书写 n 个页号（1…7 循环），同页幂等叠加 read_count。
                var footprintTotal = 0
                for book in books {
                    let fps = try stats.footprints(bookID: book)
                    try expectEqual(fps.map(\.pageNumber), [1, 2, 3, 4, 5, 6, 7], "\(book) 页号集合")
                    footprintTotal += fps.reduce(0) { $0 + $1.readCount }
                }
                try expectEqual(footprintTotal, n * books.count, "足迹次数守恒")
            },

            // ── 断言 6：两个 ReadingStatsStore 实例挂同一 IndexStore（各持私有
            // anchors/lock 状态），并发写仍不撞（共享连接锁的唯一性证明） ──
            TestDesc(suite: "ReadingStatsConcurrency", name: "twoStatsInstancesOnOneStoreDoNotCollide") {
                let dir = Fixtures.makeTempDir("f12-two-instances")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let s1 = ReadingStatsStore(indexStore: store)
                let s2 = ReadingStatsStore(indexStore: store)
                let n = 250
                let t0 = 1_767_223_200.0
                let workers: [() throws -> Void] = [
                    { for i in 0..<n { try s1.recordPageTurn(bookID: "stats-a", page: 1, now: t0 + Double(i)) } },
                    { for i in 0..<n { try s2.recordPageTurn(bookID: "stats-b", page: 1, now: t0 + Double(i)) } },
                    { for i in 0..<n { try store.upsertBook(ReadingStatsSuite.makeBook("f12-t\(i)", title: nil, author: nil)) } },
                ]
                let errors = runConcurrent(workers)
                try expectEqual(errors.count, 0, "两实例并发写出现错误: \(errors.prefix(3))")
                let rows = try s1.stats(day: dayKey(t0))
                try expectEqual(rows.count, 2)
                for book in ["stats-a", "stats-b"] {
                    let row = try expectNotNil(rows.first { $0.bookID == book }, "缺 \(book)")
                    try expectEqual(row.pages, n, "\(book) 翻页计数")
                }
                // s2 读到的也是同一盘点（两实例共库、读侧一致）。
                let rowsViaSecond = try s2.stats(day: dayKey(t0))
                try expectEqual(rowsViaSecond, rows)
            },

            // ── 断言 7：只读副本门在并发下语义不变（静默 no-op，不报 BUSY） ──
            TestDesc(suite: "ReadingStatsConcurrency", name: "readOnlyReplicaConcurrentWritesStaySilentNoOp") {
                let dir = Fixtures.makeTempDir("f12-readonly")
                defer { Fixtures.cleanup(dir) }
                let rw = try Fixtures.openStore(in: dir)
                try rw.upsertBook(ReadingStatsSuite.makeBook("stats-ro", title: "旧书", author: nil))
                let replica = try Fixtures.openStore(in: dir, options: .init(readOnlyReplica: true))
                let stats = ReadingStatsStore(indexStore: replica)
                let n = 100
                let t0 = 1_767_223_200.0
                let workers: [() throws -> Void] = [
                    { for i in 0..<n { try stats.recordPageTurn(bookID: "stats-ro", page: 1, now: t0 + Double(i)) } },
                    { for i in 0..<n { try stats.recordFootprint(bookID: "stats-ro", page: 1, now: t0 + Double(i)) } },
                    { for _ in 0..<n { _ = try replica.allBooks() } },
                ]
                let errors = runConcurrent(workers)
                try expectEqual(errors.count, 0, "只读副本并发写应静默 no-op: \(errors.prefix(3))")
                try expectEqual(try stats.stats(day: dayKey(t0)).count, 0, "只读副本零行")
                try expectEqual(try stats.footprints(bookID: "stats-ro").count, 0, "只读副本零足迹")
            },
        ]
    }
}
