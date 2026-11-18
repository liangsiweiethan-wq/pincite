import Foundation
@testable import LiteratureSearchUI

// MARK: - 功能扩展：期刊等级内联徽章数据面测试
//
// 断言面：无数据 = 空表（一个徽章都不显示的硬要求）；合法载荷往返；version
// 拒识；坏 JSON fail-closed；大小写不敏感子串匹配；条目缺键剔除。
// 全部注入临时目录，绝不触真实 Application Support。

enum JournalTierStoreSuite {
    static func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lit-tiers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    static func write(_ payload: Data, to dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(JournalTierStore.fileName)
        try payload.write(to: url)
        return url
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "JournalTierStore", name: "missingFileMeansNoBadgesAtAll") {
                let dir = try makeDir()
                defer { try? FileManager.default.removeItem(at: dir) }
                let store = JournalTierStore(directory: dir)
                try expectTrue(store.rules.isEmpty, "缺文件 = 空表（数据缺如实显示）")
                try expectNil(store.lookup(displayTitle: "任何标题"),
                              "无数据一个徽章都不出")
            },
            TestDesc(suite: "JournalTierStore", name: "validPayloadRoundTripAndCaseInsensitiveMatch") {
                let dir = try makeDir()
                defer { try? FileManager.default.removeItem(at: dir) }
                try write(Data("""
                {"version":1,"tiers":[
                  {"match":"《样刊研究》","tier":"核心期刊","note":"示例分级"},
                  {"match":"《示例学刊》","tier":"非核心"}
                ]}
                """.utf8), to: dir)
                let store = JournalTierStore(directory: dir)
                try expectEqual(store.rules.count, 2)
                let hit = try expectNotNil(store.lookup(
                    displayTitle: "《样刊研究》 示例专栏"))
                try expectEqual(hit.tier, "核心期刊", "大小写不敏感子串命中")
                try expectEqual(hit.note, "示例分级")
                try expectNil(store.lookup(displayTitle: "完全不相关标题"),
                              "零命中 → nil（不显示）")
                try expectNil(store.lookup(displayTitle: ""), "空标题 → nil")
            },
            TestDesc(suite: "JournalTierStore", name: "versionMismatchAndCorruptPayloadFailClosedEmpty") {
                let dir = try makeDir()
                defer { try? FileManager.default.removeItem(at: dir) }
                // version 拒识（schema 演进时不半读旧档）。
                try write(Data("""
                {"version":2,"tiers":[{"match":"x","tier":"y"}]}
                """.utf8), to: dir)
                try expectTrue(JournalTierStore(directory: dir).rules.isEmpty,
                               "未知 version → 空表不崩")
                // 坏 JSON。
                try write(Data("not json at all".utf8), to: dir)
                try expectTrue(JournalTierStore(directory: dir).rules.isEmpty,
                               "坏 JSON → 空表不崩")
                // 合法 version 但条目缺键 → 条目剔除不崩。
                try write(Data("""
                {"version":1,"tiers":[{"match":" ","tier":"y"},{"match":"ok","tier":"tier-1"}]}
                """.utf8), to: dir)
                let store = JournalTierStore(directory: dir)
                try expectEqual(store.rules.count, 1, "空白 match/tier 条目剔除")
                try expectEqual(store.rules.first?.tier, "tier-1")
            },
        ]
    }
}
