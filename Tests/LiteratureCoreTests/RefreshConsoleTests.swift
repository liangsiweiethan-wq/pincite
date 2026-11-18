import Foundation
@testable import LiteratureCore
@testable import LiteratureSearchUI

// MARK: - 索引刷新控制台合成套件（索引刷新控制台的验收基准）
//
// 覆盖：journal 读写与保留规矩／引擎全批跑通（书级幂等）／书边界暂停/
// 继续／停止后可续（无重复页行）／备份失败不开跑（fail-closed）／
// 备份建新删旧（keep=1）／终账解析（dryrun 排除、末行胜出、未配对如实列）／
// 空清单零写库／面板 Store 发布面（注入临时目录，绝不写真实
// Application Support——AIProfilesSuite/LibrarySnapshotStoreSuite 同款纪律）。

enum RefreshConsoleSuite {

    // MARK: 助手

    /// 三本合成 PDF 入库（每本 1 页），返回 (store, 书行按文件名序)。
    private static func makeLibrary(_ dir: URL) async throws -> (IndexStore, [IndexStore.BookRow]) {
        for n in 1...3 {
            Fixtures.makePDF(pages: [.init(lines: ["刷新批 第\(n)书 基线内容标记词\(n)。"])],
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

    /// 三本书的标准终账行（全部带 sha_after； 批起用盘上真实 sha——
    /// 收尾三向对账会把占位 sha 判为「清单≠盘上」残留，真实值才能全绿收尾）。
    private static func standardRows(_ books: [IndexStore.BookRow]) throws
        -> [(src: String, shaAfter: String?, pages: Int?)] {
        try books.map { book in
            (src: book.realPath,
             shaAfter: try Fingerprint.sha256Hex(ofFileAt: URL(fileURLWithPath: book.realPath)),
             pages: book.pageCount)
        }
    }

    /// 写终账样例 jsonl。
    /// rows: (src, shaAfter?, pages)；shaAfter nil＝dryrun 行（无 sha_after）。
    private static func writeLedger(_ dir: URL,
                                    _ rows: [(src: String, shaAfter: String?, pages: Int?)]) throws -> URL {
        let url = dir.appendingPathComponent("重建清单样例.jsonl")
        var lines: [String] = []
        for (i, row) in rows.enumerated() {
            var obj: [String: Any] = [
                "ts": "2026-10-12T10:00:0\(i)",
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

    /// 主队列排空＋轮询断言（Store 的 @Published 都在主线程发布；后台工作
    /// 完成后一次 MainActor.run 即可排空——先等后台、再排主队列）。
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
        // 后台工作完成后：排空主队列里挂着的发布块，再取终值。
        await MainActor.run { }
        try await Task.sleep(nanoseconds: 50_000_000)
        return probe()
    }

    private static func journalFileCount(_ dir: URL) -> Int {
        RefreshJournal.journalURLs(in: dir).count
    }

    static var tests: [TestDesc] {
        [
            // ================= journal 读写与保留 =================

            // 断言1：journal 事件 jsonl 往返（编码含 snake_case 键；读回逐字段等值）。
            TestDesc(suite: "RefreshConsole", name: "journalEventRoundtrip") {
                let dir = Fixtures.makeTempDir("refresh-journal-rt")
                defer { Fixtures.cleanup(dir) }
                let writer = try RefreshJournal.Writer(directory: dir, batchID: "20261012-100001")
                try writer.append(RefreshJournalEvent(event: RefreshJournalEventName.batchStart,
                                                      batchID: "20261012-100001",
                                                      ledger: "/tmp/ledger.jsonl",
                                                      booksTotal: 3, pagesTotal: 597))
                try writer.append(RefreshJournalEvent(event: RefreshJournalEventName.bookDone,
                                                      batchID: "20261012-100001",
                                                      bookID: "a1", src: "/书/甲.pdf",
                                                      shaAfter: "824a911e", pages: 597,
                                                      verdict: "updated"))
                let url = dir.appendingPathComponent("20261012-100001.jsonl")
                let events = RefreshJournal.readEvents(at: url)
                try expectEqual(events.count, 2)
                try expectEqual(events[0].event, RefreshJournalEventName.batchStart)
                try expectEqual(events[0].booksTotal, 3)
                try expectEqual(events[1].event, RefreshJournalEventName.bookDone)
                try expectEqual(events[1].bookID, "a1")
                try expectEqual(events[1].shaAfter, "824a911e")
                // jsonl 键风格镜像清单（snake_case）。
                let raw = try String(contentsOf: url, encoding: .utf8)
                try expectTrue(raw.contains("\"batch_id\":\"20261012-100001\""), "snake_case batch_id key")
                try expectTrue(raw.contains("\"sha_after\":\"824a911e\""), "snake_case sha_after key")
            },

            // 断言2：summarize 三态——中断（无终态）/已收尾；已完成与待跑可读出。
            TestDesc(suite: "RefreshConsole", name: "journalSummarizeInterruptedVsSettled") {
                let dir = Fixtures.makeTempDir("refresh-journal-sum")
                defer { Fixtures.cleanup(dir) }
                let writer = try RefreshJournal.Writer(directory: dir, batchID: "20261012-100002")
                try writer.append(RefreshJournalEvent(event: RefreshJournalEventName.batchStart,
                                                      batchID: "b", booksTotal: 3))
                try writer.append(RefreshJournalEvent(event: RefreshJournalEventName.bookDone,
                                                      batchID: "b", bookID: "x1", verdict: "updated"))
                try writer.append(RefreshJournalEvent(event: RefreshJournalEventName.bookFail,
                                                      batchID: "b", bookID: "x2",
                                                      verdict: "error", error: "页数校验不符"))
                let url = dir.appendingPathComponent("20261012-100002.jsonl")
                var summary = try expectNotNil(RefreshJournal.summarize(at: url))
                try expectTrue(summary.interrupted, "no terminal batch event => interrupted")
                try expectEqual(summary.booksSettled, 2)
                try expectEqual(summary.pendingCount, 1)
                try expectEqual(summary.failures["x2"], "页数校验不符")
                try expectEqual(summary.lastEvent, RefreshJournalEventName.bookFail)
                // 补终态后不再判中断。
                try writer.append(RefreshJournalEvent(event: RefreshJournalEventName.batchStop,
                                                      batchID: "b"))
                summary = try expectNotNil(RefreshJournal.summarize(at: url))
                try expectFalse(summary.interrupted)
                try expectEqual(summary.lastEvent, RefreshJournalEventName.batchStop)
            },

            // 断言3：journal 只留最近一份（新批保留件外全删；pruneOldJournals 返回删除的文件名）。
            TestDesc(suite: "RefreshConsole", name: "journalRetentionKeepsLatestOnly") {
                let dir = Fixtures.makeTempDir("refresh-journal-ret")
                defer { Fixtures.cleanup(dir) }
                for id in ["20261011-090000", "20261012-100000", "20261012-100001"] {
                    _ = try RefreshJournal.Writer(directory: dir, batchID: id)
                }
                try expectEqual(journalFileCount(dir), 3)
                let keeping = dir.appendingPathComponent("20261012-100001.jsonl")
                let removed = RefreshJournal.pruneOldJournals(in: dir, keeping: keeping)
                try expectEqual(removed.sorted(), ["20261011-090000.jsonl", "20261012-100000.jsonl"])
                try expectEqual(journalFileCount(dir), 1)
                try expectEqual(RefreshJournal.latestJournalURL(in: dir)?.lastPathComponent,
                                "20261012-100001.jsonl")
            },

            // ================= 终账解析（计划生成纯读） =================

            // 断言4：dryrun 行不进计划；同 src 末行胜出；未配对 src 如实列 unresolved。
            TestDesc(suite: "RefreshConsole", name: "ledgerParsingDryrunLastRowUnresolved") {
                let dir = Fixtures.makeTempDir("refresh-ledger")
                defer { Fixtures.cleanup(dir) }
                let (_, books) = try await makeLibrary(dir)
                let src1 = books[0].realPath
                let src2 = books[1].realPath
                let ledger = try writeLedger(dir, [
                    (src: src1, shaAfter: nil, pages: 1),                 // dryrun：排除
                    (src: src1, shaAfter: "aaaa1111", pages: 5),          // 末行胜出（pages=5）
                    (src: src1, shaAfter: "bbbb2222", pages: 9),
                    (src: src2, shaAfter: "cccc3333", pages: 2),
                    (src: "/nonexistent/未配对书.pdf", shaAfter: "dddd4444", pages: 1),
                ])
                let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                           snapshotDir: dir.appendingPathComponent("snap"),
                                           journalDir: dir.appendingPathComponent("jr"))
                let plan = try engine.loadLedger(ledger)
                try expectEqual(plan.books.count, 2)
                try expectEqual(plan.books.first { $0.bookID == books[0].id }?.shaExpect, "bbbb2222")
                try expectEqual(plan.books.first { $0.bookID == books[0].id }?.declaredPages, 9)
                try expectEqual(plan.unresolvedSources, ["/nonexistent/未配对书.pdf"])
                try expectEqual(plan.pagesTotal, 11)
            },

            // 断言5：空清单安全——零适用行 → books 空（面板开启按钮据此禁用，绝不误触库）。
            TestDesc(suite: "RefreshConsole", name: "ledgerEmptyYieldsEmptyPlan") {
                let dir = Fixtures.makeTempDir("refresh-empty")
                defer { Fixtures.cleanup(dir) }
                _ = try await makeLibrary(dir)
                let ledger = try writeLedger(dir, [(src: "/none/x.pdf", shaAfter: nil, pages: 1)])
                let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                           snapshotDir: dir.appendingPathComponent("snap"),
                                           journalDir: dir.appendingPathComponent("jr"))
                let plan = try engine.loadLedger(ledger)
                try expectTrue(plan.books.isEmpty)
                try expectTrue(plan.unresolvedSources.isEmpty)
            },

            // ================= 引擎：全批跑通＋幂等＋备份 =================

            TestDesc(suite: "RefreshConsole", name: "engineFullBatchCompletesWithJournal") {
                let dir = Fixtures.makeTempDir("refresh-full")
                defer { Fixtures.cleanup(dir) }
                let (store, books) = try await makeLibrary(dir)
                let book1URL = URL(fileURLWithPath: books[0].realPath)
                try FileManager.default.removeItem(at: book1URL)
                Fixtures.makePDF(pages: [.init(lines: ["刷新批 第1书 结算后新内容。"])],
                                 in: book1URL.deletingLastPathComponent(), named: "book1.pdf")
                let ledger = try writeLedger(dir, try standardRows(books))
                let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                           snapshotDir: dir.appendingPathComponent("snap"),
                                           journalDir: dir.appendingPathComponent("jr"))
                let plan = try engine.loadLedger(ledger)
                try expectEqual(plan.books.count, 3)

                let started = await engine.start(plan: plan)
                try expectTrue(started)
                let progress = engine.currentProgress()
                try expectEqual(progress.phase, .completed)
                try expectEqual(progress.booksTotal, 3)
                try expectEqual(progress.booksDone + progress.booksFailed, 3)
                try expectTrue(progress.failed.isEmpty, "no failures expected: \(progress.failed)")
                // 备份已建（快照目录恰 1 份；keep=1）。
                try expectEqual(SnapshotManager(snapshotDir: dir.appendingPathComponent("snap"),
                                                sources: []).listSnapshots().count, 1)
                // journal：batch-start … book-* ×3 … batch-complete；已收尾不判中断。
                let journalURL = try expectNotNil(RefreshJournal.latestJournalURL(in: dir.appendingPathComponent("jr")))
                let events = RefreshJournal.readEvents(at: journalURL)
                try expectEqual(events.first?.event, RefreshJournalEventName.batchStart)
                try expectEqual(events.last?.event, RefreshJournalEventName.batchComplete)
                let summary = try expectNotNil(RefreshJournal.summarize(at: journalURL))
                try expectFalse(summary.interrupted)
                try expectEqual(summary.booksSettled, 3)
                // 书 1＝updated（页行换成新内容、书身份不变）；书 2/3＝unchanged 跳过。
                try expectEqual(summary.bookVerdicts[books[0].id], RefreshJournalEventName.bookDone)
                try expectEqual(summary.bookVerdicts[books[1].id], RefreshJournalEventName.bookSkip)
                let row1 = try expectNotNil(try store.book(byID: books[0].id))
                try expectEqual(row1.pageCount, 1)
            },

            // 断言7：幂等——同计划重跑零重复页行（unchanged 跳过、done 计数归零重建）。
            TestDesc(suite: "RefreshConsole", name: "engineRerunIsIdempotentNoDuplicateRows") {
                let dir = Fixtures.makeTempDir("refresh-idem")
                defer { Fixtures.cleanup(dir) }
                let (store, books) = try await makeLibrary(dir)
                let ledger = try writeLedger(dir, try standardRows(books))
                let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                           snapshotDir: dir.appendingPathComponent("snap"),
                                           journalDir: dir.appendingPathComponent("jr"))
                let plan = try engine.loadLedger(ledger)
                _ = await engine.start(plan: plan)
                let pagesAfterFirst = try store.allBooks().reduce(0) { $0 + $1.pageCount }
                try expectEqual(pagesAfterFirst, 3)
                _ = await engine.start(plan: plan)
                let pagesAfterSecond = try store.allBooks().reduce(0) { $0 + $1.pageCount }
                try expectEqual(pagesAfterSecond, 3)
                try expectEqual(journalFileCount(dir.appendingPathComponent("jr")), 1)
                let progress = engine.currentProgress()
                try expectEqual(progress.booksDone, 3)
                try expectEqual(progress.phase, .completed)
            },

            // ================= 书边界暂停/继续/停止 =================

            TestDesc(suite: "RefreshConsole", name: "enginePauseLandsOnBookBoundaryThenResume") {
                let dir = Fixtures.makeTempDir("refresh-pause")
                defer { Fixtures.cleanup(dir) }
                let (store, books) = try await makeLibrary(dir)
                let ledger = try writeLedger(dir, try standardRows(books))
                let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                           snapshotDir: dir.appendingPathComponent("snap"),
                                           journalDir: dir.appendingPathComponent("jr"))
                let plan = try engine.loadLedger(ledger)
                // 测试注入点（密闭化说明）：第 1 本书终态后请求暂停。
                engine.perBookHook = { index in if index == 0 { engine.pause() } }
                _ = await engine.start(plan: plan)
                var progress = engine.currentProgress()
                try expectEqual(progress.phase, .paused)
                try expectEqual(progress.booksDone, 1, "pause must land after book 1 (book boundary)")
                try expectEqual(progress.currentBookName, nil)
                let journalURL = try expectNotNil(RefreshJournal.latestJournalURL(in: dir.appendingPathComponent("jr")))
                var summary = try expectNotNil(RefreshJournal.summarize(at: journalURL))
                try expectEqual(summary.lastEvent, RefreshJournalEventName.batchPause)
                try expectEqual(summary.booksSettled, 1)
                try expectEqual(try store.allBooks().reduce(0) { $0 + $1.pageCount }, 3)

                engine.perBookHook = nil
                let resumed = await engine.resume()
                try expectTrue(resumed)
                progress = engine.currentProgress()
                try expectEqual(progress.phase, .completed)
                try expectEqual(progress.booksDone, 3)
                summary = try expectNotNil(RefreshJournal.summarize(at: journalURL))
                try expectFalse(summary.interrupted)
                try expectEqual(summary.booksSettled, 3)
                // 继续后无重复页行。
                try expectEqual(try store.allBooks().reduce(0) { $0 + $1.pageCount }, 3)
                // journal 事件序：batch-pause 后有 batch-resume，末条 batch-complete。
                let names = RefreshJournal.readEvents(at: journalURL).map(\.event)
                let pauseIdx = try expectNotNil(names.firstIndex(of: RefreshJournalEventName.batchPause))
                let resumeIdx = try expectNotNil(names.firstIndex(of: RefreshJournalEventName.batchResume))
                try expectTrue(pauseIdx < resumeIdx)
                try expectEqual(names.last, RefreshJournalEventName.batchComplete)
            },

            // 断言9：停止后「继续」可续——停止在书边界收摊（journal batch-stop、
            // 已完成保留），继续跑余书，全批无重复页行、终态 completed。
            TestDesc(suite: "RefreshConsole", name: "engineStopThenResumeCompletes") {
                let dir = Fixtures.makeTempDir("refresh-stop")
                defer { Fixtures.cleanup(dir) }
                let (store, books) = try await makeLibrary(dir)
                let ledger = try writeLedger(dir, try standardRows(books))
                let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                           snapshotDir: dir.appendingPathComponent("snap"),
                                           journalDir: dir.appendingPathComponent("jr"))
                let plan = try engine.loadLedger(ledger)
                engine.perBookHook = { index in if index == 0 { engine.stop() } }
                _ = await engine.start(plan: plan)
                var progress = engine.currentProgress()
                try expectEqual(progress.phase, .stopped)
                try expectEqual(progress.booksDone, 1)
                let journalURL = try expectNotNil(RefreshJournal.latestJournalURL(in: dir.appendingPathComponent("jr")))
                var summary = try expectNotNil(RefreshJournal.summarize(at: journalURL))
                try expectFalse(summary.interrupted, "batch-stop is a settled terminal event")
                try expectEqual(summary.lastEvent, RefreshJournalEventName.batchStop)

                engine.perBookHook = nil
                let resumed = await engine.resume()
                try expectTrue(resumed)
                progress = engine.currentProgress()
                try expectEqual(progress.phase, .completed)
                try expectEqual(progress.booksDone, 3)
                summary = try expectNotNil(RefreshJournal.summarize(at: journalURL))
                try expectEqual(summary.booksSettled, 3)
                try expectEqual(summary.lastEvent, RefreshJournalEventName.batchComplete)
                try expectEqual(try store.allBooks().reduce(0) { $0 + $1.pageCount }, 3,
                                "no duplicate page rows after stop+resume")
            },

            // 断言10：暂停态直接停止——无在跑书，直接收摊（补 batch-stop 终态行）。
            TestDesc(suite: "RefreshConsole", name: "engineStopFromPausedSettlesImmediately") {
                let dir = Fixtures.makeTempDir("refresh-stop-paused")
                defer { Fixtures.cleanup(dir) }
                let (_, books) = try await makeLibrary(dir)
                let ledger = try writeLedger(dir, try standardRows(books))
                let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                           snapshotDir: dir.appendingPathComponent("snap"),
                                           journalDir: dir.appendingPathComponent("jr"))
                let plan = try engine.loadLedger(ledger)
                engine.perBookHook = { index in if index == 0 { engine.pause() } }
                _ = await engine.start(plan: plan)
                try expectEqual(engine.currentProgress().phase, .paused)
                engine.perBookHook = nil
                engine.stop()
                try expectEqual(engine.currentProgress().phase, .stopped)
                let journalURL = try expectNotNil(RefreshJournal.latestJournalURL(in: dir.appendingPathComponent("jr")))
                let summary = try expectNotNil(RefreshJournal.summarize(at: journalURL))
                try expectFalse(summary.interrupted)
                try expectEqual(summary.lastEvent, RefreshJournalEventName.batchStop)
            },

