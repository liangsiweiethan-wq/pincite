import Foundation
@testable import LiteratureCore

// MARK: - 索引队列测试（迁移幂等 / 五态轮转 / version 断点续跑 /
// 时间预算切片 / 只读句柄零写 / 空文本 unavailable）

enum IndexQueueSuite {
    static func makeStore() throws -> IndexStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lit-queue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try IndexStore(path: dir.appendingPathComponent("index.db"))
    }

    @discardableResult
    static func addBook(_ store: IndexStore, id: String, pages: [String]) throws -> IndexStore.BookRow {
        let book = IndexStore.BookRow(
            id: id, realPath: "/tmp/lit-queue-books/\(id).pdf", rootPath: "/tmp/lit-queue-books",
            relPath: "\(id).pdf", fileName: "\(id).pdf",
            title: nil, author: nil, version: nil, language: nil, metaSource: nil,
            firstFingerprint: "fp-\(id)", fingerprint: "fp-\(id)", fileSize: 1, mtime: 0,
            pageCount: pages.count, status: "ok", indexedAt: 0)
        try store.upsertBook(book)
        var rows: [IndexStore.PageRow] = []
        for (i, text) in pages.enumerated() {
            let n = normalizeForSearch(text)
            rows.append(IndexStore.PageRow(bookID: id, pageNumber: i + 1, textOriginal: text,
                                           textNorm: n.text, normStarts: n.starts, normEnds: n.ends))
        }
        try store.replacePages(bookID: id, rows)
        return book
    }

    static var tests: [TestDesc] {
        [
            // 迁移幂等：重开库不重复建表、不丢行。
            TestDesc(suite: "IndexQueue", name: "schemaV7MigrationIdempotentOnReopen") {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lit-queue-mig-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dbPath = dir.appendingPathComponent("index.db")
                do {
                    let store = try IndexStore(path: dbPath)
                    try store.enqueueBook("bKeep")
                    try store.setQueueState(bookID: "bKeep", state: .indexed,
                                            queuedVersion: IndexStore.currentPipelineVersion)
                    try expectEqual(try store.allQueueRows().count, 1)
                }
                // 重开同一路径：迁移幂等（不重复建/不丢行）。
                let reopened = try IndexStore(path: dbPath)
                let rows = try reopened.allQueueRows()
                try expectEqual(rows.count, 1)
                try expectEqual(rows.first?.bookID, "bKeep")
                try expectEqual(rows.first?.state, .indexed)
                try expectTrue(IndexStore.currentSchemaVersion >= 11)   // /C：随链演进
                try expectEqual(IndexStore.currentPipelineVersion, 1)
            },

            // 五态枚举与轮转合法路径。
            TestDesc(suite: "IndexQueue", name: "fiveStatesRoundTripLegalPath") {
                let store = try makeStore()
                try addBook(store, id: "bS", pages: ["五态轮转文本"])
                try expectEqual(IndexStore.IndexQueueState.allCases.count, 5)
                // queued → indexed（version=当前）→ 到期队列为空。
                try store.enqueueBook("bS")
                try expectEqual(try store.dueQueueRows().first?.state, .queued)
                try store.setQueueState(bookID: "bS", state: .indexed,
                                        queuedVersion: IndexStore.currentPipelineVersion)
                try expectTrue(try store.dueQueueRows().isEmpty,
                               "indexed at current version is not due")
                // 旧 version 回到到期集（断点语义）。
                try store.setQueueState(bookID: "bS", state: .indexed, queuedVersion: 0)
                try expectEqual(try store.dueQueueRows().first?.state, .indexed)
                // unavailable / partial / unindexed 亦在到期集。
                try store.setQueueState(bookID: "bS", state: .unavailable, error: "x")
                try expectEqual(try store.dueQueueRows().first?.state, .unavailable)
                try store.setQueueState(bookID: "bS", state: .partial)
                try expectEqual(try store.dueQueueRows().first?.state, .partial)
                try store.setQueueState(bookID: "bS", state: .unindexed)
                try expectEqual(try store.dueQueueRows().first?.state, .unindexed)
            },

            // version 断点续跑：两册置旧 version → runQueued 只结算这两册。
            TestDesc(suite: "IndexQueue", name: "versionCheckpointResumesOnlyStaleRows") {
                let store = try makeStore()
                try addBook(store, id: "bOld1", pages: ["断点续跑第一册 权利法理"])
                try addBook(store, id: "bOld2", pages: ["断点续跑第二册 规范体系"])
                try addBook(store, id: "bFresh", pages: ["已是当前版本 规范体系"])
                try store.enqueueBook("bOld1")
                try store.enqueueBook("bOld2")
                try store.enqueueBook("bFresh")
                try store.setQueueState(bookID: "bFresh", state: .indexed,
                                        queuedVersion: IndexStore.currentPipelineVersion)
                let engine = IndexingEngine(store: store, policy: ExclusionPolicy())
                let summary = try await engine.runQueued(timeBudget: 60)
                // 文件实际不存在（合成书）：unavailable 如实，但只考虑两册旧行。
                try expectEqual(summary.considered, 2)
                try expectEqual(summary.unavailable, 2)
                try expectEqual(summary.indexed, 0)
            },

            // 时间预算切片：预算 0.05s 时中断 → 续跑完成，计数守恒。
            TestDesc(suite: "IndexQueue", name: "timeBudgetSliceResumesWithConservation") {
                let store = try makeStore()
                for i in 0..<4 {
                    try addBook(store, id: "bSlice\(i)", pages: ["切片第\(i)册 权利法理规范"])
                    try store.enqueueBook("bSlice\(i)")
                }
                let engine = IndexingEngine(store: store, policy: ExclusionPolicy())
                // 合成书文件不存在 → 每册立刻 unavailable（真 IO 极小）；
                // 预算 0s 仍至少消费一册（先消费后查时）。
                // 真断言——预算 0 恰好处理一册（unavailable 定案）
                // 后到点退出；4 行全被考虑、exhaustedBudget 如实置位。
                let first = try await engine.runQueued(timeBudget: 0)
                try expectEqual(first.considered, 4)
                try expectEqual(first.unavailable, 1,
                                "budget 0 must still serve exactly one row (consume-then-check)")
                try expectTrue(first.exhaustedBudget, "budget 0 must trip right after the first slice")
                let second = try await engine.runQueued(timeBudget: 60)
                // 预算充足：余下行全部消费（unavailable 仍是到期态会被重新
                // 考虑——），干净退出不超预算。
                try expectFalse(second.exhaustedBudget)
                // 计数守恒：两片之后 4 行俱在（不丢行）。
                let rows = try store.allQueueRows()
                try expectEqual(rows.count, 4, "queue rows never disappear")
            },

            // 只读句柄零写：入队/出队/置态全 no-op，行数不变。
            TestDesc(suite: "IndexQueue", name: "readOnlyHandleWritesNothing") {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lit-queue-ro-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dbPath = dir.appendingPathComponent("index.db")
                // 先用写句柄建库＋建行。
                do {
                    let store = try IndexStore(path: dbPath)
                    try store.enqueueBook("bRO")
                }
                let ro = try IndexStore(path: dbPath, options: IndexStore.Options(readOnlyReplica: true))
                try expectTrue(ro.isReadOnlyReplica)
                // 只读句柄上一切队列写 no-op（不抛错、不写行）。
                try ro.enqueueBook("bRO2")
                try ro.dequeueBook("bRO")
                try ro.setQueueState(bookID: "bRO", state: .indexed)
                let rows = try ro.allQueueRows()
                try expectEqual(rows.count, 1, "readonly writes are no-op")
                try expectEqual(rows.first?.bookID, "bRO")
                // 消费循环直接返回空队列（不发起白做消费）。
                let engine = IndexingEngine(store: ro, policy: ExclusionPolicy())
                let summary = try await engine.runQueued(timeBudget: 10)
                try expectEqual(summary.considered, 0)
            },

            TestDesc(suite: "IndexQueue", name: "emptyTextBookRecordsUnavailableNotIndexed") {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lit-queue-empty-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                // 真文件：Fixtures 造一页无文本 PDF（genpdf 造有字文件——空文
                // 本页走 genpdf lines: []）。
                let pdfURL = dir.appendingPathComponent("empty.pdf")
                _ = Fixtures.makePDF(pages: [.init(lines: [])], in: dir, named: "empty.pdf")
                let store = try IndexStore(path: dir.appendingPathComponent("index.db"))
                let engine = IndexingEngine(store: store, policy: ExclusionPolicy())
                _ = try await engine.indexExplicitFiles(urls: [pdfURL])
                // 入队后消费：文件存在、抽取成功但无文本 → unavailable。
                let books = try store.allBooks()
                guard let book = books.first else { try failTest("expected indexed book") }
                try store.enqueueBook(book.id)
                let summary = try await engine.runQueued(timeBudget: 60)
                // 无文本页的 PDF：抽取结果页文本为空 → unavailable（若 PDFKit
                // 提取不出任何页则 pages 为空、同样 unavailable 基准）。
                let row = try expectNotNil(try store.allQueueRows().first)
                try expectEqual(row.state, .unavailable,
                                "empty text must never be recorded as indexed")
                try expectTrue(summary.unavailable >= 1)
            },
        ]
    }
}
