import Foundation
@testable import LiteratureCore

// MARK: - scraper 元数据链套件（全部桩注入，零真实网络）
//
// 离线实证：loader 桩记录请求并回放固定载荷——本套件全绿即「测试路径零
// 真实网络」的证据；隐私契约（URL 域白名单 / UA 串 / 不含路径与指纹）由
// 请求捕获断言锁定。

final class StubMetadataLoader: MetadataHTTPLoading, @unchecked Sendable {
    struct Recorded {
        var url: URL
        var userAgent: String?
    }

    private let lock = NSLock()
    private(set) var recorded: [Recorded] = []
    /// URL 判别器 → 载荷；命中 nil 键则抛错（模拟超时/网络失败）。
    private var responder: (URL) -> Data?

    init(responder: @escaping (URL) -> Data?) {
        self.responder = responder
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock {
            recorded.append(Recorded(url: request.url ?? URL(fileURLWithPath: "/unreachable"),
                                     userAgent: request.value(forHTTPHeaderField: "User-Agent")))
        }
        guard let url = request.url, let payload = responder(url) else {
            throw URLError(.timedOut)
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return (payload, response)
    }

    var urls: [URL] {
        lock.lock(); defer { lock.unlock() }
        return recorded.map(\.url)
    }

    var userAgents: [String?] {
        lock.lock(); defer { lock.unlock() }
        return recorded.map(\.userAgent)
    }
}

enum MetadataFetchSuite {
    static let crossrefPayload = Data("""
    {"message":{"title":["The Fictional Order"],"author":[{"given":"A. N.","family":"Author"}],"edition":"3","language":"en"}}
    """.utf8)
    static let arxivPayload = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom" xmlns:arxiv="http://arxiv.org/schemas/atom">
      <title>Query feed</title>
      <entry><title>An Agent Paper</title><author><name>Avery Quill</name></author><arxiv:doi>10.9999/xyz</arxiv:doi></entry>
    </feed>
    """.utf8)
    static let dblpPayload = Data("""
    {"result":{"hits":{"hit":[{"info":{"title":"DBLP Title","year":"2020","authors":{"author":{"text":"Jordan Marlowe"}}}}]}}}
    """.utf8)
    static let ssPayload = Data("""
    {"data":[{"title":"SS Title","authors":[{"name":"Morgan Vale"}],"year":2021,"externalIds":{"DOI":"10.5/ss"}}]}
    """.utf8)

    static func makeStore() throws -> (IndexStore, URL, String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lit-fetch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try IndexStore(path: dir.appendingPathComponent("index.db"))
        let book = IndexStore.BookRow(
            id: "bf", realPath: "/tmp/lit-tests/f.pdf", rootPath: "/tmp/lit-tests",
            relPath: "f.pdf", fileName: "f.pdf",
            firstFingerprint: "fp-f", fingerprint: "fp-f", fileSize: 1, mtime: 0,
            pageCount: 2, status: "ok", indexedAt: 0)
        try store.upsertBook(book)
        return (store, dir, book.id)
    }

    static func allSources() -> Set<MetadataSource> { Set(MetadataSource.allCases) }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "MetadataFetch", name: "doiTriggersCrossrefOnlyOnce") {
                let (store, dir, bookID) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let stub = StubMetadataLoader { url in
                    url.host == MetadataSource.crossref.host ? Self.crossrefPayload : nil
                }
                let service = MetadataFetchService(loader: stub)
                let report = await service.fetch(bookID: bookID, fileName: "f.pdf",
                                                 doi: "10.1234/abc", arxivID: nil,
                                                 title: nil, author: nil,
                                                 store: store, enabled: Self.allSources())
                try expectEqual(stub.urls.count, 1, "DOI present → Crossref only")
                try expectEqual(stub.urls[0].host, MetadataSource.crossref.host)
                try expectEqual(stub.urls[0].path, "/works/10.1234/abc")
                try expectTrue(report.appliedFields.contains("title"))
                let book = try expectNotNil(try store.book(byID: bookID))
                try expectEqual(book.title, "The Fictional Order")
                try expectEqual(book.author, "A. N. Author")
                try expectEqual(book.metaSource, "fetch:crossref")
            },

            TestDesc(suite: "MetadataFetch", name: "arxivFollowedByCrossrefWhenDOIReturned") {
                let (store, dir, bookID) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let stub = StubMetadataLoader { url in
                    if url.host == MetadataSource.arxiv.host { return Self.arxivPayload }
                    if url.host == MetadataSource.crossref.host { return Self.crossrefPayload }
                    return nil
                }
                let service = MetadataFetchService(loader: stub)
                let report = await service.fetch(bookID: bookID, fileName: "f.pdf",
                                                 doi: nil, arxivID: "2401.00001",
                                                 title: nil, author: nil,
                                                 store: store, enabled: Self.allSources())
                try expectEqual(stub.urls.count, 2, "arXiv then its DOI → Crossref once")
                try expectEqual(stub.urls[0].host, MetadataSource.arxiv.host)
                try expectTrue(stub.urls[0].query?.contains("id_list=2401.00001") == true)
                try expectEqual(stub.urls[1].host, MetadataSource.crossref.host)
                try expectEqual(stub.urls[1].path, "/works/10.9999/xyz")
                try expectEqual(report.outcomes.count, 3,
                                "outcomes carry the skipped crossref row too")
                try expectEqual(report.outcomes.filter(\.requested).count, 2,
                                "exactly two requests: arXiv + Crossref follow-up")
                let book = try expectNotNil(try store.book(byID: bookID))
                // 保守合并：arXiv 先填 title；Crossref 续查只补空字段，不覆盖。
                try expectEqual(book.title, "An Agent Paper",
                                "arXiv title fills first (first writer wins)")
                try expectEqual(book.author, "A. N. Author",
                                "Crossref follow-up fills the still-nil author")
            },

            TestDesc(suite: "MetadataFetch", name: "noIdentifiersFallsToDBLPThenSemanticScholar") {
                let (store, dir, bookID) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let stub = StubMetadataLoader { url in
                    // DBLP 零命中（parseDBLP → nil）→ 静默降级 SS。
                    if url.host == MetadataSource.dblp.host {
                        return Data(#"{"result":{"hits":{}}}"#.utf8)
                    }
                    if url.host == MetadataSource.semanticScholar.host { return Self.ssPayload }
                    return nil
                }
                let service = MetadataFetchService(loader: stub)
                let report = await service.fetch(bookID: bookID, fileName: "f.pdf",
                                                 doi: nil, arxivID: nil,
                                                 title: "somewhere title", author: "王二",
                                                 store: store, enabled: Self.allSources())
                try expectEqual(stub.urls.count, 2, "DBLP then Semantic Scholar, then stop")
                try expectEqual(stub.urls[0].host, MetadataSource.dblp.host)
                try expectEqual(stub.urls[1].host, MetadataSource.semanticScholar.host)
                try expectEqual(report.outcomes.count, 4, "skipped sources still appear as non-requested")
                let book = try expectNotNil(try store.book(byID: bookID))
                try expectEqual(book.title, "SS Title")
                try expectTrue(report.outcomes.filter(\.requested).map(\.source) ==
                               ["dblp", "semanticScholar"])
            },

            TestDesc(suite: "MetadataFetch", name: "onlyFillsNilFieldsNeverOverwrites") {
                let (store, dir, bookID) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                // 既有 title 非空；updateMetadata(COALESCE) + 服务层双保险。
                _ = try store.updateMetadata(bookID: bookID, title: "既有标题",
                                             author: nil, version: nil, language: nil,
                                             source: "manual")
                let stub = StubMetadataLoader { _ in Self.crossrefPayload }
                let service = MetadataFetchService(loader: stub)
                _ = await service.fetch(bookID: bookID, fileName: "f.pdf",
                                        doi: "10.1234/abc", arxivID: nil,
                                        title: nil, author: nil,
                                        store: store, enabled: Self.allSources())
                let book = try expectNotNil(try store.book(byID: bookID))
                try expectEqual(book.title, "既有标题", "existing title must never be overwritten")
                try expectEqual(book.author, "A. N. Author", "nil fields do get filled")
                try expectEqual(book.metaSource, "fetch:crossref")
            },

            TestDesc(suite: "MetadataFetch", name: "disabledSourcesNeverRequested") {
                let (store, dir, bookID) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let stub = StubMetadataLoader { _ in Self.dblpPayload }
                let service = MetadataFetchService(loader: stub)
                // 仅 Crossref 开且无标识符 → 零请求（逐源开关语义）。
                _ = await service.fetch(bookID: bookID, fileName: "f.pdf",
                                        doi: nil, arxivID: nil,
                                        title: "t", author: nil,
                                        store: store, enabled: [.crossref])
                try expectEqual(stub.urls.count, 0, "disabled chain → zero requests")
                // 空集合 = 总开关关 → 零请求。
                _ = await service.fetch(bookID: bookID, fileName: "f.pdf",
                                        doi: "10.1234/abc", arxivID: nil,
                                        title: nil, author: nil,
                                        store: store, enabled: [])
                try expectEqual(stub.urls.count, 0, "master switch off → zero requests")
            },

            TestDesc(suite: "MetadataFetch", name: "failureDegradesSilentlyToNextSource") {
                let (store, dir, bookID) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let stub = StubMetadataLoader { url in
                    if url.host == MetadataSource.semanticScholar.host { return Self.ssPayload }
                    return nil   // Crossref/arXiv/DBLP 全部超时抛错
                }
                let service = MetadataFetchService(loader: stub)
                let report = await service.fetch(bookID: bookID, fileName: "f.pdf",
                                                 doi: "10.1234/dead", arxivID: nil,
                                                 title: "t", author: nil,
                                                 store: store, enabled: Self.allSources())
                try expectEqual(stub.urls.count, 3,
                                "crossref/arXiv-skip/dblp fail → ss ok, then stop")
                let crossrefOutcome = report.outcomes.first { $0.source == "crossref" }
                try expectEqual(crossrefOutcome?.ok, false)
                let book = try expectNotNil(try store.book(byID: bookID))
                try expectEqual(book.title, "SS Title", "degraded source still fills fields")
            },

            TestDesc(suite: "MetadataFetch", name: "badJSONDegradesWithoutCrash") {
                let (store, dir, bookID) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let stub = StubMetadataLoader { url in
                    if url.host == MetadataSource.crossref.host {
                        return Data("{{not json".utf8)
                    }
                    if url.host == MetadataSource.dblp.host { return Self.dblpPayload }
                    return nil
                }
                let service = MetadataFetchService(loader: stub)
                let report = await service.fetch(bookID: bookID, fileName: "f.pdf",
                                                 doi: "10.1234/bad", arxivID: nil,
                                                 title: "t", author: nil,
                                                 store: store, enabled: Self.allSources())
                let crossrefOutcome = report.outcomes.first { $0.source == "crossref" }
                try expectEqual(crossrefOutcome?.note, "响应不可解析")
                let book = try expectNotNil(try store.book(byID: bookID))
                try expectEqual(book.title, "DBLP Title")
            },

            TestDesc(suite: "MetadataFetch", name: "reportRingKeepsLastTen") {
                let (store, dir, bookID) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let reportURL = dir.appendingPathComponent("fetch-report.json")
                let stub = StubMetadataLoader { _ in Self.crossrefPayload }
                let service = MetadataFetchService(loader: stub)
                for _ in 0..<12 {
                    _ = await service.fetch(bookID: bookID, fileName: "f.pdf",
                                            doi: "10.1234/abc", arxivID: nil,
                                            title: nil, author: nil,
                                            store: store, enabled: Self.allSources(),
                                            reportURL: reportURL)
                }
                let reports = MetadataFetchService.loadReports(url: reportURL)
                try expectEqual(reports.count, 10, "ring buffer keeps the most recent 10")
                try expectEqual(reports.last?.bookID, bookID)
                try expectTrue(reports.allSatisfy { !$0.outcomes.isEmpty },
                               "every report carries per-source outcomes")
            },

            TestDesc(suite: "MetadataFetch", name: "requestsMeetPrivacyContract") {
                let (store, dir, bookID) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let stub = StubMetadataLoader { url in
                    // 全链零命中（坏 JSON/空 feed/零命中/零命中）→ 四源逐级全发。
                    switch url.host {
                    case MetadataSource.crossref.host: return Data("{{not json".utf8)
                    case MetadataSource.arxiv.host:
                        return Data("<feed xmlns=\"http://www.w3.org/2005/Atom\"></feed>".utf8)
                    case MetadataSource.dblp.host:
                        return Data(#"{"result":{"hits":{}}}"#.utf8)
                    case MetadataSource.semanticScholar.host:
                        return Data(#"{"data":[]}"#.utf8)
                    default: return nil
                    }
                }
                let service = MetadataFetchService(loader: stub)
                // 指纹/路径形如敏感串：绝不出现在任何请求 URL。
                let fingerprint = "fp-f"
                _ = await service.fetch(bookID: bookID, fileName: "f.pdf",
                                        doi: "10.1234/abc", arxivID: "2401.00001",
                                        title: "privacy probe", author: nil,
                                        store: store, enabled: Self.allSources(),
                                        reportURL: nil)
                let hosts = Set(stub.urls.compactMap(\.host))
                try expectTrue(hosts.isSubset(of: Set(MetadataSource.allCases.map(\.host))),
                               "requests only go to the four registry hosts")
                try expectTrue(stub.urls.allSatisfy { $0.absoluteString.contains(fingerprint) == false },
                               "fingerprints never leave the machine")
                try expectTrue(stub.urls.allSatisfy { $0.absoluteString.contains("/tmp/") == false },
                               "library paths never leave the machine")
                for ua in stub.userAgents {
                    try expectEqual(ua, MetadataFetchService.userAgent,
                                    "UA is a fixed app name + version only")
                }
                try expectEqual(MetadataFetchService.requestTimeout, 15)
                try expectEqual(stub.urls.count, 4,
                                "one manual trigger requests at most 5 (here 4: identity-exclusivity + openlibrary tail)")
            },

            TestDesc(suite: "MetadataFetch", name: "dualIdentifiersNeverRepeatCrossref") {
                let (store, dir, bookID) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let stub = StubMetadataLoader { url in
                    switch url.host {
                    case MetadataSource.crossref.host: return Data("{{not json".utf8)
                    case MetadataSource.arxiv.host: return Self.arxivPayload
                    case MetadataSource.dblp.host:
                        return Data(#"{"result":{"hits":{}}}"#.utf8)
                    case MetadataSource.semanticScholar.host:
                        return Data(#"{"data":[]}"#.utf8)
                    default: return nil
                    }
                }
                let service = MetadataFetchService(loader: stub)
                let report = await service.fetch(bookID: bookID, fileName: "f.pdf",
                                                 doi: "10.1234/abc", arxivID: "2401.00001",
                                                 title: "dual probe", author: nil,
                                                 store: store, enabled: Self.allSources())
                let crossrefRequests = stub.urls.filter { $0.host == MetadataSource.crossref.host }
                try expectEqual(crossrefRequests.count, 1,
                                "Crossref at most once per trigger (never ×2)")
                try expectTrue(stub.urls.allSatisfy { $0.host != MetadataSource.arxiv.host },
                               "arXiv level is identity-excluded when a DOI is present")
                try expectEqual(stub.urls.count, 4,
                                "crossref(fail) → dblp → ss → openlibrary, total ≤ 5")
                let arxivOutcome = report.outcomes.first { $0.source == "arxiv" }
                try expectEqual(arxivOutcome?.requested, false)
            },

            TestDesc(suite: "MetadataFetch", name: "arxivFollowUpHappensExactlyOnceWithoutDOI") {
                let (store, dir, bookID) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let stub = StubMetadataLoader { url in
                    if url.host == MetadataSource.arxiv.host { return Self.arxivPayload }
                    if url.host == MetadataSource.crossref.host {
                        return Self.crossrefPayload
                    }
                    return nil
                }
                let service = MetadataFetchService(loader: stub)
                _ = await service.fetch(bookID: bookID, fileName: "f.pdf",
                                        doi: nil, arxivID: "2401.00001",
                                        title: nil, author: nil,
                                        store: store, enabled: Self.allSources())
                let crossrefRequests = stub.urls.filter { $0.host == MetadataSource.crossref.host }
                try expectEqual(crossrefRequests.count, 1,
                                "no-DOI chain: the Crossref follow-up happens exactly once")
                let book = try expectNotNil(try store.book(byID: bookID))
                try expectEqual(book.title, "An Agent Paper")
            },
        ]
    }
}
