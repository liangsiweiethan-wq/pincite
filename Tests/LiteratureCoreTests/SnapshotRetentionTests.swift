import Foundation
@testable import LiteratureCore

// MARK: - 快照保留序与 POSIX formatter 测试三枚（覆盖快照排序与清理规则）。

enum SnapshotRetentionSuite {

    /// 建带 marker 表 t(v) 的最小 SQLite 库（同 FailClosed 助手形制）。
    private static func makeMarkerDB(at url: URL, value: String) throws {
        let db = try SQLiteDatabase(path: url.path)
        try db.exec("CREATE TABLE t(v TEXT);")
        try db.exec("INSERT INTO t(v) VALUES ('\(value)');")
    }

    /// 手工落一个『可解析时间戳命名』的真实快照目录（含占位 alpha.db；
    /// cleanup 只按目录名判定，占位件为布景自明性而设）。
    private static func fabricateSnapshot(in snapDir: URL, _ ts: String) throws {
        let dir = snapDir.appendingPathComponent(ts)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("placeholder".utf8).write(to: dir.appendingPathComponent("alpha.db"))
    }

    /// 手工落一个 pre-restore 安全网目录（与 restore 命名同构：前缀＋ts＋UUID）。
    private static func fabricateSafetyNet(in snapDir: URL, _ ts: String, _ suffix: String) throws {
        let dir = snapDir.appendingPathComponent(
            "\(SnapshotManager.safetyNetPrefix)\(ts)-\(suffix)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// 按与 listSnapshots 同谓词取现存真实快照目录名集合（断言用）。
    private static func realSnapshotNames(in dir: URL) throws -> Set<String> {
        let f = SnapshotManager.makeTimestampFormatter()
        return Set(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { $0.hasDirectoryPath && f.date(from: $0.lastPathComponent) != nil }
            .map { $0.lastPathComponent })
    }

    /// 现存安全网目录数（断言用）。
    private static func safetyNetCount(in dir: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { $0.lastPathComponent.hasPrefix(SnapshotManager.safetyNetPrefix) }
            .count
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "SnapshotRetention", name: "cleanupKeepsRealSnapshotsWhenSafetyNetsMixed") {
                let snapDir = Fixtures.makeTempDir("snapret-mixed")
                defer { Fixtures.cleanup(snapDir) }
                let srcDir = Fixtures.makeTempDir("snapret-mixed-src")
                defer { Fixtures.cleanup(srcDir) }
                let srcURL = srcDir.appendingPathComponent("alpha.db")
                try makeMarkerDB(at: srcURL, value: "v1")
                try fabricateSnapshot(in: snapDir, "20260101-000001")
                try fabricateSnapshot(in: snapDir, "20260101-000002")
                try fabricateSnapshot(in: snapDir, "20260101-000003")
                for i in 1...5 {
                    try fabricateSafetyNet(in: snapDir, "20260101-00000\(i)", "UUID-\(i)")
                }
                let mgr = SnapshotManager(snapshotDir: snapDir, sources: [("alpha", srcURL)], keep: 2)
                let snap = try mgr.takeSnapshot()
                try expectTrue(FileManager.default.fileExists(atPath: snap.path),
                               "本次新拍快照必须存活")
                let real = try realSnapshotNames(in: snapDir)
                try expectEqual(real.count, 2, "真实快照必须保满 keep=2 槽位（旧缺陷下为 0）")
                try expectEqual(real, Set([snap.lastPathComponent, "20260101-000003"]),
                                "幸存必须恰为最新两份真实快照（保留窗语义，最旧者按窗挤出）")
                try expectEqual(try safetyNetCount(in: snapDir), SnapshotManager.safetyNetKeep,
                                "安全网目录必须单独限量（不占真实快照槽位）")
            },

            TestDesc(suite: "SnapshotRetention", name: "timestampFormatterPinnedToPOSIX") {
                let f = SnapshotManager.makeTimestampFormatter()
                try expectEqual(f.locale.identifier, "en_US_POSIX",
                                "固定格式时间戳必须断言 POSIX（非公历系统日历防线）")
                try expectEqual(f.dateFormat, "yyyyMMdd-HHmmss", "目录名格式逐字断言")
                try expectTrue(f.date(from: "20260101-000001") != nil,
                               "普通快照目录名必须可解析")
                try expectTrue(f.date(from: "20260101-000001-2") == nil,
                               "同秒二拍 -N 后缀名不可解析（不计数不清除）")
                try expectTrue(f.date(from: "\(SnapshotManager.safetyNetPrefix)20260101-000001-ABC") == nil,
                               "安全网目录名必须不可解析（绝不冒充真实快照）")
            },

            TestDesc(suite: "SnapshotRetention", name: "takeSnapshotOutputVisibleInList") {
                let snapDir = Fixtures.makeTempDir("snapret-visible")
                defer { Fixtures.cleanup(snapDir) }
                let srcDir = Fixtures.makeTempDir("snapret-visible-src")
                defer { Fixtures.cleanup(srcDir) }
                let srcURL = srcDir.appendingPathComponent("alpha.db")
                try makeMarkerDB(at: srcURL, value: "v1")
                let mgr = SnapshotManager(snapshotDir: snapDir, sources: [("alpha", srcURL)], keep: 5)
                let snap = try mgr.takeSnapshot()
                let list = mgr.listSnapshots()
                try expectTrue(list.contains { $0.lastPathComponent == snap.lastPathComponent },
                               "新拍快照必须在面板可见（产出目录名必须可解析）")
                try expectEqual(list.first?.lastPathComponent, snap.lastPathComponent,
                                "最新快照必须居列表首位（降序）")
            },
        ]
    }
}
