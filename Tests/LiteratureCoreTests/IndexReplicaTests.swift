import Foundation
@testable import LiteratureCore


enum IndexReplicaSuite {
    /// 桩 loader：manifest/卷字节全在内存；可注入错误与调用记录。
    final class StubLoader: ReplicaLoading {
        var manifestData: Data
        var volumes: [String: Data]
        var manifestError: Error?
        var downloadError: Error?
        private(set) var downloadCalls: [String] = []

        init(manifestData: Data, volumes: [String: Data]) {
            self.manifestData = manifestData
            self.volumes = volumes
        }

        func data(for remotePath: String) async throws -> (Data, URLResponse) {
            if let manifestError { throw manifestError }
            precondition(remotePath == IndexReplicaRemote.manifestPath)
            let response = HTTPURLResponse(url: URL(string: "https://stub.invalid/manifest.json")!,
                                           statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (manifestData, response)
        }

        func download(remotePath: String, to local: URL, expectedBytes: Int64?) async throws {
            let name = remotePath.split(separator: "/").last.map(String.init) ?? remotePath
            downloadCalls.append(name)
            if let downloadError { throw downloadError }
            guard let data = volumes[name] else { throw TestFailure(message: "桩无此卷: \(name)") }
            try FileManager.default.createDirectory(at: local.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: local, options: .atomic)
        }
    }

    struct Volume {
        var name: String
        var bytes: Data
    }

    /// 构造 manifest + 卷（hash16/contentHash 全按生产规则算，默认自洽；
    /// 测试可再篡改制造负例）。
    static func makeManifest(schemaVersion: Int = IndexStore.currentSchemaVersion,
                             volumes: [Volume],
                             contentHashOverride: String? = nil) throws -> (WebDAVIndexManifest, Data) {
        let assembled = volumes.map(\.bytes).reduce(Data(), +)
        var entries: [WebDAVIndexManifest.FileEntry] = []
        for (i, v) in volumes.enumerated() {
            entries.append(.init(name: v.name,
                                 sha256: Fingerprint.sha256Hex(of: v.bytes),
                                 size: Int64(v.bytes.count),
                                 order: i + 1))
        }
        let manifest = WebDAVIndexManifest(
            schemaVersion: schemaVersion,
            contentHash: contentHashOverride ?? WebDAVIndexManifest.contentHash(for: entries),
            bookCount: 1, pageCount: 2,
            createdAt: WebDAVIndexManifest.iso8601UTC.string(from: Date()),
            appVersion: "test",
            files: entries)
        return (manifest, assembled)
    }

    static func manifestData(_ manifest: WebDAVIndexManifest) throws -> Data {
        try manifest.jsonData()
    }

    /// 单卷名（含合法 hash16）。
    static func volumeName(hash16: String) -> String { "index-\(hash16).sqlite" }

