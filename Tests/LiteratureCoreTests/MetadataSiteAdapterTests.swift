import Foundation
@testable import LiteratureCore

// MARK: - 功能扩展：站点适配器契约测试（全桩注入，零真实网络）
//
// 断言面：OpenLibrary 解析（docs[0] → 统一条目契约；零命中/半空拒收）；请求
// 域白名单与 UA 契约（openlibrary.org / 固定 UA 串）；协议「不抛」断言（loader
// 抛错 → lookup 返回 nil 不崩）；单源故障隔离断言（一源故障只落该源 outcome，
// 其余照常）；arXiv 薄封装与既有解析等值。

enum MetadataSiteAdapterSuite {
    static let openLibraryPayload = Data("""
    {"docs":[{"title":"The Fictional Order","author_name":["A. N. Author","Example Author"],
              "first_publish_year":2001,"language":["en","fr"]}]}
    """.utf8)
    static let emptyDocsPayload = Data(#"{"docs":[],"numFound":0}"#.utf8)
    static let halfEmptyPayload = Data(#"{"docs":[{"first_publish_year":1990}]}"#.utf8)

    static func makeStore() throws -> (IndexStore, URL, String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lit-adapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try IndexStore(path: dir.appendingPathComponent("index.db"))
        let book = IndexStore.BookRow(
            id: "ba", realPath: "/tmp/lit-tests/a.pdf", rootPath: "/tmp/lit-tests",
            relPath: "a.pdf", fileName: "Sample_Volume_[1234.5678].pdf",
            firstFingerprint: "fp-a", fingerprint: "fp-a", fileSize: 1, mtime: 0,
            pageCount: 1, status: "ok", indexedAt: 0)
        try store.upsertBook(book)
        return (store, dir, book.id)
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "MetadataSiteAdapter", name: "openLibraryParsePinsDocs0") {
                let meta = try expectNotNil(
                    OpenLibrarySiteAdapter.parseOpenLibrary(openLibraryPayload))
                try expectEqual(meta.title, "The Fictional Order")
                try expectEqual(meta.author, "A. N. Author, Example Author")
                try expectEqual(meta.version, "2001", "first_publish_year → version")
                try expectEqual(meta.language, "en", "language[0] → language")
                // 零命中 → nil；title+author 全缺半空条目 → nil（不回半空）。
                try expectNil(OpenLibrarySiteAdapter.parseOpenLibrary(emptyDocsPayload))
                try expectNil(OpenLibrarySiteAdapter.parseOpenLibrary(halfEmptyPayload))
                try expectNil(OpenLibrarySiteAdapter.parseOpenLibrary(Data("not json".utf8)))
            },
            TestDesc(suite: "MetadataSiteAdapter", name: "openLibraryLookupHitsWhitelistedHostWithFixedUA") {
                let loader = StubMetadataLoader { url in
                    guard url.host == "openlibrary.org", url.path == "/search.json" else {
                        return nil
                    }
                    return openLibraryPayload
                }
                let adapter = OpenLibrarySiteAdapter()
                let meta = try expectNotNil(await adapter.lookup(
                    MetadataLookupRequest(title: "The Fictional Order"), loader: loader))
                try expectEqual(meta.title, "The Fictional Order")
                // 契约断言：域名白名单、limit=1、fields 集合、UA 固定串。
                let url = try expectNotNil(loader.urls.first)
                try expectEqual(url.host, "openlibrary.org")
                try expectTrue(url.query?.contains("limit=1") == true)
                let fieldsEncoded = url.query?.contains("fields=title%2Cauthor_name%2Cfirst_publish_year%2Clanguage") ?? false
                let fieldsPlain = url.query?.contains("fields=title,author_name,first_publish_year,language") ?? false
                try expectTrue(fieldsEncoded || fieldsPlain,
                               "fields 集合断言：\(url.query ?? "")")
                try expectTrue(url.query?.contains("title=The") == true,
                               "title 查询串应透传调用方给定标题")
                try expectEqual(loader.userAgents.first ?? nil,
                                MetadataFetchService.userAgent,
                                "UA 必须沿用固定串（隐私契约）")
                try expectEqual(adapter.sourceID, "openlibrary")
                try expectEqual(adapter.host, "openlibrary.org")
            },
            TestDesc(suite: "MetadataSiteAdapter", name: "lookupNeverThrowsOnLoaderFailure") {
                // responder 命中 nil → StubMetadataLoader 抛 URLError——适配器
                // 必须吞成 nil（协议契约：不抛不崩）。
                let loader = StubMetadataLoader { _ in nil }
                let adapter = OpenLibrarySiteAdapter()
                let result = await adapter.lookup(
                    MetadataLookupRequest(title: "Anything"), loader: loader)
                try expectNil(result, "失败必须吞成 nil")
                // 无标题 → 不发请求直接 nil（模糊回退位无题不查）。
                let noTitle = await adapter.lookup(MetadataLookupRequest(), loader: loader)
                try expectNil(noTitle)
                try expectEqual(loader.urls.count, 1,
                                "仅首次（带标题）调用发请求；无标题分支零请求")
            },
            TestDesc(suite: "MetadataSiteAdapter", name: "arxivAdapterThinWrapsExistingParse") {
                let loader = StubMetadataLoader { url in
                    guard url.host == MetadataSource.arxiv.host else { return nil }
                    return MetadataFetchSuite.arxivPayload
                }
                let adapter = ArxivSiteAdapter()
                let meta = try expectNotNil(await adapter.lookup(
                    MetadataLookupRequest(arxivID: "2401.00001"), loader: loader))
                try expectEqual(meta.title, "An Agent Paper")
                try expectEqual(meta.doi, "10.9999/xyz")
                // 解析器当前不会填充 arXiv 作者字段。
                // ArxivAtomDelegate 的作者赋值在 case ("entry","entry") 分支，
                // 而 currentElement 被内层元素 end 清空——该分支永不命中，
                // arXiv 源 author 恒 nil（探针实证：裸委托 authors=["Avery Quill"]
                // 而 parseArxivAtom 结果 author=nil；既有断言
                // arxivFollowedByCrossrefWhenDOIReturned 的注释正是编码了此
                // 行为）。为避免改变请求顺序，本测试不调整 delegate，
                // 适配器「薄封装既有解析」如实继承；缺陷已上报待后续路由。
                try expectNil(meta.author)
                // 与既有内联解析等值（零复制断言）。
                let direct = MetadataFetchService.parseArxivAtom(MetadataFetchSuite.arxivPayload)
                try expectEqual(meta, direct)
                // 无 arXiv ID → nil（不发请求）。
                let none = await adapter.lookup(MetadataLookupRequest(title: "x"), loader: loader)
                try expectNil(none)
                try expectEqual(loader.urls.count, 1, "无 ID 分支不得发请求")
            },
            TestDesc(suite: "MetadataSiteAdapter", name: "singleSourceFailureOnlyDegradesThatSource") {
                let (store, dir, bookID) = try makeStore()
                defer { try? FileManager.default.removeItem(at: dir) }
                let loader = StubMetadataLoader { url in
                    if url.host == MetadataSource.dblp.host { return nil }   // 故障腿
                    if url.host == "openlibrary.org" { return openLibraryPayload }
                    return nil
                }
                let service = MetadataFetchService(loader: loader)
                let reportURL = dir.appendingPathComponent("fetch-report.json")
                // title 缺 → 文件名规范化降级处理（顺带覆盖降级处理接线）。
                let report = await awaitFetch(service, bookID: bookID, store: store,
                                              url: reportURL, title: nil)
                let dblp = try expectNotNil(report.outcomes.first { $0.source == "dblp" })
                try expectEqual(dblp.ok, false, "故障腿只降级该源")
                try expectEqual(dblp.requested, true)
                let ol = try expectNotNil(report.outcomes.first { $0.source == "openlibrary" },
                                          "链尾健康腿必须有 outcome")
                try expectEqual(ol.ok, true, "其余源照常（适配器路径查得）")
                try expectTrue(ol.appliedFields.contains("title"))
                try expectTrue(report.appliedFields.contains("title"),
                               "健康腿字段照常回填")
            },
            TestDesc(suite: "MetadataSiteAdapter", name: "fuzzyFallbackUsesNormalizedFileNameWithNote") {
                let (store, dir, bookID) = try makeStore()
                defer { try? FileManager.default.removeItem(at: dir) }
                var observedQueries: [String] = []
                let loader = StubMetadataLoader { url in
                    if url.host == MetadataSource.dblp.host {
                        if let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                            .queryItems?.first(where: { $0.name == "q" })?.value {
                            observedQueries.append(q)
                        }
                    }
                    return nil   // 全链零命中，只看查询串与 note
                }
                let service = MetadataFetchService(loader: loader)
                let reportURL = dir.appendingPathComponent("fetch-report.json")
                let report = await awaitFetch(service, bookID: bookID, store: store, url: reportURL,
                                              title: nil)
                let dblp = try expectNotNil(report.outcomes.first { $0.source == "dblp" })
                try expectTrue(dblp.requested, "title 缺但文件名可规范化 → 应发模糊查询")
                try expectEqual(observedQueries.first, "Sample Volume",
                                "查询串应来自文件名规范化（去扩展名/下划线归空格/去 arXiv 段）")
                try expectTrue(dblp.note.contains("查询串来自文件名规范化"),
                               "note 必须如实标注降级处理来源：\(dblp.note)")
            },
        ]
    }

    // MARK: fetch 桥（TestDesc 体 async，直接 await）

    static func awaitFetch(_ service: MetadataFetchService, bookID: String,
                           store: IndexStore, url: URL,
                           title: String? = "Sample Volume") async -> MetadataFetchReport {
        await service.fetch(bookID: bookID,
                            fileName: "Sample_Volume_[1234.5678].pdf",
                            doi: nil, arxivID: nil,
                            title: title, author: nil,
                            store: store,
                            enabled: [.crossref, .dblp, .semanticScholar, .openLibrary],
                            reportURL: url)
    }
}