            // ================= 备份失败不开跑（fail-closed） =================

            // 断言11：库文件缺失 → 备份失败 → 不开跑：phase 回 idle、lastError
            // 非空、journal 目录零文件（batch-start 都不落）。
            TestDesc(suite: "RefreshConsole", name: "engineBackupFailureBlocksStart") {
                let dir = Fixtures.makeTempDir("refresh-backupfail")
                defer { Fixtures.cleanup(dir) }
                let journalDir = dir.appendingPathComponent("jr")
                let engine = RefreshEngine(dbURL: dir.appendingPathComponent("missing-index.db"),
                                           snapshotDir: dir.appendingPathComponent("snap"),
                                           journalDir: journalDir)
                let plan = RefreshEngine.BatchPlan(ledgerPath: "/tmp/none.jsonl",
                                                   books: [.init(bookID: "x", src: "/none/x.pdf",
                                                                 shaExpect: "aa", declaredPages: 1,
                                                                 fileName: "x.pdf", title: nil)],
                                                   unresolvedSources: [])
                let started = await engine.start(plan: plan)
                try expectFalse(started, "backup failure must block start (fail-closed)")
                let progress = engine.currentProgress()
                try expectEqual(progress.phase, .idle)
                try expectNotNil(progress.lastError)
                try expectEqual(journalFileCount(journalDir), 0, "no journal may be written")
            },

