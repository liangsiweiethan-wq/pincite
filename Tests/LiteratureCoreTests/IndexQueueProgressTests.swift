import Foundation
@testable import LiteratureCore

// MARK: - 进度落表测试

enum IndexQueueProgressSuite {
    static var tests: [TestDesc] {
        [
            TestDesc(suite: "IndexQueueProgress", name: "v13MigrationIdempotentOnReopen") {
                let dir = Fixtures.makeTempDir("qprog-mig")
                defer { Fixtures.cleanup(dir) }
                let dbPath = dir.appendingPathComponent("index.db")
                do {
                    let store = try IndexStore(path: dbPath)
                    try store.enqueueBook("bKeep")
                    try store.updateQueueProgress(bookID: "bKeep", pagesTotal: 7, pagesDone: 5, charsDone: 1234)
                }
                let reopened = try IndexStore(path: dbPath)
                let rows = try reopened.allQueueRows()
                try expectEqual(rows.count, 1)
                try expectEqual(rows.first?.pagesTotal, 7, "progress column survives reopen")
                try expectEqual(rows.first?.pagesDone, 5)
                try expectEqual(rows.first?.charsDone, 1234)
            },

            // runQueued 完成点写终值；进度写不污染 state/attempts。
            TestDesc(suite: "IndexQueueProgress", name: "runQueuedWritesFinalProgressValues") {
                let dir = Fixtures.makeTempDir("qprog-run")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let pdf = Fixtures.makePDF(pages: [.init(lines: ["progress page one"]),
                                                   .init(lines: ["progress page two"])],
                                           in: dir, named: "p.pdf")
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                let book = try expectNotNil(try store.allBooks().first)
                var mutated = book
                mutated.fingerprint = "stale-fp"
                try store.upsertBook(mutated)
                // 重入队走 enqueueBook（requeue 语义：冲突更新 state/queued_version
                // 不动 attempts）；setQueueState 是
                // 消费循环节拍 API（文档语义「既有行冲突时 attempts +1 叠加」，
                // 且引擎全部调用点默认 delta 0 亦被无条件 +1），重入队误用它会把
                // attempts 抬到 1，进度写「不污染 attempts」断言失真。
                try store.enqueueBook(book.id)
                // 中途进度写（模拟节流）：不得改 attempts/state。
                try store.updateQueueProgress(bookID: book.id, pagesTotal: nil, pagesDone: 1, charsDone: 9)
                try expectEqual(try store.allQueueRows().first?.state, .queued)
                try expectEqual(try store.allQueueRows().first?.attempts, 0,
                                "progress write must not inflate attempts")
                let engine = IndexingEngine(store: store, policy: ExclusionPolicy())
                let consumed = try await engine.runQueued(timeBudget: 30)
                try expectEqual(consumed.indexed, 1)
                let row = try expectNotNil(try store.allQueueRows().first)
                try expectEqual(row.state, .indexed)
                try expectEqual(row.pagesTotal, 2, "final pages_total from extraction")
                try expectEqual(row.pagesDone, 2)
                try expectTrue(row.charsDone >= 2, "char count accumulated across pages")
                _ = pdf
            },

            // 断点语义保持册级：崩溃模拟（state=queued 行残留）→ 重启续跑同册
            // 重抽结算，state 不回退为更早态。
            TestDesc(suite: "IndexQueueProgress", name: "bookLevelResumeAfterCrashKeepsStateForward") {
                let dir = Fixtures.makeTempDir("qprog-crash")
                let dbPath = dir.appendingPathComponent("index.db")
                defer { Fixtures.cleanup(dir) }
                let pdf = Fixtures.makePDF(pages: [.init(lines: ["crash resume 锚点文本"])], in: dir, named: "r.pdf")
                let firstStore = try IndexStore(path: dbPath)
                _ = try await IndexingEngine(store: firstStore, policy: ExclusionPolicy()).run(rootURL: dir)
                let book = try expectNotNil(try firstStore.allBooks().first)
                // 崩溃注入：结算前中断——行停在 queued。
                try firstStore.setQueueState(bookID: book.id, state: .queued,
                                             queuedVersion: IndexStore.currentPipelineVersion)
                // 重启（新店新连）：到期集含该册 → 续跑结算 indexed。
                let secondStore = try IndexStore(path: dbPath)
                let due = try secondStore.dueQueueRows()
                try expectTrue(due.contains { $0.bookID == book.id && $0.state == .queued })
                let consumed = try await IndexingEngine(store: secondStore,
                                                        policy: ExclusionPolicy()).runQueued(timeBudget: 30)
                try expectEqual(consumed.indexed, 1)
                try expectEqual(try secondStore.allQueueRows().first { $0.bookID == book.id }?.state, .indexed)
                _ = pdf
            },

            TestDesc(suite: "IndexQueueProgress", name: "readOnlyReplicaProgressWriteIsNoOp") {
                let dir = Fixtures.makeTempDir("qprog-ro")
                defer { Fixtures.cleanup(dir) }
                let dbPath = dir.appendingPathComponent("index.db")
                do {
                    let store = try IndexStore(path: dbPath)
                    try store.enqueueBook("bRO")
                }
                // 双件副本目录（分离后副本形态；非 WAL 化见 Fixtures helper——
                // WAL 形态裸拷件只读打开必 CANTOPEN，生产副本走 VACUUM INTO
                // 天然非 WAL）。
                let replicaDir = dir.appendingPathComponent("replica", isDirectory: true)
                try Fixtures.copyForReadOnlyReplica(dbURL: dbPath, into: replicaDir)
                let replica = try IndexStore(path: replicaDir.appendingPathComponent("index.db"),
                                             options: .init(readOnlyReplica: true))
                try expectTrue(replica.fulltextAttached, "replica attaches existing fulltext.db read-only")
                try replica.enqueueBook("bRO2")   // 队列写 no-op
                try replica.updateQueueProgress(bookID: "bRO2", pagesTotal: 3, pagesDone: 3, charsDone: 9)
                // no-op 语义＝不加新行、不改既有行
                //（种子行 bRO 随拷贝在副本里），不是「表空」——原断言对副本
                // 初态建模错误（早前被 WAL 打不开挡住未达此断言）。
                let rows = try replica.allQueueRows()
                try expectEqual(rows.count, 1, "seed row readable; read-only writes add nothing")
                try expectFalse(rows.contains { $0.bookID == "bRO2" }, "read-only enqueue is no-op")
                try expectTrue(rows.allSatisfy { $0.pagesDone == 0 },
                               "read-only progress write is no-op (progress untouched)")
            },
        ]
    }
}
