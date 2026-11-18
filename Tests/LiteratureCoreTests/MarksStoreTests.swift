import Foundation
@testable import LiteratureCore
@testable import LiteratureSearchUI

// MARK: -：marks 表（单字符 Marks；小写本书/大写全局）套件
//
// 契约：set/get round-trip；小写同书重设覆盖；小写跨书隔离；
// 大写全局唯一（'' 行 PK 唯一、重设覆盖、target round-trip）；delete 幂等
// 与不存在抛错；symbol 非字母拒绝；bookID(fingerprint:) 命中/未命中/双列；
// offset 纯函数边界；子版本＝1 断言固定；isWellFormed 裸键 true＋默认表前 16 项
// 与批前字面量逐项一致（防放宽波及既有）。

enum MarksStoreSuite {
    static func tempDB(_ tag: String) throws -> (SQLiteDatabase, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marks-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("annotations.db")
        return (try SQLiteDatabase(path: url.path), url)
    }

    static func makeStore(_ tag: String) throws -> MarksStore {
        let (db, _) = try tempDB(tag)
        return MarksStore(db: db)
    }

    static func mark(doc: String = "sha-A", symbol: String = "a",
                     target: String? = nil, page: Int = 3,
                     offset: Double = 0.5, zoom: Double? = 1.5,
                     created: Double = 100, modified: Double = 100) -> BookMark {
        BookMark(docSHA: doc, symbol: symbol, targetDocSHA: target, page: page,
                 offsetY: offset, zoom: zoom, createdAt: created, modifiedAt: modified)
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "MarksStore", name: "ddlIdempotentAndSubschemaVersionOne") {
                let (db, _) = try tempDB("ddl")
                _ = MarksStore(db: db)
                _ = MarksStore(db: db)
                let probe = MarksStore(db: db)
                try expectEqual(probe.storedSubschemaVersion, 1)
                try expectEqual(MarksStore.subschemaMetaKey, "marks_schema_version")
                try expectEqual(try probe.totalRowCount(), 0)
            },

            TestDesc(suite: "MarksStore", name: "setGetRoundTripLocalRow") {
                let store = try makeStore("rt")
                try store.set(mark(page: 7, offset: 0.25, zoom: 2.0))
                let got = try expectNotNil(try store.mark(docSHA: "sha-A", symbol: "a"))
                try expectEqual(got.docSHA, "sha-A")
                try expectEqual(got.symbol, "a")
                try expectNil(got.targetDocSHA)
                try expectEqual(got.page, 7)
                try expectEqual(got.offsetY, 0.25)
                try expectEqual(got.zoom, 2.0)
                // 查询键大小写归一：mark(docSHA:symbol:) 用大写查询查不到小写行。
                try expectNil(try store.mark(docSHA: "sha-A", symbol: "A"))
            },

            TestDesc(suite: "MarksStore", name: "lowercaseResetOverwritesKeepsCreatedAt") {
                let store = try makeStore("reset")
                try store.set(mark(page: 3), at: 100)
                try store.set(mark(page: 9), at: 200)
                try expectEqual(try store.totalRowCount(), 1, "PK 冲突＝覆盖不新增行")
                let got = try expectNotNil(try store.mark(docSHA: "sha-A", symbol: "a"))
                try expectEqual(got.page, 9)
                try expectEqual(got.createdAt, 100, "created_at 保留首设")
                try expectEqual(got.modifiedAt, 200, "modified_at 更新")
            },

            TestDesc(suite: "MarksStore", name: "lowercaseIsolatedAcrossBooks") {
                let store = try makeStore("iso")
                try store.set(mark(doc: "sha-A", symbol: "a", page: 3))
                try store.set(mark(doc: "sha-B", symbol: "a", page: 11))
                try expectEqual(try store.mark(docSHA: "sha-A", symbol: "a")?.page, 3)
                try expectEqual(try store.mark(docSHA: "sha-B", symbol: "a")?.page, 11)
                try expectEqual(try store.totalRowCount(), 2)
            },

            TestDesc(suite: "MarksStore", name: "uppercaseGlobalRowUniqueWithTarget") {
                let store = try makeStore("global")
                try store.set(mark(doc: "sha-A", symbol: "A", target: "sha-A", page: 2))
                try store.set(mark(doc: "sha-B", symbol: "A", target: "sha-B", page: 5))
                try expectEqual(try store.totalRowCount(), 1,
                                "大写全书库至多一行（doc_sha='' 哨兵 PK）")
                let got = try expectNotNil(try store.mark(docSHA: "sha-B", symbol: "A"))
                try expectEqual(got.docSHA, "", "全局行 doc_sha 为空哨兵")
                try expectEqual(got.targetDocSHA, "sha-B", "重设后 target 指向新文档")
                try expectEqual(got.page, 5)
                // 大写查询分支：任意 docSHA 入参都查同一全局行。
                try expectEqual(try store.mark(docSHA: "whatever", symbol: "A")?.page, 5)
            },

            TestDesc(suite: "MarksStore", name: "uppercaseWithoutTargetRejected") {
                let store = try makeStore("gt")
                try expectThrows(try store.set(mark(doc: "", symbol: "A", target: nil)),
                                 "大写（全局）标记必须携带 target_doc_sha")
            },

            TestDesc(suite: "MarksStore", name: "deleteRemovesAndThrowsWhenMissing") {
                let store = try makeStore("del")
                try store.set(mark())
                try store.delete(docSHA: "sha-A", symbol: "a")
                try expectNil(try store.mark(docSHA: "sha-A", symbol: "a"))
                try expectThrows(try store.delete(docSHA: "sha-A", symbol: "a"),
                                 "不存在的标记删除抛错")
                try expectThrows(try store.delete(docSHA: "sha-A", symbol: "1"),
                                 "非字母 symbol 校验先于删除")
            },

