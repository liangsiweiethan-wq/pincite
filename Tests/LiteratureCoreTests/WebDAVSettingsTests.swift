import Foundation
@testable import LiteratureCore

// MARK: - WebDAV 设置持久化套件（配套；临时目录，零真实落盘）
//
// 覆盖：save/load 往返（结构与 CLI --config 一致）、坏档/缺档
// fail-closed 视为无配置、默认配置形态（一条规则）。

enum WebDAVSettingsSuite {
    static var tests: [TestDesc] {
        [
            TestDesc(suite: "WebDAVSettings", name: "saveLoadRoundtripKeepsCLIShape") {
                let dir = Fixtures.makeTempDir("wdav-set")
                defer { Fixtures.cleanup(dir) }
                let store = WebDAVSettingsStore(directory: dir)
                try expectNil(store.load(), "缺档视为无配置")
                let config = WebDAVSyncConfig(
                    serverBase: "https://dav.example/webdav", username: "u",
                    rules: [WebDAVSyncRule(remoteDir: "/Books",
                                           localRoot: dir.appendingPathComponent("库", isDirectory: true))],
                    extensions: [".pdf"])
                try store.save(config)
                try expectTrue(FileManager.default.fileExists(atPath: store.fileURL.path),
                               "save 应建目录并落盘")
                let loaded = try expectNotNil(store.load())
                try expectEqual(loaded.serverBase, config.serverBase, "往返：serverBase")
                try expectEqual(loaded.username, config.username, "往返：username")
                try expectEqual(loaded.extensions, config.extensions, "往返：extensions")
                try expectEqual(loaded.rules.count, config.rules.count, "往返：规则数")
                try expectEqual(loaded.rules.first?.remoteDir, config.rules.first?.remoteDir, "往返：remoteDir")
                try expectEqual(loaded.rules.first?.localRoot, config.rules.first?.localRoot, "往返：localRoot")
                // 落盘 JSON 与 CLI --config 同构（顶层键可直接被 CLI 解析）。
                let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
                try expectTrue(raw.contains("\"serverBase\""), "顶层含 serverBase")
                try expectTrue(raw.contains("\"remoteDir\""), "规则含 remoteDir")
                try expectTrue(raw.contains("\"localRoot\""), "规则含 localRoot")
            },
            TestDesc(suite: "WebDAVSettings", name: "corruptFileFailsClosedToNil") {
                let dir = Fixtures.makeTempDir("wdav-set-bad")
                defer { Fixtures.cleanup(dir) }
                let store = WebDAVSettingsStore(directory: dir)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data("not-json{".utf8).write(to: store.fileURL)
                try expectNil(store.load(), "坏档 fail-closed 视为无配置")
            },
            TestDesc(suite: "WebDAVSettings", name: "defaultConfigIsSingleRule") {
                let config = WebDAVSettingsStore.defaultConfig()
                try expectEqual(config.rules.count, 1, "一条规则")
                try expectEqual(config.rules.first?.remoteDir, WebDAVSettingsStore.defaultRemoteDir)
                try expectTrue(config.rules.first?.localRoot.path
                    .contains(WebDAVSettingsStore.defaultLocalFolder) == true,
                    "落点在 AppSupport/WebDAVImport")
                try expectTrue(config.serverBase.hasPrefix("https://"), "默认占位为 HTTPS")
            },
        ]
    }
}