    static func tempDir(_ tag: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("replica-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "IndexReplica", name: "singleVolumeDownloadReplacesReplicaAtomically") {
                let dir = tempDir("single")
                defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
                let bytes = Data("replica-bytes-v2".utf8)
                let (m, _) = try makeManifest(volumes: [Volume(
                    name: volumeName(hash16: String(Fingerprint.sha256Hex(of: bytes).prefix(16))),
                    bytes: bytes)])
                let replicaDir = dir.appendingPathComponent("replica", isDirectory: true)
                let oldLocal = replicaDir.appendingPathComponent("index.db")
                try FileManager.default.createDirectory(at: replicaDir, withIntermediateDirectories: true)
                try Data("old-replica".utf8).write(to: oldLocal)

                let loader = StubLoader(manifestData: try manifestData(m), volumes: [m.files[0].name: bytes])
                let manager = IndexReplicaManager(
                    loader: loader,
                    configuration: .init(replicaDirectory: replicaDir, tmpDirectory: dir.appendingPathComponent("tmp")))
                let outcome = try expectNotNil(try await expectNoThrowAsync { try await manager.syncReplica() })
                guard case .replaced(let hash, let volumes) = outcome else {
                    try failTest("期望 replaced，得到 \(outcome)")
                }
                try expectEqual(hash, m.contentHash)
                try expectEqual(volumes, 1)
                try expectEqual(try Data(contentsOf: oldLocal), bytes, "本地副本必须被整体替换为新卷字节")
                try expectTrue(loader.downloadCalls.count == 1)
            },

            TestDesc(suite: "IndexReplica", name: "forbiddenVolumeNamesRejectWholeManifest") {
                let dir = tempDir("whitelist")
                defer { try? FileManager.default.removeItem(at: dir) }
                let replicaDir = dir.appendingPathComponent("replica", isDirectory: true)
                let local = replicaDir.appendingPathComponent("index.db")
                try FileManager.default.createDirectory(at: replicaDir, withIntermediateDirectories: true)
                try Data("precious-old".utf8).write(to: local)
                let badNames = ["index-0123456789abcdef-part00.sqlite", "../evil.sqlite",
                                "index-ABCDEF0123456789.sqlite", "manifest-bak.json",
                                "index-0123456789abcdef-part1.txt"]
                for (i, bad) in badNames.enumerated() {
                    let bytes = Data("v\(i)".utf8)
                    let (m, _) = try makeManifest(volumes: [Volume(name: bad, bytes: bytes)])
                    let loader = StubLoader(manifestData: try manifestData(m), volumes: [bad: bytes])
                    let manager = IndexReplicaManager(
                        loader: loader,
                        configuration: .init(replicaDirectory: replicaDir,
                                             tmpDirectory: dir.appendingPathComponent("tmp")))
                    try await expectThrowsAsync(
                        { try await manager.syncReplica() },
                        "怪名必须整体拒收: \(bad)")
                    try expectEqual(try Data(contentsOf: local), Data("precious-old".utf8),
                                    "拒收后旧副本必须原样")
                }
            },

            TestDesc(suite: "IndexReplica", name: "manifestUnreadableFailsClosedKeepingOldReplica") {
                let dir = tempDir("badmanifest")
                defer { try? FileManager.default.removeItem(at: dir) }
                let replicaDir = dir.appendingPathComponent("replica", isDirectory: true)
                let local = replicaDir.appendingPathComponent("index.db")
                try FileManager.default.createDirectory(at: replicaDir, withIntermediateDirectories: true)
                try Data("keep-me".utf8).write(to: local)
                let loader = StubLoader(manifestData: Data("not-json{".utf8), volumes: [:])
                let manager = IndexReplicaManager(
                    loader: loader,
                    configuration: .init(replicaDirectory: replicaDir,
                                         tmpDirectory: dir.appendingPathComponent("tmp")))
                try await expectThrowsAsync({ try await manager.syncReplica() })
                try expectEqual(try Data(contentsOf: local), Data("keep-me".utf8))
            },

            TestDesc(suite: "IndexReplica", name: "checksumMismatchRejectsReplacement") {
                let dir = tempDir("sha")
                defer { try? FileManager.default.removeItem(at: dir) }
                let replicaDir = dir.appendingPathComponent("replica", isDirectory: true)
                let local = replicaDir.appendingPathComponent("index.db")
                try FileManager.default.createDirectory(at: replicaDir, withIntermediateDirectories: true)
                try Data("old-good".utf8).write(to: local)
                let real = Data("real-bytes".utf8)
                let hash16 = String(Fingerprint.sha256Hex(of: real).prefix(16))
                let name = volumeName(hash16: hash16)
                var (m, _) = try makeManifest(volumes: [Volume(name: name, bytes: real)])
                // 篡改卷声明 sha。
                let wrong = String(repeating: String(m.files[0].sha256.prefix(1)) , count: 64)
                m.files[0].sha256 = wrong
                m.contentHash = WebDAVIndexManifest.contentHash(for: m.files)
                // 送的仍是 real 字节（sha 声明错 → 校验失败）。
                let loader = StubLoader(manifestData: try manifestData(m), volumes: [name: real])
                let manager = IndexReplicaManager(
                    loader: loader,
                    configuration: .init(replicaDirectory: replicaDir,
                                         tmpDirectory: dir.appendingPathComponent("tmp")))
                try await expectThrowsAsync({ try await manager.syncReplica() }, "sha 不符必须拒替换")
                try expectEqual(try Data(contentsOf: local), Data("old-good".utf8))
            },

            TestDesc(suite: "IndexReplica", name: "operationOrderTmpThenReplaceThenCleanup") {
                let dir = tempDir("order")
                defer { try? FileManager.default.removeItem(at: dir) }
                let bytes = Data("orderly".utf8)
                let hash16 = String(Fingerprint.sha256Hex(of: bytes).prefix(16))
                let (m, _) = try makeManifest(volumes: [Volume(name: volumeName(hash16: hash16), bytes: bytes)])
                var events: [String] = []
                let loader = StubLoader(manifestData: try manifestData(m), volumes: [m.files[0].name: bytes])
                let manager = IndexReplicaManager(
                    loader: loader,
                    configuration: .init(replicaDirectory: dir.appendingPathComponent("replica"),
                                         tmpDirectory: dir.appendingPathComponent("tmp")))
                manager.operationLog = { events.append($0) }
                _ = try await manager.syncReplica()
                try expectEqual(events, ["fetch-manifest", "download:\(m.files[0].name)",
                                         "assemble", "replace", "cleanup"])
                // tmp 目录不得残留卷文件。
                let tmpContents = (try? FileManager.default.contentsOfDirectory(
                    atPath: dir.appendingPathComponent("tmp").path)) ?? ["<missing>"]
                try expectTrue(tmpContents.isEmpty, "替换成功后 tmp 必须清空: \(tmpContents)")
            },

            TestDesc(suite: "IndexReplica", name: "sameContentHashSkipsDownload") {
                let dir = tempDir("idempotent")
                defer { try? FileManager.default.removeItem(at: dir) }
                let bytes = Data("stable".utf8)
                let hash16 = String(Fingerprint.sha256Hex(of: bytes).prefix(16))
                let (m, _) = try makeManifest(volumes: [Volume(name: volumeName(hash16: hash16), bytes: bytes)])
                let config = IndexReplicaManager.Configuration(
                    replicaDirectory: dir.appendingPathComponent("replica"),
                    tmpDirectory: dir.appendingPathComponent("tmp"))
                let loader1 = StubLoader(manifestData: try manifestData(m), volumes: [m.files[0].name: bytes])
                _ = try await IndexReplicaManager(loader: loader1, configuration: config).syncReplica()
                // 第二次：同 manifest，桩里不给卷字节（下载必炸）——若真的发起下载测试即失败。
                let loader2 = StubLoader(manifestData: try manifestData(m), volumes: [:])
                let outcome = try expectNotNil(try await expectNoThrowAsync {
                    try await IndexReplicaManager(loader: loader2, configuration: config).syncReplica()
                })
                guard case .skippedIdentical(let hash) = outcome else {
                    try failTest("期望 skippedIdentical，得到 \(outcome)")
                }
                try expectEqual(hash, m.contentHash)
                try expectTrue(loader2.downloadCalls.isEmpty, "幂等跳过 = 零下载")
            },

            TestDesc(suite: "IndexReplica", name: "downloadErrorsPropagateAndKeepOldReplica") {
                let dir = tempDir("retry")
                defer { try? FileManager.default.removeItem(at: dir) }
                let replicaDir = dir.appendingPathComponent("replica", isDirectory: true)
                let local = replicaDir.appendingPathComponent("index.db")
                try FileManager.default.createDirectory(at: replicaDir, withIntermediateDirectories: true)
                try Data("stable-old".utf8).write(to: local)
                let bytes = Data("never-arrives".utf8)
                let hash16 = String(Fingerprint.sha256Hex(of: bytes).prefix(16))
                let (m, _) = try makeManifest(volumes: [Volume(name: volumeName(hash16: hash16), bytes: bytes)])
                let loader = StubLoader(manifestData: try manifestData(m), volumes: [m.files[0].name: bytes])
                loader.downloadError = WebDAVError.httpStatus(503, "GET stub（5xx 连发）")
                let manager = IndexReplicaManager(
                    loader: loader,
                    configuration: .init(replicaDirectory: replicaDir,
                                         tmpDirectory: dir.appendingPathComponent("tmp")))
                try await expectThrowsAsync({ try await manager.syncReplica() }, "引擎必须传播下载错误（重试在 loader 侧）")
                try expectEqual(try Data(contentsOf: local), Data("stable-old".utf8), "失败后旧副本原样")
            },

            TestDesc(suite: "IndexReplica", name: "assemblesByOrderRegardlessOfArrival") {
                let dir = tempDir("order2")
                defer { try? FileManager.default.removeItem(at: dir) }
                let part1 = Data(repeating: 0x41, count: 64)   // "AAAA…"
                let part2 = Data(repeating: 0x42, count: 64)   // "BBBB…"
                let assembled = part1 + part2
                let hash16 = String(Fingerprint.sha256Hex(of: assembled).prefix(16))
                let (m, _) = try makeManifest(volumes: [
                    Volume(name: "index-\(hash16)-part1.sqlite", bytes: part1),
                    Volume(name: "index-\(hash16)-part2.sqlite", bytes: part2),
                ])
                let loader = StubLoader(manifestData: try manifestData(m),
                                        volumes: [m.files[0].name: part1, m.files[1].name: part2])
                // 引擎按 manifest order 串行拉取后按 order 拼接（下载到达序
                // 与文件名字典序都不参与——顺序唯一事实源是 order 字段）。
                let replicaDir = dir.appendingPathComponent("replica", isDirectory: true)
                let manager = IndexReplicaManager(
                    loader: loader,
                    configuration: .init(replicaDirectory: replicaDir,
                                         tmpDirectory: dir.appendingPathComponent("tmp")))
                let outcome = try expectNotNil(try await expectNoThrowAsync { try await manager.syncReplica() })
                guard case .replaced(_, let count) = outcome else { try failTest("期望 replaced") }
                try expectEqual(count, 2)
                try expectEqual(try Data(contentsOf: replicaDir.appendingPathComponent("index.db")), assembled,
                                "组装序必须 = order 序（part1 在前）")
            },

            TestDesc(suite: "IndexReplica", name: "contentHashRecomputeMismatchRejects") {
                let dir = tempDir("chash")
                defer { try? FileManager.default.removeItem(at: dir) }
                let bytes = Data("x".utf8)
                let hash16 = String(Fingerprint.sha256Hex(of: bytes).prefix(16))
                let (m, _) = try makeManifest(volumes: [Volume(name: volumeName(hash16: hash16), bytes: bytes)],
                                              contentHashOverride: String(repeating: "0", count: 64))
                let loader = StubLoader(manifestData: try manifestData(m), volumes: [m.files[0].name: bytes])
                let manager = IndexReplicaManager(
                    loader: loader,
                    configuration: .init(replicaDirectory: dir.appendingPathComponent("replica"),
                                         tmpDirectory: dir.appendingPathComponent("tmp")))
                try await expectThrowsAsync({ try await manager.syncReplica() }, "contentHash 重算不符必须拒收")
            },

            TestDesc(suite: "IndexReplica", name: "uploaderRoundtripAndSchemaChangeReplacesWholesale") {
                // 上传侧：合成库 → VACUUM INTO 快照。
                let libDir = tempDir("lib")
                defer { try? FileManager.default.removeItem(at: libDir) }
                let dbURL = libDir.appendingPathComponent("index.db")
                let store = try IndexStore(path: dbURL)
                try CoverageClassificationSuite.addBook(store, id: "bA", name: "a.pdf",
                                                 pages: ["roundtrip norm page", "plain"])
                try store.setNormalizationVersion()
                let workDir = libDir.appendingPathComponent("work")
                let snapshot = try WebDAVIndexUploader.buildSnapshot(dbPath: dbURL, workDir: workDir, appVersion: "test")
                // 下载侧：manifest + 全部卷入桩。
                let dir = tempDir("roundtrip")
                defer { try? FileManager.default.removeItem(at: dir) }
                var volumes: [String: Data] = [:]
                for f in snapshot.manifest.files {
                    volumes[f.name] = try Data(contentsOf: workDir.appendingPathComponent(f.name))
                }
                let loader = StubLoader(manifestData: try manifestData(snapshot.manifest), volumes: volumes)
                let replicaDir = dir.appendingPathComponent("replica", isDirectory: true)
                let manager = IndexReplicaManager(
                    loader: loader,
                    configuration: .init(replicaDirectory: replicaDir,
                                         tmpDirectory: dir.appendingPathComponent("tmp")))
                _ = try await manager.syncReplica()
                // 落地后只读开 → 检索可用（与 Mac 侧结果一致）。
                let ro = try IndexStore(path: replicaDir.appendingPathComponent("index.db"),
                                        options: .init(readOnlyReplica: true))
                let hits = try SearchService(store: ro).searchDetailed("norm")
                try expectFalse(hits.hits.isEmpty, "副本只读检索必须可用")

                // schema 变更：库内容先变（加一本书 → 新 contentHash）→ 新真快照
                // 落地 = 整体替换（禁增量混用）。
                try CoverageClassificationSuite.addBook(store, id: "bB", name: "b.pdf", pages: ["second book text"])
                let workDir2 = libDir.appendingPathComponent("work2")
                let snapshot2 = try WebDAVIndexUploader.buildSnapshot(dbPath: dbURL, workDir: workDir2, appVersion: "test")
                try expectNotEqual(snapshot2.manifest.contentHash, snapshot.manifest.contentHash)
                var volumes2: [String: Data] = [:]
                for f in snapshot2.manifest.files {
                    volumes2[f.name] = try Data(contentsOf: workDir2.appendingPathComponent(f.name))
                }
                let loader2 = StubLoader(manifestData: try manifestData(snapshot2.manifest), volumes: volumes2)
                _ = try await IndexReplicaManager(loader: loader2,
                                                  configuration: manager.configuration).syncReplica()
                let replicaURL = replicaDir.appendingPathComponent("index.db")
                try expectEqual(try Data(contentsOf: replicaURL),
                                try Data(contentsOf: workDir2.appendingPathComponent(snapshot2.manifest.files[0].name)),
                                "schema/内容变更必须整体替换（禁增量混用）")
                // 高版本形态：RW 连接把副本 index_schema_version 提到 current+1
                // （等价模拟「未来版本 App 上传的库」；SQLite 层合法改写）。
                let rw = try SQLiteDatabase(path: replicaURL.path)
                let bump = try rw.prepare(
                    "UPDATE meta SET value = ? WHERE key = 'index_schema_version';")
                try bump.bindText(1, String(IndexStore.currentSchemaVersion + 1))
                try bump.run()
                // 旧 App 拒开（门禁联动）：消息含「升级」。
                var thrown: Error?
                do {
                    _ = try IndexStore(path: replicaURL, options: .init(readOnlyReplica: true))
                } catch { thrown = error }
                let err = try expectNotNil(thrown, "高版本副本落地后旧 App 必须拒开")
                try expectTrue(String(describing: err).contains("升级"),
                               "消息须含「升级」: \(err)")
            },
        ]
    }
}