            TestDesc(suite: "MarksStore", name: "nonLetterSymbolsRejected") {
                let store = try makeStore("sym")
                for bad in ["1", "中", "aa", "", "!", "ä"] {
                    try expectThrows(try store.set(mark(symbol: bad)),
                                     "symbol=\"\(bad)\" 必须拒绝")
                }
                // a-zA-Z 全通过（边界字母抽验）。
                for good in ["a", "z", "A", "Z", "m", "M"] {
                    try store.set(mark(doc: "sha-A", symbol: good,
                                       target: good.first?.isUppercase == true ? "sha-A" : nil))
                }
                try expectEqual(try store.totalRowCount(), 6)
            },

            TestDesc(suite: "MarksStore", name: "allMarksMergesLocalAndGlobalTargeting") {
                let store = try makeStore("all")
                try store.set(mark(doc: "sha-A", symbol: "b", page: 1))
                try store.set(mark(doc: "sha-A", symbol: "a", page: 2))
                try store.set(mark(doc: "sha-A", symbol: "Z", target: "sha-A", page: 3))
                try store.set(mark(doc: "sha-B", symbol: "c", page: 4))
                try store.set(mark(doc: "sha-A", symbol: "Y", target: "sha-B", page: 5))
                let marks = try store.allMarks(docSHA: "sha-A")
                try expectEqual(marks.map(\.symbol), ["Z", "a", "b"],
                                "只含本文档行与指向它的全局行，symbol 序")
            },

            TestDesc(suite: "MarksStore", name: "fingerprintLookupHitsBothColumns") {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("marks-books-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let index = try IndexStore(path: dir.appendingPathComponent("index.db"))
                try index.upsertBook(IndexStore.BookRow(
                    id: "bA", realPath: "/tmp/lit-tests/a.pdf", rootPath: "/tmp/lit-tests",
                    relPath: "a.pdf", fileName: "a.pdf",
                    firstFingerprint: "first-fp-A", fingerprint: "fp-A", fileSize: 1,
                    mtime: 0, pageCount: 3, status: "ok", indexedAt: 0))
                let store = MarksStore(indexStore: index)
                try expectEqual(try store.bookID(fingerprint: "fp-A"), "bA",
                                "fingerprint 列命中")
                try expectEqual(try store.bookID(fingerprint: "first-fp-A"), "bA",
                                "first_fingerprint 列命中")
                try expectNil(try store.bookID(fingerprint: "no-such-fp"),
                              "未命中返回 nil 不猜")
            },

            TestDesc(suite: "MarksStore", name: "markOffsetVisibleRatioBoundaries") {
                let page = CGRect(x: 0, y: 0, width: 100, height: 400)
                // 可见区整页 → 0.5（中心）。
                try expectEqual(MarkOffset.visibleRatio(pageBounds: page,
                                                        visibleRect: page), 0.5)
                // 页顶可见 → 0；页底可见 → 1。
                try expectEqual(MarkOffset.visibleRatio(
                    pageBounds: page,
                    visibleRect: CGRect(x: 0, y: 0, width: 100, height: 100)), 0.125)
                try expectEqual(MarkOffset.visibleRatio(
                    pageBounds: page,
                    visibleRect: CGRect(x: 0, y: 300, width: 100, height: 100)), 0.875)
                // 可见区越出页界（视口大于页）→ 交集中心，clamp 0-1 内。
                try expectEqual(MarkOffset.visibleRatio(
                    pageBounds: page,
                    visibleRect: CGRect(x: -50, y: -100, width: 200, height: 600)), 0.5)
                // 零高页 → 0（不猜除零）；不相交 → 0。
                try expectEqual(MarkOffset.visibleRatio(
                    pageBounds: CGRect(x: 0, y: 0, width: 100, height: 0),
                    visibleRect: page), 0)
                try expectEqual(MarkOffset.visibleRatio(
                    pageBounds: page,
                    visibleRect: CGRect(x: 0, y: 1000, width: 10, height: 10)), 0)
            },

            TestDesc(suite: "MarksStore", name: "keybindingBareKeysAllowedAndDefaultTablePinned") {
                let bare = KeybindingEntry(action: "marksSet", key: "m",
                                           modifiers: [], context: "reader")
                try expectTrue(bare.isWellFormed, "裸键（空 modifiers）放宽后合法")
                try expectFalse(KeybindingEntry(action: "marksSet", key: "",
                                                modifiers: [], context: "reader").isWellFormed)
                try expectFalse(KeybindingEntry(action: "", key: "m",
                                                modifiers: [], context: "reader").isWellFormed)
                // 默认表：19 项；前 16 项与 字面量逐项一致（KeybindingSuite
                // expected 常量同源）；表尾三条为 新增。
                let entries = KeybindingRegistry.defaultEntries
                try expectEqual(entries.count, 19)
                let v74Tail = [
                    ("reader", "marksSet", "m", [String]()),
                    ("reader", "marksJump", "'", [String]()),
                    ("reader", "followCitations", "f", [String]()),
                ]
                for (i, want) in v74Tail.enumerated() {
                    let entry = entries[16 + i]
                    try expectEqual(entry.context, want.0)
                    try expectEqual(entry.action, want.1)
                    try expectEqual(entry.key, want.2)
                    try expectEqual(entry.modifiers, want.3)
                }
                // 前 16 项全带修饰键（放宽不影响既有）。
                for entry in entries.prefix(16) {
                    try expectTrue(entry.isWellFormed)
                    try expectFalse(entry.modifiers.isEmpty,
                                    "前 16 项修饰键非空（行为零变化）")
                }
            },
        ]
    }
}
