import Foundation
@testable import LiteratureCore

// MARK: -：Share 回传 inbox（文件名白名单/载荷校验/拉取编排）
//
// 全部桩注入离线跑；凭据守卫与 CLI 共用同一条
// ShareInboxPuller.validateCredentials。

enum ShareInboxSuite {
    /// 桩 loader：远端 listing 与字节表全在内存。
    final class StubLoader: ShareInboxLoading {
        var listing: [WebDAVResource]
        var files: [String: Data]
        var downloadCalls: [String] = []
        /// true = 下载成功但不落盘（预算用例：只验证预算计算，不写 64+MiB）。
        var noWrite = false
        init(listing: [WebDAVResource] = [], files: [String: Data] = [:]) {
            self.listing = listing
            self.files = files
        }
        func list(directory: String) async throws -> [WebDAVResource] {
            precondition(directory == ShareInbox.prefixDirectory, "必须拉 inbox 前缀")
            return listing
        }
        func download(remotePath: String, to local: URL, expectedBytes: Int64?) async throws {
            let name = remotePath.split(separator: "/").last.map(String.init) ?? remotePath
            downloadCalls.append(name)
            if noWrite { return }
            guard let data = files[name] else { throw TestFailure(message: "桩无此文件: \(name)") }
            try data.write(to: local, options: .atomic)
        }
    }

    static func tempDir(_ tag: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shareinbox-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "ShareInbox", name: "fileNameRegexAcceptsOnlyProgramGenerated") {
                try expectTrue(ShareInbox.isAllowedFileName("share-0a1b2c3d-1767000000-ab12cd.txt"))
                try expectTrue(ShareInbox.isAllowedFileName(ShareInbox.makeFileName()))
                // 穿越串/绝对路径/大写 hex/位数不对/错误扩展 全拒。
                try expectFalse(ShareInbox.isAllowedFileName("../evil.txt"))
                try expectFalse(ShareInbox.isAllowedFileName("share-../../etc/passwd.txt"))
                try expectFalse(ShareInbox.isAllowedFileName("share-0A1B2C3D-1767000000-ab12cd.txt")) // 大写 hex
                try expectFalse(ShareInbox.isAllowedFileName("share-0a1b2c3d-176700000-ab12cd.txt"))  // 9 位时间戳
                try expectFalse(ShareInbox.isAllowedFileName("share-0a1b2c3d-1767000000-ab12cd.sqlite"))
                try expectFalse(ShareInbox.isAllowedFileName("manifest.json"))
                try expectFalse(ShareInbox.isAllowedFileName("share-0a1b2c3d-1767000000-ab12cd"))     // 无扩展
                // 前缀常量毗邻 index 前缀且互不污染。
                try expectEqual(ShareInbox.prefixDirectory, "LiteratureSearch/sync/inbox")
                try expectEqual(WebDAVIndexPaths.uploadPrefixDirectory, "LiteratureSearch/sync/index")
            },

            TestDesc(suite: "ShareInbox", name: "makeFileNameUniqueAndWellFormed") {
                var seen = Set<String>()
                for _ in 0..<100 {
                    let name = ShareInbox.makeFileName()
                    try expectTrue(ShareInbox.isAllowedFileName(name), "生成名必须过自己的白名单: \(name)")
                    try expectTrue(seen.insert(name).inserted, "文件名必须唯一（重名避让前提）: \(name)")
                }
                // 注入随机段：同秒同随机段才可能撞——程序语义下随机段取 UUID。
                let fixed = ShareInbox.makeFileName(now: Date(timeIntervalSince1970: 1_767_000_000), random: "abc123")
                try expectEqual(fixed, "share-\(fixed.split(separator: "-")[1])-1767000000-abc123.txt")
            },

            TestDesc(suite: "ShareInbox", name: "payloadValidationFailClosed") {
                try expectThrows(try ShareInbox.validatePayload(Data()), "空载荷必须拒收")
                let tooBig = Data(repeating: 0x61, count: ShareInbox.maxPayloadBytes + 1)
                try expectThrows(try ShareInbox.validatePayload(tooBig), "超 64KiB 必须拒收")
                try expectThrows(try ShareInbox.validatePayload(Data([0xFF, 0xFE, 0xFD])), "非 UTF-8 必须拒收")
                // 恰好 64KiB 可过；带 # 元数据行通过。
                let exactly = Data(String(repeating: "a", count: ShareInbox.maxPayloadBytes).utf8)
                try expectNoThrow(try ShareInbox.validatePayload(exactly))
                let payload = try ShareInbox.makePayload(text: "正文选段", sourceLines: ["书: xx", "页: 12"])
                try expectNoThrow(try ShareInbox.validatePayload(payload))
                try expectTrue(String(decoding: payload, as: UTF8.self).hasPrefix("# 书: xx\n# 页: 12\n正文选段"))
            },

