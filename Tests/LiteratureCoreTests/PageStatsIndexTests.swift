import Foundation
@testable import LiteratureCore
@testable import LiteratureSearchUI

// MARK: - 刷新批收尾建索引测试
enum PageStatsIndexTests {

    // MARK: 助手

    /// 三本合成 PDF 入库（每本 1 页）——与 RefreshConsoleSuite 同款夹具基准。
    private static func makeLibrary(_ dir: URL) async throws -> (IndexStore, [IndexStore.BookRow]) {
        for n in 1...3 {
            Fixtures.makePDF(pages: [.init(lines: ["页统计索引测试 第\(n)书 标记词\(n)。"])],
                             in: dir, named: "book\(n).pdf")
        }
        let store = try Fixtures.openStore(in: dir)
        let engine = IndexingEngine(store: store, policy: ExclusionPolicy())
        let run = try await engine.run(rootURL: dir)
        precondition(run.indexedNew == 3, "fixture library must index 3 books")
        let books = try store.allBooks().sorted { $0.fileName < $1.fileName }
        precondition(books.count == 3)
        return (store, books)
    }

    private static func standardRows(_ books: [IndexStore.BookRow]) throws
        -> [(src: String, shaAfter: String?, pages: Int?)] {
        try books.map { book in
            (src: book.realPath,
             shaAfter: try Fingerprint.sha256Hex(ofFileAt: URL(fileURLWithPath: book.realPath)),
             pages: book.pageCount)
        }
    }

