import Foundation
@testable import LiteratureCore

enum OcrDualEngineSuite {
    static func makeStore() throws -> (IndexStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lit-ocrdual-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try IndexStore(path: dir.appendingPathComponent("index.db")), dir)
    }

    static var tests: [TestDesc] {
        var t: [TestDesc] = []
        t.append(TestDesc(suite: "OcrDualEngine", name: "migrationV11AddsThreeColumnsAndReopenIsIdempotent") {
            let (store, dir) = try makeStore()
            defer { Fixtures.cleanup(dir) }
            let cols = try store.tableColumns("books")
            try expectTrue(cols.contains("ocr_status"), "v11 缺列 ocr_status")
            try expectTrue(cols.contains("ocr_error"), "v11 缺列 ocr_error")
            try expectTrue(cols.contains("ocr_driver_id"), "v11 缺列 ocr_driver_id")
            // 重开同一文件：列集不变（迁移幂等，重开零副作用）。
            _ = try IndexStore(path: dir.appendingPathComponent("index.db"))
            let after = try store.tableColumns("books")
            try expectTrue(after.contains("ocr_status") && after.contains("ocr_error") && after.contains("ocr_driver_id"),
                           "重开后 v11 列缺席")
        })
        t.append(TestDesc(suite: "OcrDualEngine", name: "newBookDefaultsAreEmptyStrings") {
            let (store, dir) = try makeStore()
            defer { Fixtures.cleanup(dir) }
            try store.upsertBook(IndexStore.BookRow(
                id: "od1", realPath: "/tmp/od1.pdf", rootPath: "/tmp", relPath: "od1.pdf",
                fileName: "od1.pdf", firstFingerprint: "fp-od1", fingerprint: "fp-od1",
                fileSize: 1, mtime: 0, pageCount: 1, status: "ok", indexedAt: 0))
            let stmt = try store.db.prepare("SELECT ocr_status, ocr_error, ocr_driver_id FROM books WHERE id = ?;")
            try stmt.bindText(1, "od1")
            guard try stmt.step() else { try failTest("book 行不存在") }
            let (s, e, d) = (stmt.text(0), stmt.text(1), stmt.text(2))
            try expectTrue(s == "" && e == "" && d == "", "默认值非空: \(s)/\(e)/\(d)")
        })
        t.append(TestDesc(suite: "OcrDualEngine", name: "driverStateCoversSixRawValues") {
            let all = OCRDriverState.allCases.map(\.rawValue)
            try expectTrue(all == ["idle", "queued", "running", "merged", "rejected", "circuit-broken"],
                           "六态 rawValue 不符: \(all)")
        })
        t.append(TestDesc(suite: "OcrDualEngine", name: "chainVersionAtLeastEleven") {
            try expectTrue(IndexStore.currentSchemaVersion >= 11,
                           "currentSchemaVersion=\(IndexStore.currentSchemaVersion) < 11")
        })
        t.append(TestDesc(suite: "OcrDualEngine", name: "schemaVersionMetaKeyWrittenAsEleven") {
            let (store, dir) = try makeStore()
            defer { Fixtures.cleanup(dir) }
            let stmt = try store.db.prepare("SELECT value FROM meta WHERE key = ?;")
            try stmt.bindText(1, "schema_version")
            guard try stmt.step() else { try failTest("schema_version 键缺失") }
            try expectTrue(Int(stmt.text(0)) ?? 0 >= 11, "meta schema_version=\(stmt.text(0)) < 11")
        })
        return t
    }
}
