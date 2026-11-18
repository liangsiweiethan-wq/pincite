import Foundation
@testable import LiteratureCore

// MARK: - IndexAssetsManifest 测试
//
// 断言面：generate→verify 空失配（全通过）；篡改一字节 → 点名该资产；
// 缺件 → 点名 [missing]；size 漂移 → 点名；JSON 往返稳定。全部合成件。

enum IndexAssetsManifestSuite {
    static var tests: [TestDesc] {
        [
            // generate→verify：完好资产零失配。
            TestDesc(suite: "IndexAssetsManifest", name: "generateThenVerifyPassesClean") {
                let dir = Fixtures.makeTempDir("manifest-ok")
                defer { Fixtures.cleanup(dir) }
                let db = dir.appendingPathComponent("fulltext.db")
                try Data(String(repeating: "sqlite-page-bytes-", count: 256).utf8).write(to: db)
                let manifest = try IndexAssetsManifest.generate(fulltextDB: db)
                try expectEqual(manifest.formatVersion, IndexStore.currentFulltextFormatVersion)
                try expectEqual(manifest.assets.count, 1)
                try expectEqual(manifest.assets[0].name, "fulltext.db")
                try expectTrue(manifest.verify(fulltextDB: db).isEmpty,
                               "intact asset passes with zero failures")
            },

            // 篡改一字节 → sha256 失配点名该资产。
            TestDesc(suite: "IndexAssetsManifest", name: "tamperedByteIsNamedByVerify") {
                let dir = Fixtures.makeTempDir("manifest-tamper")
                defer { Fixtures.cleanup(dir) }
                let db = dir.appendingPathComponent("fulltext.db")
                try Data(String(repeating: "A", count: 4096).utf8).write(to: db)
                let manifest = try IndexAssetsManifest.generate(fulltextDB: db)
                // 篡改 1 字节（末字节 A→B）。
                var bytes = try Data(contentsOf: db)
                bytes[bytes.count - 1] = UInt8(ascii: "B")
                try bytes.write(to: db)
                let failures = manifest.verify(fulltextDB: db)
                try expectEqual(failures.count, 1)
                try expectTrue(failures[0].hasPrefix("fulltext.db"), "failure names the asset: \(failures)")
                try expectTrue(failures[0].contains("sha256 mismatch"))
            },

            // 缺件 → 点名 [missing]；size 漂移 → 点名 size 失配。
            TestDesc(suite: "IndexAssetsManifest", name: "missingAndResizedAssetsAreNamed") {
                let dir = Fixtures.makeTempDir("manifest-miss")
                defer { Fixtures.cleanup(dir) }
                let db = dir.appendingPathComponent("fulltext.db")
                try Data("payload".utf8).write(to: db)
                let manifest = try IndexAssetsManifest.generate(fulltextDB: db)
                try FileManager.default.removeItem(at: db)
                let missing = manifest.verify(fulltextDB: db)
                try expectEqual(missing.count, 1)
                try expectTrue(missing[0].contains("[missing]"), "missing asset named: \(missing)")
                // 恢复为不同长度内容 → size 先失配（校验短路于 sha 前）。
                try Data("payload-longer".utf8).write(to: db)
                let resized = manifest.verify(fulltextDB: db)
                try expectEqual(resized.count, 1)
                try expectTrue(resized[0].contains("size "), "size drift named: \(resized)")
            },

            // JSON 往返稳定（确定性编码：键排序＋美化）＋ parse 校验形制。
            TestDesc(suite: "IndexAssetsManifest", name: "jsonRoundTripIsStable") {
                let dir = Fixtures.makeTempDir("manifest-json")
                defer { Fixtures.cleanup(dir) }
                let db = dir.appendingPathComponent("fulltext.db")
                try Data("roundtrip".utf8).write(to: db)
                let manifest = try IndexAssetsManifest.generate(fulltextDB: db)
                let data1 = try manifest.jsonData()
                let parsed = try IndexAssetsManifest.parse(data1)
                try expectEqual(parsed, manifest)
                let data2 = try parsed.jsonData()
                try expectEqual(data1, data2, "deterministic encoding (sorted keys + pretty)")
            },
        ]
    }
}