            // 断言12：备份建新删旧——先手备一份，再开批：快照目录仍恰 1 份且
            // 为新名（keep=1 语义照旧）。
            TestDesc(suite: "RefreshConsole", name: "engineBackupKeepsSingleSnapshot") {
                let dir = Fixtures.makeTempDir("refresh-keep1")
                defer { Fixtures.cleanup(dir) }
                _ = try await makeLibrary(dir)
                let snapDir = dir.appendingPathComponent("snap")
                let dbURL = dir.appendingPathComponent("index.db")
                let manual = try SnapshotManager(snapshotDir: snapDir,
                                                 sources: [("index", dbURL)]).takeSnapshot()
                try await Task.sleep(nanoseconds: 1_100_000_000)
                let engine = RefreshEngine(dbURL: dbURL,
                                           snapshotDir: snapDir,
                                           journalDir: dir.appendingPathComponent("jr"))
                let books = try Fixtures.openStore(in: dir).allBooks().sorted { $0.fileName < $1.fileName }
                let ledger = try writeLedger(dir, try standardRows(books))
                let plan = try engine.loadLedger(ledger)
                try expectEqual(plan.books.count, 3)
                _ = await engine.start(plan: plan)
                try expectEqual(engine.currentProgress().phase, .completed)
                let snapshots = SnapshotManager(snapshotDir: snapDir, sources: []).listSnapshots()
                try expectEqual(snapshots.count, 1, "keep=1: new backup replaces the old one")
                try expectTrue(snapshots[0].lastPathComponent != manual.lastPathComponent,
                               "remaining snapshot must be the newer one")
            },

