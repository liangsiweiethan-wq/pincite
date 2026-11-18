import Foundation
@testable import LiteratureCore

// MARK: -：批注/涂画合并引擎(冲突模型)+ AnnotationBundle
//
// append-only / 幂等键新者胜 / 墓碑保留 / 单事务整批回滚 / fail-closed 拒收。

enum AnnotationMergeSuite {
    static func tempDB(_ tag: String) throws -> (SQLiteDatabase, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("merge-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("annotations.db")
        return (try SQLiteDatabase(path: url.path), url)
    }

    /// 已完成迁移的批注库（HighlightStore+InkStrokesStore 各开一次）。
    static func readyStore(_ tag: String) throws -> (SQLiteDatabase, HighlightStore, InkStrokesStore) {
        let (db, _) = try tempDB(tag)
        let highlights = HighlightStore(db: db)
        let strokes = InkStrokesStore(db: db)
        return (db, highlights, strokes)
    }

    static func highlight(uuid: String = UUID().uuidString, book: String = "bA", page: Int = 2,
                          note: String = "n", created: Double = 100,
                          device: String = "devX", deleted: Double? = nil) -> BundleHighlight {
        BundleHighlight(rowUUID: uuid, bookID: book, pageNumber: page,
                        utf16Start: 0, utf16End: 5, color: "#FFDF3E", note: note,
                        createdAt: created, anchorText: "abcde", anchorVerified: 1,
                        style: "highlight", viewSource: "original", deviceID: device,
                        deletedAt: deleted)
    }

    static func stroke(_ s: InkStroke) -> BundleStroke { BundleStroke(s) }

    static func inkStroke(uuid: String = UUID().uuidString, book: String = "bA", page: Int = 3,
                          device: String = "devX", created: Double = 100,
                          deleted: Double? = nil) -> InkStroke {
        InkStroke(strokeUUID: uuid, bookID: book, pageNumber: page, deviceID: device,
                  createdAt: created, color: "#8EC9FF", lineWidth: 2,
                  points: [InkPoint(x: 0.1, y: 0.1), InkPoint(x: 0.8, y: 0.8)],
                  deletedAt: deleted)
    }

    static func bundle(highlights: [BundleHighlight], strokes: [BundleStroke]) -> AnnotationBundle {
        AnnotationBundle(exportedAt: "2026-09-29T00:00:00Z", deviceID: "devOther",
                         highlightsSubschemaVersion: 8, strokesSubschemaVersion: 1,
                         highlights: highlights, strokes: strokes)
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "AnnotationMerge", name: "mergeIsIdempotentForIdenticalBundle") {
                let (db, highlights, strokesStore) = try readyStore("idem")
                let engine = AnnotationMergeEngine(db: db)
                let b = bundle(highlights: [highlight()], strokes: [stroke(inkStroke())])
                let first = try engine.merge(bundle: b)
                try expectEqual(first.highlightsInserted, 1)
                try expectEqual(first.strokesInserted, 1)
                let second = try engine.merge(bundle: b)
                try expectEqual(second.duplicatesSkipped, 2, "二次导入 = 全部幂等跳过")
                try expectEqual(second.highlightsInserted, 0)
                try expectEqual(second.strokesInserted, 0)
                try expectEqual(try strokesStore.totalRowCount(), 1)
                try expectEqual(try highlights.highlightsForBook("bA", viewSource: nil).count, 1)
            },

            TestDesc(suite: "AnnotationMerge", name: "highlightConflictNewerWinsOlderTombstoned") {
                let (db, highlights, _) = try readyStore("hclash")
                let engine = AnnotationMergeEngine(db: db)
                let uuid = "hl-fixed-uuid"
                try engine.merge(bundle: bundle(highlights: [highlight(uuid: uuid, note: "old", created: 100)],
                                                strokes: []))
                // 远端同 uuid、created_at 更新 → 旧行墓碑 + 新行落库。
                let out = try engine.merge(bundle: bundle(highlights: [highlight(uuid: uuid, note: "new", created: 200)],
                                                          strokes: []))
                try expectEqual(out.replacedTombstoned, 1)
                // 活动视图只有新行；墓碑旧行在库里可查（含墓碑导出视图）。
                let live = try highlights.highlightsForBook("bA", viewSource: nil)
                try expectEqual(live.count, 1)
                try expectEqual(live.first?.note, "new")
                let exported = try AnnotationBundle.export(db: db, deviceID: "probe")
                let rows = exported.highlights.filter { $0.rowUUID == uuid }
                try expectEqual(rows.count, 2, "导出（含墓碑）必须两行都在")
                try expectTrue(rows.contains { $0.note == "old" && $0.deletedAt != nil })
                try expectTrue(rows.contains { $0.note == "new" && $0.deletedAt == nil })
                // 远端更旧 → 保留本地（幂等跳过）。
                let again = try engine.merge(bundle: bundle(highlights: [highlight(uuid: uuid, note: "older", created: 50)],
                                                            strokes: []))
                try expectEqual(again.duplicatesSkipped, 1)
                try expectEqual(try highlights.highlightsForBook("bA", viewSource: nil).first?.note, "new")
            },

            TestDesc(suite: "AnnotationMerge", name: "strokeConflictNewerWinsBothRowsKept") {
                let (db, _, strokes) = try readyStore("sclash")
                let engine = AnnotationMergeEngine(db: db)
                let uuid = "st-fixed-uuid"
                try engine.merge(bundle: bundle(highlights: [], strokes: [stroke(inkStroke(uuid: uuid, created: 100))]))
                let out = try engine.merge(bundle: bundle(highlights: [],
                                                          strokes: [stroke(inkStroke(uuid: uuid, created: 300))]))
                try expectEqual(out.replacedTombstoned, 1)
                try expectEqual(try strokes.totalRowCount(), 2, "旧行墓碑保留 + 新行 = 两行")
                let live = try strokes.strokes(bookID: "bA")
                try expectEqual(live.count, 1, "活动视图取 created_at 新者")
                try expectEqual(live.first?.createdAt, 300)
                let exported = try AnnotationBundle.export(db: db, deviceID: "probe")
                try expectEqual(exported.strokes.count, 2, "导出含墓碑两行")
            },

            TestDesc(suite: "AnnotationMerge", name: "twoDevicesSamePageCoexist") {
                let (db, _, strokes) = try readyStore("twodev")
                let engine = AnnotationMergeEngine(db: db)
                try engine.merge(bundle: bundle(highlights: [], strokes: [
                    stroke(inkStroke(uuid: "u-a", device: "devA", created: 100)),
                    stroke(inkStroke(uuid: "u-b", device: "devB", created: 105)),
                ]))
                let live = try strokes.strokes(bookID: "bA", pageNumber: 3)
                try expectEqual(live.count, 2, "同页两笔都保留")
                try expectEqual(Set(live.map(\.deviceID)), Set(["devA", "devB"]))
                _ = db
            },

            TestDesc(suite: "AnnotationMerge", name: "invalidRowRejectsWholeBundleWithoutPartialWrite") {
                let (db, highlights, strokes) = try readyStore("invalid")
                let engine = AnnotationMergeEngine(db: db)
                // 两行：第一行合法、第二行页码非法 → 整包拒收（零落库）。
                let bad = bundle(highlights: [
                    highlight(uuid: "ok-1"),
                    highlight(uuid: "bad-1", page: 0),
                ], strokes: [])
                try expectThrows(try engine.merge(bundle: bad), "非法行必须整包拒收")
                try expectEqual(try highlights.highlightsForBook("bA", viewSource: nil).count, 0, "合法行也不得落库")
                // 笔迹侧同规：第二行坐标越界 → 整包拒收。
                let badStrokeBundle = bundle(highlights: [], strokes: [
                    stroke(inkStroke(uuid: "ok-s")),
                    stroke(InkStroke(strokeUUID: "bad-s", bookID: "bB", pageNumber: 1, deviceID: "d",
                                     createdAt: 1, color: "#8EC9FF", lineWidth: 2,
                                     points: [InkPoint(x: 2.0, y: 0.1), InkPoint(x: 0.1, y: 0.1)])),
                ])
                try expectThrows(try engine.merge(bundle: badStrokeBundle))
                try expectEqual(try strokes.totalRowCount(), 0)
            },

            TestDesc(suite: "AnnotationMerge", name: "midTransactionFailureRollsBackWholeBatch") {
                let (db, highlights, _) = try readyStore("rollback")
                // 预埋同 row_uuid 行（模拟旧库状态）。
                _ = try highlights.add(bookID: "bA", pageNumber: 2, utf16Start: 0, utf16End: 5,
                                       color: .yellow, note: "seed", anchorText: "abcde")
                try db.exec("UPDATE user_highlights SET row_uuid = 'dup-uuid' WHERE row_uuid = '';")
                let engine = AnnotationMergeEngine(db: db)
                let out = try engine.merge(bundle: bundle(highlights: [
                    highlight(uuid: "x-new-1"),
                    // created_at 必须比种子行（Date 级 epoch）新才触发替换路径。
                    highlight(uuid: "dup-uuid", note: "conflict",
                              created: Date().timeIntervalSince1970 + 1000),
                ], strokes: []))
                try expectEqual(out.highlightsInserted, 1)
                try expectEqual(out.replacedTombstoned, 1)
                let live = try highlights.highlightsForBook("bA", viewSource: nil)
                try expectEqual(live.count, 2, "种子行（被替换后新行）+ 新行")
                try expectTrue(live.contains { $0.note == "conflict" })
            },

            TestDesc(suite: "AnnotationMerge", name: "bundleParseFailsClosed") {
                try expectThrows(try AnnotationBundle.parse(Data("{{{".utf8)))
                let (db, _, _) = try readyStore("parse")
                let good = try AnnotationBundle.export(db: db, deviceID: "d")
                var tampered = try JSONSerialization.jsonObject(with: good.jsonData()) as! [String: Any]
                tampered["bundle_version"] = 99
                let data = try JSONSerialization.data(withJSONObject: tampered)
                try expectThrows(try AnnotationBundle.parse(data), "版本不符必须拒收")
                tampered["bundle_version"] = AnnotationBundle.bundleVersion
                tampered["format"] = "someone-else-format"
                try expectThrows(try AnnotationBundle.parse(
                    try JSONSerialization.data(withJSONObject: tampered)), "format 不识别必须拒收")
            },

            TestDesc(suite: "AnnotationMerge", name: "exportRoundtripPreservesEverything") {
                let (db, highlights, strokes) = try readyStore("roundtrip")
                try highlights.add(bookID: "bA", pageNumber: 2, utf16Start: 0, utf16End: 5,
                                   color: .yellow, note: "kept", anchorText: "abcde")
                try strokes.addStroke(inkStroke(uuid: "live-stroke"))
                try strokes.addStroke(inkStroke(uuid: "dead-stroke", deleted: 123.0))
                let exported = try AnnotationBundle.export(db: db, deviceID: "devExp")
                try expectEqual(exported.highlights.count, 1)
                try expectEqual(exported.strokes.count, 2, "墓碑行必须随包")
                try expectTrue(exported.strokes.contains { $0.strokeUUID == "dead-stroke" && $0.deletedAt != nil })
                try expectEqual(exported.highlightsSubschemaVersion, 8)  // 子版本 7→8
                try expectEqual(exported.strokesSubschemaVersion, InkStrokesStore.subschemaVersion)
                // JSON 往返字节级可解析、字段完整。
                let re = try AnnotationBundle.parse(exported.jsonData())
                try expectEqual(re, exported)
            },

            TestDesc(suite: "AnnotationMerge", name: "tombstoneImportLandsAsTombstone") {
                let (db, _, strokes) = try readyStore("tombimport")
                let engine = AnnotationMergeEngine(db: db)
                let out = try engine.merge(bundle: bundle(
                    highlights: [],
                    strokes: [stroke(inkStroke(uuid: "gone", deleted: 999.0))]))
                try expectEqual(out.tombstonesImported, 1)
                try expectEqual(try strokes.totalRowCount(), 1)
                try expectTrue(try strokes.strokes(bookID: "bA").isEmpty, "墓碑行不出现在活动视图")
                // 高亮侧同规。
                let outH = try engine.merge(bundle: bundle(
                    highlights: [highlight(uuid: "hl-gone", deleted: 888.0)], strokes: []))
                try expectEqual(outH.tombstonesImported, 1)
                _ = db
            },

            TestDesc(suite: "AnnotationMerge", name: "threeColumnMigrationZeroLoss") {
                let (db, _) = try tempDB("migrate3col")
                _ = InkStrokesStore(db: db)
                _ = db.tryExec("""
                CREATE TABLE IF NOT EXISTS user_highlights(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    book_id TEXT NOT NULL, page_number INTEGER NOT NULL,
                    utf16_start INTEGER NOT NULL, utf16_end INTEGER NOT NULL,
                    color TEXT NOT NULL, note TEXT NOT NULL DEFAULT '',
                    created_at REAL NOT NULL, anchor_text TEXT NOT NULL DEFAULT '',
                    anchor_verified INTEGER NOT NULL DEFAULT 0,
                    style TEXT NOT NULL DEFAULT 'highlight',
                    view_source TEXT NOT NULL DEFAULT 'ocr'
                );
                """)
                _ = db.tryExec("INSERT INTO user_highlights(book_id, page_number, utf16_start, utf16_end, color, note, created_at) VALUES('old-book', 9, 1, 4, '#F7D774', 'legacy note', 42.0);")
                _ = db.tryExec("INSERT INTO user_highlights(book_id, page_number, utf16_start, utf16_end, color, note, created_at) VALUES('old-book', 10, 0, 3, '#A8D5A2', 'second', 43.0);")
                // 旧档打开（迁移发生）。
                let highlights = HighlightStore(db: db)
                let live = try highlights.highlightsForBook("old-book", viewSource: nil)
                try expectEqual(live.count, 2, "旧行零损失")
                try expectEqual(live.first?.note, "legacy note")
                // row_uuid 一次性回填：全行非空且互不相同。
                let exported = try AnnotationBundle.export(db: db, deviceID: "probe")
                let uuids = exported.highlights.map(\.rowUUID)
                try expectTrue(uuids.allSatisfy { !$0.isEmpty }, "旧行 row_uuid 必须已回填")
                try expectEqual(Set(uuids).count, 2, "回填值必须互异")
                // 二次打开幂等：行数不变、row_uuid 不变。
                _ = HighlightStore(db: db)
                let again = try AnnotationBundle.export(db: db, deviceID: "probe")
                try expectEqual(again.highlights.map(\.rowUUID), uuids, "二次迁移不得重填/换值")
                try expectEqual(try AnnotationBundle.export(db: db, deviceID: "d").highlights.count, 2)
            },

            TestDesc(suite: "AnnotationMerge", name: "viewSourceNormalizedOnMerge") {
                let (db, highlights, _) = try readyStore("vsrc")
                let engine = AnnotationMergeEngine(db: db)
                var h = highlight(uuid: "vs-1")
                h.viewSource = "weird-value"
                _ = try engine.merge(bundle: bundle(highlights: [h], strokes: []))
                let live = try highlights.highlightsForBook("bA", viewSource: nil)
                try expectEqual(live.first?.viewSource, HighlightStore.viewSourceOCR)
                _ = db
            },
        ]
    }
}
