import Foundation
@testable import LiteratureCore


enum HighlightStoreSuite {
    static var tests: [TestDesc] {
        [
            TestDesc(suite: "HighlightStore", name: "schemaVersionIsSeven") {
                let dir = Fixtures.makeTempDir("hl-schema")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                // IndexStore 顶层 schema_version 随迁移链常量走（6，
                // page_map 表；本套件的 user_highlights 子模式不受影响），
                // user_highlights 子模式（style + view_source 列）记录在自己的 meta 键下。
                try expectEqual(try store.metaValue("schema_version"),
                                String(IndexStore.currentSchemaVersion))
                let highlights = HighlightStore(indexStore: store)
                try expectEqual(try store.metaValue("user_highlights_schema_version"), "8")  // 7→8（三列 additive）
                try expectEqual(try highlights.highlightsForBook("bX").count, 0)
                try expectEqual(try highlights.highlightsForPage(bookID: "bX", pageNumber: 1).count, 0)
            },

            TestDesc(suite: "HighlightStore", name: "addListByBookAndPage") {
                let dir = Fixtures.makeTempDir("hl-crud")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let highlights = HighlightStore(indexStore: store)
                let id1 = try highlights.add(bookID: "bA", pageNumber: 2, utf16Start: 5, utf16End: 12,
                                             color: .yellow)
                let id2 = try highlights.add(bookID: "bA", pageNumber: 1, utf16Start: 0, utf16End: 4,
                                             color: .blue, note: "n1")
                _ = try highlights.add(bookID: "bB", pageNumber: 1, utf16Start: 3, utf16End: 9,
                                       color: .red)
                try expectNotEqual(id1, id2)

                let forBook = try highlights.highlightsForBook("bA")
                try expectEqual(forBook.count, 2)
                // ordered by page_number, then utf16_start
                try expectEqual(forBook[0].id, id2)
                try expectEqual(forBook[1].id, id1)
                try expectEqual(forBook[0].color, .blue)
                try expectEqual(forBook[0].note, "n1")
                try expectEqual(forBook[0].pageNumber, 1)
                try expectEqual(forBook[1].utf16Start, 5)
                try expectEqual(forBook[1].utf16End, 12)

                let forPage = try highlights.highlightsForPage(bookID: "bA", pageNumber: 2)
                try expectEqual(forPage.count, 1)
                try expectEqual(forPage[0].id, id1)
                try expectEqual(forPage[0].bookID, "bA")

                // colors carry fixed presentation hex values
                try expectEqual(HighlightColor.yellow.colorHex, "#F7D774")
                try expectEqual(HighlightColor.green.colorHex, "#A8D5A2")
                try expectEqual(HighlightColor.blue.colorHex, "#9FC5E8")
                try expectEqual(HighlightColor.red.colorHex, "#E8A09A")
            },

            TestDesc(suite: "HighlightStore", name: "updateColorAndNote") {
                let dir = Fixtures.makeTempDir("hl-update")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let highlights = HighlightStore(indexStore: store)
                let id = try highlights.add(bookID: "bA", pageNumber: 1, utf16Start: 0, utf16End: 3,
                                            color: .yellow)
                try highlights.updateColor(id: id, color: .green)
                try highlights.updateNote(id: id, note: "changed")
                let all = try highlights.highlightsForBook("bA")
                try expectEqual(all.count, 1)
                try expectEqual(all[0].color, .green)
                try expectEqual(all[0].note, "changed")
                // updates on missing ids throw
                try expectThrows(try highlights.updateColor(id: id + 999, color: .red), "missing id must throw")
                try expectThrows(try highlights.updateNote(id: id + 999, note: "x"), "missing id must throw")
            },

            TestDesc(suite: "HighlightStore", name: "deleteRemovesHighlight") {
                let dir = Fixtures.makeTempDir("hl-delete")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let highlights = HighlightStore(indexStore: store)
                let id = try highlights.add(bookID: "bA", pageNumber: 1, utf16Start: 0, utf16End: 3,
                                            color: .yellow)
                try highlights.delete(id: id)
                try expectEqual(try highlights.highlightsForBook("bA").count, 0)
                try expectThrows(try highlights.delete(id: id), "deleting a missing id must throw")
            },

            TestDesc(suite: "HighlightStore", name: "utf16BoundsAreValidatedOnAdd") {
                let dir = Fixtures.makeTempDir("hl-bounds")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let highlights = HighlightStore(indexStore: store)
                // valid boundary cases
                _ = try highlights.add(bookID: "bA", pageNumber: 1, utf16Start: 0, utf16End: 1, color: .yellow)
                _ = try highlights.add(bookID: "bA", pageNumber: 1, utf16Start: 10, utf16End: 1_000_000, color: .yellow)
                // invalid: negative start
                try expectThrows(try highlights.add(bookID: "bA", pageNumber: 1, utf16Start: -1, utf16End: 5, color: .yellow), "negative start must throw")
                // invalid: empty range
                try expectThrows(try highlights.add(bookID: "bA", pageNumber: 1, utf16Start: 5, utf16End: 5, color: .yellow), "empty range must throw")
                // invalid: reversed range
                try expectThrows(try highlights.add(bookID: "bA", pageNumber: 1, utf16Start: 9, utf16End: 3, color: .yellow), "reversed range must throw")
                // invalid: beyond sanity cap
                try expectThrows(try highlights.add(bookID: "bA", pageNumber: 1, utf16Start: 0, utf16End: 1_000_001, color: .yellow), "over cap must throw")
                try expectEqual(try highlights.highlightsForBook("bA").count, 2)
            },

            TestDesc(suite: "HighlightStore", name: "existingV4DatabaseMigratesAndStaysEmpty") {
                let dir = Fixtures.makeTempDir("hl-mig")
                defer { Fixtures.cleanup(dir) }
                let dbPath = dir.appendingPathComponent("old.db")
                let old = try SQLiteDatabase(path: dbPath.path)
                try old.exec("""
                CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                INSERT INTO meta VALUES('schema_version','4');
                """)
                let store = try IndexStore(path: dbPath)
                try expectEqual(try store.metaValue("schema_version"), String(IndexStore.currentSchemaVersion))
                let highlights = HighlightStore(indexStore: store)
                try expectEqual(try highlights.highlightsForBook("bA").count, 0, "migrated db has no highlights, and queries must not throw")
                let id = try highlights.add(bookID: "bA", pageNumber: 1, utf16Start: 2, utf16End: 8, color: .green)
                let added = try highlights.highlightsForBook("bA").first
                try expectEqual(added?.id, id)
                try expectEqual(added?.style, "highlight", "fresh rows default to style 'highlight'")
            },

            TestDesc(suite: "HighlightStore", name: "addWithExplicitUnderlineStyleReadsBack") {
                let dir = Fixtures.makeTempDir("hl-style")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let highlights = HighlightStore(indexStore: store)
                let underlineID = try highlights.add(bookID: "bA", pageNumber: 1, utf16Start: 0, utf16End: 5,
                                                     color: .blue, style: "underline")
                let defaultID = try highlights.add(bookID: "bA", pageNumber: 1, utf16Start: 6, utf16End: 9,
                                                   color: .red)
                let all = try highlights.highlightsForBook("bA")
                try expectEqual(all.count, 2)
                try expectEqual(all[0].id, underlineID)
                try expectEqual(all[0].style, "underline")
                try expectEqual(all[0].color, .blue)
                try expectEqual(all[1].id, defaultID)
                try expectEqual(all[1].style, "highlight", "style param omitted defaults to 'highlight'")
                // unknown style values normalize to 'highlight'
                let weirdID = try highlights.add(bookID: "bA", pageNumber: 1, utf16Start: 10, utf16End: 12,
                                                 color: .yellow, style: "weird")
                let weird = try highlights.highlightsForBook("bA").first { $0.id == weirdID }
                try expectEqual(weird?.style, "highlight")
            },

            TestDesc(suite: "HighlightStore", name: "legacyV5DatabaseWithoutStyleColumnMigrates") {
                let dir = Fixtures.makeTempDir("hl-style-mig")
                defer { Fixtures.cleanup(dir) }
                let dbPath = dir.appendingPathComponent("old.db")
                let old = try SQLiteDatabase(path: dbPath.path)
                try old.exec("""
                CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                INSERT INTO meta VALUES('schema_version','5');
                CREATE TABLE user_highlights(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    book_id TEXT NOT NULL,
                    page_number INTEGER NOT NULL,
                    utf16_start INTEGER NOT NULL,
                    utf16_end INTEGER NOT NULL,
                    color TEXT NOT NULL,
                    note TEXT NOT NULL DEFAULT '',
                    created_at REAL NOT NULL,
                    anchor_text TEXT NOT NULL DEFAULT '',
                    anchor_verified INTEGER NOT NULL DEFAULT 0
                );
                INSERT INTO user_highlights(book_id, page_number, utf16_start, utf16_end, color, created_at)
                VALUES('bA', 1, 2, 8, 'green', 100.0);
                """)
                let store = try IndexStore(path: dbPath)
                let highlights = HighlightStore(indexStore: store)
                try expectEqual(try store.metaValue("user_highlights_schema_version"), "8")  // 7→8（三列 additive）
                let migrated = try highlights.highlightsForBook("bA")
                try expectEqual(migrated.count, 1, "legacy row survives the style-column migration")
                try expectEqual(migrated[0].style, "highlight", "legacy rows read back as style 'highlight'")
                try expectEqual(migrated[0].viewSource, "ocr", "legacy rows read back as viewSource 'ocr'")
                try expectEqual(migrated[0].color, .green)
                // and new rows can carry explicit styles alongside legacy ones
                let newID = try highlights.add(bookID: "bA", pageNumber: 1, utf16Start: 20, utf16End: 25,
                                               color: .red, style: "underline")
                let all = try highlights.highlightsForBook("bA")
                try expectEqual(all.count, 2)
                try expectEqual(all.first { $0.id == newID }?.style, "underline")
            },

            TestDesc(suite: "HighlightStore", name: "updateAppearanceChangesColorAndStyle") {
                let dir = Fixtures.makeTempDir("hl-appearance")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let highlights = HighlightStore(indexStore: store)
                let id = try highlights.add(bookID: "bA", pageNumber: 1, utf16Start: 0, utf16End: 3,
                                            color: .yellow, style: "highlight")
                try highlights.updateAppearance(id: id, color: .blue, style: "underline")
                var all = try highlights.highlightsForBook("bA")
                try expectEqual(all[0].color, .blue)
                try expectEqual(all[0].style, "underline")
                // style toggles back without touching other fields
                try highlights.updateAppearance(id: id, color: .blue, style: "highlight")
                all = try highlights.highlightsForBook("bA")
                try expectEqual(all[0].color, .blue)
                try expectEqual(all[0].style, "highlight")
                // updateColor still works and preserves the style column
                try highlights.updateColor(id: id, color: .red)
                all = try highlights.highlightsForBook("bA")
                try expectEqual(all[0].color, .red)
                try expectEqual(all[0].style, "highlight")
                try expectThrows(try highlights.updateAppearance(id: id + 999, color: .red, style: "underline"),
                                 "missing id must throw")
            },

            TestDesc(suite: "HighlightStore", name: "anchorDriftReanchorsSuccessfully") {
                let dir = Fixtures.makeTempDir("hl-drift")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let highlights = HighlightStore(indexStore: store)

                let initialText = "Original header. Here is the highlighted text to test anchor drift. Footer."
                let anchor = "highlighted text"
                let start16 = (initialText as NSString).range(of: anchor).location
                let end16 = start16 + (anchor as NSString).length

                try Self.addBook(store, id: "b1", text: initialText)
                let id = try highlights.add(bookID: "b1", pageNumber: 1,
                                            utf16Start: start16, utf16End: end16,
                                            color: .yellow, anchorText: anchor)

                let storedBefore = try highlights.highlightsForBook("b1")
                try expectEqual(storedBefore.count, 1)
                try expectEqual(storedBefore[0].anchorVerified, 1)
                try expectEqual(storedBefore[0].utf16Start, start16)

                // Page text drifts: a prefix is inserted, shifting the anchor to a new offset
                let driftedText = "Newly inserted prefix line shifts offsets! " + initialText
                try Self.addBook(store, id: "b1", text: driftedText)

                let newStart16 = (driftedText as NSString).range(of: anchor).location
                let newEnd16 = newStart16 + (anchor as NSString).length
                try expectNotEqual(start16, newStart16)

                // Render verification triggers double-check & re-anchoring
                let verified = try highlights.verifiedHighlightsForPage(bookID: "b1", pageNumber: 1)
                try expectEqual(verified.count, 1)
                try expectEqual(verified[0].id, id)
                try expectEqual(verified[0].utf16Start, newStart16)
                try expectEqual(verified[0].utf16End, newEnd16)
                try expectEqual(verified[0].anchorVerified, 1)

                // Database has been updated with the re-anchored coordinates
                let reloaded = try highlights.highlightsForBook("b1")[0]
                try expectEqual(reloaded.utf16Start, newStart16)
                try expectEqual(reloaded.utf16End, newEnd16)
                try expectEqual(reloaded.anchorVerified, 1)
            },

            TestDesc(suite: "HighlightStore", name: "anchorDeletedMarksInvalid") {
                let dir = Fixtures.makeTempDir("hl-deleted")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let highlights = HighlightStore(indexStore: store)

                let initialText = "Chapter 1. Sentence that will be completely deleted later. End."
                let anchor = "Sentence that will be completely deleted later."
                let start16 = (initialText as NSString).range(of: anchor).location
                let end16 = start16 + (anchor as NSString).length

                try Self.addBook(store, id: "b2", text: initialText)
                _ = try highlights.add(bookID: "b2", pageNumber: 1,
                                       utf16Start: start16, utf16End: end16,
                                       color: .blue, anchorText: anchor)

                // Page text updated: the anchor text has been completely removed
                let replacedText = "Chapter 1. Completely different content without the anchor. End."
                try Self.addBook(store, id: "b2", text: replacedText)

                // Render verification fails to find anchor -> marked invalid (anchorVerified = -1)
                let forPage = try highlights.verifiedHighlightsForPage(bookID: "b2", pageNumber: 1)
                try expectEqual(forPage.count, 0, "stale/invalid highlight must NOT be rendered on PDF")

                // Row is retained in database (never deleted)
                let all = try highlights.highlightsForBook("b2")
                try expectEqual(all.count, 1, "stale highlight is preserved in store without deletion")
                try expectEqual(all[0].anchorVerified, -1, "stale highlight is marked invalid")
            },

            // MARK: — 显式事务 / 启动完整性检查 / .bak 快照回退

            TestDesc(suite: "HighlightStore", name: "batchAddIsAtomicAndWritesRollingBackup") {
                let dir = Fixtures.makeTempDir("hl-batch")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let highlights = HighlightStore(indexStore: store)
                let ids = try highlights.addBatch([
                    ("bA", 1, 0, 5, .yellow, "n1", "alpha", 0, "highlight"),
                    ("bA", 2, 3, 9, .green, "", "beta", 1, "underline"),
                    ("bB", 1, 2, 8, .red, "", "", 0, "highlight"),
                ])
                try expectEqual(ids.count, 3)
                try expectEqual(try highlights.highlightsForBook("bA").count, 2)
                try expectEqual(try highlights.highlightsForBook("bB").count, 1)

                // 滚动备份：与 index.db 同目录、JSON 载荷可解码回全表内容。
                let backupURL = highlights.backupFileURL
                try expectTrue(FileManager.default.fileExists(atPath: backupURL.path), "批量写后必须滚动一份 .bak")
                let payload = try JSONDecoder().decode(HighlightStore.BackupPayload.self,
                                                       from: Data(contentsOf: backupURL))
                try expectEqual(payload.format, HighlightStore.backupFormatID)
                try expectEqual(payload.rows.count, 3)
                try expectEqual(payload.rows[1].bookID, "bA")
                try expectEqual(payload.rows[1].style, "underline")
                try expectEqual(payload.rows[1].anchorVerified, 1)

                // 整批校验前置：任一条越界 → 整批拒绝，BEGIN 之前就失败。
                try expectThrows(try highlights.addBatch([
                    ("bC", 1, 0, 5, .yellow, "", "", 0, "highlight"),
                    ("bC", 1, 9, 3, .yellow, "", "", 0, "highlight"),
                ]), "越界项必须让整批失败")
                try expectEqual(try highlights.highlightsForBook("bC").count, 0)
            },

            TestDesc(suite: "HighlightStore", name: "explicitTransactionRollsBackMidwayFailure") {
                let dir = Fixtures.makeTempDir("hl-tx-rollback")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let highlights = HighlightStore(indexStore: store)
                func row() -> HighlightStore.PendingHighlight {
                    HighlightStore.PendingHighlight(
                        bookID: "bA", pageNumber: 1, utf16Start: 0, utf16End: 4,
                        color: .yellow, note: "", createdAt: 0, anchorText: "",
                        anchorVerified: 0, style: "highlight")
                }
                // 事务内先插一条合法行，再制造 SQL 层失败（INSERT 引用已被
                // DROP 的表）→ 显式事务必须把先前插入一并回滚。
                try expectTrue(store.db.tryExec("DROP TABLE user_highlights;"), "测试前置 DROP 必须成功")
                _ = try? highlights.performWriteTransaction {
                    _ = try highlights.insertRowLocked(row())
                    let boom = try store.db.prepare("INSERT INTO user_highlights_missing(book_id) VALUES('x');")
                    try boom.run()
                }
                // 事务失败后表仍在缺失态（ROLLBACK 不复活 DROP）；重建表后
                // 行数必须为 0 —— 事务内的那行插入没有留下半态。
                try store.db.exec("""
                CREATE TABLE user_highlights(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    book_id TEXT NOT NULL, page_number INTEGER NOT NULL,
                    utf16_start INTEGER NOT NULL, utf16_end INTEGER NOT NULL,
                    color TEXT NOT NULL, note TEXT NOT NULL DEFAULT '',
                    created_at REAL NOT NULL, anchor_text TEXT NOT NULL DEFAULT '',
                    anchor_verified INTEGER NOT NULL DEFAULT 0,
                    style TEXT NOT NULL DEFAULT 'highlight',
                    view_source TEXT NOT NULL DEFAULT 'ocr',
                    device_id TEXT NOT NULL DEFAULT '',
                    row_uuid TEXT NOT NULL DEFAULT '',
                    deleted_at REAL);
                """)
                try expectEqual(try highlights.highlightsForBook("bA").count, 0,
                                "事务中途失败必须整批回滚，不留半态")
            },

            TestDesc(suite: "HighlightStore", name: "droppedTableRestoresFromBackupOnReinit") {
                let dir = Fixtures.makeTempDir("hl-restore")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let highlights = HighlightStore(indexStore: store)
                _ = try highlights.addBatch([
                    ("bA", 1, 0, 5, .yellow, "keep1", "first anchor", 1, "highlight"),
                    ("bA", 2, 6, 12, .blue, "keep2", "second anchor", 1, "underline"),
                ])
                // 模拟损坏：直接 DROP 批注表（表结构损坏在 SQLite 侧同样
                // 表现为表不可用；quick_check 分支与缺失分支共用回退路径）。
                try expectTrue(store.db.tryExec("DROP TABLE user_highlights;"), "测试前置 DROP 必须成功")
                // 重新初始化（同 IndexStore）：完整性检查先于迁移 DDL，发现
                // 表缺失 → 从 .bak 灌回。
                let revived = HighlightStore(indexStore: store)
                let restored = try revived.highlightsForBook("bA")
                try expectEqual(restored.count, 2, "损坏后必须从 .bak 完整回退")
                try expectEqual(restored[0].note, "keep1")
                try expectEqual(restored[0].anchorText, "first anchor")
                try expectEqual(restored[1].style, "underline")
                try expectEqual(try store.metaValue("highlights_restore_ok"), "1")
                let reason = try expectNotNil(try store.metaValue("highlights_restore_reason"))
                try expectTrue(reason.contains("缺失"), "留痕原因应指出表缺失: \(reason)")
                try expectNotNil(try store.metaValue("highlights_restore_at"))
                // 回退后的库可继续正常写入，并滚动新备份。
                _ = try revived.add(bookID: "bB", pageNumber: 1, utf16Start: 0, utf16End: 3, color: .red)
                try expectEqual(try revived.highlightsForBook("bB").count, 1)
            },

            TestDesc(suite: "HighlightStore", name: "addVerifiedAnchorsInOneTransaction") {
                let dir = Fixtures.makeTempDir("hl-addverified")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let highlights = HighlightStore(indexStore: store)
                let text = "In the beginning of the passage lies our target phrase."
                try Self.addBook(store, id: "b1", text: text)

                let anchor = "target phrase"
                let r = (text as NSString).range(of: anchor)
                let ok = try highlights.addVerified(bookID: "b1", pageNumber: 1,
                                                    utf16Start: r.location, utf16End: r.location + r.length,
                                                    color: .yellow, anchorText: anchor)
                try expectEqual(ok.anchorVerified, 1)
                try expectEqual(ok.utf16Start, r.location)

                let drifted = try highlights.addVerified(bookID: "b1", pageNumber: 1,
                                                         utf16Start: 0, utf16End: 4,
                                                         color: .blue, anchorText: anchor)
                try expectEqual(drifted.anchorVerified, 1)
                try expectEqual(drifted.utf16Start, r.location, "重锚定坐标必须写回")

                let lost = try highlights.addVerified(bookID: "b1", pageNumber: 1,
                                                      utf16Start: 0, utf16End: 4,
                                                      color: .red, anchorText: "absent anchor text")
                try expectEqual(lost.anchorVerified, -1)
                try expectEqual(try highlights.highlightsForBook("b1").count, 3,
                                "失效项保留不删除")
            },

            // MARK: — view_source 视图来源（迁移/双来源过滤/original 增删查）

            TestDesc(suite: "HighlightStore", name: "v6DatabaseWithoutViewSourceColumnMigrates") {
                let dir = Fixtures.makeTempDir("hl-v6-mig")
                defer { Fixtures.cleanup(dir) }
                let dbPath = dir.appendingPathComponent("old.db")
                let old = try SQLiteDatabase(path: dbPath.path)
                try old.exec("""
                CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                INSERT INTO meta VALUES('schema_version','5');
                INSERT INTO meta VALUES('user_highlights_schema_version','6');
                CREATE TABLE user_highlights(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    book_id TEXT NOT NULL,
                    page_number INTEGER NOT NULL,
                    utf16_start INTEGER NOT NULL,
                    utf16_end INTEGER NOT NULL,
                    color TEXT NOT NULL,
                    note TEXT NOT NULL DEFAULT '',
                    created_at REAL NOT NULL,
                    anchor_text TEXT NOT NULL DEFAULT '',
                    anchor_verified INTEGER NOT NULL DEFAULT 0,
                    style TEXT NOT NULL DEFAULT 'highlight'
                );
                INSERT INTO user_highlights(book_id, page_number, utf16_start, utf16_end, color, created_at, style)
                VALUES('bA', 3, 2, 8, 'blue', 200.0, 'underline');
                """)
                let store = try IndexStore(path: dbPath)
                let highlights = HighlightStore(indexStore: store)
                // 子版本 6→7；旧数据迁移后整体标 'ocr'（语义零损失）。
                try expectEqual(try store.metaValue("user_highlights_schema_version"), "8")  // 7→8（三列 additive）
                let migrated = try highlights.highlightsForBook("bA")
                try expectEqual(migrated.count, 1, "v6 行必须在 view_source 迁移中幸存")
                try expectEqual(migrated[0].viewSource, "ocr", "迁移旧行必须整体标 'ocr'")
                try expectEqual(migrated[0].pageNumber, 3)
                try expectEqual(migrated[0].style, "underline")
                try expectEqual(migrated[0].color, .blue)
            },

            TestDesc(suite: "HighlightStore", name: "dualViewSourceWriteAndFilterDoesNotCrossShow") {
                let dir = Fixtures.makeTempDir("hl-dual-src")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let highlights = HighlightStore(indexStore: store)
                // 同书同页写两来源各一条；默认参数 = 'ocr'（既有调用零改动）。
                let ocrID = try highlights.add(bookID: "bA", pageNumber: 2, utf16Start: 0, utf16End: 5,
                                               color: .yellow)
                let originalID = try highlights.add(bookID: "bA", pageNumber: 2, utf16Start: 6, utf16End: 11,
                                                    color: .blue, viewSource: "original")
                try expectNotEqual(ocrID, originalID)
                // 默认（'ocr'）与显式 'original' 互不串显。
                try expectEqual(try highlights.highlightsForBook("bA").map(\.id), [ocrID])
                try expectEqual(try highlights.highlightsForBook("bA", viewSource: "original").map(\.id), [originalID])
                // nil = 全部来源（批注面板汇总用），按页升序+偏移排序。
                try expectEqual(try highlights.highlightsForBook("bA", viewSource: nil).map(\.id), [ocrID, originalID])
                // 页查询同样过滤。
                try expectEqual(try highlights.highlightsForPage(bookID: "bA", pageNumber: 2).count, 1)
                try expectEqual(try highlights.highlightsForPage(bookID: "bA", pageNumber: 2, viewSource: "original").count, 1)
                try expectEqual(try highlights.highlightsForPage(bookID: "bA", pageNumber: 2, viewSource: nil).count, 2)
                // 未知历史值读回归一为 'ocr'（写入侧同样归一）。
                let weirdID = try highlights.add(bookID: "bA", pageNumber: 1, utf16Start: 0, utf16End: 3,
                                                 color: .red, viewSource: "weird")
                let weird = try highlights.highlightsForBook("bA", viewSource: nil).first { $0.id == weirdID }
                try expectEqual(weird?.viewSource, "ocr", "未知 viewSource 必须归一为 'ocr'")
            },

            TestDesc(suite: "HighlightStore", name: "originalViewSourceCRUDIsStable") {
                let dir = Fixtures.makeTempDir("hl-original-crud")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let highlights = HighlightStore(indexStore: store)
                let id = try highlights.add(bookID: "bA", pageNumber: 4, utf16Start: 1, utf16End: 9,
                                            color: .green, note: "orig", viewSource: "original")
                try highlights.updateColor(id: id, color: .red)
                try highlights.updateAppearance(id: id, color: .blue, style: "underline")
                try highlights.updateNote(id: id, note: "orig2")
                let row = try highlights.highlightsForBook("bA", viewSource: "original")[0]
                try expectEqual(row.color, .blue)
                try expectEqual(row.style, "underline")
                try expectEqual(row.note, "orig2")
                try expectEqual(row.viewSource, "original")
                try highlights.delete(id: id)
                try expectEqual(try highlights.highlightsForBook("bA", viewSource: "original").count, 0)
                // addVerified 同样带来源。
                let verified = try highlights.addVerified(bookID: "bA", pageNumber: 1,
                                                          utf16Start: 0, utf16End: 2,
                                                          color: .yellow, anchorText: "ab",
                                                          pageText: "abcd", viewSource: "original")
                try expectEqual(verified.viewSource, "original")
                // addBatch 整批来源参数。
                _ = try highlights.addBatch([
                    ("bB", 1, 0, 4, .yellow, "", "abcd", 0, "highlight"),
                ], viewSource: "original")
                try expectEqual(try highlights.highlightsForBook("bB", viewSource: "original").count, 1)
                try expectEqual(try highlights.highlightsForBook("bB").count, 0)
            },

            TestDesc(suite: "HighlightStore", name: "pageNoteNeverRendersButStaysListed") {
                let dir = Fixtures.makeTempDir("hl-page-note")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let highlights = HighlightStore(indexStore: store)
                let text = "Whole page note anchor material."
                try Self.addBook(store, id: "b1", text: text)
                // 页级批注（无选区）：(0,0) 占位区间 + 空 anchor。
                let id = try highlights.addPageNote(bookID: "b1", pageNumber: 1,
                                                    note: "整页批注内容", viewSource: "original")
                try expectNotEqual(id, Int64(0))
                // 渲染查询必须不产出（校验语义自然判失效）。
                try expectEqual(try highlights.verifiedHighlightsForPage(
                    bookID: "b1", pageNumber: 1, pageText: text).count, 0)
                try expectEqual(try highlights.verifiedHighlightsForPage(
                    bookID: "b1", pageNumber: 1, pageText: text, viewSource: "original").count, 0)
                // 列表查询保留（含失效项；批注面板据此展示）。
                let listed = try highlights.verifiedHighlightsForBook("b1", viewSource: "original")
                try expectEqual(listed.count, 1)
                try expectEqual(listed[0].note, "整页批注内容")
                try expectEqual(listed[0].utf16Start, 0)
                try expectEqual(listed[0].utf16End, 0)
                try expectEqual(listed[0].anchorVerified, -1)
                // 页级批注可被 updateNote/delete 正常操作。
                try highlights.updateNote(id: id, note: "改过的批注")
                try expectEqual(try highlights.highlightsForBook("b1", viewSource: nil)[0].note, "改过的批注")
                try highlights.delete(id: id)
                try expectEqual(try highlights.highlightsForBook("b1", viewSource: nil).count, 0)
            },

            TestDesc(suite: "HighlightStore", name: "backupCarriesViewSourceAndReadsLegacyPayload") {
                let dir = Fixtures.makeTempDir("hl-backup-src")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let highlights = HighlightStore(indexStore: store)
                // 事务批写（滚动 .bak 的路径）带整批 viewSource。
                _ = try highlights.addBatch([
                    ("bA", 1, 0, 4, .yellow, "", "abcd", 0, "highlight"),
                    ("bA", 2, 0, 4, .blue, "", "abcd", 0, "highlight"),
                ])
                _ = try highlights.addBatch([
                    ("bA", 2, 6, 10, .blue, "", "abcd", 0, "highlight"),
                ], viewSource: "original")
                // 滚动备份载荷带 view_source（最后一份快照覆盖全表 3 行）。
                let payload = try JSONDecoder().decode(HighlightStore.BackupPayload.self,
                                                       from: Data(contentsOf: highlights.backupFileURL))
                try expectEqual(payload.rows.count, 3)
                try expectEqual(payload.rows[0].viewSource, "ocr")
                try expectEqual(payload.rows[2].viewSource, "original")
                // 旧 /1 载荷（无 view_source 键）必须仍可解码（回退路径兼容）。
                let legacyJSON = """
                {"format":"\(HighlightStore.backupFormatID)","rows":[
                  {"bookID":"bZ","pageNumber":1,"utf16Start":0,"utf16End":4,"color":"yellow",
                   "note":"","createdAt":1.0,"anchorText":"abcd","anchorVerified":1,"style":"highlight"}]}
                """
                let legacy = try JSONDecoder().decode(HighlightStore.BackupPayload.self, from: Data(legacyJSON.utf8))
                try expectEqual(legacy.rows.count, 1)
                try expectEqual(legacy.rows[0].viewSource, nil, "旧载荷缺 view_source 键必须解码为 nil")
            },
        ]
    }

