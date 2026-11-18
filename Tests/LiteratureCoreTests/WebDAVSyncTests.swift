import Foundation
@testable import LiteratureCore

// MARK: - WebDAV 同步合成套件（解析/账本/增量判定；不触网）

enum WebDAVSyncSuite {
    static func propfindFixture(entries: [(href: String, dir: Bool, size: Int64, mtime: String?)]) -> Data {
        var xml = #"<?xml version="1.0" encoding="utf-8"?><D:multistatus>"#
        for e in entries {
            xml += "<D:response><D:href>\(e.href)</D:href><D:propstat><D:prop>"
            if e.dir { xml += "<D:resourcetype><D:collection/></D:resourcetype>" }
            else { xml += "<D:resourcetype/><D:getcontentlength>\(e.size)</D:getcontentlength>" }
            if let m = e.mtime { xml += "<D:getlastmodified>\(m)</D:getlastmodified>" }
            xml += "</D:prop></D:propstat></D:response>"
        }
        xml += "</D:multistatus>"
        return Data(xml.utf8)
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "WebDAVSync", name: "propfindParseSkipsSelfAndTypesCorrectly") {
                let base = URL(string: "https://dav.example/webdav/books/")!
                let data = propfindFixture(entries: [
                    (href: "/webdav/books/", dir: true, size: 0, mtime: nil),                       // 目录自身：跳过
                    (href: "/webdav/books/%E6%A0%B7%E4%B9%A6%E4%B8%80.pdf",       // URL 编码中文
                     dir: false, size: 1234, mtime: "Mon, 21 Sep 2026 10:00:00 GMT"),
                    (href: "/webdav/books/sub/", dir: true, size: 0, mtime: nil),
                    (href: "/webdav/books/paper.pdf", dir: false, size: 99, mtime: nil),
                ])
                let res = try WebDAVClient.parsePropfind(data, baseURL: base)
                try expectEqual(res.count, 3, "目录自身跳过")
                let pdf = try expectNotNil(res.first { $0.fileName == "样书一.pdf" }, "URL 编码解码")
                try expectFalse(pdf.isDirectory)
                try expectEqual(pdf.size, Int64(1234))
                try expectNotNil(pdf.lastModified, "RFC1123 时间解析")
                try expectTrue(try expectNotNil(res.first { $0.fileName == "sub" }).isDirectory)
            },
            TestDesc(suite: "WebDAVSync", name: "ledgerDiffDownloadsOnlyNewOrChanged") {
                let dir = Fixtures.makeTempDir("wdav")
                defer { Fixtures.cleanup(dir) }
                let root = dir.appendingPathComponent("库", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let rule = WebDAVSyncRule(remoteDir: "/books", localRoot: root)
                let ledgerURL = WebDAVSyncEngine.ledgerURL(for: rule)
                // 既有账本：a.pdf 已同步（同 size+mtime）、b.pdf 尺寸变化。
                let ledger = """
                {"/books/a.pdf":{"size":10,"mtime":1000.0},"/books/b.pdf":{"size":5,"mtime":2000.0}}
                """.data(using: .utf8)!
                try ledger.write(to: ledgerURL)
                try "aaaaaaaaaa".write(to: root.appendingPathComponent("a.pdf"), atomically: true, encoding: .ascii)
                let remote = [
                    WebDAVResource(path: "/books/a.pdf", isDirectory: false, size: 10,
                                   lastModified: Date(timeIntervalSince1970: 1000)),
                    WebDAVResource(path: "/books/b.pdf", isDirectory: false, size: 77,
                                   lastModified: Date(timeIntervalSince1970: 3000)),
                    WebDAVResource(path: "/books/c.pdf", isDirectory: false, size: 5, lastModified: nil),
                ]
                // Stub 客户端：记录下载并把内容写到目标路径。
                final class StubClient: WebDAVClient {
                    var downloaded: [String] = []
                    var listing: [WebDAVResource]
                    init(listing: [WebDAVResource]) {
                        self.listing = listing
                        super.init(serverBase: URL(string: "https://dav.example/webdav")!, username: "u", password: "p")
                    }
                    override func list(directory: String) async throws -> [WebDAVResource] { listing }
                    override func download(remotePath: String, to local: URL,
                                           expectedBytes: Int64?, absoluteCap: Int64) async throws {
                        downloaded.append(remotePath)
                        try "new-content".write(to: local, atomically: true, encoding: .ascii)
                    }
                }
                let config = WebDAVSyncConfig(serverBase: "https://dav.example/webdav", username: "u", rules: [rule])
                let stub = StubClient(listing: remote)
                let out = try await WebDAVSyncEngine.sync(rule: rule, config: config, password: "p", client: stub)
                try expectEqual(out.downloaded.sorted(), ["b.pdf", "c.pdf"], "a.pdf 未变化跳过")
                try expectEqual(stub.downloaded.count, 2)
                try expectTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("c.pdf").path))
                // 账本更新：重跑同一远端视图应当全跳过（幂等）。
                let again = try await WebDAVSyncEngine.sync(rule: rule, config: config, password: "p", client: stub)
                try expectTrue(again.downloaded.isEmpty, "账本幂等：二次同步零下载")
            },
            TestDesc(suite: "WebDAVSync", name: "extensionFilterAndMissingTargetFailClosed") {
                let dir = Fixtures.makeTempDir("wdav-fail")
                defer { Fixtures.cleanup(dir) }
                let missing = dir.appendingPathComponent("不存在", isDirectory: true)
                let rule = WebDAVSyncRule(remoteDir: "/x", localRoot: missing)
                let config = WebDAVSyncConfig(serverBase: "https://dav.example/webdav", username: "u", rules: [rule])
                do {
                    _ = try await WebDAVSyncEngine.sync(rule: rule, config: config, password: "p", client: nil)
                    try failTest("目标目录缺失应 fail-closed")
                } catch let e as WebDAVError {
                    try expectTrue(String(describing: e).contains("本地目标目录不可用"))
                }
            },
            TestDesc(suite: "WebDAVSync", name: "dryRunReturnsPlanWithoutSideEffects") {
                // dry-run 与真实同步同基准比对，但零下载、零落盘、
                // 零记账；随后真实同步仍按原账本下载同一批（预演无副作用）。
                let dir = Fixtures.makeTempDir("wdav-dry")
                defer { Fixtures.cleanup(dir) }
                let root = dir.appendingPathComponent("库", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let rule = WebDAVSyncRule(remoteDir: "/books", localRoot: root)
                let ledgerURL = WebDAVSyncEngine.ledgerURL(for: rule)
                let ledgerJSON = """
                {"/books/a.pdf":{"size":10,"mtime":1000.0},"/books/b.pdf":{"size":5,"mtime":2000.0}}
                """
                try ledgerJSON.write(to: ledgerURL, atomically: true, encoding: .utf8)
                try "aaaaaaaaaa".write(to: root.appendingPathComponent("a.pdf"), atomically: true, encoding: .ascii)
                final class NoDownloadClient: WebDAVClient {
                    var downloadCalls = 0
                    /// dry-run 阶段 false：任何 download 一律判失败；真实同步前置 true。
                    var allowDownload = false
                    init() {
                        super.init(serverBase: URL(string: "https://dav.example/webdav")!, username: "u", password: "p")
                    }
                    override func list(directory: String) async throws -> [WebDAVResource] {[
                        .init(path: "/books/a.pdf", isDirectory: false, size: 10,
                              lastModified: Date(timeIntervalSince1970: 1000)),   // 账本一致：跳过
                        .init(path: "/books/b.pdf", isDirectory: false, size: 77,
                              lastModified: Date(timeIntervalSince1970: 3000)),   // 尺寸变化：将下载
                        .init(path: "/books/c.pdf", isDirectory: false, size: 5, lastModified: nil),  // 新文件：将下载
                        .init(path: "/books/n.txt", isDirectory: false, size: 9, lastModified: nil),  // 扩展名过滤：跳过
                        .init(path: "/books/sub/", isDirectory: true, size: 0, lastModified: nil),    // 目录：不进循环
                    ]}
                    override func download(remotePath: String, to local: URL,
                                           expectedBytes: Int64?, absoluteCap: Int64) async throws {
                        downloadCalls += 1
                        guard allowDownload else {
                            try failTest("dry-run 绝不允许 download（\(remotePath)）")
                        }
                        try "new-content".write(to: local, atomically: true, encoding: .ascii)
                    }
                }
                let config = WebDAVSyncConfig(serverBase: "https://dav.example/webdav", username: "u", rules: [rule])
                let stub = NoDownloadClient()
                let out = try await WebDAVSyncEngine.sync(rule: rule, config: config, password: "p",
                                                          client: stub, dryRun: true)
                try expectTrue(out.downloaded.isEmpty, "预演零下载")
                try expectTrue(out.failed.isEmpty)
                try expectEqual(out.skipped, 2, "账本一致 1 + 扩展名过滤 1")
                try expectEqual(out.pendingDownloads.map(\.fileName).sorted(), ["b.pdf", "c.pdf"])
                try expectEqual(out.pendingDownloads.first { $0.fileName == "b.pdf" }?.size, Int64(77))
                try expectEqual(out.pendingDownloads.first { $0.fileName == "c.pdf" }?.size, Int64(5))
                try expectTrue(out.pendingDownloads.allSatisfy { $0.remotePath.hasPrefix("/books/") },
                               "清单带远端路径")
                try expectEqual(stub.downloadCalls, 0, "预演零下载调用")
                try expectFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("c.pdf").path),
                                "预演不落盘")
                try expectFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("b.pdf").path),
                                "预演不覆盖既有文件")
                let ledgerAfter = try String(contentsOf: ledgerURL, encoding: .utf8)
                try expectEqual(ledgerAfter, ledgerJSON, "预演不写账本（逐字节一致）")
                // 预演后真实同步：仍按原账本下载 b/c（预演无副作用的可观察结论）。
                stub.allowDownload = true
                let real = try await WebDAVSyncEngine.sync(rule: rule, config: config, password: "p", client: stub)
                try expectEqual(stub.downloadCalls, 2, "真实同步恰好下载 b/c 两次")
                try expectEqual(real.downloaded.sorted(), ["b.pdf", "c.pdf"], "预演后真实同步照常增量")
            },
        ]
    }
}
