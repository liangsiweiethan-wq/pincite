import Foundation
import Darwin
@testable import LiteratureCore
@testable import LiteratureSearchUI

// MARK: - 索引刷新控制台合并套件（索引刷新控制台的验收基准）

enum RefreshConsoleMergeSuite {

    // MARK: 助手

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

    /// 可配书数的同款夹具（超样本数场景需「已结算书数 >
    /// auditProbeSampleSize」；合成件与 makeLibrary 同款，仅书数不同）。
    private static func makeLibrary(_ dir: URL, books count: Int) async throws -> (IndexStore, [IndexStore.BookRow]) {
        for n in 1...count {
            Fixtures.makePDF(pages: [.init(lines: ["刷新批 第\(n)书 基线内容标记词\(n)。"])],
                             in: dir, named: "book\(n).pdf")
        }
        let store = try Fixtures.openStore(in: dir)
        let engine = IndexingEngine(store: store, policy: ExclusionPolicy())
        let run = try await engine.run(rootURL: dir)
        precondition(run.indexedNew == count, "fixture library must index \(count) books")
        let books = try store.allBooks().sorted { $0.fileName < $1.fileName }
        precondition(books.count == count)
        return (store, books)
    }

    private static func makePlanBooks(_ books: [IndexStore.BookRow]) -> [RefreshEngine.PlanBook] {
        books.map {
            RefreshEngine.PlanBook(bookID: $0.id, src: $0.realPath, shaExpect: nil,
                                   declaredPages: $0.pageCount, fileName: $0.fileName, title: $0.title)
        }
    }

    private static func settledEvents(_ events: [RefreshJournalEvent]) -> [RefreshJournalEvent] {
        events.filter {
            [RefreshJournalEventName.bookDone, RefreshJournalEventName.bookSkip,
             RefreshJournalEventName.bookFail].contains($0.event)
        }
    }

    /// 捕获抛错并取文案（fail-closed 测试须断言错误指向人工核查；
    /// 不抛返回 nil——调用方先经 expectNotNil 判「必须抛」，故无恒真风险）。
    private static func throwMessage(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch { return (error as NSError).localizedDescription }
    }

    /// 捕获抛错并返回原始 NSError：精确错误码断言须拿
    /// `code` 字段——文案断言挡不住「改错错误码仍绿」的判别力缺口）。
    /// 不抛返回 nil（调用方先经 expectNotNil 判「必须抛」）。
    private static func thrownError(_ body: () throws -> Void) -> NSError? {
        do { try body(); return nil } catch { return error as NSError }
    }

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

    private static func drainAndPoll<T>(_ probe: () -> T,
                                        until predicate: (T) -> Bool,
                                        timeoutMs: Int = 6000) async throws -> T where T: Equatable {
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

    private static func journalFileCount(_ dir: URL) -> Int {
        RefreshJournal.journalURLs(in: dir).count
    }

    private static func sha8(_ file: URL) throws -> String {
        String(try Fingerprint.sha256Hex(ofFileAt: file).prefix(8))
    }

    /// 实际页行数（fulltext pages 表 COUNT，不使用 books.page_count
    /// 总和冒充页行检查）。
    static func pageRowCount(in dir: URL) throws -> Int {
        let store = try Fixtures.openStore(in: dir)
        let stmt = try store.db.prepare("SELECT COUNT(*) FROM \(store.ftQual)pages;")
        guard try stmt.step() else { return 0 }
        return Int(stmt.int(0))
    }

    /// 唯一页键数（book_id+page_number 去重——重复页行在此暴露）。
    static func uniquePageKeyCount(in dir: URL) throws -> Int {
        let store = try Fixtures.openStore(in: dir)
        let stmt = try store.db.prepare(
            "SELECT COUNT(*) FROM (SELECT DISTINCT book_id, page_number FROM \(store.ftQual)pages);")
        guard try stmt.step() else { return 0 }
        return Int(stmt.int(0))
    }

    static var tests: [TestDesc] {
        [
            // ================= -1 跨启动续跑 =================

            // 断言1：停止收摊后「换引擎实例」续跑（跨启动基准）——journal 重建
            // 计划与已完成集合；无快照不补备（已有）；续跑段恰跑余书
            // （book-start 总数 3 不是 5）、无重复页行、收尾 completed。
            TestDesc(suite: "RefreshConsoleMerge", name: "crossRestartResumeFromStoppedJournal") {
                let dir = Fixtures.makeTempDir("refresh-cross-restart")
                defer { Fixtures.cleanup(dir) }
                let (_, books) = try await makeLibrary(dir)
                // 清单 sha 用盘上真实值（三向对账基准：续跑收尾应 PASS）。
                let rows = try books.map { book -> (src: String, shaAfter: String?, pages: Int?) in
                    (src: book.realPath,
                     shaAfter: try Fingerprint.sha256Hex(ofFileAt: URL(fileURLWithPath: book.realPath)),
                     pages: book.pageCount)
                }
                let ledger = try writeLedger(dir, rows)
                let engine1 = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                            snapshotDir: dir.appendingPathComponent("snap"),
                                            journalDir: dir.appendingPathComponent("jr"))
                let plan = try engine1.loadLedger(ledger)
                engine1.perBookHook = { index in if index == 0 { engine1.stop() } }
                _ = await engine1.start(plan: plan)
                try expectEqual(engine1.currentProgress().phase, .stopped)
                // batch-start 首事件内嵌完整计划＋版本号。
                let journalURL0 = try expectNotNil(RefreshJournal.latestJournalURL(in: dir.appendingPathComponent("jr")))
                let events0 = RefreshJournal.readEvents(at: journalURL0)
                try expectEqual(events0.first?.event, RefreshJournalEventName.batchStart)
                try expectEqual(events0.first?.plan?.count, 3, "batch-start must embed the full plan")
                try expectEqual(events0.first?.plan?.map(\.bookID).sorted(),
                                books.map(\.id).sorted(),
                                "embedded plan must mirror the batch plan")
                try expectEqual(events0.first?.planVersion, RefreshJournal.currentPlanVersion)
                let snapshotCount = SnapshotManager(snapshotDir: dir.appendingPathComponent("snap"),
                                                    sources: []).listSnapshots().count

                // 「重启」：全新引擎实例（同库/同 journal 目录、零内存态）。
                let engine2 = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                            snapshotDir: dir.appendingPathComponent("snap"),
                                            journalDir: dir.appendingPathComponent("jr"))
                let resumable = try expectNotNil(engine2.loadResumableBatch())
                try expectEqual(resumable.pendingCount, 2)
                try expectEqual(resumable.completedBookIDs.count, 1)
                try expectEqual(resumable.batchID.count > 0, true)
                let resumed = await engine2.resumeLastBatch()
                try expectTrue(resumed)
                let progress = engine2.currentProgress()
                try expectEqual(progress.phase, .completed)
                try expectEqual(progress.booksDone + progress.booksFailed, 3)
                // 无重复页行；续跑段只处理剩余书目。
                try expectEqual(try Self.pageRowCount(in: dir), 3)
                try expectEqual(try Self.uniquePageKeyCount(in: dir), 3)
                // 续跑段恰跑余书：book-start 事件总数 3（1＋2），不是 5。
                let journalURL = try expectNotNil(RefreshJournal.latestJournalURL(in: dir.appendingPathComponent("jr")))
                let events = RefreshJournal.readEvents(at: journalURL)
                try expectEqual(events.filter { $0.event == RefreshJournalEventName.bookStart }.count, 3)
                try expectEqual(events.last?.event, RefreshJournalEventName.batchComplete)
                // 已有快照不补备（份数不变）。
                try expectEqual(SnapshotManager(snapshotDir: dir.appendingPathComponent("snap"),
                                                sources: []).listSnapshots().count, snapshotCount)
                // 三向对账 PASS（清单 sha 用盘上真实值）。
                try expectEqual(progress.phase, .completed,
                                "three-way PASS after cross-restart resume, got \(progress.phase)")
            },

            // 断言2：崩溃形态（journal 无终态事件）跨启动续跑——计划已随
            // batch-start 持久化＝唯一重建源；旧版无计划
            // journal 一律问题，绝不按 book-start 反推（会漏掉从未开跑的书）。
            TestDesc(suite: "RefreshConsoleMerge", name: "crashJournalResumeWithAndWithoutLedger") {
                let dir = Fixtures.makeTempDir("refresh-crash-resume")
                defer { Fixtures.cleanup(dir) }
                let (_, books) = try await makeLibrary(dir)
                let ledger = try writeLedger(dir, books.map { (src: $0.realPath, shaAfter: "bb", pages: 1) })
                func journalPlan(_ rows: [IndexStore.BookRow]) -> [JournalPlanBook] {
                    rows.map { JournalPlanBook(bookID: $0.id, src: $0.realPath, shaExpect: "bb",
                                               declaredPages: 1, fileName: $0.fileName, title: $0.title) }
                }

                let writerA = try RefreshJournal.Writer(directory: dir.appendingPathComponent("jr"),
                                                        batchID: "20261015-110000")
                try writerA.append(RefreshJournalEvent(event: RefreshJournalEventName.batchStart,
                                                       batchID: "20261015-110000",
                                                       ledger: ledger.path,
                                                       booksTotal: 3,
                                                       plan: journalPlan(books),
                                                       planVersion: RefreshJournal.currentPlanVersion))
                try writerA.append(RefreshJournalEvent(event: RefreshJournalEventName.bookDone,
                                                       batchID: "20261015-110000",
                                                       bookID: books[0].id,
                                                       src: books[0].realPath,
                                                       pages: 1, verdict: "updated"))
                let engineA = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                            snapshotDir: dir.appendingPathComponent("snap"),
                                            journalDir: dir.appendingPathComponent("jr"))
                let resumableA = try expectNotNil(engineA.loadResumableBatch())
                try expectTrue(resumableA.plan.ledgerPath.contains("重建清单样例"))
                try expectTrue(resumableA.plan.books.allSatisfy { $0.declaredPages == 1 })
                try expectEqual(resumableA.pendingCount, 2, "never-started books must be pending")
                try expectNil(engineA.lastResumableBlockReason())
                _ = await engineA.resumeLastBatch()
                let phaseA = engineA.currentProgress().phase
                try expectTrue(phaseA == .completed || phaseA == .completedWithResidue,
                               "resume must finish the batch family, got \(phaseA)")
                try expectEqual(try Self.pageRowCount(in: dir), 3)
                try expectEqual(try Self.uniquePageKeyCount(in: dir), 3)

                // 场景 B（问题）：旧版 journal（batch-start 无计划
                // 载荷）——不再按 book-start 反推；问题续跑、原因可读、不动 journal。
                // journal 形态＝崩溃前 3 本都已 book-start、前 2 本已 book-done。
                let dirB = Fixtures.makeTempDir("refresh-crash-resume-noplan")
                defer { Fixtures.cleanup(dirB) }
                let (_, booksB) = try await makeLibrary(dirB)
                let writerB = try RefreshJournal.Writer(directory: dirB.appendingPathComponent("jr"),
                                                        batchID: "20261015-110001")
                try writerB.append(RefreshJournalEvent(event: RefreshJournalEventName.batchStart,
                                                       batchID: "20261015-110001",
                                                       ledger: "/nonexistent/终账.jsonl",
                                                       booksTotal: 3))
                for (i, book) in booksB.enumerated() {
                    try writerB.append(RefreshJournalEvent(event: RefreshJournalEventName.bookStart,
                                                           batchID: "20261015-110001",
                                                           bookID: book.id, src: book.realPath))
                    if i < 2 {
                        try writerB.append(RefreshJournalEvent(event: RefreshJournalEventName.bookDone,
                                                                batchID: "20261015-110001",
                                                                bookID: book.id,
                                                                pages: 1, verdict: "updated"))
                    }
                }
                let engineB = RefreshEngine(dbURL: dirB.appendingPathComponent("index.db"),
                                            snapshotDir: dirB.appendingPathComponent("snap"),
                                            journalDir: dirB.appendingPathComponent("jr"))
                try expectNil(engineB.loadResumableBatch(), "plan-less journal must block resume")
                let reasonB = try expectNotNil(engineB.lastResumableBlockReason(),
                                               "block reason must be human-readable")
                try expectTrue(reasonB.contains("阻断"))
                let resumedB = await engineB.resumeLastBatch()
                try expectFalse(resumedB)
                try expectEqual(engineB.currentProgress().phase, .idle)
                try expectNotNil(engineB.currentProgress().lastError,
                                 "block reason must land in lastError for the panel")
                // 问题即不动：journal 无 batch-resume、页行原样。
                let journalURLB = try expectNotNil(RefreshJournal.latestJournalURL(in: dirB.appendingPathComponent("jr")))
                let eventsB = RefreshJournal.readEvents(at: journalURLB)
                try expectFalse(eventsB.contains { $0.event == RefreshJournalEventName.batchResume },
                                "blocked resume must not append a batch-resume event")
                try expectEqual(try Self.pageRowCount(in: dirB), 3)
            },

