import Foundation
import CryptoKit
import LiteratureSearchUI
@testable import LiteratureCore

// MARK: - 索引上传合成套件（零真实网络；桩记录请求序）

enum WebDAVIndexUploadSuite {
    // MARK: 合成库与工具

    /// 合成小库（数本书数页，含 FTS，使快照体积可超过调小的分卷上限）。
    static func makeStoreWithBooks(in dir: URL) throws -> IndexStore {
        let store = try Fixtures.openStore(in: dir)
        for b in 1...3 {
            let pages = (1...4).map { p -> String in
                "book\(b) 第\(p)页 sample title legal concept alpha beta " + String(repeating: "x", count: 200)
            }
            try addBook(store, id: "b\(b)", name: "book\(b).pdf", pages: pages)
        }
        return store
    }

    static func addBook(_ store: IndexStore, id: String, name: String, pages: [String]) throws {
        let book = IndexStore.BookRow(
            id: id, realPath: "/tmp/lit-tests/\(name)", rootPath: "/tmp/lit-tests",
            relPath: name, fileName: name,
            firstFingerprint: "fp-\(id)", fingerprint: "fp-\(id)", fileSize: 1, mtime: 0,
            pageCount: pages.count, status: "ok", indexedAt: 0)
        try store.upsertBook(book)
        var rows: [IndexStore.PageRow] = []
        for (i, text) in pages.enumerated() {
            let n = normalizeForSearch(text)
            rows.append(IndexStore.PageRow(bookID: id, pageNumber: i + 1, textOriginal: text,
                                           textNorm: n.text, normStarts: n.starts, normEnds: n.ends))
        }
        try store.replacePages(bookID: id, rows)
    }

    /// 独立流式 sha256（不经 Fingerprint stat 缓存，杜绝环形断言）。
    static func sha256File(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20)
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func manifestData(files: [WebDAVIndexManifest.FileEntry]) throws -> Data {
        try WebDAVIndexManifest(schemaVersion: IndexStore.currentSchemaVersion,
                                contentHash: WebDAVIndexManifest.contentHash(for: files),
                                bookCount: 1, pageCount: 2,
                                createdAt: "2026-09-29T00:00:00Z", appVersion: "test",
                                files: files).jsonData()
    }

    static func singleFile(_ name: String, size: Int64) -> [WebDAVIndexManifest.FileEntry] {
        [.init(name: name, sha256: String(repeating: String(name.first ?? "0"), count: 64),
               size: size, order: 1)]
    }

    static func bytes(_ n: Int, seed: UInt8 = 7) -> [UInt8] {
        (0..<n).map { UInt8((Int($0) % 251) ^ Int(seed)) }
    }