    private static func writeLedger(_ dir: URL,
                                    _ rows: [(src: String, shaAfter: String?, pages: Int?)]) throws -> URL {
        let url = dir.appendingPathComponent("重建清单样例.jsonl")
        var lines: [String] = []
        for (i, row) in rows.enumerated() {
            var obj: [String: Any] = [
                "ts": "2026-10-18T10:00:0\(i)",
                "src": row.src,
                "apply": row.shaAfter != nil,
                "pages": row.pages ?? 1,
                "status": row.shaAfter != nil ? "OK" : "DRYRUN_PASS",
            ]
            if let sha = row.shaAfter { obj["sha_after"] = sha }
            let data = try JSONSerialization.data(withJSONObject: obj)
            lines.append(String(data: data, encoding: .utf8)!)
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 让 `CREATE INDEX` 必失败：在 ft schema 里先占同名表。SQLite 实证——
    /// 同 schema 内表名与索引名共用命名空间，`CREATE INDEX IF NOT EXISTS` 遇
    /// 同名**表**照样报 "there is already a table named ..."（`IF NOT EXISTS`
    /// 只对同名索引生效）。这样失败注入不碰生产代码、不加任何测试钩子。
    private static func injectIndexNameCollision(_ store: IndexStore) throws {
        try store.db.exec("CREATE TABLE \(store.ftQual)idx_pages_stats(x);")
    }

    private static func indexExists(_ store: IndexStore) throws -> Bool {
        try store.hasSqliteObjectLocked(type: "index", name: IndexStore.pageStatsIndexName)
    }

    private static func drainAndPoll<T>(_ probe: () -> T,
                                        until predicate: (T) -> Bool,
                                        timeoutMs: Int = 4000) async throws -> T where T: Equatable {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
        var value = probe()
        while !predicate(value) {
            if Date() > deadline {
                throw TestFailure(message: "drainAndPoll timeout, last value: \(value)")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            value = probe()
        }
        await MainActor.run { }
        try await Task.sleep(nanoseconds: 50_000_000)
        return probe()
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "PageStatsIndex", name: "ensureBuildsOnDemandAndIsIdempotent") {
                let dir = Fixtures.makeTempDir("page-stats-ensure")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                try PagesStatsCacheTests.addBook(store, id: "bA", name: "a.pdf",
                                                 pages: ["one", "", "three"])
                try expectFalse(try indexExists(store),
                                "默认 Options（App 路径）开库不得建索引；保持开库开销不变")
                try expectFalse(store.allowPageStatsStatsIndex,
                                "默认门控应为 false")

                let first = store.ensurePageStatsIndex()
                try expectEqual(first.outcome, .built, "首次调用应真建（\(first.message ?? "—")）")
                try expectNil(first.message, "成功路径不带错误原文")
                try expectTrue(try indexExists(store), "建完后索引必须在册")
                try expectFalse(store.allowPageStatsStatsIndex,
                                "补建不得改写开库门控（只影响这一次显式调用）")

                // 形态核对：与 migrateSchemaV14 的 DDL 同源——两列、第二列是
                // TRIM(text_norm)='' 表达式。
                let ddlStmt = try store.db.prepare(
                    "SELECT sql FROM \(store.ftQual)sqlite_master WHERE type='index' AND name=?;")
                try ddlStmt.bindText(1, IndexStore.pageStatsIndexName)
                let ddl = try expectNotNil(try ddlStmt.step() ? ddlStmt.textOrNull(0) : nil)
                try expectTrue(ddl.contains("book_id"), "索引首列应为 book_id，实际：\(ddl)")
                try expectTrue(ddl.uppercased().contains("TRIM"),
                               "索引第二列应为 TRIM(text_norm) 表达式，实际：\(ddl)")

                let second = store.ensurePageStatsIndex()
                try expectEqual(second.outcome, .alreadyPresent,
                                "索引已在时必须报 alreadyPresent（幂等）")
                try expectTrue(second.seconds < 2.0,
                                "已存在时的判别应近乎零成本，耗时 \(second.seconds)s")

                // 补建之后统计基准不变（建索引只买时间，不改结果）。
                try expectEqual(try submitStats(store, "bA").pagesWithText, 2)
            },

            TestDesc(suite: "PageStatsIndex", name: "ensureSkipsReadOnlyReplica") {
                let dir = Fixtures.makeTempDir("page-stats-replica")
                defer { Fixtures.cleanup(dir) }
                let dbPath = dir.appendingPathComponent("index.db")
                do {
                    let writer = try IndexStore(path: dbPath)
                    try PagesStatsCacheTests.addBook(writer, id: "bA", name: "a.pdf", pages: ["one"])
                }
                let replicaDir = dir.appendingPathComponent("replica", isDirectory: true)
                try Fixtures.copyForReadOnlyReplica(dbURL: dbPath, into: replicaDir)
                let replica = try IndexStore(path: replicaDir.appendingPathComponent("index.db"),
                                             options: .init(readOnlyReplica: true))
                let result = replica.ensurePageStatsIndex()
                try expectEqual(result.outcome, .skipped,
                                "只读副本上无处建，应如实 skipped 而不是报失败")
                try expectNil(result.message)
            },

            TestDesc(suite: "PageStatsIndex", name: "ensureSkipsWithoutPagesTable") {
                let dir = Fixtures.makeTempDir("page-stats-no-pages")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                // split 形态 pages 在 ft；删掉它 = 「无页表可建」。
                try store.db.exec("DROP TABLE IF EXISTS \(store.ftQual)pages;")
                let result = store.ensurePageStatsIndex()
                try expectEqual(result.outcome, .skipped,
                                "无 pages 表时应 skipped（不是 failed——没东西可建不算错）")
            },

            TestDesc(suite: "PageStatsIndex", name: "ensureFailureIsReportedNotThrown") {
                let dir = Fixtures.makeTempDir("page-stats-fail")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                try PagesStatsCacheTests.addBook(store, id: "bA", name: "a.pdf",
                                                 pages: ["alpha", ""])
                try injectIndexNameCollision(store)

                let result = store.ensurePageStatsIndex()
                try expectEqual(result.outcome, .failed, "同名表占位时建索引必失败")
                let message = try expectNotNil(result.message, "失败必须带 SQLite 错误原文")
                try expectTrue(message.contains("already a table")
                               || message.contains("idx_pages_stats"),
                               "错误原文应指认同名冲突，实际：\(message)")
                // 关键：**不抛**。调用方（刷新批收尾）据此继续走完收尾。
                // 且检索统计仍走慢路得出正确结果（性能增益非正确性前提）。
                let stats = try store.perBookPageStats()
                let row = try expectNotNil(stats.first { $0.bookID == "bA" })
                try expectEqual(row.indexedPages, 2, "无索引时慢路仍须给出正确页数")
                try expectEqual(row.pagesWithText, 1, "无索引时慢路仍须给出正确文本页数")
            },

            TestDesc(suite: "PageStatsIndex", name: "batchFinalizeBuildsIndexAndKeepsJournalContract") {
                let dir = Fixtures.makeTempDir("page-stats-batch")
                defer { Fixtures.cleanup(dir) }
                let (store, books) = try await makeLibrary(dir)
                try expectFalse(try indexExists(store),
                                "批次开跑前库内不得有该索引（App 路径从不建）")
                let ledger = try writeLedger(dir, try standardRows(books))
                let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                           snapshotDir: dir.appendingPathComponent("snap"),
                                           journalDir: dir.appendingPathComponent("jr"))
                let plan = try engine.loadLedger(ledger)
                let started = await engine.start(plan: plan)
                try expectTrue(started)

                let progress = engine.currentProgress()
                try expectEqual(progress.phase, .completed, "批次的结论基准不变")
                let result = try expectNotNil(progress.pageStatsIndex,
                                              "收尾必须走到建索引这一步，结果要挂在 progress 上")
                try expectEqual(result.outcome, .built, "首建应为 built（\(result.message ?? "—")）")
                try expectTrue(try indexExists(store), "收尾后索引必须在册")

                // journal 契约：不新增事件类型，末事件仍是 batch-complete
                //（既有 6 处断言与面板「停在何处」都依赖它）。
                let journalURL = try expectNotNil(RefreshJournal.latestJournalURL(in: dir.appendingPathComponent("jr")))
                let events = RefreshJournal.readEvents(at: journalURL)
                try expectEqual(events.last?.event, RefreshJournalEventName.batchComplete,
                                "末事件必须仍是 batch-complete")
                try expectFalse(events.contains { $0.event.contains("page-stats") },
                                "本次不新增 journal 事件类型（设计取舍见 buildPageStatsIndex 注释）")
                let summary = try expectNotNil(RefreshJournal.summarize(at: journalURL))
                try expectFalse(summary.interrupted)
                try expectEqual(summary.booksSettled, 3)
                try expectEqual(summary.lastEvent, RefreshJournalEventName.batchComplete)

                _ = await engine.start(plan: plan)
                let second = try expectNotNil(engine.currentProgress().pageStatsIndex)
                try expectEqual(second.outcome, .alreadyPresent,
                                "第二批收尾应报 alreadyPresent，不重建")
            },

            TestDesc(suite: "PageStatsIndex", name: "indexFailureDoesNotChangeBatchVerdict") {
                let dir = Fixtures.makeTempDir("page-stats-batch-fail")
                defer { Fixtures.cleanup(dir) }
                let (store, books) = try await makeLibrary(dir)
                try injectIndexNameCollision(store)   // 让收尾必失败
                let ledger = try writeLedger(dir, try standardRows(books))
                let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                           snapshotDir: dir.appendingPathComponent("snap"),
                                           journalDir: dir.appendingPathComponent("jr"))
                let plan = try engine.loadLedger(ledger)
                _ = await engine.start(plan: plan)

                let progress = engine.currentProgress()
                try expectEqual(progress.phase, .completed,
                                "建索引失败不得把已成功的刷新批改成失败/残留")
                try expectNil(progress.lastError, "建索引失败不得写引擎级 lastError（那是批次失败面）")
                try expectTrue(progress.failed.isEmpty,
                               "建索引失败不得进错误清单（那是「书有问题」的清单）：\(progress.failed)")
                try expectEqual(progress.booksDone + progress.booksFailed, 3)
                try expectTrue(progress.succeededBookIDs.count == 3, "三本书都应记为成功")
                let check = try expectNotNil(progress.finalCheck)
                try expectTrue(check.pass, "三向对账仍须 PASS")

                let result = try expectNotNil(progress.pageStatsIndex)
                try expectEqual(result.outcome, .failed, "索引确实没建成，要如实报")
                try expectNotNil(result.message)
                try expectFalse(try indexExists(store), "同名表占位时索引建不出来")
                let journalURL = try expectNotNil(RefreshJournal.latestJournalURL(in: dir.appendingPathComponent("jr")))
                let events = RefreshJournal.readEvents(at: journalURL)
                try expectEqual(events.last?.event, RefreshJournalEventName.batchComplete)
                let summary = try expectNotNil(RefreshJournal.summarize(at: journalURL))
                try expectFalse(summary.interrupted, "批次必须仍是已收尾状态")
                try expectFalse(summary.finalizeResidue, "建索引失败不得被读成三向对账残留")
            },

            TestDesc(suite: "PageStatsIndex", name: "indexStepIsIndependentOfJournalWrites") {
                let dir = Fixtures.makeTempDir("page-stats-journal-fail")
                defer { Fixtures.cleanup(dir) }
                let (store, books) = try await makeLibrary(dir)
                let ledger = try writeLedger(dir, try standardRows(books))
                let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                           snapshotDir: dir.appendingPathComponent("snap"),
                                           journalDir: dir.appendingPathComponent("jr"))
                engine.appendFailureEventNames = ["page-stats-index"]
                let plan = try engine.loadLedger(ledger)
                _ = await engine.start(plan: plan)

                let progress = engine.currentProgress()
                try expectEqual(progress.phase, .completed, "批次结论不受影响")
                try expectNil(progress.lastError)
                try expectEqual(try expectNotNil(progress.pageStatsIndex).outcome, .built,
                                "建索引不依赖 journal 写入，索引仍应建成")
                try expectTrue(try indexExists(store), "索引仍应建成")
                let journalURL = try expectNotNil(RefreshJournal.latestJournalURL(in: dir.appendingPathComponent("jr")))
                let events = RefreshJournal.readEvents(at: journalURL)
                try expectEqual(events.last?.event, RefreshJournalEventName.batchComplete)
            },

