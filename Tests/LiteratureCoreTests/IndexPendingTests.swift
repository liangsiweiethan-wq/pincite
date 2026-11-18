import Foundation
@testable import LiteratureCore

// MARK: - index_pending 测试
//
// 断言面：去重 upsert（重复路径不叠加不覆盖首见时间）；排空成功删行；
// 失败 attempts 叠加；≥3 弃试删行；只读句柄 no-op。

enum IndexPendingSuite {
    static var tests: [TestDesc] {
        [
            // 去重 upsert：同路径多次入队仍一行；attempts 保留不重置。
            TestDesc(suite: "IndexPending", name: "enqueueDedupesByPath") {
                let store = try Fixtures.openStore(in: Fixtures.makeTempDir("pend-dedupe"))
                let url = URL(fileURLWithPath: "/tmp/pend/book.pdf")
                try store.enqueuePendingPaths([url])
                try store.enqueuePendingPaths([url, url])
                let rows = try store.duePendingPaths(limit: 10)
                try expectEqual(rows.count, 1, "path PK dedupes")
                try expectEqual(rows.first?.attempts, 0)
            },

            // 排空成功删行：pending → drain → 书入库且 pending 清空。
            TestDesc(suite: "IndexPending", name: "drainSuccessRemovesPendingRow") {
                let dir = Fixtures.makeTempDir("pend-drain")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let pdf = Fixtures.makePDF(pages: [.init(lines: ["pending drain 文本"])], in: dir, named: "d.pdf")
                try store.enqueuePendingPaths([pdf])
                try expectEqual(try store.duePendingPaths(limit: 10).count, 1)
                let engine = IndexingEngine(store: store, policy: ExclusionPolicy())
                let summary = try await engine.drainPending(limit: 8)
                try expectEqual(summary.considered, 1)
                try expectEqual(summary.indexed, 1)
                try expectEqual(summary.failed, 0)
                try expectEqual(try store.duePendingPaths(limit: 10).count, 0, "success consumes pending row")
                let book = try expectNotNil(try store.allBooks().first)
                try expectEqual(try store.pageCount(bookID: book.id), 1)
                _ = pdf
            },

            // 失败 attempts 叠加；≥3 弃试删行（防坏件永久占队）。
            TestDesc(suite: "IndexPending", name: "failureBumpsAttemptsAndGivesUpAtThree") {
                let dir = Fixtures.makeTempDir("pend-fail")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let bad = dir.appendingPathComponent("corrupt.pdf")
                try Data("not a pdf".utf8).write(to: bad)
                // 回拨 mtime 越过写保护窗：drainPending
                // 对 mtime <10s 的失败件不计 attempts（防 watcher settle 后仍在落盘的半成品被三振弃试）——刚写好的
                // 坏件三连排空全被护栏吞掉，三振断言失真；本测试的是计数/弃试
                // 语义，把坏件造成「已落盘稳定件」。
                try FileManager.default.setAttributes(
                    [.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: bad.path)
                try store.enqueuePendingPaths([bad])
                let engine = IndexingEngine(store: store, policy: ExclusionPolicy())
                // 失败：attempts 1 → 2 → 3（第弃试删行）。
                let r1 = try await engine.drainPending(limit: 8)
                try expectEqual(r1.failed, 1)
                try expectEqual(try store.duePendingPaths(limit: 8).first?.attempts, 1)
                let r2 = try await engine.drainPending(limit: 8)
                try expectEqual(r2.failed, 1)
                let r3 = try await engine.drainPending(limit: 8)
                try expectEqual(r3.failed, 1)
                try expectEqual(r3.abandoned, 1, "third strike gives up")
                try expectEqual(try store.duePendingPaths(limit: 8).count, 0,
                                "abandoned row removed (no permanent queue occupant)")
            },

            // 失败面另一形态：文件缺失同样走失败计数（attempts 叠加收敛弃试）。
            TestDesc(suite: "IndexPending", name: "missingPathCountsTowardGiveUp") {
                let dir = Fixtures.makeTempDir("pend-excl")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let pdf = Fixtures.makePDF(pages: [.init(lines: ["vanishing content"])], in: dir, named: "vanish.pdf")
                try store.enqueuePendingPaths([pdf])
                try FileManager.default.removeItem(at: pdf)
                let engine = IndexingEngine(store: store, policy: ExclusionPolicy())
                let r = try await engine.drainPending(limit: 8)
                try expectEqual(r.failed, 1, "missing file counts as failure")
                try expectEqual(try store.duePendingPaths(limit: 8).first?.attempts, 1)
            },

            // 只读句柄：pending 写全部 no-op。
            TestDesc(suite: "IndexPending", name: "readOnlyReplicaPendingWritesAreNoOp") {
                let dir = Fixtures.makeTempDir("pend-ro")
                defer { Fixtures.cleanup(dir) }
                let dbPath = dir.appendingPathComponent("index.db")
                do {
                    let store = try IndexStore(path: dbPath)
                    try store.enqueuePendingPaths([URL(fileURLWithPath: "/tmp/x/seed.pdf")])
                }
                let replicaDir = dir.appendingPathComponent("replica", isDirectory: true)
                try Fixtures.copyForReadOnlyReplica(dbURL: dbPath, into: replicaDir)
                let replica = try IndexStore(path: replicaDir.appendingPathComponent("index.db"),
                                             options: .init(readOnlyReplica: true))
                let seeded = try replica.duePendingPaths(limit: 8)
                try expectEqual(seeded.count, 1, "seed row readable on replica")
                try replica.enqueuePendingPaths([URL(fileURLWithPath: "/tmp/x/more.pdf")])   // no-op
                try replica.removePendingPaths([seeded[0].path])                              // no-op
                try replica.bumpPendingAttempts(path: seeded[0].path)                         // no-op
                let after = try replica.duePendingPaths(limit: 8)
                try expectEqual(after.count, 1)
                try expectEqual(after.first?.attempts, 0, "read-only attempts write is no-op")
            },
        ]
    }
}