    static func byteStream(_ payload: [UInt8]) -> AsyncStream<UInt8> {
        AsyncStream { cont in
            for b in payload { cont.yield(b) }
            cont.finish()
        }
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// 测试调小上传器常量（defer 恢复生产值；在用例闭包内成对使用）。
    static func shrinkUploadLimits(volume: Int64? = nil, verifyBackoffNs: UInt64? = nil,
                                   intervalNs: UInt64? = nil) -> [(String, UInt64, Int64)] {
        var restore: [(String, UInt64, Int64)] = []
        if let volume {
            restore.append(("maxVolumeBytes", 0, WebDAVIndexUploader.maxVolumeBytes))
            WebDAVIndexUploader.maxVolumeBytes = volume
        }
        if let verifyBackoffNs {
            restore.append(("backoff", verifyBackoffNs, Int64(WebDAVIndexUploader.verifyRetryBackoffNanoseconds)))
            WebDAVIndexUploader.verifyRetryBackoffNanoseconds = verifyBackoffNs
        }
        if let intervalNs {
            restore.append(("interval", intervalNs, Int64(WebDAVIndexUploader.volumePutIntervalNanoseconds)))
            WebDAVIndexUploader.volumePutIntervalNanoseconds = intervalNs
        }
        return restore
    }

    static func restoreUploadLimits(_ saved: [(String, UInt64, Int64)]) {
        for entry in saved {
            switch entry.0 {
            case "maxVolumeBytes": WebDAVIndexUploader.maxVolumeBytes = entry.2
            case "backoff": WebDAVIndexUploader.verifyRetryBackoffNanoseconds = entry.1
            case "interval": WebDAVIndexUploader.volumePutIntervalNanoseconds = entry.1
            default: break
            }
        }
    }

    // MARK: 桩服务器（记录 PUT/DELETE 序；list/manifest 可脚本化）

    /// 远端形态 = 上传前缀内 {name → size} 字典 + 可选 manifest.json。
    class StubUploadServer: WebDAVClient {
        var remote: [String: Int64] = [:]
        var mtimes: [String: Date] = [:]
        var manifestBytes: Data?
        private(set) var puts: [String] = []
        private(set) var deletes: [String] = []
        private(set) var mkcolCalls = 0
        private(set) var manifestPUTs = 0
        var failUploadNames: Set<String> = []
        var lieFirstVerifyFor: String?
        private var lieNextListFor: String?
        var lieAllSizes = false
        /// 下载任何远端文件时抛错（fail-closed 门测试）。
        var downloadFails = false
        /// 第 2 次 manifest 下载改发此内容（两步之间并发方提交了引用
        /// 候选卷的新 manifest）。
        var secondManifestBytes: Data?
        /// 第 2 次 manifest 下载直接 404（二次核对 fail-closed 场景）。
        var secondManifestAbsent = false
        private(set) var manifestDownloads = 0
        /// 第 N 次 list 隐藏这些名（清理器最后一次 list = 二次确认）。
        var hideOnListCall: [Int: Set<String>] = [:]
        var listCount = 0
        var seenExpectedDownloadBytes: [Int64?] = []

        init() {
            super.init(serverBase: URL(string: "https://dav.example/webdav")!,
                       username: "u", password: "p")
        }

        func resources() -> [WebDAVResource] {
            var names = Set(remote.keys)
            if manifestBytes != nil { names.insert("manifest.json") }
            if let hide = hideOnListCall[listCount] { names.subtract(hide) }
            return names.sorted().map { name in
                var size = remote[name] ?? 0
                if let lied = lieNextListFor, lied == name { size += 1; lieNextListFor = nil }
                if lieAllSizes { size += 1 }
                let href = "/webdav/LiteratureSearch/sync/index/\(name)"
                return WebDAVResource(path: href, isDirectory: false, size: size,
                                      lastModified: mtimes[name])
            }
        }

        override func list(directory: String) async throws -> [WebDAVResource] {
            listCount += 1
            return resources()
        }

        override func upload(fileURL: URL, to remotePath: String) async throws -> Int64 {
            let name = (remotePath as NSString).lastPathComponent
            if failUploadNames.contains(name) {
                throw WebDAVError.httpStatus(500, "PUT \(name)")
            }
            puts.append(name)
            let size = WebDAVIndexUploadSuite.fileSize(fileURL)
            if name == "manifest.json" {
                manifestPUTs += 1
                manifestBytes = try Data(contentsOf: fileURL)
            } else {
                remote[name] = size
                if name == lieFirstVerifyFor { lieNextListFor = name; lieFirstVerifyFor = nil }
            }
            return size
        }

        override func delete(path: String) async throws {
            let name = (path as NSString).lastPathComponent
            deletes.append(name)
            remote.removeValue(forKey: name)
        }

        override func makeCollection(path: String = WebDAVIndexPaths.uploadPrefixDirectory) async throws {
            mkcolCalls += 1
        }

        override func download(remotePath: String, to local: URL,
                               expectedBytes: Int64?, absoluteCap: Int64) async throws {
            seenExpectedDownloadBytes.append(expectedBytes)
            if downloadFails {
                throw WebDAVError.httpStatus(500, "GET \(remotePath)")
            }
            let name = (remotePath as NSString).lastPathComponent
            if name == "manifest.json" {
                manifestDownloads += 1
                if manifestDownloads == 2 {
                    if secondManifestAbsent {
                        throw WebDAVError.httpStatus(404, "GET \(remotePath)")
                    }
                    if let second = secondManifestBytes {
                        try second.write(to: local, options: .atomic)
                        return
                    }
                }
            }
            guard let manifestBytes else {
                throw WebDAVError.httpStatus(404, "GET \(remotePath)")
            }
            try manifestBytes.write(to: local, options: .atomic)
        }
    }

    // MARK: 用例

    static var tests: [TestDesc] {
        [
            // MARK: 白名单与编码

            TestDesc(suite: "WebDAVIndexUpload", name: "whitelistAcceptsWellFormedNames") {
                for ok in ["index-0123456789abcdef.sqlite",
                           "index-0123456789abcdef-part2.sqlite",
                           "index-0123456789abcdef-part12.sqlite",
                           "manifest.json"] {
                    try expectTrue(WebDAVIndexPaths.isAllowedRemoteName(ok), "应通过：\(ok)")
                }
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "whitelistRejectsMalformedNames") {
                for bad in ["index-0123456789ABCDEF.sqlite",        // 大写 hash 拒
                            "index-0123456789abcdeff.sqlite",       // 17 位拒
                            "index-0123456789abcdef-part00.sqlite", // part00 拒
                            "index-0123456789abcdef-part0.sqlite",  // part0 拒
                            "index-0123456789abcdef.sqlite3",       // 扩展名变体拒
                            "index-0123456789abcdef.sqlite.bak",
                            "index-0123456789abcde/../../etc.sqlite", // 带路径分隔拒
                            "",
                            "%2e%2e",                               // 解码后穿越形态（字面不匹配正则）
                            "manifest.json5",
                            "Manifest.json",
                            "manifest .json"] {
                    try expectFalse(WebDAVIndexPaths.isAllowedRemoteName(bad), "应拒绝：\(bad)")
                }
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "encodeSegmentRFC3986Matrix") {
                try expectEqual(WebDAVIndexPaths.encodeSegment("法"), "%E6%B3%95", "中文逐字节")
                try expectEqual(WebDAVIndexPaths.encodeSegment("a b"), "a%20b", "空格")
                try expectEqual(WebDAVIndexPaths.encodeSegment("a#b"), "a%23b", "#")
                try expectEqual(WebDAVIndexPaths.encodeSegment("a?b"), "a%3Fb", "?")
                try expectEqual(WebDAVIndexPaths.encodeSegment("a%b"), "a%25b", "%")
                try expectEqual(WebDAVIndexPaths.encodeSegment("a\\b"), "a%5Cb", "反斜杠")
                try expectEqual(WebDAVIndexPaths.encodeSegment("👍"), "%F0%9F%91%8D", "emoji")
                try expectEqual(WebDAVIndexPaths.encodeSegment("a-._~b"), "a-._~b", "unreserved 不动")
                try expectNil(WebDAVIndexPaths.encodeSegment(""), "空段拒")
                try expectNil(WebDAVIndexPaths.encodeSegment("a/b"), "含 / 拒")
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "remoteURLCompositionAndTraversal") {
                let base = try expectNotNil(URL(string: "https://dav.example.com/webdav"))
                let url = try expectNotNil(WebDAVIndexPaths.remoteURL(
                    base: base, segments: ["LiteratureSearch", "sync", "index", "index-0123456789abcdef.sqlite"]))
                try expectEqual(url.absoluteString,
                                "https://dav.example.com/webdav/LiteratureSearch/sync/index/index-0123456789abcdef.sqlite")
                for bad in [[".."], ["a?b"], ["a#b"], ["a/b"]] {
                    try expectNil(WebDAVIndexPaths.remoteURL(base: base, segments: bad), "应拒：\(bad)")
                }
                let root = try expectNotNil(WebDAVIndexPaths.remoteURL(base: base, segments: []))
                try expectEqual(root.absoluteString, "https://dav.example.com/webdav",
                                "空段=根目录（尾斜杠由 list() 补）")
                let sneaky = try expectNotNil(URL(string: "https://x.example/a/../b"))
                try expectNil(WebDAVIndexPaths.remoteURL(base: sneaky, segments: []), "base 内 .. 拒")
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "uploadURLRequiresWhitelistName") {
                let base = try expectNotNil(URL(string: "https://dav.example/webdav"))
                try expectNotNil(WebDAVIndexPaths.uploadURL(base: base, fileName: "manifest.json"))
                try expectNil(WebDAVIndexPaths.uploadURL(base: base, fileName: "evil.txt"))
                try expectNil(WebDAVIndexPaths.uploadURL(base: base, fileName: "index-XYZ.sqlite"))
            },

            // MARK: 三方法+MKCOL

            TestDesc(suite: "WebDAVIndexUpload", name: "newMethodRequestShapesAndAuthHeader") {
                let client = WebDAVClient(serverBase: URL(string: "https://dav.example/webdav")!,
                                          username: "u", password: "p")
                _ = try client.validatedUploadURL("LiteratureSearch/sync/index/index-0123456789abcdef.sqlite")
                let url = try client.validatedUploadURL("LiteratureSearch/sync/index/manifest.json")
                for method in ["PUT", "MOVE", "DELETE", "MKCOL"] {
                    let req = client.request(method: method, url: url, depth: nil)
                    try expectEqual(req.httpMethod, method)
                    try expectEqual(req.value(forHTTPHeaderField: "Authorization"),
                                    "Basic \(Data("u:p".utf8).base64EncodedString())")
                    try expectNil(req.value(forHTTPHeaderField: "Depth"))
                }
                let propfind = client.request(method: "PROPFIND", url: url, depth: 1)
                try expectEqual(propfind.value(forHTTPHeaderField: "Depth"), "1")
                // MOVE 的 Destination 头 = validated target 绝对串（接线经代码
                // 走查；离线无真实传输层，此处断言固定目标 URL 构造）。
                let target = try client.validatedUploadURL(
                    "LiteratureSearch/sync/index/index-ffffffffffffffff.sqlite")
                try expectEqual(target.path, "/webdav/LiteratureSearch/sync/index/index-ffffffffffffffff.sqlite")
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "forbiddenTargetsThrowBeforeAnyNetwork") {
                let client = WebDAVClient(serverBase: URL(string: "https://dav.example/webdav")!,
                                          username: "u", password: "p")
                let evil = "LiteratureSearch/sync/index/evil.txt"
                // 全部在 URL 校验层抛错（session 触达之前，零网络调用）。
                try expectThrows(try client.validatedUploadTarget(evil), "白名单外 PUT 目标拒")
                try expectThrows(try client.validatedUploadTarget("LiteratureSearch/sync/index/../../etc/passwd"),
                                 "穿越路径拒")
                try expectThrows(try client.mkcolSegments("Other/sync/index"), "前缀外 MKCOL 拒")
                let ok = try client.mkcolSegments("LiteratureSearch")
                try expectEqual(ok, [["LiteratureSearch"]], "前缀首段合法")
            },

            // MARK: 安全约束

            TestDesc(suite: "WebDAVIndexUpload", name: "validatedBaseMatrix") {
                try expectNotNil(try WebDAVClient.validatedBase("https://dav.example/webdav"))
                // 大写 scheme 按 URL 标准处理（scheme 大小写不敏感）。
                if URL(string: "HTTPS://dav.example/webdav") != nil {
                    try expectNotNil(try WebDAVClient.validatedBase("HTTPS://dav.example/webdav"))
                }
                for bad in ["http://dav.example/webdav",        // 明文拒
                            "https://user:pass@dav.example/x",  // 内嵌 userinfo 拒
                            "https://",                          // 空 host 拒
                            "not a url",
                            "ftp://dav.example"] {
                    try expectThrows(try WebDAVClient.validatedBase(bad), "应拒：\(bad)")
                }
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "insecureBaseErrorOmitsRawInput") {
                // 拒绝错误只带 scheme/host 与原因，绝不回显地址
                // 原文（原文可能含凭据与 query；错误串会进状态行/审计）。
                let secret = "https://alice:s3cret-pw@dav.example/x?token=topsecret"
                do {
                    _ = try WebDAVClient.validatedBase(secret)
                    try failTest("内嵌 userinfo 必须被拒")
                } catch {
                    let d = String(describing: error)
                    try expectFalse(d.contains("alice"), "用户名不入错误串")
                    try expectFalse(d.contains("s3cret-pw"), "密码不入错误串")
                    try expectFalse(d.contains("topsecret"), "query 不入错误串")
                    try expectTrue(d.contains("https"), "只回显 scheme")
                    try expectTrue(d.contains("dav.example"), "只回显 host")
                }
                // 无 scheme 输入（scheme 被解析为用户名串）同样不回显。
                let noScheme = "alice:s3cret-pw@dav.example"
                do {
                    _ = try WebDAVClient.validatedBase(noScheme)
                    try failTest("无 scheme 输入必须被拒")
                } catch {
                    let d = String(describing: error)
                    try expectFalse(d.contains("alice"), "scheme 位不得回显用户名串")
                    try expectFalse(d.contains("s3cret-pw"), "密码不入错误串")
                }
                // 拒绝信息入库路径（AppState 审计 append 的负载即 error 串）
                // 与本断言同源，串净化即审计净化。
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "propfindWithoutContentLengthMarksUndeclared") {
                // getcontentlength 缺失 = 未声明（≠0 字节文件）。
                let noLength = #"<?xml version="1.0"?><D:multistatus><D:response><D:href>/webdav/books/a.pdf</D:href><D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat></D:response></D:multistatus>"#
                let res = try WebDAVClient.parsePropfind(Data(noLength.utf8),
                                                         baseURL: URL(string: "https://dav.example/webdav/books/")!)
                try expectEqual(res.count, 1)
                try expectEqual(res[0].size, 0)
                try expectFalse(res[0].sizeDeclared, "缺失 = 未声明")
                let withLength = #"<?xml version="1.0"?><D:multistatus><D:response><D:href>/webdav/books/a.pdf</D:href><D:propstat><D:prop><D:resourcetype/><D:getcontentlength>77</D:getcontentlength></D:prop></D:propstat></D:response></D:multistatus>"#
                let res2 = try WebDAVClient.parsePropfind(Data(withLength.utf8),
                                                          baseURL: URL(string: "https://dav.example/webdav/books/")!)
                try expectTrue(res2[0].sizeDeclared, "有长度 = 已声明")
                try expectEqual(res2[0].size, 77)
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "engineSkipsDeclaredSizeWhenUndeclared") {
                // 未声明 size 的条目不传声明值（兼容回归防护
                // 传 0 会把一切非空文件判 mismatch）。
                let dir = Fixtures.makeTempDir("dl-undeclared")
                defer { Fixtures.cleanup(dir) }
                let root = dir.appendingPathComponent("库", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let rule = WebDAVSyncRule(remoteDir: "/books", localRoot: root)
                final class UndeclaredSpy: StubUploadServer {
                    override func list(directory: String) async throws -> [WebDAVResource] {
                        [WebDAVResource(path: "/books/a.pdf", isDirectory: false, size: 0,
                                        lastModified: nil, sizeDeclared: false)]
                    }
                    override func download(remotePath: String, to local: URL,
                                           expectedBytes: Int64?, absoluteCap: Int64) async throws {
                        seenExpectedDownloadBytes.append(expectedBytes)
                        try "new-content".write(to: local, atomically: true, encoding: .ascii)
                    }
                }
                let stub = UndeclaredSpy()
                let config = WebDAVSyncConfig(serverBase: "https://dav.example/webdav",
                                              username: "u", rules: [rule])
                let out = try await WebDAVSyncEngine.sync(rule: rule, config: config, password: "p", client: stub)
                try expectEqual(stub.seenExpectedDownloadBytes, [Int64?(nil)], "未声明 → expectedBytes=nil")
                try expectEqual(out.downloaded, ["a.pdf"], "下载照常完成（不被 0 判 mismatch）")
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "redirectGuardMatrix") {
                let from = URL(string: "https://dav.example:443/webdav/a")!
                try expectTrue(RedirectGuard.isAllowed(
                    from: from, to: URL(string: "https://dav.example/webdav/b")!), "同 origin 过")
                try expectFalse(RedirectGuard.isAllowed(
                    from: from, to: URL(string: "http://dav.example/webdav/b")!), "降级 http 拒")
                try expectFalse(RedirectGuard.isAllowed(
                    from: from, to: URL(string: "https://evil.example/webdav/b")!), "跨 host 拒")
                try expectFalse(RedirectGuard.isAllowed(
                    from: from, to: URL(string: "https://dav.example:8443/webdav/b")!), "跨端口拒")
                try expectFalse(RedirectGuard.isAllowed(from: nil, to: from), "空源拒")
                try expectFalse(RedirectGuard.isAllowed(from: from, to: nil), "空目标拒")
                try expectTrue(RedirectGuard.isAllowed(
                    from: from, to: URL(string: "HTTPS://DAV.EXAMPLE/webdav/b")!), "scheme/host 大小写归一")
            },

            // MARK: 快照/分卷/manifest

            TestDesc(suite: "WebDAVIndexUpload", name: "buildSnapshotSingleVolumeManifestFields") {
                let dir = Fixtures.makeTempDir("snap-single")
                defer { Fixtures.cleanup(dir) }
                let store = try makeStoreWithBooks(in: dir)
                let snapshot = try WebDAVIndexUploader.buildSnapshot(
                    dbPath: dir.appendingPathComponent("index.db"),
                    workDir: dir.appendingPathComponent("work"), appVersion: "t")
                _ = store   // 源库保持打开（快照连接非唯一连接）
                let m = snapshot.manifest
                try expectEqual(m.schemaVersion, IndexStore.currentSchemaVersion, "schema_version")
                try expectEqual(m.bookCount, 3, "book_count=coverageStats 基准")
                try expectEqual(m.pageCount, 12, "page_count")
                try expectNotNil(WebDAVIndexManifest.iso8601UTC.date(from: m.createdAt), "ISO8601 UTC")
                try expectEqual(m.appVersion, "t")
                let indexFiles = m.files.filter { $0.name.hasPrefix("index-") }
                let fulltextFiles = m.files.filter { $0.name.hasPrefix("fulltext-") }
                try expectEqual(indexFiles.count, 1, "主库单卷")
                try expectEqual(fulltextFiles.count, 1, "全文库单卷（双件分离）")
                let f = try expectNotNil(indexFiles.first)
                try expectEqual(f.order, 1)
                try expectEqual(f.name, "index-\(snapshot.assembledSHA256.prefix(16)).sqlite",
                                "卷名内嵌整快照 sha 前 16 位")
                try expectEqual(f.sha256, snapshot.assembledSHA256)
                try expectEqual(fulltextFiles[0].order, 2, "ft 卷 order 续接（全局唯一）")
                try expectEqual(m.contentHash, WebDAVIndexManifest.contentHash(for: m.files))
                try expectTrue(FileManager.default.fileExists(
                    atPath: snapshot.volumeURL(f.name).path), "卷文件落 workDir")
                let round = try WebDAVIndexManifest.parse(
                    try Data(contentsOf: snapshot.manifestFileURL))
                try expectEqual(round, m, "manifest.json 往返一致")
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "manifestJSONKeysMatchDesignVerbatim") {
                let dir = Fixtures.makeTempDir("snap-keys")
                defer { Fixtures.cleanup(dir) }
                _ = try makeStoreWithBooks(in: dir)
                let snapshot = try WebDAVIndexUploader.buildSnapshot(
                    dbPath: dir.appendingPathComponent("index.db"),
                    workDir: dir.appendingPathComponent("work"), appVersion: "t")
                let raw = try String(contentsOf: snapshot.manifestFileURL, encoding: .utf8)
                for key in ["schema_version", "content_hash", "book_count", "page_count",
                            "created_at", "app_version", "\"name\"", "sha256", "\"size\"", "\"order\""] {
                    try expectTrue(raw.contains(key), "JSON 须含设计稿 字段 \(key)")
                }
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "buildSnapshotMultiVolumeRoundtrip") {
                let dir = Fixtures.makeTempDir("snap-multi")
                defer { Fixtures.cleanup(dir) }
                _ = try makeStoreWithBooks(in: dir)
                let saved = shrinkUploadLimits(volume: 16 << 10)
                defer { restoreUploadLimits(saved) }
                let snapshot = try WebDAVIndexUploader.buildSnapshot(
                    dbPath: dir.appendingPathComponent("index.db"),
                    workDir: dir.appendingPathComponent("work"), appVersion: "t")
                let files = snapshot.manifest.files.sorted { $0.order < $1.order }
                try expectTrue(files.count > 1, "合成库须切成多卷（预置条件）")
                let indexFiles = files.filter { $0.name.hasPrefix("index-") }
                let fulltextFiles = files.filter { $0.name.hasPrefix("fulltext-") }
                try expectTrue(indexFiles.count > 1, "主库须切成多卷（预置条件）")
                try expectTrue(!fulltextFiles.isEmpty, "全文库卷在位（双件分离）")
                for (i, f) in files.enumerated() {
                    try expectEqual(f.order, i + 1, "order 全局连续")
                }
                for (i, f) in indexFiles.enumerated() {
                    try expectTrue(f.name ==
                        "index-\(snapshot.assembledSHA256.prefix(16))-part\(i + 1).sqlite",
                        "主库卷名形态：\(f.name)")
                }
                for (i, f) in fulltextFiles.enumerated() {
                    try expectTrue(f.name.hasPrefix("fulltext-") && f.name.contains("-part\(i + 1).sqlite"),
                                    "全文库卷名形态：\(f.name)")
                }
                // 按逻辑件分组、组内按 order 字节拼接 → 各自整件 sha == 卷名
                // 内嵌 hash16 的整 sha（主库=assembledSHA256）。
                func assembledSHA(of group: [WebDAVIndexManifest.FileEntry]) throws -> String {
                    var assembled = Data()
                    for f in group.sorted(by: { $0.order < $1.order }) {
                        assembled.append(try Data(contentsOf: snapshot.volumeURL(f.name)))
                    }
                    return Fingerprint.sha256Hex(of: assembled)
                }
                let indexSHA = try assembledSHA(of: indexFiles)
                try expectEqual(indexSHA, snapshot.assembledSHA256,
                                "主库分卷 roundtrip：拼接逐字节还原")
                try expectTrue(String(indexSHA.prefix(16)) == snapshot.assembledSHA256.prefix(16),
                               "主库内嵌 hash 对照")
                let ftSHA = try assembledSHA(of: fulltextFiles)
                for f in fulltextFiles {
                    try expectTrue(f.name.contains(String(ftSHA.prefix(16))),
                                    "ft 卷名内嵌 ft 整件 hash：\(f.name)")
                }
                try expectEqual(WebDAVIndexManifest.contentHash(for: files),
                                snapshot.manifest.contentHash, "content_hash 单多卷同规则")
                // 每卷 size ≤ 上限，且无 0 字节卷。
                for f in files {
                    try expectTrue(f.size > 0 && f.size <= 16 << 10,
                                   "卷 \(f.name) size=\(f.size) 须在 (0, 上限] 内")
                }
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "splitVolumesBoundedAndNoEmptyTail") {
                // 以任意字节负载直测分卷上限语义（不依赖 SQLite）。
                let dir = Fixtures.makeTempDir("split")
                defer { Fixtures.cleanup(dir) }
                let hash16 = "0123456789abcdef"

                func runSplit(_ payload: Data, cap: Int64)
                    throws -> ([WebDAVIndexManifest.FileEntry], URL) {
                    let work = dir.appendingPathComponent("work-\(cap)-\(payload.count)")
                    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                    let src = dir.appendingPathComponent("assembled-\(cap)-\(payload.count).bin")
                    try payload.write(to: src)
                    return (try WebDAVIndexUploader.splitVolumes(
                        assembledAt: src, workDir: work, hash16: hash16, volumeCap: cap), work)
                }

                let (exact, exactWork) = try runSplit(Data(bytes(12288, seed: 1)), cap: 4096)
                try expectEqual(exact.map(\.size), [Int64(4096), 4096, 4096], "整除场景恰 3 满卷")
                try expectTrue(exact.allSatisfy { $0.name.hasSuffix("-part\($0.order).sqlite") })
                let (tiny, tinyWork) = try runSplit(Data(bytes(250, seed: 2)), cap: 100)
                try expectEqual(tiny.map(\.size), [Int64(100), 100, 50], "小上限逐额切分")
                let (single, singleWork) = try runSplit(Data(bytes(300, seed: 3)), cap: 4096)
                try expectEqual(single.count, 1)
                try expectEqual(single[0].name, "index-\(hash16).sqlite", "单卷不带 part 序号")

                // 三种切分均 roundtrip 还原。
                for (entry, workDir, payload) in [(exact, exactWork, Data(bytes(12288, seed: 1))),
                                                  (tiny, tinyWork, Data(bytes(250, seed: 2))),
                                                  (single, singleWork, Data(bytes(300, seed: 3)))] {
                    var reassembled = Data()
                    for f in entry {
                        let url = workDir.appendingPathComponent(f.name)
                        let chunk = try Data(contentsOf: url)
                        try expectTrue(Int64(chunk.count) == f.size && f.size > 0,
                                       "卷 \(f.name) 无 0 字节且 size 与落盘一致")
                        reassembled.append(chunk)
                    }
                    try expectEqual(Fingerprint.sha256Hex(of: reassembled),
                                    Fingerprint.sha256Hex(of: Data(payload)), "roundtrip 还原")
                }
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "contentHashCanonicalRulePinned") {
                let f1 = WebDAVIndexManifest.FileEntry(name: "index-aaaaaaaaaaaaaaaa.sqlite",
                                                       sha256: String(repeating: "a", count: 64),
                                                       size: 5, order: 2)
                let f2 = WebDAVIndexManifest.FileEntry(name: "index-bbbbbbbbbbbbbbbb.sqlite",
                                                       sha256: String(repeating: "b", count: 64),
                                                       size: 7, order: 1)
                let hash = WebDAVIndexManifest.contentHash(for: [f1, f2])
                // 规范化串独立重建（按 order 排序后逐行 name|sha256|size|\n）。
                let canonical = "index-bbbbbbbbbbbbbbbb.sqlite|\(String(repeating: "b", count: 64))|7|\n"
                    + "index-aaaaaaaaaaaaaaaa.sqlite|\(String(repeating: "a", count: 64))|5|\n"
                try expectEqual(hash, Fingerprint.sha256Hex(of: Data(canonical.utf8)), "规则逐字断言固定")
                try expectEqual(hash, WebDAVIndexManifest.contentHash(for: [f2, f1]), "输入顺序无关")
                try expectEqual(hash, WebDAVIndexManifest.contentHash(for: [f1, f2]), "确定性：两次一致")
                let changed = WebDAVIndexManifest.FileEntry(name: f2.name, sha256: f2.sha256,
                                                            size: 8, order: 1)
                try expectNotEqual(hash, WebDAVIndexManifest.contentHash(for: [f1, changed]),
                                   "size 变化 → hash 变化")
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "vacuumIntoReadOnlyUniqueConnectionKeepsSource") {
                // 唯一连接场景：关闭写连接后再快照，只读连接 VACUUM INTO
                // 不经 checkpoint 改写主库。以 RW 打开时，本场景会改写主库
                // 并删 -wal。
                let dir = Fixtures.makeTempDir("snap-unique")
                defer { Fixtures.cleanup(dir) }
                let dbPath = dir.appendingPathComponent("index.db")
                do { _ = try makeStoreWithBooks(in: dir) }   // 关闭唯一写连接（clean close：wal 合并删除）
                let before = try sha256File(dbPath)
                let walBefore = FileManager.default.fileExists(atPath: dbPath.path + "-wal")
                let snapshot = try WebDAVIndexUploader.buildSnapshot(
                    dbPath: dbPath, workDir: dir.appendingPathComponent("work"), appVersion: "t")
                try expectEqual(try sha256File(dbPath), before, "主库逐字节不变（零写）")
                let walAfter = try? Data(contentsOf: URL(fileURLWithPath: dbPath.path + "-wal"))
                // wal 存在性：原本不存在 → 不得冒出非空 wal（RO 连接至多为
                // SQLite 自身初始化的 0 字节 wal，不含任何帧）。
                try expectTrue(walAfter == nil || walAfter?.isEmpty == true,
                               "唯一连接场景：无数据写入 wal（got \(walAfter?.count ?? -1) B）")
                try expectTrue(walBefore == (walAfter != nil) || walAfter?.isEmpty == true,
                               "-wal 存在性不变或为 0 字节空件")
                // 快照含全部已提交内容（只读通道读全量）。
                let round = try WebDAVIndexManifest.parse(
                    try Data(contentsOf: snapshot.manifestFileURL))
                try expectEqual(round.bookCount, 3)
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "vacuumIntoWithOpenWriterKeepsWalIntact") {
                // 生产形态：App 持 IndexStore（写连接，WAL 含未合并帧）时快照。
                // 断言主库 sha 与 -wal 字节均逐字节不变（零写 + 零 checkpoint）。
                let dir = Fixtures.makeTempDir("snap-open")
                defer { Fixtures.cleanup(dir) }
                let store = try makeStoreWithBooks(in: dir)
                let dbPath = dir.appendingPathComponent("index.db")
                let walPath = dbPath.path + "-wal"
                try expectTrue(FileManager.default.fileExists(atPath: walPath), "预置条件：WAL 在场")
                let mainBefore = try sha256File(dbPath)
                let walBefore = try Data(contentsOf: URL(fileURLWithPath: walPath))
                _ = try WebDAVIndexUploader.buildSnapshot(
                    dbPath: dbPath, workDir: dir.appendingPathComponent("work"), appVersion: "t")
                try expectEqual(try sha256File(dbPath), mainBefore, "主库逐字节不变")
                try expectEqual(try Data(contentsOf: URL(fileURLWithPath: walPath)), walBefore,
                                "-wal 内容逐字节不变（零 checkpoint、零帧写入）")
                try expectTrue(FileManager.default.fileExists(atPath: walPath), "-wal 保留")
                _ = store
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "vacuumIntoCrashResidueKeepsMainAndWalIntact") {
                // clean-close 场景旧 RW 实现
                // 同样主库零变化（无 wal 可 checkpoint）、持锁场景本就无
                // checkpoint——两场景均不判别。唯有崩溃残留形态（主库+WAL
                // 在场、无 -shm、无其他连接）能区分：RW 连接打开即恢复 WAL
                // 并在 close 时 checkpoint（改写主库、删 wal）；RO 连接零改。
                // 造残留：写连接在场时复制 主库+WAL（不带 -shm）到新位置，
                // 随后弃原店；对残留跑 buildSnapshot。
                let srcDir = Fixtures.makeTempDir("crash-src")
                defer { Fixtures.cleanup(srcDir) }
                let residue = Fixtures.makeTempDir("crash-residue")
                defer { Fixtures.cleanup(residue) }
                let dbPath = residue.appendingPathComponent("index.db")
                do {
                    let store = try makeStoreWithBooks(in: srcDir)
                    let srcDB = srcDir.appendingPathComponent("index.db")
                    try FileManager.default.copyItem(atPath: srcDB.path, toPath: dbPath.path)
                    try FileManager.default.copyItem(atPath: srcDB.path + "-wal",
                                                     toPath: dbPath.path + "-wal")
                    _ = store
                }   // 弃原店；其 clean close 不影响复制出的残留
                try expectTrue(FileManager.default.fileExists(atPath: dbPath.path + "-wal"),
                               "预置条件：残留 wal 在场")
                let mainBefore = try sha256File(dbPath)
                let walBefore = try Data(contentsOf: URL(fileURLWithPath: dbPath.path + "-wal"))
                let snapshot = try WebDAVIndexUploader.buildSnapshot(
                    dbPath: dbPath, workDir: residue.appendingPathComponent("work"), appVersion: "t")
                try expectEqual(try sha256File(dbPath), mainBefore,
                                "主库逐字节不变（唯一连接+崩溃残留也不写）")
                try expectEqual(try Data(contentsOf: URL(fileURLWithPath: dbPath.path + "-wal")),
                                walBefore, "-wal 逐字节不变")
                try expectTrue(FileManager.default.fileExists(atPath: dbPath.path + "-wal"),
                               "-wal 在场（未被 checkpoint 合并删除）")
                let round = try WebDAVIndexManifest.parse(
                    try Data(contentsOf: snapshot.manifestFileURL))
                try expectEqual(round.bookCount, 3, "快照读穿 WAL，含全部已提交内容")
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "existingTempTargetClearedBeforeSnapshot") {
                let dir = Fixtures.makeTempDir("snap-tmp")
                defer { Fixtures.cleanup(dir) }
                _ = try makeStoreWithBooks(in: dir)
                let work = dir.appendingPathComponent("work")
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                try Data("junk".utf8).write(to: WebDAVIndexUploader.snapshotTempURL(in: work))
                let snapshot = try WebDAVIndexUploader.buildSnapshot(
                    dbPath: dir.appendingPathComponent("index.db"), workDir: work, appVersion: "t")
                try expectTrue(FileManager.default.fileExists(
                    atPath: snapshot.volumeURL(snapshot.manifest.files[0].name).path),
                    "残留临时件被先清再建")
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "snapshotTempNameNeverMatchesWhitelist") {
                let tmpName = WebDAVIndexUploader.snapshotTempURL(
                    in: URL(fileURLWithPath: "/tmp")).lastPathComponent
                try expectFalse(WebDAVIndexPaths.isAllowedRemoteName(tmpName),
                                ".tmp 临时名永不过白名单（正名永不生效）")
            },

            // MARK: uploadAll 主序列

            TestDesc(suite: "WebDAVIndexUpload", name: "uploadAllHappyPathVolumesThenManifest") {
                let dir = Fixtures.makeTempDir("up-happy")
                defer { Fixtures.cleanup(dir) }
                _ = try makeStoreWithBooks(in: dir)
                let snapshot = try WebDAVIndexUploader.buildSnapshot(
                    dbPath: dir.appendingPathComponent("index.db"),
                    workDir: dir.appendingPathComponent("work"), appVersion: "t")
                let auditDir = Fixtures.makeTempDir("up-audit")
                defer { Fixtures.cleanup(auditDir) }
                let audit = WebDAVUploadAuditStore(directory: auditDir)
                let stub = StubUploadServer()
                let outcome = try await WebDAVIndexUploader.uploadAll(
                    client: stub, snapshot: snapshot, audit: audit)
                try expectEqual(stub.mkcolCalls, 1, "先建前缀目录")
                let expected = snapshot.manifest.files.map(\.name) + ["manifest.json"]
                try expectEqual(stub.puts, expected, "逐卷顺序 PUT，manifest 永远最后")
                try expectEqual(stub.manifestPUTs, 1)
                try expectTrue(stub.deletes.isEmpty, "默认不清理")
                try expectEqual(outcome.volumesUploaded, snapshot.manifest.files.count)
                try expectEqual(outcome.volumesSkipped, 0)
                try expectEqual(outcome.totalBytes,
                                snapshot.manifest.files.reduce(Int64(0)) { $0 + $1.size })
                let rows = audit.entries()
                try expectEqual(rows.count, 1)
                try expectEqual(rows.first?.kind, "upload")
                try expectEqual(rows.first?.result, "ok")
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "uploadRetriesOnceWhenFirstVerifyLies") {
                let dir = Fixtures.makeTempDir("up-retry")
                defer { Fixtures.cleanup(dir) }
                _ = try makeStoreWithBooks(in: dir)
                let snapshot = try WebDAVIndexUploader.buildSnapshot(
                    dbPath: dir.appendingPathComponent("index.db"),
                    workDir: dir.appendingPathComponent("work"), appVersion: "t")
                let saved = shrinkUploadLimits(verifyBackoffNs: 1_000, intervalNs: 1)
                defer { restoreUploadLimits(saved) }
                let stub = StubUploadServer()
                stub.lieFirstVerifyFor = snapshot.manifest.files[0].name
                let outcome = try await WebDAVIndexUploader.uploadAll(client: stub, snapshot: snapshot)
                let vols = Set(snapshot.manifest.files.map(\.name))
                try expectEqual(stub.puts.filter { vols.contains($0) }.count,
                                vols.count + 1, "首答 size 不符 → 恰一次重传")
                try expectEqual(stub.manifestPUTs, 1, "复核通过后 manifest 照常 PUT")
                try expectEqual(outcome.volumesUploaded, vols.count)
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "uploadGivesUpAfterThreeAttemptsNoManifest") {
                let dir = Fixtures.makeTempDir("up-fail")
                defer { Fixtures.cleanup(dir) }
                _ = try makeStoreWithBooks(in: dir)
                let snapshot = try WebDAVIndexUploader.buildSnapshot(
                    dbPath: dir.appendingPathComponent("index.db"),
                    workDir: dir.appendingPathComponent("work"), appVersion: "t")
                let saved = shrinkUploadLimits(verifyBackoffNs: 1_000)
                defer { restoreUploadLimits(saved) }
                let stub = StubUploadServer()
                stub.lieAllSizes = true
                try await expectThrowsAsync(
                    { try await WebDAVIndexUploader.uploadAll(client: stub, snapshot: snapshot) },
                    "恒不符 → 3 次后整体失败")
                try expectEqual(stub.puts.count, WebDAVIndexUploader.maxVerifyAttempts,
                                "恰 3 次 PUT（无 manifest）")
                try expectEqual(stub.manifestPUTs, 0, "提交点未动")
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "secondVolumeFailureLeavesNoPartialCommit") {
                let dir = Fixtures.makeTempDir("up-partial")
                defer { Fixtures.cleanup(dir) }
                _ = try makeStoreWithBooks(in: dir)
                let saved = shrinkUploadLimits(volume: 16 << 10, verifyBackoffNs: 1_000)
                defer { restoreUploadLimits(saved) }
                let snapshot = try WebDAVIndexUploader.buildSnapshot(
                    dbPath: dir.appendingPathComponent("index.db"),
                    workDir: dir.appendingPathComponent("work"), appVersion: "t")
                try expectTrue(snapshot.manifest.files.count > 1, "预置条件：多卷")
                let stub = StubUploadServer()
                let sorted = snapshot.manifest.files.sorted { $0.order < $1.order }
                stub.failUploadNames = [sorted[1].name]   // 第 2 卷抛网络错
                try await expectThrowsAsync(
                    { try await WebDAVIndexUploader.uploadAll(client: stub, snapshot: snapshot) })
                try expectTrue(stub.puts.contains(sorted[0].name), "第 1 卷已上传")
                try expectFalse(stub.puts.contains(sorted[1].name), "第 2 卷未上传")
                try expectEqual(stub.manifestPUTs, 0, "无部分提交：manifest 零调用")
                try expectTrue(stub.remote[sorted[0].name] != nil, "远端只有卷文件")
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "sec03SameHashSameSizeSkipsPUT") {
                let dir = Fixtures.makeTempDir("up-idem")
                defer { Fixtures.cleanup(dir) }
                _ = try makeStoreWithBooks(in: dir)
                let snapshot = try WebDAVIndexUploader.buildSnapshot(
                    dbPath: dir.appendingPathComponent("index.db"),
                    workDir: dir.appendingPathComponent("work"), appVersion: "t")
                let vol = snapshot.manifest.files[0]
                let stub = StubUploadServer()
                stub.remote[vol.name] = vol.size   // 同 hash 同 size
                stub.manifestBytes = try manifestData(files: [vol])
                let outcome = try await WebDAVIndexUploader.uploadAll(client: stub, snapshot: snapshot)
                try expectFalse(stub.puts.contains(vol.name), "引用卷零 PUT（幂等跳过）")
                try expectEqual(stub.manifestPUTs, 1, "提交点照常 PUT")
                try expectEqual(outcome.volumesSkipped, 1)
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "sec03SameHashDifferentSizeFailsClosed") {
                let dir = Fixtures.makeTempDir("up-clash")
                defer { Fixtures.cleanup(dir) }
                _ = try makeStoreWithBooks(in: dir)
                let snapshot = try WebDAVIndexUploader.buildSnapshot(
                    dbPath: dir.appendingPathComponent("index.db"),
                    workDir: dir.appendingPathComponent("work"), appVersion: "t")
                let vol = snapshot.manifest.files[0]
                let stub = StubUploadServer()
                stub.remote[vol.name] = vol.size + 1   // 引用名但 size 不符 = 远端异常态
                stub.manifestBytes = try manifestData(files: [vol])
                try await expectThrowsAsync(
                    { try await WebDAVIndexUploader.uploadAll(client: stub, snapshot: snapshot) },
                    "不覆盖：fail-closed 中止")
                try expectTrue(stub.puts.isEmpty, "零 PUT（含 manifest）")
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "manifestJSONExemptFromVolumeGuard") {
                let dir = Fixtures.makeTempDir("up-exempt")
                defer { Fixtures.cleanup(dir) }
                _ = try makeStoreWithBooks(in: dir)
                let snapshot = try WebDAVIndexUploader.buildSnapshot(
                    dbPath: dir.appendingPathComponent("index.db"),
                    workDir: dir.appendingPathComponent("work"), appVersion: "t")
                let stub = StubUploadServer()
                // 远端已有旧 manifest（引用别的快照）；manifest.json 本身不受守卫。
                stub.manifestBytes = try manifestData(files: singleFile("index-ffffffffffffffff.sqlite", size: 1))
                let outcome = try await WebDAVIndexUploader.uploadAll(client: stub, snapshot: snapshot)
                try expectTrue(stub.puts.contains("manifest.json"), "manifest 是提交点，每次上传必 PUT")
                try expectEqual(outcome.volumesUploaded, snapshot.manifest.files.count)
            },

            // MARK: 清理

            TestDesc(suite: "WebDAVIndexUpload", name: "cleanupFailsClosedWhenManifestAbsent") {
                let stub = StubUploadServer()
                stub.remote["index-0123456789abcdef.sqlite"] = 10   // 孤儿在场
                try await expectThrowsAsync(
                    { try await WebDAVIndexUploader.cleanupUploadDir(client: stub, audit: nil) })
                try expectTrue(stub.deletes.isEmpty, "无 manifest = 零 DELETE")
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "cleanupFailsClosedOnManifestFetchError") {
                let stub = StubUploadServer()
                stub.manifestBytes = try manifestData(files: singleFile("index-0123456789abcdef.sqlite", size: 1))
                stub.downloadFails = true
                try await expectThrowsAsync(
                    { try await WebDAVIndexUploader.cleanupUploadDir(client: stub, audit: nil) })
                try expectTrue(stub.deletes.isEmpty)
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "cleanupFailsClosedOnCorruptManifest") {
                let stub = StubUploadServer()
                stub.manifestBytes = Data("not-json{".utf8)
                try await expectThrowsAsync(
                    { try await WebDAVIndexUploader.cleanupUploadDir(client: stub, audit: nil) })
                try expectTrue(stub.deletes.isEmpty, "解析失败 = 零 DELETE")
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "cleanupFailsClosedOnEmptyReferenceSet") {
                let stub = StubUploadServer()
                stub.manifestBytes = try manifestData(files: [])   // 引用集空 = 异常态
                try await expectThrowsAsync(
                    { try await WebDAVIndexUploader.cleanupUploadDir(client: stub, audit: nil) })
                try expectTrue(stub.deletes.isEmpty)
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "cleanupDeletesAtMostEightWithAudit") {
                let stub = StubUploadServer()
                // 当前快照 f...f（被引用）+ 11 个孤儿单卷快照（mtime 递增）。
                let live = "index-ffffffffffffffff.sqlite"
                stub.remote[live] = 3
                stub.manifestBytes = try manifestData(files: singleFile(live, size: 3))
                let base = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1))!
                var names: [String] = []
                for i in 1...11 {
                    let name = "index-\(String(format: "%016x", i)).sqlite"
                    stub.remote[name] = Int64(10 + i)
                    stub.mtimes[name] = base.addingTimeInterval(TimeInterval(i) * 3600)
                    names.append(name)
                }
                let dir = Fixtures.makeTempDir("cl-eight")
                defer { Fixtures.cleanup(dir) }
                let audit = WebDAVUploadAuditStore(directory: dir)
                let deleted = try await WebDAVIndexUploader.cleanupUploadDir(client: stub, audit: audit)
                try expectEqual(deleted.count, WebDAVIndexUploader.maxDeletesPerRun, "恰删 8")
                try expectEqual(stub.deletes.count, 8)
                try expectEqual(stub.deletes, Array(names.prefix(8)), "最旧先删")
                // 审计：每删一条已写入，但环形容量固定 5 条：「审计 8 行」与「环形 5 条」在超过 5 次删除时不可同真；取
                // 环形语义，明细行走 os_log）。断言环形内恰为最新 5 条。
                let cleanupRows = audit.entries().filter { $0.kind == "cleanup" }
                try expectEqual(cleanupRows.count, WebDAVUploadAuditStore.capacity, "环形 5 条")
                try expectEqual(cleanupRows.map(\.fileName), Array(names[3...7].reversed()),
                                "最新在前：第 8..4 次删除")
                try expectTrue(stub.remote[names[8]] != nil, "余 3 留待下次")
                try expectTrue(stub.remote[live] != nil, "被引用卷不删")
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "cleanupHrefNormalizationNoFalseDelete") {
                // 服务器 href 带 percent 编码/尾斜杠也能归一进引用集（不误删）。
                final class EncodedStub: StubUploadServer {
                    override func list(directory: String) async throws -> [WebDAVResource] {
                        listCount += 1
                        var out = resources()
                        // 引用卷以 %2D 形态 + 尾斜杠出现（解析层归一后仍是同一文件）。
                        out = out.map { res in
                            res.fileName == "index-ffffffffffffffff.sqlite"
                                ? WebDAVResource(path: "/webdav/LiteratureSearch/sync/index/index%2Dffffffffffffffff.sqlite/",
                                                 isDirectory: false, size: res.size,
                                                 lastModified: res.lastModified)
                                : res
                        }
                        return out
                    }
                }
                let stub = EncodedStub()
                let live = "index-ffffffffffffffff.sqlite"
                stub.remote[live] = 3
                stub.manifestBytes = try manifestData(files: singleFile(live, size: 3))
                stub.remote["index-1111111111111111.sqlite"] = 9
                stub.mtimes["index-1111111111111111.sqlite"] = Date(timeIntervalSince1970: 1)
                stub.remote["index-2222222222222222.sqlite"] = 9
                stub.mtimes["index-2222222222222222.sqlite"] = Date(timeIntervalSince1970: 2)
                stub.remote["index-3333333333333333.sqlite"] = 9
                stub.mtimes["index-3333333333333333.sqlite"] = Date(timeIntervalSince1970: 3)
                let deleted = try await WebDAVIndexUploader.cleanupUploadDir(client: stub, audit: nil)
                try expectEqual(deleted, ["index-1111111111111111.sqlite"],
                                "最旧孤儿删；编码形态引用卷不误删；新两份保留")
                try expectTrue(stub.remote["index-2222222222222222.sqlite"] != nil)
                try expectTrue(stub.remote["index-3333333333333333.sqlite"] != nil)
                try expectTrue(stub.remote[live] != nil)
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "cleanupSecondListingSkipsVanishedTarget") {
                let stub = StubUploadServer()
                let live = "index-ffffffffffffffff.sqlite"
                stub.remote[live] = 3
                stub.manifestBytes = try manifestData(files: singleFile(live, size: 3))
                for (hash, t) in [("4444444444444444", 1.0), ("5555555555555555", 2.0),
                                  ("6666666666666666", 3.0)] {
                    let name = "index-\(hash).sqlite"
                    stub.remote[name] = 5
                    stub.mtimes[name] = Date(timeIntervalSince1970: t)
                }
                // 清理器最后一次 list（= 二次核对）里目标已消失 → 跳过。
                stub.hideOnListCall[3] = ["index-4444444444444444.sqlite"]
                let deleted = try await WebDAVIndexUploader.cleanupUploadDir(client: stub, audit: nil)
                try expectTrue(deleted.isEmpty, "二次列表不在场 → 跳过（TOCTOU 防护）")
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "cleanupRechecksReferenceSetBeforeDelete") {
                // 两步之间并发方（另一设备 uploadAll）提交了引用
                // 候选卷的新 manifest → 二次核对重取引用集后跳过，不误删。
                let stub = StubUploadServer()
                let live = "index-ffffffffffffffff.sqlite"
                stub.remote[live] = 3
                stub.manifestBytes = try manifestData(files: singleFile(live, size: 3))
                stub.remote["index-7777777777777777.sqlite"] = 5
                stub.mtimes["index-7777777777777777.sqlite"] = Date(timeIntervalSince1970: 1)
                stub.remote["index-8888888888888888.sqlite"] = 6
                stub.mtimes["index-8888888888888888.sqlite"] = Date(timeIntervalSince1970: 2)
                stub.remote["index-9999999999999999.sqlite"] = 7
                stub.mtimes["index-9999999999999999.sqlite"] = Date(timeIntervalSince1970: 3)
                // 并发方的新 manifest：引用 X（候选卷）。
                stub.secondManifestBytes = try manifestData(files: [
                    .init(name: "index-7777777777777777.sqlite",
                          sha256: String(repeating: "7", count: 64), size: 5, order: 1),
                ])
                let deleted = try await WebDAVIndexUploader.cleanupUploadDir(client: stub, audit: nil)
                try expectTrue(deleted.isEmpty,
                               "候选已被新 manifest 引用 → 二次核对跳过（不误删）")
                try expectTrue(stub.remote["index-7777777777777777.sqlite"] != nil,
                               "被新引用的候选卷仍在")
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "cleanupFailsClosedWhenRecheckManifestMissing") {
                let stub = StubUploadServer()
                let live = "index-ffffffffffffffff.sqlite"
                stub.remote[live] = 3
                stub.manifestBytes = try manifestData(files: singleFile(live, size: 3))
                for (hash, t) in [("aaaaaaaaaaaaaaaa", 1.0), ("bbbbbbbbbbbbbbbb", 2.0),
                                  ("cccccccccccccccc", 3.0)] {
                    let name = "index-\(hash).sqlite"
                    stub.remote[name] = 5
                    stub.mtimes[name] = Date(timeIntervalSince1970: t)
                }
                stub.secondManifestAbsent = true   // 二次核对时 manifest 拉取失败
                try await expectThrowsAsync(
                    { try await WebDAVIndexUploader.cleanupUploadDir(client: stub, audit: nil) },
                    "二次核对失败 = fail-closed")
                try expectTrue(stub.deletes.isEmpty, "零 DELETE")
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "cleanupKeepsTwoNewestSnapshotGroups") {
                let stub = StubUploadServer()
                let liveA = "index-dddddddddddddddd.sqlite"
                let liveB = "index-eeeeeeeeeeeeeeee.sqlite"
                stub.remote[liveA] = 1
                stub.remote[liveB] = 2
                stub.manifestBytes = try manifestData(files: [
                    .init(name: liveA, sha256: String(repeating: "d", count: 64), size: 1, order: 1),
                    .init(name: liveB, sha256: String(repeating: "e", count: 64), size: 2, order: 2),
                ])
                for (hash, t) in [("3333333333333333", 1.0), ("4444444444444444", 2.0),
                                  ("5555555555555555", 3.0)] {
                    let name = "index-\(hash).sqlite"
                    stub.remote[name] = 9
                    stub.mtimes[name] = Date(timeIntervalSince1970: t)
                }
                let deleted = try await WebDAVIndexUploader.cleanupUploadDir(client: stub, audit: nil)
                try expectEqual(deleted, ["index-3333333333333333.sqlite"],
                                "3 份旧快照 → 仅最旧 1 份进候选；其余保留")
                try expectTrue(stub.remote["index-4444444444444444.sqlite"] != nil)
                try expectTrue(stub.remote["index-5555555555555555.sqlite"] != nil)
                try expectTrue(stub.remote[liveA] != nil && stub.remote[liveB] != nil, "现行引用不删")
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "cleanupDisabledByDefaultEvenWithOrphans") {
                let dir = Fixtures.makeTempDir("up-disabled")
                defer { Fixtures.cleanup(dir) }
                _ = try makeStoreWithBooks(in: dir)
                let snapshot = try WebDAVIndexUploader.buildSnapshot(
                    dbPath: dir.appendingPathComponent("index.db"),
                    workDir: dir.appendingPathComponent("work"), appVersion: "t")
                let stub = StubUploadServer()
                stub.remote["index-6666666666666666.sqlite"] = 4   // 孤儿在场
                _ = try await WebDAVIndexUploader.uploadAll(client: stub, snapshot: snapshot)
                try expectTrue(stub.deletes.isEmpty, "清理默认不执行")
            },

            // MARK: 下载

            TestDesc(suite: "WebDAVIndexUpload", name: "downloadNeverReplacesAnExistingFile") {
                let dir = Fixtures.makeTempDir("dl-conflict")
                defer { Fixtures.cleanup(dir) }
                let local = dir.appendingPathComponent("sample.pdf")
                let original = Data("existing local file".utf8)
                try original.write(to: local)
                let payload = bytes(50)
                try await expectThrowsAsync {
                    try await WebDAVClient.consumeDownload(byteStream(payload), to: local,
                                                           expectedBytes: 50, absoluteCap: 100, context: "t")
                }
                try expectEqual(try Data(contentsOf: local), original)
                try expectEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["sample.pdf"])
                let client = WebDAVClient(serverBase: URL(string: "https://dav.example/webdav")!,
                                          username: "u", password: "p")
                do {
                    try await client.download(remotePath: "sample.pdf", to: local)
                    throw TestFailure(message: "expected conflict for existing file")
                } catch WebDAVError.localFileExists {
                    try expectEqual(try Data(contentsOf: local), original)
                }
            },
            TestDesc(suite: "WebDAVIndexUpload", name: "downloadStreamsBytesExactly") {
                let dir = Fixtures.makeTempDir("dl-ok")
                defer { Fixtures.cleanup(dir) }
                let local = dir.appendingPathComponent("sub/out.bin")
                let payload = bytes(5000)
                try await WebDAVClient.consumeDownload(byteStream(payload), to: local,
                                                       expectedBytes: 5000, absoluteCap: 1 << 20,
                                                       context: "t")
                try expectEqual(try Data(contentsOf: local), Data(payload), "逐字节一致")
                let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                try expectTrue(!leftovers.contains { $0.hasPrefix(".download-") }, "无临时件残留")
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "downloadStopsAtDeclaredSize") {
                let dir = Fixtures.makeTempDir("dl-expected")
                defer { Fixtures.cleanup(dir) }
                let local = dir.appendingPathComponent("out.bin")
                try await expectThrowsAsync(
                    { try await WebDAVClient.consumeDownload(byteStream(bytes(110)), to: local,
                                                             expectedBytes: 100, absoluteCap: 1 << 20,
                                                             context: "t") },
                    "超声明值即断")
                try expectFalse(FileManager.default.fileExists(atPath: local.path), "不落盘")
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "downloadStopsAtAbsoluteCap") {
                let dir = Fixtures.makeTempDir("dl-cap")
                defer { Fixtures.cleanup(dir) }
                let local = dir.appendingPathComponent("out.bin")
                try await expectThrowsAsync(
                    { try await WebDAVClient.consumeDownload(byteStream(bytes(200)), to: local,
                                                             expectedBytes: nil, absoluteCap: 100,
                                                             context: "t") },
                    "绝对上限即断")
                try expectFalse(FileManager.default.fileExists(atPath: local.path))
                // 声明值 > 绝对上限：发起请求前直接拒（零网络）。
                let client = WebDAVClient(serverBase: URL(string: "https://dav.example/webdav")!,
                                          username: "u", password: "p")
                try await expectThrowsAsync(
                    { try await client.download(remotePath: "a.bin", to: local, expectedBytes: 9 << 30) },
                    "声明值预检拒")
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "downloadRetryLimitConstantPinned") {
                try expectEqual(WebDAVClient.maxDownloadAttempts, 3, "丢弃重下上限断言固定")
                try expectEqual(WebDAVClient.absoluteDownloadCap, Int64(8) << 30, "绝对上限 8 GiB")
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "enginePassesDeclaredSizeToDownload") {
                let dir = Fixtures.makeTempDir("dl-engine")
                defer { Fixtures.cleanup(dir) }
                let root = dir.appendingPathComponent("库", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let rule = WebDAVSyncRule(remoteDir: "/books", localRoot: root)
                final class SizeSpy: StubUploadServer {
                    override func list(directory: String) async throws -> [WebDAVResource] {
                        [WebDAVResource(path: "/books/a.pdf", isDirectory: false, size: 77,
                                        lastModified: nil)]
                    }
                    override func download(remotePath: String, to local: URL,
                                           expectedBytes: Int64?, absoluteCap: Int64) async throws {
                        seenExpectedDownloadBytes.append(expectedBytes)
                        try "new-content".write(to: local, atomically: true, encoding: .ascii)
                    }
                }
                let stub = SizeSpy()
                let config = WebDAVSyncConfig(serverBase: "https://dav.example/webdav",
                                              username: "u", rules: [rule])
                _ = try await WebDAVSyncEngine.sync(rule: rule, config: config, password: "p", client: stub)
                try expectEqual(stub.seenExpectedDownloadBytes, [Int64?(77)],
                                "PROPFIND 声明值传入下载")
            },

            // MARK: 审计与选项

            TestDesc(suite: "WebDAVIndexUpload", name: "auditRingKeepsFiveNewestInOrder") {
                let dir = Fixtures.makeTempDir("audit-ring")
                defer { Fixtures.cleanup(dir) }
                let store = WebDAVUploadAuditStore(directory: dir)
                for i in 1...7 {
                    store.append(kind: "upload", result: "ok", detail: "run-\(i)")
                }
                let rows = store.entries()
                try expectEqual(rows.count, 5, "写 7 留 5")
                try expectEqual(rows.first?.detail, "run-7", "最新在前")
                try expectEqual(rows.last?.detail, "run-3", "最旧被挤出的恰是 run-1/run-2")
                try expectTrue(rows.contains { $0.detail == "run-5" })
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "auditCorruptFileFailsClosedToEmpty") {
                let dir = Fixtures.makeTempDir("audit-bad")
                defer { Fixtures.cleanup(dir) }
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let store = WebDAVUploadAuditStore(directory: dir)
                try Data("not-json{".utf8).write(to: store.fileURL)
                try expectTrue(store.entries().isEmpty, "坏档回空")
                store.append(kind: "upload", result: "failed", detail: "x")   // 坏档后可继续写
                try expectEqual(store.entries().count, 1)
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "uploadOptionsDefaultOffAndPersist") {
                let name = "lit-tests-\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: name)!
                defer { defaults.removePersistentDomain(forName: name) }
                try expectFalse(WebDAVUploadOptions.autoUploadEnabled(defaults), "自动上传默认关")
                try expectFalse(WebDAVUploadOptions.cleanupEnabled(defaults), "清理默认关")
                WebDAVUploadOptions.setAutoUpload(true, defaults: defaults)
                WebDAVUploadOptions.setCleanup(true, defaults: defaults)
                try expectTrue(WebDAVUploadOptions.autoUploadEnabled(defaults), "持久化")
                try expectTrue(WebDAVUploadOptions.cleanupEnabled(defaults), "持久化")
                try expectEqual(WebDAVUploadOptions.autoUploadDefaultsKey, "webdavAutoUploadAfterRebuild",
                                "键名与设计逐字一致")
            },

            TestDesc(suite: "WebDAVIndexUpload", name: "uploadAuditL10nKeysReady") {
                // 设置页可见面文案在册（LiteratureSearchUI），且新键全部非空。
                try expectTrue(!L10n.webdavUploadIndex.isEmpty)
                try expectTrue(!L10n.webdavAutoUploadToggle.isEmpty)
                try expectTrue(!L10n.webdavCleanupToggle.isEmpty)
                try expectTrue(!L10n.webdavUploadPrivacyNote.isEmpty)
                try expectTrue(!L10n.webdavUploadAuditEmpty.isEmpty)
                try expectTrue(L10n.webdavUploadOK(2, 1, "1 GB", "9.9 秒").contains("2"))
                try expectTrue(L10n.webdavUploadAuditCleanup("index-aa.sqlite", "deleted")
                    .contains("index-aa.sqlite"))
            },
        ]
    }
}