            TestDesc(suite: "PageStatsIndex", name: "indexResultPresentBeforeCompletedPhase") {
                let dir = Fixtures.makeTempDir("page-stats-order")
                defer { Fixtures.cleanup(dir) }
                let (_, books) = try await makeLibrary(dir)
                let ledger = try writeLedger(dir, try standardRows(books))
                let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                           snapshotDir: dir.appendingPathComponent("snap"),
                                           journalDir: dir.appendingPathComponent("jr"))
                let seen = SnapshotLog()
                engine.onUpdate = { snapshot in seen.record(snapshot) }
                let plan = try engine.loadLedger(ledger)
                _ = await engine.start(plan: plan)

                let firstCompleted = try expectNotNil(seen.firstCompletedSnapshot(),
                                                     "整批跑完必然发布过 completed 快照")
                try expectNotNil(firstCompleted.pageStatsIndex,
                                 "phase 到 completed 的那一刻，建索引结果必须已在")
                // 且那一刻三向对账结果也在（既有顺序不受影响）。
                try expectNotNil(firstCompleted.finalCheck)
            },

            TestDesc(suite: "PageStatsIndex", name: "storePublishesIndexLineAndExportsIt") {
                let dir = Fixtures.makeTempDir("page-stats-store")
                defer { Fixtures.cleanup(dir) }
                let (_, books) = try await makeLibrary(dir)
                let ledger = try writeLedger(dir, try standardRows(books))
                let store = RefreshConsoleStore(dbURL: dir.appendingPathComponent("index.db"),
                                                snapshotDir: dir.appendingPathComponent("snap"),
                                                journalDir: dir.appendingPathComponent("jr"))
                try expectNil(store.pageStatsIndexLine, "未跑批次时不得显示该行（空态安全）")
                store.loadLedger(at: ledger)
                _ = try await drainAndPoll({ store.plan?.books.count ?? -1 }, until: { $0 == 3 })
                store.start()
                _ = try await drainAndPoll({ store.phase }, until: { $0 == .completed })

                let line = try expectNotNil(try await drainAndPoll({ store.pageStatsIndexLine },
                                                                  until: { $0 != nil }) as String?,
                                            "批次完成后面板必须能显示这一行")
                try expectTrue(line.contains("已建"), "首建应显示「已建」，实际：\(line)")
                try expectTrue(line.contains("秒"), "已建态应带耗时，实际：\(line)")
                // completed 后 progress 不再更新——结果必须被 Store 缓存住。
                try expectNotNil(store.lastPageStatsIndexResult)
                // 随三向对账总表一起导出（含「不影响结论」基准）。
                let text = store.finalCheckText()
                try expectTrue(text.contains(L10n.indexRefreshStatsIndexTitle),
                               "导出总表应带该行，实际：\(text)")
                try expectTrue(text.contains("已建"), "导出件里要能读到结果，实际：\(text)")
            },

            TestDesc(suite: "PageStatsIndex", name: "failureLineSaysBatchVerdictUnaffected") {
                let dir = Fixtures.makeTempDir("page-stats-copy")
                defer { Fixtures.cleanup(dir) }
                let (store, books) = try await makeLibrary(dir)
                try injectIndexNameCollision(store)
                let ledger = try writeLedger(dir, try standardRows(books))
                let store2 = RefreshConsoleStore(dbURL: dir.appendingPathComponent("index.db"),
                                                 snapshotDir: dir.appendingPathComponent("snap"),
                                                 journalDir: dir.appendingPathComponent("jr"))
                store2.loadLedger(at: ledger)
                _ = try await drainAndPoll({ store2.plan?.books.count ?? -1 }, until: { $0 == 3 })
                store2.start()
                _ = try await drainAndPoll({ store2.phase }, until: { $0 == .completed })
                let line = try expectNotNil(try await drainAndPoll({ store2.pageStatsIndexLine },
                                                                   until: { $0 != nil }) as String?,
                                            "失败也必须有这一行（如实报，不静默）")
                try expectTrue(line.contains("未建成"), "应显示「未建成」，实际：\(line)")
                try expectTrue(line.contains("不影响本次结论"),
                               "失败文案必须明写不影响批次结论（本次设计取舍的基准），实际：\(line)")
                try expectEqual(store2.phase, .completed, "同一时刻批次结论仍是 completed")
                try expectEqual(store2.lastPageStatsIndexResult?.isFailure, true)
            },
        ]
    }

    /// onUpdate 快照记录器（回调来自引擎的任意线程；内部加锁）。
    final class SnapshotLog: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshots: [RefreshEngine.Progress] = []

        func record(_ snapshot: RefreshEngine.Progress) {
            lock.lock()
            snapshots.append(snapshot)
            lock.unlock()
        }

        func firstCompletedSnapshot() -> RefreshEngine.Progress? {
            lock.lock(); defer { lock.unlock() }
            return snapshots.first { $0.phase == .completed || $0.phase == .completedWithResidue }
        }
    }

    private static func submitStats(_ store: IndexStore, _ id: String) throws -> BookPageStat {
        try expectNotNil(try store.perBookPageStats().first { $0.bookID == id })
    }
}