            // ================= 面板 Store 发布面（主线程镜像） =================

            // 断言13：Store 载入终账→计划发布（注入临时目录，引擎/发布全程零写
            // 真实 Application Support）；空清单 → 计划为空＋消息提示（空态引导）。
            TestDesc(suite: "RefreshConsole", name: "storeLoadsLedgerPublishesPlan") {
                let dir = Fixtures.makeTempDir("refresh-store")
                defer { Fixtures.cleanup(dir) }
                _ = try await makeLibrary(dir)
                let store = RefreshConsoleStore(dbURL: dir.appendingPathComponent("index.db"),
                                                snapshotDir: dir.appendingPathComponent("snap"),
                                                journalDir: dir.appendingPathComponent("jr"))
                let books = try Fixtures.openStore(in: dir).allBooks().sorted { $0.fileName < $1.fileName }
                // 空清单（零适用行）先行：计划发布但 books 空——面板空态。
                let emptyLedger = try writeLedger(dir, [(src: "/none/e.pdf", shaAfter: nil, pages: 1)])
                store.loadLedger(at: emptyLedger)
                _ = try await drainAndPoll({ store.plan?.books.count ?? -1 }, until: { $0 == 0 })
                try expectTrue((store.plan?.books.isEmpty) == true)
                try expectTrue(!store.message.isEmpty, "empty-plan guidance message must be set")

                // 实清单：3 本全配对。
                let ledger = try writeLedger(dir, try standardRows(books))
                store.loadLedger(at: ledger)
                let plan = try await drainAndPoll({ store.plan }, until: { $0?.books.count == 3 })
                try expectEqual(try expectNotNil(plan).books.count, 3)
                try expectEqual(store.phase, .idle)
                try expectTrue(store.journalSummary == nil, "no journal exists yet (read-only status)")
                // 空转期间零 journal、零快照（只读载入零写库）。
                try expectEqual(journalFileCount(dir.appendingPathComponent("jr")), 0)
                try expectEqual(SnapshotManager(snapshotDir: dir.appendingPathComponent("snap"),
                                                sources: []).listSnapshots().count, 0)
            },

