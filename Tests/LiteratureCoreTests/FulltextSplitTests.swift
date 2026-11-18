import Foundation
import SQLite3
@testable import LiteratureCore

// MARK: - 两库分离测试

enum FulltextSplitSuite {
    static func makeLegacyDB(at dbURL: URL, bookID: String, pages: [String]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            try failTest("legacy db open failed")
        }
        defer { sqlite3_close(db) }
        let ddl = """
        CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE books(id TEXT PRIMARY KEY, real_path TEXT NOT NULL UNIQUE, root_path TEXT NOT NULL,
            rel_path TEXT NOT NULL, file_name TEXT NOT NULL, title TEXT, author TEXT, version TEXT,
            first_fingerprint TEXT NOT NULL, fingerprint TEXT NOT NULL, file_size INTEGER NOT NULL,
            mtime REAL NOT NULL, page_count INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'ok',
            error TEXT, indexed_at REAL NOT NULL);
        CREATE TABLE pages(book_id TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
            page_number INTEGER NOT NULL, label TEXT, printed_page INTEGER,
            text_original TEXT NOT NULL, text_norm TEXT NOT NULL,
            norm_starts BLOB NOT NULL, norm_ends BLOB NOT NULL,
            source TEXT NOT NULL DEFAULT 'native', text_latin TEXT NOT NULL DEFAULT '',
            PRIMARY KEY(book_id, page_number));
        CREATE TABLE index_queue(book_id TEXT PRIMARY KEY, state TEXT NOT NULL,
            queued_version INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
            last_error TEXT, updated_at REAL NOT NULL);
        INSERT INTO meta(key, value) VALUES('index_schema_version', '12');
        INSERT INTO meta(key, value) VALUES('normalization_version', '4');
        """
        // sqlite3_prepare_v2 compiles only the first statement in a multi-statement string
        // 首条——原写法只建了 meta 表，books/pages 根本不存在，页插入必
        // 「no such table」。DDL 全段走 sqlite3_exec；带参的 books 行单独
        // prepare/step。
        var execErr: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, ddl, nil, nil, &execErr) == SQLITE_OK else {
            let msg = execErr.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(execErr)
            try failTest("legacy ddl exec failed: \(msg)")
        }
        let insBook = """
        INSERT INTO books VALUES(?, '/tmp/legacy/\(bookID).pdf', '/tmp/legacy', '\(bookID).pdf',
            '\(bookID).pdf', NULL, NULL, NULL, 'fp-\(bookID)', 'fp-\(bookID)', 1, 0, ?, 'ok', NULL, 0);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insBook, -1, &stmt, nil) == SQLITE_OK else {
            try failTest("legacy book insert prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_bind_text(stmt, 1, bookID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 2, Int64(pages.count))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            try failTest("legacy book insert step failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_finalize(stmt)
        let ins = """
        INSERT INTO pages(book_id, page_number, text_original, text_norm, norm_starts, norm_ends, text_latin)
        VALUES(?, ?, ?, ?, ?, ?, ?);
        """
        guard sqlite3_prepare_v2(db, ins, -1, &stmt, nil) == SQLITE_OK else {
            try failTest("legacy page insert prepare failed")
        }
        // 偏移 blob 与真实索引同构（[Int32] 小端；空 blob 是真实索引永不
        // 产出的退化形态——verify 相按诚实降级丢匹配，会假红查询等值断言）。
        func offsetBlob(_ values: [Int32]) -> Data {
            var d = Data(capacity: values.count * 4)
            for v in values { var le = v.littleEndian; withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }
            return d
        }
        for (i, text) in pages.enumerated() {
            let norm = normalizeForSearch(text)
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, bookID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int64(stmt, 2, Int64(i + 1))
            sqlite3_bind_text(stmt, 3, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 4, norm.text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            offsetBlob(norm.starts).withUnsafeBytes { raw in
                _ = sqlite3_bind_blob(stmt, 5, raw.baseAddress, Int32(raw.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            offsetBlob(norm.ends).withUnsafeBytes { raw in
                _ = sqlite3_bind_blob(stmt, 6, raw.baseAddress, Int32(raw.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            sqlite3_bind_text(stmt, 7, LatinProjection.transform(norm.text), -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                try failTest("legacy page insert failed: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
        sqlite3_finalize(stmt)
    }

    /// 表所在库断言助手：schema 下对象存在 → true。
    static func objectExists(_ store: IndexStore, schema: String, name: String) throws -> Bool {
        let stmt = try store.db.prepare("SELECT 1 FROM \(schema).sqlite_master WHERE type='table' AND name = ?;")
        try stmt.bindText(1, name)
        return try stmt.step()
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "FulltextSplit", name: "freshStoreSplitsPagesIntoFulltextDB") {
                let dir = Fixtures.makeTempDir("fs-split")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                try expectTrue(store.fulltextAttached, "fresh install opens split (ft attached)")
                try expectTrue(try objectExists(store, schema: "main", name: "books"))
                try expectTrue(try objectExists(store, schema: "main", name: "meta"))
                try expectFalse(try objectExists(store, schema: "main", name: "pages"),
                                "main must NOT carry pages after split")
                try expectTrue(try objectExists(store, schema: "ft", name: "pages"))
                try expectTrue(try objectExists(store, schema: "ft", name: "pages_fts"))
                try expectTrue(try objectExists(store, schema: "ft", name: "bigram_index"))
                try expectTrue(try objectExists(store, schema: "ft", name: "pages_wfts"))
                try expectTrue(try objectExists(store, schema: "ft", name: "book_native_counts"))
                try expectTrue(try objectExists(store, schema: "ft", name: "ft_meta"))
                // fulltext.db 落点 = index.db 同目录（init 推导）。
                try expectTrue(FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("fulltext.db").path))
            },

            TestDesc(suite: "FulltextSplit", name: "snapshotProductsCarryOnlyIndexDB") {
                let dir = Fixtures.makeTempDir("fs-snap")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                try expectTrue(store.fulltextAttached)
                let snapDir = dir.appendingPathComponent("snaps")
                let manager = SnapshotManager(snapshotDir: snapDir,
                                              sources: [("index", dir.appendingPathComponent("index.db"))],
                                              keep: 3)
                let product = try manager.takeSnapshot()
                let files = try FileManager.default.contentsOfDirectory(atPath: product.path)
                    .filter { !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") }
                try expectEqual(files, ["index.db"],
                                "snapshot must carry only index.db (fulltext excluded by construction)")
            },

            TestDesc(suite: "FulltextSplit", name: "deleteBookLeavesNoOrphanFulltextPages") {
                let dir = Fixtures.makeTempDir("fs-del")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                Fixtures.makePDF(pages: [.init(lines: ["orphan check 孤儿检查"])], in: dir, named: "o.pdf")
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                let book = try expectNotNil(try store.allBooks().first)
                try expectNotNil(try store.page(bookID: book.id, pageNumber: 1))
                try store.deleteBook(id: book.id)
                // 显式删路径：ft.pages 零孤儿。
                let orphan = try store.db.prepare("SELECT COUNT(*) FROM ft.pages WHERE book_id NOT IN (SELECT id FROM main.books);")
                try expectTrue(try orphan.step())
                try expectEqual(Int(orphan.int(0)), 0)
                // 清扫路径：人工塞一行孤儿 → 清 throttle → sweepOrphanFulltextPagesLocked。
                try store.db.exec("INSERT INTO ft.pages(book_id, page_number, text_original, text_norm, norm_starts, norm_ends) VALUES('bGhost', 1, 'x', 'x', X'', X'');")
                try store.setMetaValue("orphan_sweep_at", "0")
                try store.sweepOrphanFulltextPagesLocked()
                let orphan2 = try store.db.prepare("SELECT COUNT(*) FROM ft.pages WHERE book_id NOT IN (SELECT id FROM main.books);")
                try expectTrue(try orphan2.step())
                try expectEqual(Int(orphan2.int(0)), 0)
            },

            TestDesc(suite: "FulltextSplit", name: "persistWriteOrderWindowKeepsFingerprintSemantics") {
                let dir = Fixtures.makeTempDir("fs-write-order")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                Fixtures.makePDF(pages: [.init(lines: ["write order v1"])], in: dir, named: "w.pdf")
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                let book = try expectNotNil(try store.allBooks().first)
                try store.enqueueBook(book.id)
                let engine = IndexingEngine(store: store, policy: ExclusionPolicy())
                let consumed = try await engine.runQueued(timeBudget: 10)
                try expectEqual(consumed.indexed, 1)
                try store.db.exec("DELETE FROM ft.pages WHERE book_id = '\(book.id)';")
                try store.setQueueState(bookID: book.id, state: .queued,
                                        queuedVersion: IndexStore.currentPipelineVersion)
                let consumed2 = try await engine.runQueued(timeBudget: 10)
                try expectEqual(consumed2.unavailable, 1,
                                "fingerprint advanced without pages must never be stamped indexed")
                // unavailable 行留在到期集（文件恢复可重试——既有队列语义）。
                try expectEqual(try store.dueQueueRows().count, 1)
            },

            TestDesc(suite: "FulltextSplit", name: "legacyMigrationMovesPagesAndPreservesQueries") {
                let dir = Fixtures.makeTempDir("fs-mig")
                defer { Fixtures.cleanup(dir) }
                let dbPath = dir.appendingPathComponent("index.db")
                try makeLegacyDB(at: dbPath, bookID: "bLeg", pages: ["迁移前的独特文本 qz Unique 迁移锚点", "second page text"])
                // legacy 开库：main.pages 存在 → 不 ATTACH 走旧读路。
                let legacy = try IndexStore(path: dbPath)
                try expectFalse(legacy.fulltextAttached, "legacy layout opens without ft")
                let serviceBefore = SearchService(store: legacy)
                let hitsBefore = try serviceBefore.search("迁移锚点")
                try expectEqual(hitsBefore.count, 1)
                let latinBefore = try serviceBefore.search("Unique")
                try expectEqual(latinBefore.count, 1)
                // 搬迁。
                let summary = try legacy.migrateMainPagesToFulltext(progress: nil, vacuumAfter: true)
                try expectEqual(summary.booksMoved, 1)
                try expectEqual(summary.pagesMoved, 2)
                try expectTrue(summary.ftsRebuilt)
                try expectEqual(try legacy.pageCount(bookID: "bLeg"), 2)
                try expectFalse(try objectExists(legacy, schema: "main", name: "pages"))
                // 迁移后同查询同结果（查询等值断言）。
                let hitsAfter = try serviceBefore.search("迁移锚点")
                try expectEqual(hitsAfter.count, 1)
                let latinAfter = try serviceBefore.search("Unique")
                try expectEqual(latinAfter.count, 1)
                // 重开：split 形态（main.pages 已 DROP）＋数据完整。
                let reopened = try IndexStore(path: dbPath)
                try expectTrue(reopened.fulltextAttached, "post-migration reopen is split")
                try expectEqual(try reopened.pageCount(bookID: "bLeg"), 2)
                let hitsReopen = try SearchService(store: reopened).search("迁移锚点")
                try expectEqual(hitsReopen.count, 1)
                // 幂等：已迁移库再迁 → 显式拒绝（不静默半搬）。
                try expectThrows(try reopened.migrateMainPagesToFulltext(progress: nil, vacuumAfter: false))
            },
        ]
    }

}