            // 断言2b：崩溃发生在任何书开跑之前——计划已随
            // batch-start 持久化 ⇒ 续跑必须把全部书跑完，绝不能把「无
            // book-start」当成「无待跑」。
            TestDesc(suite: "RefreshConsoleMerge", name: "crashBeforeAnyBookStartedResumesAll") {
                let dir = Fixtures.makeTempDir("refresh-crash-prestart")
                defer { Fixtures.cleanup(dir) }
                let (_, books) = try await makeLibrary(dir)
                // 清单与计划都用盘上真实 sha（续跑收尾三向对账应 PASS）。
                var ledgerRows: [(src: String, shaAfter: String?, pages: Int?)] = []
                var planRows: [JournalPlanBook] = []
                for book in books {
                    let sha = try Fingerprint.sha256Hex(ofFileAt: URL(fileURLWithPath: book.realPath))
                    ledgerRows.append((src: book.realPath, shaAfter: sha, pages: book.pageCount))
                    planRows.append(JournalPlanBook(bookID: book.id, src: book.realPath,
                                                    shaExpect: sha, declaredPages: book.pageCount,
                                                    fileName: book.fileName, title: book.title))
                }
                let ledger = try writeLedger(dir, ledgerRows)
                let writer = try RefreshJournal.Writer(directory: dir.appendingPathComponent("jr"),
                                                       batchID: "20261015-120000")
                try writer.append(RefreshJournalEvent(event: RefreshJournalEventName.batchStart,
                                                      batchID: "20261015-120000",
                                                      ledger: ledger.path,
                                                      booksTotal: 3,
                                                      plan: planRows,
                                                      planVersion: RefreshJournal.currentPlanVersion))
                let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                           snapshotDir: dir.appendingPathComponent("snap"),
                                           journalDir: dir.appendingPathComponent("jr"))
                let resumable = try expectNotNil(engine.loadResumableBatch())
                try expectEqual(resumable.pendingCount, 3, "all books pending — none ever started")
                try expectEqual(resumable.completedBookIDs.count, 0)
                let resumed = await engine.resumeLastBatch()
                try expectTrue(resumed)
                let progress = engine.currentProgress()
                try expectEqual(progress.phase, .completed, "three-way PASS with real shas")
                try expectEqual(progress.booksDone + progress.booksFailed, 3)
                try expectEqual(try Self.pageRowCount(in: dir), 3)
                try expectEqual(try Self.uniquePageKeyCount(in: dir), 3)
                // 续跑段恰跑全部书：book-start 3 条、终态 batch-complete。
                let journalURL = try expectNotNil(RefreshJournal.latestJournalURL(in: dir.appendingPathComponent("jr")))
                let events = RefreshJournal.readEvents(at: journalURL)
                try expectEqual(events.filter { $0.event == RefreshJournalEventName.bookStart }.count, 3)
                try expectEqual(events.last?.event, RefreshJournalEventName.batchComplete)
            },

            TestDesc(suite: "RefreshConsoleMerge", name: "resumeBlockedOnInconsistentJournal") {
                func makeScenario(_ name: String) async throws
                    -> (dir: URL, books: [IndexStore.BookRow], engine: RefreshEngine) {
                    let dir = Fixtures.makeTempDir(name)
                    let (_, books) = try await makeLibrary(dir)
                    let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                                snapshotDir: dir.appendingPathComponent("snap"),
                                                journalDir: dir.appendingPathComponent("jr"))
                    return (dir, books, engine)
                }
                func planPayload(_ books: [IndexStore.BookRow]) -> [JournalPlanBook] {
                    books.map { JournalPlanBook(bookID: $0.id, src: $0.realPath, shaExpect: "cc",
                                                declaredPages: 1, fileName: $0.fileName, title: $0.title) }
                }

                let s1 = try await makeScenario("refresh-block-count")
                defer { Fixtures.cleanup(s1.dir) }
                let w1 = try RefreshJournal.Writer(directory: s1.dir.appendingPathComponent("jr"),
                                                   batchID: "20261015-130000")
                try w1.append(RefreshJournalEvent(event: RefreshJournalEventName.batchStart,
                                                  batchID: "20261015-130000",
                                                  booksTotal: 3,
                                                  plan: planPayload(Array(s1.books.prefix(2))),
                                                  planVersion: RefreshJournal.currentPlanVersion))
                try expectNil(s1.engine.loadResumableBatch())
                try expectTrue(s1.engine.lastResumableBlockReason()?.contains("不符") == true)

                let s2 = try await makeScenario("refresh-block-version")
                defer { Fixtures.cleanup(s2.dir) }
                let w2 = try RefreshJournal.Writer(directory: s2.dir.appendingPathComponent("jr"),
                                                   batchID: "20261015-130001")
                try w2.append(RefreshJournalEvent(event: RefreshJournalEventName.batchStart,
                                                  batchID: "20261015-130001",
                                                  booksTotal: 3,
                                                  plan: planPayload(s2.books),
                                                  planVersion: 99))
                try expectNil(s2.engine.loadResumableBatch())
                try expectTrue(s2.engine.lastResumableBlockReason()?.contains("版本") == true)

                let s3 = try await makeScenario("refresh-block-foreign")
                defer { Fixtures.cleanup(s3.dir) }
                let w3 = try RefreshJournal.Writer(directory: s3.dir.appendingPathComponent("jr"),
                                                   batchID: "20261015-130002")
                try w3.append(RefreshJournalEvent(event: RefreshJournalEventName.batchStart,
                                                  batchID: "20261015-130002",
                                                  booksTotal: 3,
                                                  plan: planPayload(s3.books),
                                                  planVersion: RefreshJournal.currentPlanVersion))
                try w3.append(RefreshJournalEvent(event: RefreshJournalEventName.bookDone,
                                                  batchID: "20261015-130002",
                                                  bookID: "计划外书", pages: 1, verdict: "updated"))
                try expectNil(s3.engine.loadResumableBatch())
                try expectTrue(s3.engine.lastResumableBlockReason()?.contains("计划外") == true)
            },

            // 断言3：journal 摘要 增补面——kind/ledgerPath/startedBooks 往返；
            // unfinished 语义（stopped 未收尾＝unfinished）。
            TestDesc(suite: "RefreshConsoleMerge", name: "journalSummaryKindLedgerStartedBooks") {
                let dir = Fixtures.makeTempDir("refresh-journal-summary")
                defer { Fixtures.cleanup(dir) }
                let writer = try RefreshJournal.Writer(directory: dir, batchID: "20261012-120000")
                try writer.append(RefreshJournalEvent(event: RefreshJournalEventName.batchStart,
                                                      batchID: "20261012-120000",
                                                      kind: "sync-repair",
                                                      ledger: "/tmp/repair-none",
                                                      booksTotal: 2))
                try writer.append(RefreshJournalEvent(event: RefreshJournalEventName.bookStart,
                                                      batchID: "20261012-120000",
                                                      bookID: "z1", src: "/书/甲.pdf", shaExpect: "abcd1234"))
                try writer.append(RefreshJournalEvent(event: RefreshJournalEventName.bookDone,
                                                      batchID: "20261012-120000",
                                                      bookID: "z1", verdict: "updated"))
                let url = dir.appendingPathComponent("20261012-120000.jsonl")
                var summary = try expectNotNil(RefreshJournal.summarize(at: url))
                try expectEqual(summary.kind, "sync-repair")
                try expectEqual(summary.ledgerPath, "/tmp/repair-none")
                try expectEqual(summary.startedBooks.count, 1)
                try expectEqual(summary.startedBooks[0].bookID, "z1")
                try expectEqual(summary.startedBooks[0].shaExpect, "abcd1234")
                try expectTrue(summary.interrupted)
                try expectTrue(summary.unfinished, "interrupted ⇒ unfinished")
                // batch-stop 后：不判 interrupted，但仍有书待跑 ⇒ unfinished。
                try writer.append(RefreshJournalEvent(event: RefreshJournalEventName.batchStop,
                                                      batchID: "20261012-120000"))
                summary = try expectNotNil(RefreshJournal.summarize(at: url))
                try expectFalse(summary.interrupted)
                try expectTrue(summary.unfinished, "stopped with pending books ⇒ unfinished")
                try expectEqual(summary.pendingCount, 1)
            },

            // ================= -2 同步对账（只读＋修复） =================

            TestDesc(suite: "RefreshConsoleMerge", name: "syncAuditReadOnlyThenRepair") {
                let dir = Fixtures.makeTempDir("refresh-audit")
                defer { Fixtures.cleanup(dir) }
                let (store, books) = try await makeLibrary(dir)
                // 窗口期基准：盘上改写第 1 本（库内指纹仍旧值）。
                let book1URL = URL(fileURLWithPath: books[0].realPath)
                try FileManager.default.removeItem(at: book1URL)
                Fixtures.makePDF(pages: [.init(lines: ["刷新批 第1书 结算后新内容。"])],
                                 in: book1URL.deletingLastPathComponent(), named: "book1.pdf")
                let dbURL = dir.appendingPathComponent("index.db")
                let engine = RefreshEngine(dbURL: dbURL,
                                            snapshotDir: dir.appendingPathComponent("snap"),
                                            journalDir: dir.appendingPathComponent("jr"))
                let beforeDB = try Data(contentsOf: dbURL)

                let audit = try engine.auditLibrary()
                try expectEqual(audit.audited, 3)
                try expectEqual(audit.matched, 2)
                try expectEqual(audit.differences.count, 1)
                let diff = audit.differences[0]
                try expectEqual(diff.issue, .mismatch)
                try expectEqual(diff.bookID, books[0].id)
                try expectNotEqual(diff.dbSha8, try sha8(book1URL))
                // 只读半步零写库：库文件字节级不变。
                try expectEqual(try Data(contentsOf: dbURL), beforeDB, "audit must not write the db")

                let repaired = await engine.repair(books: audit.repairable)
                try expectTrue(repaired)
                let progress = engine.currentProgress()
                try expectTrue(progress.phase == .completed || progress.phase == .completedWithResidue,
                               "repair batch should finish, got \(progress.phase)")
                try expectEqual(progress.batchKind, "sync-repair")
                // 库内指纹已跟上盘上（红条消除）。
                let row = try expectNotNil(try store.book(byID: books[0].id))
                try expectEqual(row.fingerprint, try Fingerprint.sha256Hex(ofFileAt: book1URL))
                // 复对账：零差异（无需修复基准）。
                let reAudit = try engine.auditLibrary()
                try expectTrue(reAudit.differences.isEmpty)
                // journal：sync-repair 批的 batch-start 带 kind。
                let journalURL = try expectNotNil(RefreshJournal.latestJournalURL(in: dir.appendingPathComponent("jr")))
                let events = RefreshJournal.readEvents(at: journalURL)
                try expectEqual(events.first?.kind, "sync-repair")
            },

            // 断言5：盘上文件缺失书的对账基准——missingFile 如实列，不进修复集。
            TestDesc(suite: "RefreshConsoleMerge", name: "syncAuditMissingFileNotRepairable") {
                let dir = Fixtures.makeTempDir("refresh-audit-missing")
                defer { Fixtures.cleanup(dir) }
                _ = try await makeLibrary(dir)
                let books = try Fixtures.openStore(in: dir).allBooks().sorted { $0.fileName < $1.fileName }
                try FileManager.default.removeItem(at: URL(fileURLWithPath: books[2].realPath))
                let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                            snapshotDir: dir.appendingPathComponent("snap"),
                                            journalDir: dir.appendingPathComponent("jr"))
                let audit = try engine.auditLibrary()
                try expectEqual(audit.missingFiles.count, 1)
                try expectEqual(audit.missingFiles[0].issue, .missingFile)
                try expectTrue(audit.repairable.isEmpty, "missing files are not repairable by reindex")
            },

            // 断言6：零差异对账——全套一致时 differences 空（面板「无需修复」源）。
            TestDesc(suite: "RefreshConsoleMerge", name: "syncAuditCleanLibrary") {
                let dir = Fixtures.makeTempDir("refresh-audit-clean")
                defer { Fixtures.cleanup(dir) }
                _ = try await makeLibrary(dir)
                let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                            snapshotDir: dir.appendingPathComponent("snap"),
                                            journalDir: dir.appendingPathComponent("jr"))
                let audit = try engine.auditLibrary()
                try expectEqual(audit.audited, 3)
                try expectTrue(audit.differences.isEmpty)
                try expectTrue(audit.repairable.isEmpty)
            },

            // ================= -3 窗口期状态（Store 三源合成） =================

            // 断言7：Store 窗口期状态——对账差异未修复＝active；修复完成后回落
            // inactive（对账差异驱动源；回调驱动零轮询）。
            TestDesc(suite: "RefreshConsoleMerge", name: "storeWindowPeriodTogglesWithAuditAndRepair") {
                let dir = Fixtures.makeTempDir("refresh-window")
                defer { Fixtures.cleanup(dir) }
                _ = try await makeLibrary(dir)
                let store = RefreshConsoleStore(dbURL: dir.appendingPathComponent("index.db"),
                                                snapshotDir: dir.appendingPathComponent("snap"),
                                                journalDir: dir.appendingPathComponent("jr"))
                try expectFalse(store.windowPeriodActive, "fresh store with no journal/audit ⇒ inactive")
                let books = try Fixtures.openStore(in: dir).allBooks().sorted { $0.fileName < $1.fileName }
                let book1URL = URL(fileURLWithPath: books[0].realPath)
                try FileManager.default.removeItem(at: book1URL)
                Fixtures.makePDF(pages: [.init(lines: ["窗口期 第1书 改写后内容。"])],
                                 in: book1URL.deletingLastPathComponent(), named: "book1.pdf")
                store.auditSync()
                _ = try await drainAndPoll({ store.auditResult?.differences.count ?? -1 }, until: { $0 == 1 })
                try expectTrue(store.windowPeriodActive, "unrepaired audit mismatch ⇒ active")
                store.repairDifferences()
                let done: (RefreshEngine.Phase) -> Bool = { $0 == .completed || $0 == .completedWithResidue }
                _ = try await drainAndPoll({ store.phase }, until: done)
                _ = try await drainAndPoll({ store.windowPeriodActive }, until: { $0 == false })
                try expectTrue(store.repairedBookIDs.contains(books[0].id))
                try expectTrue(store.auditDiffText().contains(L10n.indexRefreshAuditRepairedMark))
            },

            // ================= -4 页级进度＋ETA＋撞名 =================

            // 断言8：页级进度回调与速率/ETA 快照——改写书抽取期间逐页发布；
            // 终态快照含 pagesSettled/rate；formatDuration 基准。
            TestDesc(suite: "RefreshConsoleMerge", name: "pageProgressAndEtaSnapshots") {
                let dir = Fixtures.makeTempDir("refresh-pageprogress")
                defer { Fixtures.cleanup(dir) }
                let (_, books) = try await makeLibrary(dir)
                let book1URL = URL(fileURLWithPath: books[0].realPath)
                try FileManager.default.removeItem(at: book1URL)
                Fixtures.makePDF(pages: [.init(lines: ["页级进度 第1书 结算后新内容。"])],
                                 in: book1URL.deletingLastPathComponent(), named: "book1.pdf")
                let ledger = try writeLedger(dir, books.map { (src: $0.realPath, shaAfter: "cc", pages: 1) })
                let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                            snapshotDir: dir.appendingPathComponent("snap"),
                                            journalDir: dir.appendingPathComponent("jr"))
                let plan = try engine.loadLedger(ledger)
                let box = ProgressBox()
                engine.onUpdate = { snapshot in box.record(snapshot) }
                _ = await engine.start(plan: plan)
                let snapshots = box.all()
                try expectTrue(!snapshots.isEmpty)
                // 页级回调曾发布（当前书页计数非 nil 的中间快照存在）。
                try expectTrue(snapshots.contains { $0.currentBookPagesDone != nil },
                               "per-page progress must be published during extraction")
                let final = engine.currentProgress()
                try expectEqual(final.pagesSettled, 3)
                try expectNotNil(final.ratePagesPerSecond)
                // 视图侧时长格式（mm:ss / h:mm:ss）。
                try expectEqual(formatDurationProbe(75), "1:15")
                try expectEqual(formatDurationProbe(3675), "1:01:15")
            },

                // 同秒撞名时为唯一名称添加数字后缀；
            // 同秒二开批不混入既有 journal 文件。
            TestDesc(suite: "RefreshConsoleMerge", name: "journalSameSecondCollisionGuard") {
                let dir = Fixtures.makeTempDir("refresh-collision")
                defer { Fixtures.cleanup(dir) }
                let sameInstant = Date(timeIntervalSince1970: 1_766_000_000)
                let base = RefreshJournal.makeBatchID(for: sameInstant)
                _ = try RefreshJournal.Writer(directory: dir, batchID: base)
                let unique = RefreshJournal.uniqueBatchID(in: dir, for: sameInstant)
                try expectEqual(unique, base + "-2")
                _ = try RefreshJournal.Writer(directory: dir, batchID: base + "-2")
                try expectEqual(RefreshJournal.uniqueBatchID(in: dir, for: sameInstant), base + "-3")
                let dir2 = Fixtures.makeTempDir("refresh-collision-run")
                defer { Fixtures.cleanup(dir2) }
                let (_, books) = try await makeLibrary(dir2)
                let ledger = try writeLedger(dir2, books.map { (src: $0.realPath, shaAfter: "dd", pages: 1) })
                let engine = RefreshEngine(dbURL: dir2.appendingPathComponent("index.db"),
                                            snapshotDir: dir2.appendingPathComponent("snap"),
                                            journalDir: dir2.appendingPathComponent("jr"))
                let plan = try engine.loadLedger(ledger)
                _ = await engine.start(plan: plan)
                let id1 = engine.currentProgress().batchID ?? ""
                _ = await engine.start(plan: plan)
                let id2 = engine.currentProgress().batchID ?? ""
                try expectNotEqual(id1, id2, "same-second restart must yield a distinct batch id")
                let journalURL = try expectNotNil(RefreshJournal.latestJournalURL(in: dir2.appendingPathComponent("jr")))
                let events = RefreshJournal.readEvents(at: journalURL)
                try expectEqual(events.filter { $0.event == RefreshJournalEventName.batchStart }.count, 1,
                                "new batch journal must not append into an existing batch file")
                try expectEqual(journalFileCount(dir2.appendingPathComponent("jr")), 1)
            },

            // ================= -7 批间只读抽验 =================

            TestDesc(suite: "RefreshConsoleMerge", name: "interBatchProbePasses") {
                let dir = Fixtures.makeTempDir("refresh-probe-pass")
                defer { Fixtures.cleanup(dir) }
                let (_, books) = try await makeLibrary(dir)
                let ledger = try writeLedger(dir, books.map { (src: $0.realPath, shaAfter: nil, pages: 1) })
                // sha_after nil 不进计划——用 force 型计划：直接拿库行建计划。
                let planBooks = books.map {
                    RefreshEngine.PlanBook(bookID: $0.id, src: $0.realPath, shaExpect: nil,
                                           declaredPages: $0.pageCount, fileName: $0.fileName, title: $0.title)
                }
                let plan = RefreshEngine.BatchPlan(ledgerPath: ledger.path, books: planBooks,
                                                   unresolvedSources: [])
                let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                            snapshotDir: dir.appendingPathComponent("snap"),
                                            journalDir: dir.appendingPathComponent("jr"))
                engine.auditProbeInterval = 1   // 测试注入点（密闭化说明；生产 50）
                _ = await engine.start(plan: plan)
                try expectEqual(engine.currentProgress().phase, .completed)
                let journalURL = try expectNotNil(RefreshJournal.latestJournalURL(in: dir.appendingPathComponent("jr")))
                let events = RefreshJournal.readEvents(at: journalURL)
                try expectTrue(events.contains { $0.event == RefreshJournalEventName.auditPass },
                               "probe must pass and journal it")
            },

            TestDesc(suite: "RefreshConsoleMerge", name: "interBatchProbeFailurePausesBatch") {
                let dir = Fixtures.makeTempDir("refresh-probe-fail")
                defer { Fixtures.cleanup(dir) }
                let (_, books) = try await makeLibrary(dir)
                // 开跑前删第 2 本：其 reindex 判 missing（书级失败），
                // 抽验样本含它 → 「盘上文件缺失」→ audit-fail → 自动暂停。
                try FileManager.default.removeItem(at: URL(fileURLWithPath: books[1].realPath))
                let planBooks = books.map {
                    RefreshEngine.PlanBook(bookID: $0.id, src: $0.realPath, shaExpect: nil,
                                           declaredPages: $0.pageCount, fileName: $0.fileName, title: $0.title)
                }
                let plan = RefreshEngine.BatchPlan(ledgerPath: "/tmp/none.jsonl", books: planBooks,
                                                   unresolvedSources: [])
                let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                            snapshotDir: dir.appendingPathComponent("snap"),
                                            journalDir: dir.appendingPathComponent("jr"))
                engine.auditProbeInterval = 1
                _ = await engine.start(plan: plan)
                let progress = engine.currentProgress()
                try expectEqual(progress.phase, .paused, "probe failure must auto-pause (no further writes)")
                try expectTrue(progress.failed.contains { $0.bookID == "audit-probe" },
                               "probe failure must land in the error list")
                let journalURL = try expectNotNil(RefreshJournal.latestJournalURL(in: dir.appendingPathComponent("jr")))
                let events = RefreshJournal.readEvents(at: journalURL)
                try expectTrue(events.contains { $0.event == RefreshJournalEventName.auditFail })
                try expectTrue(events.contains { $0.event == RefreshJournalEventName.batchPause })
                // 抽验失败后暂停，避免开始处理下一本书。
                try expectFalse(events.contains { $0.event == RefreshJournalEventName.bookStart
                                                   && $0.bookID == books[2].id },
                                "next book must not start after audit-fail pause")
            },

            // ================= -8 收尾三向对账 =================

            // 断言12：三向对账 PASS——清单 sha_after 用盘上真实 sha；全批完成
            // 后 finalCheck.pass、phase completed、journal 落 batch-finalize。
            TestDesc(suite: "RefreshConsoleMerge", name: "finalThreeWayCheckPass") {
                let dir = Fixtures.makeTempDir("refresh-final-pass")
                defer { Fixtures.cleanup(dir) }
                let (_, books) = try await makeLibrary(dir)
                let rows = try books.map { book -> (src: String, shaAfter: String?, pages: Int?) in
                    (src: book.realPath,
                     shaAfter: try Fingerprint.sha256Hex(ofFileAt: URL(fileURLWithPath: book.realPath)),
                     pages: book.pageCount)
                }
                let ledger = try writeLedger(dir, rows)
                let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                            snapshotDir: dir.appendingPathComponent("snap"),
                                            journalDir: dir.appendingPathComponent("jr"))
                let plan = try engine.loadLedger(ledger)
                _ = await engine.start(plan: plan)
                let progress = engine.currentProgress()
                try expectEqual(progress.phase, .completed, "three-way PASS ⇒ completed (banner may clear)")
                let check = try expectNotNil(progress.finalCheck)
                try expectTrue(check.pass)
                try expectEqual(check.booksOk, 3)
                try expectEqual(check.shaMismatch, 0)
                let journalURL = try expectNotNil(RefreshJournal.latestJournalURL(in: dir.appendingPathComponent("jr")))
                let events = RefreshJournal.readEvents(at: journalURL)
                let finalize = events.first { $0.event == RefreshJournalEventName.batchFinalize }
                try expectNotNil(finalize)
                try expectEqual(finalize?.checkBooksOk, 3)
                try expectEqual(finalize?.checkShaMismatch, 0)
            },

            // 断言13：三向对账有差异——清单 sha 与盘上不符 → completedWithResidue
            //（横幅不消）、差异行 reasons 如实列、batch-finalize 记 check_failed。
            TestDesc(suite: "RefreshConsoleMerge", name: "finalThreeWayCheckResidue") {
                let dir = Fixtures.makeTempDir("refresh-final-residue")
                defer { Fixtures.cleanup(dir) }
                let (_, books) = try await makeLibrary(dir)
                // 第 2 本书清单 sha 故意写错（模拟终账与盘上不同步）。
                var rows: [(src: String, shaAfter: String?, pages: Int?)] = []
                for (i, book) in books.enumerated() {
                    let sha = i == 1 ? "deadbeef" : try Fingerprint.sha256Hex(ofFileAt: URL(fileURLWithPath: book.realPath))
                    rows.append((src: book.realPath, shaAfter: sha, pages: book.pageCount))
                }
                let ledger = try writeLedger(dir, rows)
                let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                            snapshotDir: dir.appendingPathComponent("snap"),
                                            journalDir: dir.appendingPathComponent("jr"))
                let plan = try engine.loadLedger(ledger)
                _ = await engine.start(plan: plan)
                let progress = engine.currentProgress()
                try expectEqual(progress.phase, .completedWithResidue,
                                "residue must keep the batch in completedWithResidue (banner stays)")
                let check = try expectNotNil(progress.finalCheck)
                try expectFalse(check.pass)
                try expectEqual(check.booksFailed, 1)
                let bad = check.rows.first { !$0.ok }
                try expectNotNil(bad)
                try expectTrue(bad?.reasons.joined().contains("清单") == true,
                               "residue reason must name the ledger mismatch")
                let journalURL = try expectNotNil(RefreshJournal.latestJournalURL(in: dir.appendingPathComponent("jr")))
                let finalize = RefreshJournal.readEvents(at: journalURL)
                    .first { $0.event == RefreshJournalEventName.batchFinalize }
                try expectEqual(finalize?.checkBooksFailed, 1)
            },

            // ================= -6 基线轮换（Core＋CLI） =================





            // ================= 补充断言 =================

            // 回归断言1：崩溃 torn write 留半行——读侧按有效前缀截断、
            // 写侧续写前修复截尾；续跑事件须可读、再重启后状态一致。
            TestDesc(suite: "RefreshConsoleMerge", name: "journalTruncatedTailIsRepairedOnResume") {
                let dir = Fixtures.makeTempDir("refresh-torn-tail")
                defer { Fixtures.cleanup(dir) }
                let (_, books) = try await makeLibrary(dir)
                let planRows = books.map {
                    JournalPlanBook(bookID: $0.id, src: $0.realPath, shaExpect: nil,
                                    declaredPages: $0.pageCount, fileName: $0.fileName, title: $0.title)
                }
                let jr = dir.appendingPathComponent("jr")
                let writer = try RefreshJournal.Writer(directory: jr, batchID: "20261015-140000")
                try writer.append(RefreshJournalEvent(event: RefreshJournalEventName.batchStart,
                                                      batchID: "20261015-140000",
                                                      booksTotal: 3,
                                                      plan: planRows,
                                                      planVersion: RefreshJournal.currentPlanVersion))
                try writer.append(RefreshJournalEvent(event: RefreshJournalEventName.bookDone,
                                                      batchID: "20261015-140000",
                                                      bookID: books[0].id, src: books[0].realPath,
                                                      pages: 1, verdict: "updated"))
                // 模拟崩溃 torn write：无换行的半行 JSON＋一段截断 UTF-8 字节。
                let journalURL = jr.appendingPathComponent("20261015-140000.jsonl")
                let handle = try FileHandle(forWritingTo: journalURL)
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: Data("{\"event\":\"book-st".utf8))
                try handle.write(contentsOf: Data([0xE6, 0xB3, 0x00]))
                try handle.close()
                // 读侧：截尾被识别，有效前缀（计划＋1 书完成）仍可读。
                let read0 = RefreshJournal.readEventsDetailed(at: journalURL)
                try expectTrue(read0.truncated, "torn tail must be detected")
                try expectEqual(read0.events.count, 2)
                let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                           snapshotDir: dir.appendingPathComponent("snap"),
                                           journalDir: jr)
                let resumable = try expectNotNil(engine.loadResumableBatch())
                try expectEqual(resumable.pendingCount, 2)
                _ = await engine.resumeLastBatch()
                try expectEqual(engine.currentProgress().phase, .completed)
                let read1 = RefreshJournal.readEventsDetailed(at: journalURL)
                try expectFalse(read1.truncated, "tail must be repaired before append")
                try expectTrue(read1.events.contains { $0.event == RefreshJournalEventName.batchResume })
                try expectEqual(read1.events.last?.event, RefreshJournalEventName.batchComplete)
                try expectFalse(try Data(contentsOf: journalURL).contains(0),
                                "torn bytes (NUL from truncated UTF-8) must be gone after repair")
                let engine2 = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                            snapshotDir: dir.appendingPathComponent("snap"),
                                            journalDir: jr)
                try expectNil(engine2.loadResumableBatch())
            },

            // 回归断言2：事件流完整性——双 batch-start / 事件号与文件名
            // 不符 / book-start 缺 src，一律问题续跑。
            TestDesc(suite: "RefreshConsoleMerge", name: "journalIntegrityBlocksBadStreams") {
                func scenario(_ name: String, fileBatchID: String,
                              extras: (RefreshJournal.Writer, [IndexStore.BookRow]) throws -> Void) async throws
                    -> (dir: URL, engine: RefreshEngine) {
                    let dir = Fixtures.makeTempDir(name)
                    let (_, books) = try await makeLibrary(dir)
                    let plan = books.map {
                        JournalPlanBook(bookID: $0.id, src: $0.realPath, shaExpect: nil,
                                        declaredPages: 1, fileName: $0.fileName, title: nil)
                    }
                    let w = try RefreshJournal.Writer(directory: dir.appendingPathComponent("jr"),
                                                      batchID: fileBatchID)
                    try w.append(RefreshJournalEvent(event: RefreshJournalEventName.batchStart,
                                                     batchID: fileBatchID, booksTotal: 3,
                                                     plan: plan,
                                                     planVersion: RefreshJournal.currentPlanVersion))
                    try extras(w, books)
                    let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                               snapshotDir: dir.appendingPathComponent("snap"),
                                               journalDir: dir.appendingPathComponent("jr"))
                    return (dir, engine)
                }

                let s1 = try await scenario("refresh-integ-dupstart", fileBatchID: "20261015-150000") { w, _ in
                    try w.append(RefreshJournalEvent(event: RefreshJournalEventName.batchStart,
                                                     batchID: "20261015-150000", booksTotal: 3))
                }
                defer { Fixtures.cleanup(s1.dir) }
                try expectNil(s1.engine.loadResumableBatch())
                try expectTrue(s1.engine.lastResumableBlockReason()?.contains("唯一") == true)

                let s2 = try await scenario("refresh-integ-idmismatch", fileBatchID: "20261015-150001") { w, books in
                    try w.append(RefreshJournalEvent(event: RefreshJournalEventName.bookDone,
                                                     batchID: "wrong-id",
                                                     bookID: books[0].id, pages: 1, verdict: "updated"))
                }
                defer { Fixtures.cleanup(s2.dir) }
                try expectNil(s2.engine.loadResumableBatch())
                try expectTrue(s2.engine.lastResumableBlockReason()?.contains("batch_id") == true)

                let s3 = try await scenario("refresh-integ-nosrc", fileBatchID: "20261015-150002") { w, books in
                    try w.append(RefreshJournalEvent(event: RefreshJournalEventName.bookStart,
                                                     batchID: "20261015-150002",
                                                     bookID: books[1].id))
                }
                defer { Fixtures.cleanup(s3.dir) }
                try expectNil(s3.engine.loadResumableBatch())
                try expectTrue(s3.engine.lastResumableBlockReason()?.contains("src") == true)

                let s4 = try await scenario("refresh-integ-dupsettle", fileBatchID: "20261015-150003") { w, books in
                    for _ in 0..<2 {
                        try w.append(RefreshJournalEvent(event: RefreshJournalEventName.bookDone,
                                                         batchID: "20261015-150003",
                                                         bookID: books[0].id,
                                                         src: books[0].realPath,
                                                         pages: 1, verdict: "updated"))
                    }
                }
                defer { Fixtures.cleanup(s4.dir) }
                try expectNil(s4.engine.loadResumableBatch())
                try expectTrue(s4.engine.lastResumableBlockReason()?.contains("重复终态") == true,
                               "duplicate settlement must be blocked, got: \(s4.engine.lastResumableBlockReason() ?? "nil")")

                let s5 = try await scenario("refresh-integ-dupcrosstype", fileBatchID: "20261015-150004") { w, books in
                    try w.append(RefreshJournalEvent(event: RefreshJournalEventName.bookDone,
                                                     batchID: "20261015-150004",
                                                     bookID: books[0].id,
                                                     src: books[0].realPath,
                                                     pages: 1, verdict: "updated"))
                    try w.append(RefreshJournalEvent(event: RefreshJournalEventName.bookFail,
                                                     batchID: "20261015-150004",
                                                     bookID: books[0].id,
                                                     src: books[0].realPath,
                                                     error: "串批嫌疑的第二次终态"))
                }
                defer { Fixtures.cleanup(s5.dir) }
                try expectNil(s5.engine.loadResumableBatch())
                try expectTrue(s5.engine.lastResumableBlockReason()?.contains("重复终态") == true,
                               "cross-type duplicate settlement must be blocked, got: \(s5.engine.lastResumableBlockReason() ?? "nil")")

                let s6 = try await scenario("refresh-integ-dupaftercomplete", fileBatchID: "20261015-150005") { w, books in
                    for b in books {
                        try w.append(RefreshJournalEvent(event: RefreshJournalEventName.bookDone,
                                                         batchID: "20261015-150005",
                                                         bookID: b.id, src: b.realPath,
                                                         pages: 1, verdict: "updated"))
                    }
                    try w.append(RefreshJournalEvent(event: RefreshJournalEventName.batchComplete,
                                                     batchID: "20261015-150005",
                                                     booksTotal: 3))
                    try w.append(RefreshJournalEvent(event: RefreshJournalEventName.bookDone,
                                                     batchID: "20261015-150005",
                                                     bookID: books[0].id, src: books[0].realPath,
                                                     pages: 1, verdict: "updated"))
                }
                defer { Fixtures.cleanup(s6.dir) }
                try expectNil(s6.engine.loadResumableBatch())
                try expectNil(s6.engine.lastResumableBlockReason(),
                              "a finished batch must return early without a block reason even with duplicate settlements")

                do {
                    let dir7 = Fixtures.makeTempDir("refresh-integ-finishednobtotal")
                    defer { Fixtures.cleanup(dir7) }
                    let jr7 = dir7.appendingPathComponent("jr")
                    let w7 = try RefreshJournal.Writer(directory: jr7, batchID: "20261015-150006")
                    // batch-start **不带 booksTotal**（scenario 助手必带，故手工构造）。
                    try w7.append(RefreshJournalEvent(event: RefreshJournalEventName.batchStart,
                                                      batchID: "20261015-150006"))
                    try w7.append(RefreshJournalEvent(event: RefreshJournalEventName.batchComplete,
                                                      batchID: "20261015-150006"))
                    // 完整性校验确实会报缺 books_total（证明本形态是「坏但收尾」）。
                    let problems7 = RefreshJournal.integrityProblems(
                        events: RefreshJournal.readEvents(at: w7.url), fileNameStem: "20261015-150006")
                    try expectTrue(problems7.contains { $0.contains("books_total") },
                                   "the fixture must be integrity-broken, got: \(problems7)")
                    let engine7 = RefreshEngine(dbURL: dir7.appendingPathComponent("index.db"),
                                                snapshotDir: dir7.appendingPathComponent("snap"),
                                                journalDir: jr7)
                    try expectNil(engine7.loadResumableBatch())
                    try expectNil(engine7.lastResumableBlockReason(),
                                  "a finished batch must return early without touching integrity checks")
                }
            },


            // 回归断言5：收尾残留（completedWithResidue）跨启动——
            // 新 Store 读 journal 残留源，窗口期横幅保持活跃。
            TestDesc(suite: "RefreshConsoleMerge", name: "residueBannerSurvivesRestart") {
                let dir = Fixtures.makeTempDir("refresh-residue-restart")
                defer { Fixtures.cleanup(dir) }
                let (_, books) = try await makeLibrary(dir)
                var rows: [(src: String, shaAfter: String?, pages: Int?)] = []
                for (i, book) in books.enumerated() {
                    let sha = i == 1 ? "deadbeef" : try Fingerprint.sha256Hex(ofFileAt: URL(fileURLWithPath: book.realPath))
                    rows.append((src: book.realPath, shaAfter: sha, pages: book.pageCount))
                }
                let ledger = try writeLedger(dir, rows)
                let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                           snapshotDir: dir.appendingPathComponent("snap"),
                                           journalDir: dir.appendingPathComponent("jr"))
                _ = await engine.start(plan: try engine.loadLedger(ledger))
                try expectEqual(engine.currentProgress().phase, .completedWithResidue)
                // 「重启」：全新 Store 只读 journal——残留源保持横幅。
                let store = RefreshConsoleStore(dbURL: dir.appendingPathComponent("index.db"),
                                                snapshotDir: dir.appendingPathComponent("snap"),
                                                journalDir: dir.appendingPathComponent("jr"))
                _ = try await drainAndPoll({ store.journalSummary?.finalizeResidue == true },
                                           until: { $0 })
                try expectTrue(store.windowPeriodActive,
                               "residue must keep the window banner after restart")
            },

            // 回归断言6：抽验失败跨启动保留——重启后续跑须重新通过
            // 抽验（不过再次自动暂停），问题状态不因重启消失。
            TestDesc(suite: "RefreshConsoleMerge", name: "probeFailureBlocksAcrossRestart") {
                let dir = Fixtures.makeTempDir("refresh-probe-restart")
                defer { Fixtures.cleanup(dir) }
                let (_, books) = try await makeLibrary(dir)
                try FileManager.default.removeItem(at: URL(fileURLWithPath: books[1].realPath))
                let planBooks = books.map {
                    RefreshEngine.PlanBook(bookID: $0.id, src: $0.realPath, shaExpect: nil,
                                           declaredPages: $0.pageCount, fileName: $0.fileName, title: $0.title)
                }
                let plan = RefreshEngine.BatchPlan(ledgerPath: "/tmp/none.jsonl", books: planBooks,
                                                   unresolvedSources: [])
                let engine1 = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                            snapshotDir: dir.appendingPathComponent("snap"),
                                            journalDir: dir.appendingPathComponent("jr"))
                engine1.auditProbeInterval = 1
                _ = await engine1.start(plan: plan)
                try expectEqual(engine1.currentProgress().phase, .paused)
                // 「重启」：抽验失败从 journal 摘要种回（错误清单含 audit-probe）。
                let engine2 = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                            snapshotDir: dir.appendingPathComponent("snap"),
                                            journalDir: dir.appendingPathComponent("jr"))
                engine2.auditProbeInterval = 1   // 跨启动实例同样触发抽验（生产 50）
                let resumable = try expectNotNil(engine2.loadResumableBatch())
                try expectTrue(resumable.probeFailures.count >= 1,
                               "audit failures must survive restart")
                try expectTrue(resumable.failures.contains { $0.bookID == "audit-probe" })
                _ = await engine2.resumeLastBatch()
                let progress2 = engine2.currentProgress()
                try expectEqual(progress2.phase, .paused,
                                "resume gate must probe BEFORE running pending books")
                let journalURL = try expectNotNil(RefreshJournal.latestJournalURL(in: dir.appendingPathComponent("jr")))
                let events = RefreshJournal.readEvents(at: journalURL)
                try expectEqual(events.filter { $0.event == RefreshJournalEventName.auditFail }.count, 2,
                                "audit failures must accumulate across restarts")
                try expectFalse(events.contains { $0.event == RefreshJournalEventName.bookStart
                                                   && $0.bookID == books[2].id },
                                "pending book must NOT start when the resume gate fails")
            },

            TestDesc(suite: "RefreshConsoleMerge", name: "resumeGateInSessionWithOversizedSample") {
                let dir = Fixtures.makeTempDir("refresh-resume-gate-insession")
                defer { Fixtures.cleanup(dir) }
                let (_, books) = try await makeLibrary(dir, books: 6)
                let planBooks = makePlanBooks(books)
                let plan = RefreshEngine.BatchPlan(ledgerPath: "/tmp/none.jsonl", books: planBooks,
                                                   unresolvedSources: [])
                let jr = dir.appendingPathComponent("jr")
                let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                           snapshotDir: dir.appendingPathComponent("snap"),
                                           journalDir: jr)
                // 样本量 2（生产 5）；间隔调大——本段内不触发批间抽验，
                // 使「续跑门禁」成为唯一抽验入口（否则两只抽验会混淆断言）。
                engine.auditProbeSampleSize = 2
                engine.auditProbeInterval = 100
                // 会话内停止：第 4 本终态后请求停止 → 书边界收摊（settledOrder
                // 前 4 册），余 2 本未开跑。
                engine.perBookHook = { index in if index == 3 { engine.stop() } }
                _ = await engine.start(plan: plan)
                engine.perBookHook = nil
                try expectEqual(engine.currentProgress().phase, .stopped,
                                "in-session stop must land on the book boundary")
                try expectEqual(engine.currentProgress().booksDone, 4)
                let journalURL = try expectNotNil(RefreshJournal.latestJournalURL(in: jr))
                // 落盘序＝跑序：settledOrder 恰前 4 册（样本＝suffix(2)＝第 3、4 册）。
                let settledIDs = Self.settledEvents(RefreshJournal.readEvents(at: journalURL))
                    .compactMap(\.bookID)
                try expectEqual(settledIDs, books.prefix(4).map(\.id),
                                "journal settled order must mirror the run order")
                try expectNotEqual(planBooks[0].displayName, planBooks[3].displayName,
                                   "sample-window assertions need distinct display names")

                // 篡改盘上文件：末册（样本窗口内）＋第 1 册（窗口外对照）。
                let windowOutURL = URL(fileURLWithPath: books[0].realPath)
                let lastSettledURL = URL(fileURLWithPath: books[3].realPath)
                let windowOutBytes = try Data(contentsOf: windowOutURL)
                let lastSettledBytes = try Data(contentsOf: lastSettledURL)
                try Data("tampered window-out book1".utf8).write(to: windowOutURL)
                try Data("tampered last-settled book4".utf8).write(to: lastSettledURL)

                // 会话内 resume：门禁必须先抽验（不过则停在书边界）。
                let resumed = await engine.resume()
                try expectTrue(resumed, "resume() must enter the gate path and return true")
                let progress2 = engine.currentProgress()
                try expectEqual(progress2.phase, .paused,
                                "in-session resume gate must pause at the book boundary when the probe fails")
                try expectEqual(progress2.booksDone, 4, "settled books must not be re-run by the gate")
                let events2 = RefreshJournal.readEvents(at: journalURL)
                let auditFails = events2.filter { $0.event == RefreshJournalEventName.auditFail }
                try expectEqual(auditFails.count, 1,
                                "the in-session resume gate must run exactly one probe round")
                let fail = try expectNotNil(auditFails.first)
                try expectEqual(fail.checked, 2,
                                "probe sample size must be honored (auditProbeSampleSize=2)")
                let failText = fail.error ?? ""
                try expectTrue(failText.contains("抽验不过"), "audit-fail must carry probe detail")
                try expectTrue(failText.contains(planBooks[3].displayName),
                               "sample must include the MOST RECENT settled book, got: \(failText)")
                try expectFalse(failText.contains(planBooks[0].displayName),
                                "sample must NOT reach the oldest settled book (window = last N), got: \(failText)")
                // 门禁在书之前：audit-fail 落在本段 batch-resume 之后，且其后的
                // 事件流里没有任何 book-start（下一本不得开跑——journal 验证）。
                let resumeIdx = try expectNotNil(events2.lastIndex { $0.event == RefreshJournalEventName.batchResume },
                                                 "the gate leg must record a batch-resume entry")
                let failIdx = try expectNotNil(events2.firstIndex { $0.event == RefreshJournalEventName.auditFail })
                try expectTrue(failIdx > resumeIdx,
                               "the resume gate must probe AFTER batch-resume and BEFORE any book")
                try expectFalse(events2[resumeIdx...].contains { $0.event == RefreshJournalEventName.bookStart },
                                "no book may start while the in-session resume gate fails")
                try expectEqual(Set(events2.filter { $0.event == RefreshJournalEventName.bookStart }
                                        .compactMap(\.bookID)),
                                Set(books.prefix(4).map(\.id)),
                                "book-start set must stay at the four pre-stop books")

                // 复原盘上文件（逐字节）→ 再 resume：门禁放行、余书开跑。
                try windowOutBytes.write(to: windowOutURL)
                try lastSettledBytes.write(to: lastSettledURL)
                let resumedHealed = await engine.resume()
                try expectTrue(resumedHealed)
                let progress3 = engine.currentProgress()
                try expectEqual(progress3.booksDone + progress3.booksFailed, 6,
                                "healed gate must run the remaining two books to settlement")
                try expectEqual(progress3.booksDone, 6)
                try expectEqual(progress3.phase, .completedWithResidue,
                                "earlier gate failure must keep dragging finalization into residue")
                try expectEqual(progress3.finalCheck?.probeFailures.count, 1,
                                "the earlier gate failure must stay on the record")
                let events3 = RefreshJournal.readEvents(at: journalURL)
                try expectEqual(events3.filter { $0.event == RefreshJournalEventName.auditPass }.count, 1,
                                "the healed gate must record exactly one audit-pass")
                try expectEqual(events3.filter { $0.event == RefreshJournalEventName.bookStart }.count, 6,
                                "each planned book must start exactly once (no re-run of settled books)")
                try expectEqual(Set(events3.filter { $0.event == RefreshJournalEventName.bookStart }
                                        .compactMap(\.bookID)),
                                Set(books.map(\.id)))
                try expectEqual(events3.last?.event, RefreshJournalEventName.batchComplete)
                // 无重复页行（续跑段只跑余书）。
                try expectEqual(try Self.pageRowCount(in: dir), 6)
                try expectEqual(try Self.uniquePageKeyCount(in: dir), 6)
            },

            // 回归断言7：备份失败（快照目标被文件占据）回落 idle——
            // Store 绝不把未执行的修复书标成已修复。
            TestDesc(suite: "RefreshConsoleMerge", name: "storeRepairNoFalsePositiveOnBackupFailure") {
                let dir = Fixtures.makeTempDir("refresh-repair-backupfail")
                defer { Fixtures.cleanup(dir) }
                _ = try await makeLibrary(dir)
                let books = try Fixtures.openStore(in: dir).allBooks().sorted { $0.fileName < $1.fileName }
                let book1URL = URL(fileURLWithPath: books[0].realPath)
                try FileManager.default.removeItem(at: book1URL)
                Fixtures.makePDF(pages: [.init(lines: ["备份失败路径 改写后。"])],
                                 in: book1URL.deletingLastPathComponent(), named: "book1.pdf")
                // 快照目录被一个普通文件占据 → 开跑前备份必败 → fail-closed idle。
                let snapAsFile = dir.appendingPathComponent("snap-as-file")
                try Data("x".utf8).write(to: snapAsFile)
                let store = RefreshConsoleStore(dbURL: dir.appendingPathComponent("index.db"),
                                                snapshotDir: snapAsFile,
                                                journalDir: dir.appendingPathComponent("jr"))
                store.auditSync()
                _ = try await drainAndPoll({ store.auditResult?.differences.count ?? -1 }, until: { $0 == 1 })
                store.repairDifferences()
                _ = try await drainAndPoll({ store.progress.lastError != nil ? 1 : 0 }, until: { $0 == 1 })
                try expectTrue(store.repairedBookIDs.isEmpty,
                               "backup-failed repair must not mark any book repaired")
            },

            TestDesc(suite: "RefreshConsoleMerge", name: "firstBookMissingNoETACrash") {
                let dir = Fixtures.makeTempDir("refresh-eta-crash")
                defer { Fixtures.cleanup(dir) }
                let (_, books) = try await makeLibrary(dir)
                // 计划首位放幽灵书号（库中无此 book_id → pages=0 直击除零路径）。
                let ghost = RefreshEngine.PlanBook(bookID: "ghost-no-such",
                                                   src: "/nonexistent/ghost.pdf",
                                                   shaExpect: nil, declaredPages: 1,
                                                   fileName: "ghost.pdf", title: nil)
                let planBooks = [ghost] + books.dropFirst().map {
                    RefreshEngine.PlanBook(bookID: $0.id, src: $0.realPath, shaExpect: nil,
                                           declaredPages: $0.pageCount, fileName: $0.fileName, title: $0.title)
                }
                let plan = RefreshEngine.BatchPlan(ledgerPath: "/tmp/none.jsonl", books: planBooks,
                                                   unresolvedSources: [])
                let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                           snapshotDir: dir.appendingPathComponent("snap"),
                                           journalDir: dir.appendingPathComponent("jr"))
                _ = await engine.start(plan: plan)
                let progress = engine.currentProgress()
                try expectEqual(progress.phase, .completedWithResidue,
                                "zero-page first book must finish as residue, not crash")
                try expectEqual(progress.booksFailed, 1)
                if let eta = progress.etaSeconds {
                    try expectTrue(eta >= 0, "eta must be finite, got \(eta)")
                }
            },




            TestDesc(suite: "RefreshConsoleMerge", name: "probeOnlyResidueKeepsBannerAcrossRestart") {
                let dir = Fixtures.makeTempDir("refresh-probe-only-residue")
                defer { Fixtures.cleanup(dir) }
                let (_, books) = try await makeLibrary(dir)
                // 崩溃形态：计划内 3 本全部 book-done＋一条 audit-fail，无终态事件。
                let planRows = books.map {
                    JournalPlanBook(bookID: $0.id, src: $0.realPath, shaExpect: nil,
                                    declaredPages: $0.pageCount, fileName: $0.fileName, title: $0.title)
                }
                let jr = dir.appendingPathComponent("jr")
                let w = try RefreshJournal.Writer(directory: jr, batchID: "20261015-160000")
                try w.append(RefreshJournalEvent(event: RefreshJournalEventName.batchStart,
                                                 batchID: "20261015-160000",
                                                 booksTotal: 3, plan: planRows,
                                                 planVersion: RefreshJournal.currentPlanVersion))
                for book in books {
                    try w.append(RefreshJournalEvent(event: RefreshJournalEventName.bookDone,
                                                     batchID: "20261015-160000",
                                                     bookID: book.id, src: book.realPath,
                                                     pages: 1, verdict: "updated"))
                }
                try w.append(RefreshJournalEvent(event: RefreshJournalEventName.auditFail,
                                                 batchID: "20261015-160000",
                                                 error: "抽验不过：样本——指纹不一致（演示）"))
                // 续跑：门禁抽验会跑真实样本（全部完好→过），随后无待跑书、
                // 直接收尾——种子抽验残留拖住 PASS＋写入 finalize 载荷。
                let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                           snapshotDir: dir.appendingPathComponent("snap"),
                                           journalDir: jr)
                let resumable = try expectNotNil(engine.loadResumableBatch())
                try expectTrue(resumable.probeFailures.count == 1)
                _ = await engine.resumeLastBatch()
                try expectEqual(engine.currentProgress().phase, .completedWithResidue,
                                "probe-only residue must not pass cleanly")
                let journalURL = try expectNotNil(RefreshJournal.latestJournalURL(in: jr))
                let events = RefreshJournal.readEvents(at: journalURL)
                let finalize = events
                    .first { $0.event == RefreshJournalEventName.batchFinalize }
                try expectEqual(finalize?.checkProbesFailed, 1,
                                "finalize payload must carry probe failures")
                try expectEqual(events.filter { $0.event == RefreshJournalEventName.auditPass }.count, 1,
                                "resume gate must re-probe and journal exactly one audit-pass")
                try expectEqual(engine.currentProgress().finalCheck?.probeFailures.count, 1,
                                "finalized probe failures must reflect the seeded historical audit-fail")
                // 重启：新 Store 由 journal 残留源保持横幅。
                let store2 = RefreshConsoleStore(dbURL: dir.appendingPathComponent("index.db"),
                                                 snapshotDir: dir.appendingPathComponent("snap"),
                                                 journalDir: jr)
                _ = try await drainAndPoll({ store2.journalSummary?.finalizeResidue == true },
                                           until: { $0 })
                //（「明确断言 finalizeProbesFailed == 1」）：直接读
                // Summary 的 finalizeProbesFailed，不只靠 finalizeResidue 间接证。
                try expectEqual(store2.journalSummary?.finalizeProbesFailed, 1,
                                "summary must carry finalizeProbesFailed == 1 directly")
                try expectTrue(store2.windowPeriodActive,
                               "probe-only residue must keep the banner after restart")
            },

            TestDesc(suite: "RefreshConsoleMerge", name: "storeRepairMixedSuccessFailureBackfill") {
                let dir = Fixtures.makeTempDir("refresh-mixed-backfill")
                defer { Fixtures.cleanup(dir) }
                let store = RefreshConsoleStore(dbURL: dir.appendingPathComponent("index.db"),
                                                snapshotDir: dir.appendingPathComponent("snap"),
                                                journalDir: dir.appendingPathComponent("jr"))
                var snapshot = RefreshEngine.Progress()
                snapshot.phase = .completedWithResidue
                snapshot.succeededBookIDs = ["book-A", "book-C"]
                snapshot.failed = [
                    // A 书的历史失败记录仍在清单（首轮失败、续跑成功）——
                    // 这正是「计划−失败」推算会把 A 错排的场景。
                    RefreshEngine.BookFailure(bookID: "book-A", fileName: "a.pdf",
                                              message: "首轮失败（历史条目）"),
                    RefreshEngine.BookFailure(bookID: "book-B", fileName: "b.pdf",
                                              message: "真失败"),
                ]
                store.driveRepairCompletionForTesting(plan: ["book-A", "book-B", "book-C"],
                                                      snapshot: snapshot)
                try expectEqual(store.repairedBookIDs, Set(["book-A", "book-C"]),
                                "backfill must follow succeededBookIDs, not plan-minus-failed")
                try expectTrue(store.message.contains("2 本已重新配对"),
                               "done count must be the intersection size, got: \(store.message)")
                try expectTrue(store.message.contains("1 本失败"),
                               "failed count must exclude the healed book, got: \(store.message)")
            },

            //回归断言13：停止后续跑、恰好全部书完成但收尾前
            // 崩溃」）：journal 形态＝batch-start(计划3本)→book0 done→
            // batch-stop→batch-resume→book1/book2 done→崩溃（无 finalize/
            // complete）。后生命周期按**末次**事件判定：末次生命周期
            // 事件是 batch-resume ⇒ interrupted=true、pendingCount=0 仍
            // unfinished ⇒ 跨启动可续、续跑直接收尾（补 finalize/complete）。
            TestDesc(suite: "RefreshConsoleMerge", name: "stopResumeCrashBeforeFinalizeIsRecoverable") {
                let dir = Fixtures.makeTempDir("refresh-stop-resume-crash")
                defer { Fixtures.cleanup(dir) }
                let (_, books) = try await makeLibrary(dir)
                let jr = dir.appendingPathComponent("jr")
                let batchID = "20261016-230000"
                let planRows = books.map {
                    JournalPlanBook(bookID: $0.id, src: $0.realPath, shaExpect: nil,
                                    declaredPages: $0.pageCount, fileName: $0.fileName, title: $0.title)
                }
                let w = try RefreshJournal.Writer(directory: jr, batchID: batchID)
                try w.append(RefreshJournalEvent(event: RefreshJournalEventName.batchStart,
                                                 batchID: batchID, booksTotal: 3,
                                                 plan: planRows,
                                                 planVersion: RefreshJournal.currentPlanVersion))
                try w.append(RefreshJournalEvent(event: RefreshJournalEventName.bookDone,
                                                 batchID: batchID, bookID: books[0].id,
                                                 src: books[0].realPath, pages: 1, verdict: "updated"))
                try w.append(RefreshJournalEvent(event: RefreshJournalEventName.batchStop,
                                                 batchID: batchID))
                try w.append(RefreshJournalEvent(event: RefreshJournalEventName.batchResume,
                                                 batchID: batchID))
                for book in books[1...] {
                    try w.append(RefreshJournalEvent(event: RefreshJournalEventName.bookDone,
                                                     batchID: batchID, bookID: book.id,
                                                     src: book.realPath, pages: 1, verdict: "updated"))
                }
                // ←「崩溃」：无 batch-finalize / batch-complete。
                let journalURL = try expectNotNil(RefreshJournal.latestJournalURL(in: jr))
                let summary = try expectNotNil(RefreshJournal.summarize(at: journalURL))
                // 判别：末次生命周期事件＝batch-resume ⇒ 仍判 interrupted；
                // pendingCount=0 但 unfinished=true（可恢复性不丢）。
                try expectTrue(summary.interrupted,
                               "last lifecycle event is batch-resume ⇒ must stay interrupted")
                try expectEqual(summary.pendingCount, 0)
                try expectTrue(summary.unfinished,
                               "all books settled but unfinalized must still count as unfinished")
                // 跨启动续跑：可加载、续跑直接收尾（不重跑任何书）。
                let engine2 = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                            snapshotDir: dir.appendingPathComponent("snap"),
                                            journalDir: jr)
                let resumable = try expectNotNil(engine2.loadResumableBatch(),
                                                 "crash-before-finalize must be recoverable")
                try expectEqual(resumable.pendingCount, 0)
                let resumed = await engine2.resumeLastBatch()
                try expectTrue(resumed)
                let progress = engine2.currentProgress()
                try expectTrue(progress.phase == .completed || progress.phase == .completedWithResidue,
                               "recovery must finalize the batch, got \(progress.phase)")
                let events = RefreshJournal.readEvents(at: journalURL)
                try expectTrue(events.contains { $0.event == RefreshJournalEventName.batchFinalize },
                               "recovery must append the missing batch-finalize")
                try expectEqual(events.last?.event, RefreshJournalEventName.batchComplete)
                // 已结算书零重跑：book-start 总数仍为 0（journal 里原本没有）。
                try expectEqual(events.filter { $0.event == RefreshJournalEventName.bookStart }.count, 0,
                                "settled books must not be re-run by the recovery")
                // 恢复后生命周期事件严格序列——batch-resume →
                // batch-finalize → batch-complete（不只验「没有重跑书」）。
                let lifecycle = events.map(\.event).filter {
                    [RefreshJournalEventName.batchStart, RefreshJournalEventName.batchStop,
                     RefreshJournalEventName.batchResume, RefreshJournalEventName.batchFinalize,
                     RefreshJournalEventName.batchComplete].contains($0)
                }
                try expectEqual(lifecycle,
                                [RefreshJournalEventName.batchStart, RefreshJournalEventName.batchStop,
                                 RefreshJournalEventName.batchResume, RefreshJournalEventName.batchResume,
                                 RefreshJournalEventName.batchFinalize, RefreshJournalEventName.batchComplete],
                                "recovery must append resume→finalize→complete in strict order")
            },

            TestDesc(suite: "RefreshConsoleMerge", name: "gateFlagMustNotPolluteNextBatch") {
                let dir = Fixtures.makeTempDir("refresh-gate-flag-pollution")
                defer { Fixtures.cleanup(dir) }
                let (_, books) = try await makeLibrary(dir)
                let jr = dir.appendingPathComponent("jr")
                let planRows = books.map {
                    JournalPlanBook(bookID: $0.id, src: $0.realPath, shaExpect: nil,
                                    declaredPages: $0.pageCount, fileName: $0.fileName, title: $0.title)
                }
                let batchID = "20261017-010000"
                let w = try RefreshJournal.Writer(directory: jr, batchID: batchID)
                try w.append(RefreshJournalEvent(event: RefreshJournalEventName.batchStart,
                                                 batchID: batchID, booksTotal: 3, plan: planRows,
                                                 planVersion: RefreshJournal.currentPlanVersion))
                for book in books {
                    try w.append(RefreshJournalEvent(event: RefreshJournalEventName.bookDone,
                                                     batchID: batchID, bookID: book.id,
                                                     src: book.realPath, pages: 1, verdict: "updated"))
                }
                try w.append(RefreshJournalEvent(event: RefreshJournalEventName.auditFail,
                                                 batchID: batchID, error: "抽验不过：历史残留（演示）"))
                let lastBookURL = URL(fileURLWithPath: books[2].realPath)
                let goodBytes = try Data(contentsOf: lastBookURL)
                try Data("tampered for gate failure".utf8).write(to: lastBookURL)
                let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                           snapshotDir: dir.appendingPathComponent("snap"),
                                           journalDir: jr)
                _ = await engine.resumeLastBatch()
                try expectEqual(engine.currentProgress().phase, .completedWithResidue,
                                "all-settled batch with gate failure must finalize as residue")
                try goodBytes.write(to: lastBookURL)  // 复原（新批与篡改无关）

                // 从 completedWithResidue 直接 start 新一轮（同一引擎实例——旗标
                // 是实例态，正是「污染」的载体）。新一轮 3 本必须全部开跑。
                let plan2 = RefreshEngine.BatchPlan(ledgerPath: "", books: makePlanBooks(books),
                                                    unresolvedSources: [])
                let started = await engine.start(plan: plan2)
                try expectTrue(started, "start from completedWithResidue must be accepted")
                let p2 = engine.currentProgress()
                try expectEqual(p2.phase, .completed,
                                "the next batch must run to completion, got \(p2.phase)")
                try expectEqual(p2.booksDone, 3, "no book may be skipped by a stale gate flag")
                let journalURL2 = try expectNotNil(RefreshJournal.latestJournalURL(in: jr))
                let events2 = RefreshJournal.readEvents(at: journalURL2)
                try expectEqual(events2.filter { $0.event == RefreshJournalEventName.bookStart }.count, 3,
                                "the new batch must journal book-start for every book")
                try expectFalse(events2.contains { $0.event == RefreshJournalEventName.batchPause },
                                "a stale pauseRequested must never pause the new batch")
            },

            TestDesc(suite: "RefreshConsoleMerge", name: "crossRestartGateSamplesMostRecentSettled") {
                // 场景表：6 本计划；settled＝落盘结算序（计划内下标）；
                // 样本量 2 → 期望样本＝settled 尾两册；pending＝其余两本。
                let scenarios: [(label: String, settled: [Int])] = [
                    ("乱序A", [2, 5, 0, 3]),   // 样本＝{0,3}；pending＝{1,4}
                    ("乱序B", [1, 4, 5, 2]),   // 样本＝{5,2}；pending＝{0,3}
                ]
                for (si, scenario) in scenarios.enumerated() {
                    let dir = Fixtures.makeTempDir("refresh-cross-gate-order-\(si)")
                    defer { Fixtures.cleanup(dir) }
                    let (_, books) = try await makeLibrary(dir, books: 6)
                    let planRows = books.map {
                        JournalPlanBook(bookID: $0.id, src: $0.realPath, shaExpect: nil,
                                        declaredPages: $0.pageCount, fileName: $0.fileName, title: $0.title)
                    }
                    let jr = dir.appendingPathComponent("jr")
                    let batchID = "20261017-03\(si)0000"
                    let w = try RefreshJournal.Writer(directory: jr, batchID: batchID)
                    try w.append(RefreshJournalEvent(event: RefreshJournalEventName.batchStart,
                                                     batchID: batchID, booksTotal: 6, plan: planRows,
                                                     planVersion: RefreshJournal.currentPlanVersion))
                    // 按给定落盘序逐本记 book-done（模拟任意历史跑序）。
                    for bi in scenario.settled {
                        try w.append(RefreshJournalEvent(event: RefreshJournalEventName.bookDone,
                                                         batchID: batchID, bookID: books[bi].id,
                                                         src: books[bi].realPath, pages: 1,
                                                         verdict: "updated"))
                    }
                    // ←「崩溃」：无终态事件。
                    // 篡改期望样本两册（窗口内）＋settled 首两册（窗口外对照）。
                    let sampleIdx = Array(scenario.settled.suffix(2))
                    let outIdx = Array(scenario.settled.prefix(2))
                    var restore: [(URL, Data)] = []
                    for bi in sampleIdx + outIdx {
                        let u = URL(fileURLWithPath: books[bi].realPath)
                        restore.append((u, try Data(contentsOf: u)))
                        try Data("tampered \(scenario.label) book\(bi)".utf8).write(to: u)
                    }
                    // 「重启」：全新引擎（零内存态）→ resumeLastBatch 跨启动续跑。
                    let engine2 = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                                snapshotDir: dir.appendingPathComponent("snap"),
                                                journalDir: jr)
                    engine2.auditProbeSampleSize = 2
                    engine2.auditProbeInterval = 100
                    let resumable = try expectNotNil(engine2.loadResumableBatch(), scenario.label)
                    try expectEqual(resumable.settledOrder, scenario.settled.map { books[$0].id },
                                    "settledOrder must equal the journal order (\(scenario.label))")
                    let resumed = await engine2.resumeLastBatch()
                    try expectTrue(resumed, scenario.label)
                    try expectEqual(engine2.currentProgress().phase, .paused,
                                    "cross-restart gate must pause when the probe fails (\(scenario.label))")
                    let journalURL = try expectNotNil(RefreshJournal.latestJournalURL(in: jr))
                    let events = RefreshJournal.readEvents(at: journalURL)
                    let fail = try expectNotNil(events.last { $0.event == RefreshJournalEventName.auditFail },
                                                "the gate must journal an audit-fail (\(scenario.label))")
                    try expectEqual(fail.checked, 2, "sample size must be honored (\(scenario.label))")
                    let failText = fail.error ?? ""
                    for bi in sampleIdx {
                        try expectTrue(failText.contains(books[bi].fileName),
                                       "sample must include settled[\(bi)] (\(scenario.label)), got: \(failText)")
                    }
                    for bi in outIdx {
                        try expectFalse(failText.contains(books[bi].fileName),
                                        "sample must NOT include settled[\(bi)] (\(scenario.label)), got: \(failText)")
                    }
                    let resumeIdx = try expectNotNil(events.lastIndex { $0.event == RefreshJournalEventName.batchResume },
                                                     scenario.label)
                    try expectFalse(events[resumeIdx...].contains { $0.event == RefreshJournalEventName.bookStart },
                                    "no book may start while the cross-restart gate fails (\(scenario.label))")
                    // 复原（不留篡改现场）。
                    for (u, bytes) in restore { try bytes.write(to: u) }
                }
            },

            TestDesc(suite: "RefreshConsoleMerge", name: "lifecycleWriteFailureFailsClosed") {
                let dir = Fixtures.makeTempDir("refresh-lifecycle-writefail")
                defer { Fixtures.cleanup(dir) }
                let (_, books) = try await makeLibrary(dir)
                let plan = RefreshEngine.BatchPlan(ledgerPath: "", books: makePlanBooks(books),
                                                   unresolvedSources: [])
                let jr = dir.appendingPathComponent("jr")

                let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                           snapshotDir: dir.appendingPathComponent("snap"),
                                           journalDir: jr)
                engine.appendFailureEventNames = [RefreshJournalEventName.batchPause]
                engine.perBookHook = { index in if index == 0 { engine.pause() } }
                _ = await engine.start(plan: plan)
                engine.perBookHook = nil
                let p = engine.currentProgress()
                try expectNotEqual(p.phase, .paused,
                                   "a failed batch-pause write must never publish .paused")
                try expectEqual(p.phase, .idle, "lifecycle write failure must fail closed to idle")
                try expectNotNil(p.lastError, "the write failure must surface in lastError")
                try expectTrue((p.lastError ?? "").contains("注入的 journal 写失败"),
                               "lastError must carry the injected failure, got: \(p.lastError ?? "")")
                let journalURL = try expectNotNil(RefreshJournal.latestJournalURL(in: jr))
                let events = RefreshJournal.readEvents(at: journalURL)
                try expectFalse(events.contains { $0.event == RefreshJournalEventName.batchPause },
                                "the failed pause event must not exist in the journal")

                let jr2 = dir.appendingPathComponent("jr2")
                let engine2 = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                            snapshotDir: dir.appendingPathComponent("snap2"),
                                            journalDir: jr2)
                engine2.appendFailureEventNames = [RefreshJournalEventName.batchStop]
                engine2.perBookHook = { index in if index == 0 { engine2.stop() } }
                _ = await engine2.start(plan: plan)
                engine2.perBookHook = nil
                let p2 = engine2.currentProgress()
                try expectNotEqual(p2.phase, .stopped,
                                   "a failed batch-stop write must never publish .stopped")
                try expectEqual(p2.phase, .idle, "lifecycle write failure must fail closed to idle")
                try expectTrue((p2.lastError ?? "").contains("注入的 journal 写失败"),
                               "lastError must carry the injected failure, got: \(p2.lastError ?? "")")
                let journalURL2 = try expectNotNil(RefreshJournal.latestJournalURL(in: jr2))
                try expectFalse(RefreshJournal.readEvents(at: journalURL2)
                                    .contains { $0.event == RefreshJournalEventName.batchStop },
                                "the failed stop event must not exist in the journal")

                let jr3 = dir.appendingPathComponent("jr3")
                let engine3 = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                            snapshotDir: dir.appendingPathComponent("snap3"),
                                            journalDir: jr3)
                engine3.perBookHook = { index in if index == 0 { engine3.pause() } }
                _ = await engine3.start(plan: plan)
                engine3.perBookHook = nil
                try expectEqual(engine3.currentProgress().phase, .paused,
                                "leg 3 must first reach a real .paused state")
                engine3.appendFailureEventNames = [RefreshJournalEventName.batchStop]
                engine3.stop()
                let p3 = engine3.currentProgress()
                try expectNotEqual(p3.phase, .stopped,
                                   "a failed batch-stop write must never publish .stopped (paused-stop path)")
                try expectEqual(p3.phase, .idle,
                                "paused-stop write failure must fail closed to idle")
                try expectTrue((p3.lastError ?? "").contains("注入的 journal 写失败"),
                               "lastError must carry the injected failure, got: \(p3.lastError ?? "")")
                let journalURL3 = try expectNotNil(RefreshJournal.latestJournalURL(in: jr3))
                let events3 = RefreshJournal.readEvents(at: journalURL3)
                try expectFalse(events3.contains { $0.event == RefreshJournalEventName.batchStop },
                                "the failed stop event must not exist in the journal (paused-stop path)")
                try expectTrue(events3.contains { $0.event == RefreshJournalEventName.batchPause },
                               "the earlier successful pause must still be journaled")
            },

            TestDesc(suite: "RefreshConsoleMerge", name: "unknownJournalKindBlocksResume") {
                let dir = Fixtures.makeTempDir("refresh-unknown-kind")
                defer { Fixtures.cleanup(dir) }
                let (_, books) = try await makeLibrary(dir)
                let jr = dir.appendingPathComponent("jr")
                let batchID = "20261017-020000"
                let planRows = books.map {
                    JournalPlanBook(bookID: $0.id, src: $0.realPath, shaExpect: nil,
                                    declaredPages: $0.pageCount, fileName: $0.fileName, title: $0.title)
                }
                let w = try RefreshJournal.Writer(directory: jr, batchID: batchID)
                try w.append(RefreshJournalEvent(event: RefreshJournalEventName.batchStart,
                                                 batchID: batchID, kind: "corrupted-kind",
                                                 booksTotal: 3, plan: planRows,
                                                 planVersion: RefreshJournal.currentPlanVersion))
                let engine = RefreshEngine(dbURL: dir.appendingPathComponent("index.db"),
                                           snapshotDir: dir.appendingPathComponent("snap"),
                                           journalDir: jr)
                try expectNil(engine.loadResumableBatch(), "unknown kind must block resume")
                let reason = try expectNotNil(engine.lastResumableBlockReason())
                try expectTrue(reason.contains("corrupted-kind"), "reason must quote the bad kind, got: \(reason)")
                try expectTrue(reason.contains("阻断"), "reason must state the block, got: \(reason)")
            },


















            TestDesc(suite: "RefreshConsoleMerge", name: "ledgerRollbackFailureFailsClosedAndJournalWriterAtomic") {
                let dir = Fixtures.makeTempDir("refresh-ledger-rollback")
                defer { Fixtures.cleanup(dir) }
                defer {
                    RefreshJournal.Writer.postWriteFailureHook = nil
                    RefreshJournal.Writer.rollbackFailureHook = nil
                    RefreshJournal.Writer.opFailureHook = nil
                }
                func injectedOpError(_ step: String) -> any Error {
                    NSError(domain: "InjectedOpFailure", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "注入的操作级失败（\(step)）"])
                }

                let jDir = dir.appendingPathComponent("jr")
                let jw = try RefreshJournal.Writer(directory: jDir, batchID: "20261017-090000")
                let jEvent = RefreshJournalEvent(event: RefreshJournalEventName.batchStart,
                                                 batchID: "20261017-090000", booksTotal: 1)
                RefreshJournal.Writer.postWriteFailureHook = { $0 == 0 }
                let msgJ = try expectNotNil(Self.throwMessage { try jw.append(jEvent) },
                                            "journal post-write failure must throw")
                try expectTrue(msgJ.contains("注入的 journal 写后失败"), "got: \(msgJ)")
                RefreshJournal.Writer.postWriteFailureHook = nil
                try expectFalse(jw.rollbackFailed, "a confirmed rollback must not latch rollbackFailed (journal)")
                try expectEqual(RefreshJournal.readEvents(at: jw.url).count, 0,
                                "a confirmed rollback must leave no visible journal event")
                try jw.append(jEvent)
                try expectEqual(RefreshJournal.readEvents(at: jw.url).count, 1,
                                "the journal must accept a normal append after a confirmed rollback")
                let bytesBefore = try Data(contentsOf: jw.url)
                RefreshJournal.Writer.postWriteFailureHook = { $0 == 1 }
                RefreshJournal.Writer.rollbackFailureHook = { true }
                let bookEvt = RefreshJournalEvent(event: RefreshJournalEventName.bookDone,
                                                  batchID: "20261017-090000",
                                                  bookID: "bk-1", src: "/tmp/bk1.pdf",
                                                  pages: 1, verdict: "updated")
                let msgJ2 = try expectNotNil(Self.throwMessage { try jw.append(bookEvt) },
                                             "journal post-write failure with unconfirmed rollback must throw")
                try expectTrue(msgJ2.contains("禁止继续写入"), "must state write ban (journal), got: \(msgJ2)")
                try expectTrue(jw.rollbackFailed, "journal rollbackFailed must latch")
                RefreshJournal.Writer.postWriteFailureHook = nil
                RefreshJournal.Writer.rollbackFailureHook = nil
                let msgJ3 = try expectNotNil(Self.throwMessage { try jw.append(bookEvt) },
                                             "a rollback-failed journal must reject every subsequent append")
                try expectTrue(msgJ3.contains("禁止继续写入"), "the journal write ban must persist, got: \(msgJ3)")
                let bytesAfter = try Data(contentsOf: jw.url)
                try expectTrue(bytesAfter.starts(with: bytesBefore),
                               "committed prefix must survive a failed rollback untouched")
                try expectEqual(RefreshJournal.readEvents(at: jw.url).first?.event,
                                RefreshJournalEventName.batchStart,
                                "the committed first event must still read back intact")

                for step in ["truncate", "seek", "sizeCheck", "resync"] {
                    let sDir = dir.appendingPathComponent("jr-step-\(step)")
                    let sw = try RefreshJournal.Writer(directory: sDir, batchID: "20261017-100000")
                    let startEvt = RefreshJournalEvent(event: RefreshJournalEventName.batchStart,
                                                       batchID: "20261017-100000", booksTotal: 1)
                    try sw.append(startEvt)
                    let committed = try Data(contentsOf: sw.url)
                    RefreshJournal.Writer.postWriteFailureHook = { $0 == 1 }
                    RefreshJournal.Writer.opFailureHook = { $0 == step ? injectedOpError(step) : nil }
                    let msgS = try expectNotNil(Self.throwMessage { try sw.append(bookEvt) },
                                                "rollback step failure must throw (\(step))")
                    try expectTrue(msgS.contains("禁止继续写入"),
                                   "rollback step failure must latch the write ban (\(step)), got: \(msgS)")
                    try expectTrue(msgS.contains("注入的操作级失败（\(step)）"),
                                   "the ban message must carry the original op failure (\(step)), got: \(msgS)")
                    RefreshJournal.Writer.postWriteFailureHook = nil
                    RefreshJournal.Writer.opFailureHook = nil
                    try expectTrue(sw.rollbackFailed,
                                   "rollbackFailed must latch after a real step failure (\(step))")
                    let msgS2 = try expectNotNil(Self.throwMessage { try sw.append(bookEvt) },
                                                 "the write ban must persist after step failure (\(step))")
                    try expectTrue(msgS2.contains("禁止继续写入"), "got: \(msgS2)")
                    let afterStep = try Data(contentsOf: sw.url)
                    try expectTrue(afterStep.starts(with: committed),
                                   "committed prefix must survive byte-identical after rollback failure (\(step))")
                    try expectEqual(RefreshJournal.readEvents(at: sw.url).first?.event,
                                    RefreshJournalEventName.batchStart,
                                    "the committed first event must read back intact (\(step))")
                }

                do {
                    let aDir = dir.appendingPathComponent("jr-offset-a")
                    let aw = try RefreshJournal.Writer(directory: aDir, batchID: "20261017-110001")
                    RefreshJournal.Writer.opFailureHook = { $0 == "offset" ? injectedOpError("offset") : nil }
                    try aw.append(RefreshJournalEvent(event: RefreshJournalEventName.batchStart,
                                                      batchID: "20261017-110001", booksTotal: 1))
                    RefreshJournal.Writer.opFailureHook = nil
                    try expectFalse(aw.rollbackFailed,
                                    "a seekToEnd-fallback success must not latch rollbackFailed")
                    try expectEqual(RefreshJournal.readEvents(at: aw.url).count, 1,
                                    "the fallback offset path must write normally")
                }
                do {
                    let oDir = dir.appendingPathComponent("jr-offset")
                    let ow = try RefreshJournal.Writer(directory: oDir, batchID: "20261017-110000")
                    let oStart = RefreshJournalEvent(event: RefreshJournalEventName.batchStart,
                                                     batchID: "20261017-110000", booksTotal: 1)
                    try ow.append(oStart)
                    let oCommitted = try Data(contentsOf: ow.url)
                    RefreshJournal.Writer.opFailureHook = {
                        ($0 == "offset" || $0 == "seekToEnd") ? injectedOpError($0) : nil
                    }
                    let errO = try expectNotNil(Self.thrownError { try ow.append(bookEvt) },
                                                "an unknown write offset must fail closed before any write")
                    RefreshJournal.Writer.opFailureHook = nil
                    try expectEqual(errO.code, 5,
                                    "the offset double-failure must throw code 5, got \(errO.code)")
                    let msgO = errO.localizedDescription
                    try expectTrue(msgO.contains("已禁止写入"), "must state the write ban, got: \(msgO)")
                    try expectTrue(msgO.contains("offset 与 seekToEnd 均败"),
                                   "must name the double failure, got: \(msgO)")
                    try expectTrue(msgO.contains("注入的操作级失败（seekToEnd）"),
                                   "must carry the fallback failure as the original error, got: \(msgO)")
                    try expectTrue(ow.rollbackFailed, "rollbackFailed must latch when the offset is unknown")
                    try expectEqual(try Data(contentsOf: ow.url), oCommitted,
                                    "no bytes may be appended when the write offset is unknown")
                    let msgO2 = try expectNotNil(Self.throwMessage { try ow.append(bookEvt) },
                                                 "the write ban must persist after an unknown-offset failure")
                    try expectTrue(msgO2.contains("禁止继续写入"), "got: \(msgO2)")
                }
                do {
                    let sDir = dir.appendingPathComponent("jr-seektoend-single")
                    let sw2 = try RefreshJournal.Writer(directory: sDir, batchID: "20261017-110002")
                    RefreshJournal.Writer.opFailureHook = { $0 == "seekToEnd" ? injectedOpError("seekToEnd") : nil }
                    try sw2.append(RefreshJournalEvent(event: RefreshJournalEventName.batchStart,
                                                       batchID: "20261017-110002", booksTotal: 1))
                    RefreshJournal.Writer.opFailureHook = nil
                    try expectFalse(sw2.rollbackFailed,
                                    "a successful offset with a failed seekToEnd must not latch rollbackFailed")
                    try expectEqual(RefreshJournal.readEvents(at: sw2.url).count, 1,
                                    "seekToEnd single-failure must still write normally via the offset path")
                }
            },





            // ═══════════════════════════════════════════════════════════════
            // 新增腿：覆盖最后两处。
            // ═══════════════════════════════════════════════════════════════


        ]
    }

    // MARK: 测试小件

    /// onUpdate 快照收集盒（后台线程写、测试线程读）。
    final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [RefreshEngine.Progress] = []
        func record(_ p: RefreshEngine.Progress) {
            lock.lock(); items.append(p); lock.unlock()
        }
        func all() -> [RefreshEngine.Progress] {
            lock.lock(); defer { lock.unlock() }
            return items
        }
    }

    /// 视图侧 formatDuration 的同基准镜像（IndexRefreshPanelView 为 App 域
    /// 不可导入；基准改动须双侧同步）。
    static func formatDurationProbe(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }


}