            // 断言14：Store 全批端到端（引擎在后台跑、发布面主线程镜像）：载入→
            // start→completed；journalSummary 刷新后可读出「已收尾」。
            TestDesc(suite: "RefreshConsole", name: "storeStartCompletesAndJournalReadable") {
                let dir = Fixtures.makeTempDir("refresh-store-e2e")
                defer { Fixtures.cleanup(dir) }
                _ = try await makeLibrary(dir)
                let store = RefreshConsoleStore(dbURL: dir.appendingPathComponent("index.db"),
                                                snapshotDir: dir.appendingPathComponent("snap"),
                                                journalDir: dir.appendingPathComponent("jr"))
                let books = try Fixtures.openStore(in: dir).allBooks().sorted { $0.fileName < $1.fileName }
                let ledger = try writeLedger(dir, try standardRows(books))
                store.loadLedger(at: ledger)
                _ = try await drainAndPoll({ store.plan?.books.count ?? -1 }, until: { $0 == 3 })
                store.start()
                let phase = try await drainAndPoll({ store.phase },
                                                    until: { $0 == .completed })
                try expectEqual(phase, .completed)
                try expectEqual(store.progress.booksDone + store.progress.booksFailed, 3)
                store.refreshJournalStatus()
                let summary = try await drainAndPoll({ store.journalSummary },
                                                      until: { $0 != nil })
                try expectFalse(try expectNotNil(summary).interrupted)
                try expectEqual(try expectNotNil(summary).booksSettled, 3)
            },

        ]
    }
}