            TestDesc(suite: "ShareInbox", name: "pullFiltersForeignNamesAndOversize") {
                let dir = tempDir("filter")
                defer { try? FileManager.default.removeItem(at: dir) }
                let good = "share-0a1b2c3d-1767000000-aaaaaa.txt"
                let good2 = "share-0a1b2c3d-1767000001-bbbbbb.txt"
                let oversize = "share-0a1b2c3d-1767000002-cccccc.txt"
                let loader = StubLoader(
                    listing: [
                        WebDAVResource(path: "/LiteratureSearch/sync/inbox/\(good)", isDirectory: false, size: 10, lastModified: nil),
                        WebDAVResource(path: "/LiteratureSearch/sync/inbox/\(good2)", isDirectory: false, size: 10, lastModified: nil),
                        WebDAVResource(path: "/LiteratureSearch/sync/inbox/\(oversize)", isDirectory: false,
                                       size: ShareInbox.maxFileBytes + 1, lastModified: nil),
                        WebDAVResource(path: "/LiteratureSearch/sync/inbox/manifest.json", isDirectory: false, size: 5, lastModified: nil),
                        WebDAVResource(path: "/LiteratureSearch/sync/inbox/../../evil.txt", isDirectory: false, size: 5, lastModified: nil),
                        WebDAVResource(path: "/LiteratureSearch/sync/inbox", isDirectory: true, size: 0, lastModified: nil),
                    ],
                    files: [good: Data("hello".utf8), good2: Data("world".utf8)])
                let puller = ShareInboxPuller(loader: loader, into: dir)
                let outcome = try await expectNoThrowAsync { try await puller.pull() }
                let out = try expectNotNil(outcome)
                try expectEqual(Set(out.downloaded), Set([good, good2]))
                try expectEqual(out.skippedOversize, [oversize])
                try expectEqual(out.foreignSkipped, 2, "怪名（manifest.json/穿越串）必须不下载")
                try expectFalse(out.stoppedForBudget)
                try expectTrue(String(decoding: try Data(contentsOf: dir.appendingPathComponent(good)), as: UTF8.self) == "hello")
            },

            TestDesc(suite: "ShareInbox", name: "pullSkipsExistingNamesIdempotently") {
                let dir = tempDir("idempotent")
                defer { try? FileManager.default.removeItem(at: dir) }
                let name = "share-0a1b2c3d-1767000000-aaaaaa.txt"
                try Data("old".utf8).write(to: dir.appendingPathComponent(name))
                let loader = StubLoader(
                    listing: [WebDAVResource(path: "/LiteratureSearch/sync/inbox/\(name)", isDirectory: false, size: 4, lastModified: nil)],
                    files: [name: Data("new".utf8)])
                let outcome = try expectNotNil(try await expectNoThrowAsync {
                    try await ShareInboxPuller(loader: loader, into: dir).pull()
                })
                try expectTrue(outcome.downloaded.isEmpty, "已存在同名必须跳过")
                try expectEqual(outcome.skippedExisting, [name])
                try expectTrue(loader.downloadCalls.isEmpty, "跳过 = 零下载调用")
                try expectTrue(String(decoding: try Data(contentsOf: dir.appendingPathComponent(name)), as: UTF8.self) == "old",
                               "本地内容不得被覆盖")
            },

            TestDesc(suite: "ShareInbox", name: "pullStopsAtTotalBudget") {
                let dir = tempDir("budget")
                defer { try? FileManager.default.removeItem(at: dir) }
                let perFile = Int64(700 * 1024)
                let names: [String] = (0..<100).map {
                    String(format: "share-0a1b2c3d-17670000%02d-%06d.txt", $0, $0)
                }
                for n in names { try expectTrue(ShareInbox.isAllowedFileName(n), "生成名必须合法: \(n)") }
                let listing = names.map {
                    WebDAVResource(path: "/LiteratureSearch/sync/inbox/\($0)", isDirectory: false,
                                   size: perFile, lastModified: nil)
                }
                let loader = StubLoader(listing: listing, files: [:])
                loader.noWrite = true
                let outcome = try expectNotNil(try await expectNoThrowAsync {
                    try await ShareInboxPuller(loader: loader, into: dir).pull()
                })
                let expected = Int(ShareInbox.maxTotalBytes / perFile)   // 67,108,864 / 716,800 = 93
                try expectEqual(outcome.downloaded.count, expected,
                                "预算内可下 \(expected) 个")
                try expectTrue(outcome.stoppedForBudget, "超预算即停")
                try expectEqual(outcome.bytes, Int64(expected) * perFile)
                try expectEqual(loader.downloadCalls.count, expected)
            },

            TestDesc(suite: "ShareInbox", name: "credentialMissingFailsLoudly") {
                try expectThrows(try ShareInboxPuller.validateCredentials(username: "", password: "x"))
                try expectThrows(try ShareInboxPuller.validateCredentials(username: "u", password: ""))
                try expectThrows(try ShareInboxPuller.validateCredentials(username: "   ", password: "x"))
                try expectNoThrow(try ShareInboxPuller.validateCredentials(username: "user", password: "app-password"))
            },
        ]
    }
}
