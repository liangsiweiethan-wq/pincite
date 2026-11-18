import Foundation
@testable import LiteratureCore
@testable import LiteratureSearchUI


enum LibrarySnapshotStoreSuite {

    /// 最小 SQLite 库（marker 表 t(v)），照 FailClosedSuite 助手基准。
    private static func makeMarkerDB(at url: URL, value: String) throws {
        let db = try SQLiteDatabase(path: url.path)
        try db.exec("CREATE TABLE t(v TEXT);")
        try db.exec("INSERT INTO t(v) VALUES ('\(value)');")
    }

    /// 新开连接读 marker 值（避免持旧句柄读旧 inode）。
    private static func readMarker(at url: URL) throws -> String {
        let db = try SQLiteDatabase(path: url.path)
        let st = try db.prepare("SELECT v FROM t;")
        try expectTrue(try st.step(), "marker 行必须存在")
        return st.text(0)
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "LibrarySnapshotStore", name: "backupCreatesListedSnapshotWithIndexDB") {
                let dbDir = Fixtures.makeTempDir("libsnap-db")
                let snapDir = Fixtures.makeTempDir("libsnap-snap")
                let dbURL = dbDir.appendingPathComponent("index.db")
                try makeMarkerDB(at: dbURL, value: "v1")
                let store = LibrarySnapshotStore(indexDBURL: dbURL, snapshotDir: snapDir)
                try expectTrue(store.snapshots.isEmpty, "初始清单应为空")

                let snap = try store.backupNow()
                try expectTrue(FileManager.default.fileExists(
                    atPath: snap.appendingPathComponent("index.db").path),
                    "快照内必须含 index.db")
                store.reload()
                try expectEqual(store.snapshots.count, 1)
                try expectEqual(store.snapshots.first?.lastPathComponent, snap.lastPathComponent)
            },

            TestDesc(suite: "LibrarySnapshotStore", name: "restoreBringsBackPreBackupState") {
                let dbDir = Fixtures.makeTempDir("libsnap-db2")
                let snapDir = Fixtures.makeTempDir("libsnap-snap2")
                let dbURL = dbDir.appendingPathComponent("index.db")
                try makeMarkerDB(at: dbURL, value: "v1")
                let store = LibrarySnapshotStore(indexDBURL: dbURL, snapshotDir: snapDir)
                let snap = try store.backupNow()

                do { let db = try SQLiteDatabase(path: dbURL.path); try db.exec("UPDATE t SET v='v2';") }
                try expectEqual(try readMarker(at: dbURL), "v2")

                try store.restoreNow(snap)
                try expectEqual(try readMarker(at: dbURL), "v1")
            },

            TestDesc(suite: "LibrarySnapshotStore", name: "sourcesDeriveFromAppSupportPathsOrInjection") {
                try expectTrue(AppSupportPaths.appDirectory("snapshots").path.hasSuffix("snapshots"),
                               "默认快照目录必须落在 snapshots/ 子目录（AppSupportPaths 生产基准）")
                let snapDir = Fixtures.makeTempDir("libsnap-def")
                let store = LibrarySnapshotStore(indexDBURL: nil, snapshotDir: snapDir)
                try expectEqual(store.sources.count, 1)
                try expectEqual(store.sources[0].name, "index")
                try expectTrue(store.sources[0].url.lastPathComponent == "index.db",
                               "默认库源必须指向 index.db（macOS 全 store 共享同一连接）")
                try expectEqual(store.snapshotDir, snapDir,
                                "注入快照目录逐字随注入")

                let injected = Fixtures.makeTempDir("libsnap-inject").appendingPathComponent("index.db")
                let injectedStore = LibrarySnapshotStore(indexDBURL: injected,
                                                         snapshotDir: Fixtures.makeTempDir("libsnap-def2"))
                try expectEqual(injectedStore.sources[0].url, injected)
            },
        ]
    }
}