    private static func addBook(_ store: IndexStore, id: String, text: String,
                                status: String = "ok", fingerprint: String = "fp1") throws {
        let book = IndexStore.BookRow(
            id: id, realPath: "/tmp/lit-tests/\(id).pdf", rootPath: "/tmp/lit-tests",
            relPath: "\(id).pdf", fileName: "\(id).pdf",
            firstFingerprint: fingerprint, fingerprint: fingerprint, fileSize: 100, mtime: 0,
            pageCount: 1, status: status, indexedAt: 0)
        try store.upsertBook(book)
        let n = normalizeForSearch(text)
        let page = IndexStore.PageRow(bookID: id, pageNumber: 1, textOriginal: text,
                                      textNorm: n.text, normStarts: n.starts, normEnds: n.ends)
        try store.replacePages(bookID: id, [page])
    }
}

// MARK: - AnnotationPlan suite (快速批注与 AI 纳入的两分支写入)

enum AnnotationPlanSuite {
    static var tests: [TestDesc] {
        [
            TestDesc(suite: "AnnotationPlan", name: "withSelectionAnchorsSelection") {
                // 有选区：锚选区（add 语义），页码=选区所在页，锚=选中文本截 200。
                let plan = AnnotationPlan.make(selectionPage: 7, selectionRange: 12..<40,
                                               selectionText: "  选中文本  ",
                                               currentPage: 9, note: "就此批注",
                                               viewSource: "original")
                let p = try expectNotNil(plan)
                try expectEqual(p.isPageNote, false)
                try expectEqual(p.pageNumber, 7)
                try expectEqual(p.utf16Start, 12)
                try expectEqual(p.utf16End, 40)
                try expectEqual(p.anchorText, "选中文本")
                try expectEqual(p.note, "就此批注")
                try expectEqual(p.viewSource, "original")
            },

            TestDesc(suite: "AnnotationPlan", name: "withoutSelectionAnchorsCurrentPage") {
                // 无选区：页级批注（当前页），无坐标无锚；页码未落地（0）fail-closed。
                let plan = AnnotationPlan.make(selectionPage: nil, selectionRange: nil,
                                               selectionText: nil,
                                               currentPage: 5, note: "整页想法",
                                               viewSource: "ocr")
                let p = try expectNotNil(plan)
                try expectEqual(p.isPageNote, true)
                try expectEqual(p.pageNumber, 5)
                try expectEqual(p.utf16Start, 0)
                try expectEqual(p.utf16End, 0)
                try expectEqual(p.anchorText, "")
                // 空选区文本视同无选区。
                let blank = AnnotationPlan.make(selectionPage: 3, selectionRange: 0..<4,
                                                selectionText: "   ",
                                                currentPage: 5, note: "n", viewSource: "ocr")
                try expectEqual(try expectNotNil(blank).isPageNote, true)
                try expectNil(AnnotationPlan.make(selectionPage: nil, selectionRange: nil,
                                                  selectionText: nil, currentPage: 0,
                                                  note: "n", viewSource: "ocr"),
                              "无选区且页码未落地必须拒绝写入")
            },

            TestDesc(suite: "AnnotationPlan", name: "aiNotePrefixPinnedAndIngestCarriesIt") {
                // 轻标记前缀断言固定（列表识别 AI 产出；schema 零改动）。
                try expectEqual(AnnotationPlan.aiNotePrefix, "[AI] ")
                let answer = "回答全文含引用行（书名 物理页 12）。"
                let plan = AnnotationPlan.make(selectionPage: nil, selectionRange: nil,
                                               selectionText: nil, currentPage: 2,
                                               note: AnnotationPlan.aiNotePrefix + answer,
                                               viewSource: "ocr")
                let p = try expectNotNil(plan)
                try expectEqual(p.note, "[AI] " + answer)
                try expectEqual(p.isPageNote, true)
                // 有选区时 AI 回答锚选区（note 同样带前缀）。
                let anchored = AnnotationPlan.make(selectionPage: 4, selectionRange: 0..<6,
                                                   selectionText: "被选中",
                                                   currentPage: 4,
                                                   note: AnnotationPlan.aiNotePrefix + answer,
                                                   viewSource: "original")
                let a = try expectNotNil(anchored)
                try expectEqual(a.isPageNote, false)
                try expectEqual(a.pageNumber, 4)
                try expectEqual(a.note, "[AI] " + answer)
                try expectEqual(a.viewSource, "original")
            },
        ]
    }
}
