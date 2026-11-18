import Foundation
@testable import LiteratureCore
import LiteratureSearchUI

enum DeepLinkHistorySuite {
    static var tests: [TestDesc] {
        [
            TestDesc(suite: "DeepLink", name: "roundTripWithChineseAndSpaces") {
                let link = DeepLink.search(query: "计算理论 graph 检索")
                let url = try expectNotNil(link.build())
                try expectEqual(url.scheme, "literaturesearch")
                try expectEqual(url.host, "search")
                try expectEqual(DeepLink.parse(url), link)
            },
            TestDesc(suite: "DeepLink", name: "rejectsForeignURLs") {
                try expectNil(DeepLink.parse(URL(string: "https://example.com/search?q=x")!))
                try expectNil(DeepLink.parse(URL(string: "literaturesearch://settings")!))
            },
            TestDesc(suite: "DeepLink", name: "emptyQueryBuildReturnsNilNoFileFallback") {
                // widgets must never emit file:/// fallbacks for empty queries
                try expectNil(DeepLink.search(query: "").build())
                let crafted = URL(string: "literaturesearch://search?q=")!
                try expectEqual(DeepLink.parse(crafted), .search(query: ""))
            },
            TestDesc(suite: "DeepLink", name: "quoteRoundTripAlwaysBuilds") {
                // DailyQuoteWidget tap target: parameterless, never nil.
                let url = try expectNotNil(DeepLink.quote.build())
                try expectEqual(url.scheme, "literaturesearch")
                try expectEqual(url.host, "quote")
                try expectEqual(DeepLink.parse(url), .quote)
                try expectNil(DeepLink.parse(URL(string: "literaturesearch://quotes")!))
            },

            // ──：open / collection 两动词 ──
            TestDesc(suite: "DeepLink", name: "openRoundTripWithPage") {
                let link = DeepLink.open(doc: "babc123", page: 42, highlight: nil)
                let url = try expectNotNil(link.build())
                try expectEqual(url.host, "open")
                try expectTrue(url.absoluteString.contains("doc=babc123"))
                try expectTrue(url.absoluteString.contains("page=42"))
                try expectEqual(DeepLink.parse(url), link)
            },
            TestDesc(suite: "DeepLink", name: "openWithoutPageOmitsParam") {
                let link = DeepLink.open(doc: "babc123", page: nil, highlight: nil)
                let url = try expectNotNil(link.build())
                let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                try expectTrue(comps?.queryItems?.contains { $0.name == "page" } != true)
                try expectEqual(DeepLink.parse(url), link)
            },
            TestDesc(suite: "DeepLink", name: "openInvalidInputsFailClosed") {
                // doc 空白 → build/parse 双向 nil（照 .search 空查询惯例）
                try expectNil(DeepLink.open(doc: "  ", page: 3, highlight: nil).build())
                try expectNil(DeepLink.parse(URL(string: "literaturesearch://open?doc=&page=3")!))
                try expectNil(DeepLink.parse(URL(string: "literaturesearch://open?page=3")!))
                // doc 缺失
                try expectNil(DeepLink.open(doc: "", page: nil, highlight: nil).build())
            },
            TestDesc(suite: "DeepLink", name: "openMalformedPageMeansNilNotError") {
                // page 非数字/缺失 → 解出 page=nil（只选书不开页），不整体拒绝
                let noPage = try expectNotNil(DeepLink.parse(
                    URL(string: "literaturesearch://open?doc=babc")!))
                try expectEqual(noPage, DeepLink.open(doc: "babc", page: nil, highlight: nil))
                let badPage = try expectNotNil(DeepLink.parse(
                    URL(string: "literaturesearch://open?doc=babc&page=abc")!))
                try expectEqual(badPage, DeepLink.open(doc: "babc", page: nil, highlight: nil))
            },
            TestDesc(suite: "DeepLink", name: "openPercentEncodingRoundTrips") {
                // doc 含特殊字符：URLComponents 编码往返不丢
                let link = DeepLink.open(doc: "b+abc/def=x", page: 7, highlight: nil)
                let url = try expectNotNil(link.build())
                try expectEqual(DeepLink.parse(url), link)
            },
            // ── 功能扩展：open hl（高亮定位）契约 ──
            TestDesc(suite: "DeepLink", name: "openHighlightRoundTripAndBuildParam") {
                let link = DeepLink.open(doc: "babc123", page: nil, highlight: 42)
                let url = try expectNotNil(link.build())
                try expectTrue(url.absoluteString.contains("hl=42"),
                               "build 应带 hl 参数：\(url.absoluteString)")
                try expectEqual(DeepLink.parse(url), link)
                // hl 与 page 独立可选：双参并存往返不丢。
                let both = DeepLink.open(doc: "babc123", page: 7, highlight: 9)
                let bothURL = try expectNotNil(both.build())
                try expectTrue(bothURL.absoluteString.contains("page=7"))
                try expectTrue(bothURL.absoluteString.contains("hl=9"))
                try expectEqual(DeepLink.parse(bothURL), both)
            },
            TestDesc(suite: "DeepLink", name: "openWithoutHighlightOmitsParam") {
                let link = DeepLink.open(doc: "babc123", page: 3, highlight: nil)
                let url = try expectNotNil(link.build())
                let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                try expectTrue(comps?.queryItems?.contains { $0.name == "hl" } != true,
                               "hl=nil build 不得带参数（与 page 同款缺省省参）")
            },
            TestDesc(suite: "DeepLink", name: "openMalformedHighlightMeansNilNotError") {
                // 非法 hl → 该参数按缺省处理（宽容侧照 page），不整体拒绝。
                let crafted = URL(string: "literaturesearch://open?doc=babc&hl=abc")!
                try expectEqual(DeepLink.parse(crafted),
                                DeepLink.open(doc: "babc", page: nil, highlight: nil))
            },
            TestDesc(suite: "DeepLink", name: "highlightPageLookupFindsRowByID") {
                func row(_ id: Int64, page: Int) -> UserHighlight {
                    UserHighlight(id: id, bookID: "b", pageNumber: page, utf16Start: 0,
                                  utf16End: 1, color: .yellow, note: "",
                                  createdAt: Date(timeIntervalSince1970: 0))
                }
                let rows = [row(11, page: 3), row(12, page: 8)]
                try expectEqual(DeepLink.highlightPage(in: rows, id: 12), 8)
                try expectEqual(DeepLink.highlightPage(in: rows, id: 11), 3)
                try expectNil(DeepLink.highlightPage(in: rows, id: 99),
                              "查无 → nil（不猜）")
            },

            TestDesc(suite: "DeepLink", name: "collectionRoundTripAndValidation") {
                let link = DeepLink.collection(id: 7)
                let url = try expectNotNil(link.build())
                try expectEqual(url.host, "collection")
                try expectTrue(url.absoluteString.contains("id=7"))
                try expectEqual(DeepLink.parse(url), link)
                // 非法 id：0 / 负数 / 非数字 → nil（正整数才合法）
                try expectNil(DeepLink.collection(id: 0).build())
                try expectNil(DeepLink.collection(id: -3).build())
                try expectNil(DeepLink.parse(URL(string: "literaturesearch://collection?id=0")!))
                try expectNil(DeepLink.parse(URL(string: "literaturesearch://collection?id=-3")!))
                try expectNil(DeepLink.parse(URL(string: "literaturesearch://collection?id=abc")!))
                try expectNil(DeepLink.parse(URL(string: "literaturesearch://collection")!))
            },
            TestDesc(suite: "DeepLink", name: "unknownHostStillFailClosed") {
                // 既有 fail-closed 不被新 case 放松
                try expectNil(DeepLink.parse(URL(string: "literaturesearch://settings")!))
                try expectNil(DeepLink.parse(URL(string: "literaturesearch://")!))
            },
            TestDesc(suite: "DeepLink", name: "l10nDeepLinkErrorTextsPresent") {
                // App 层处理函数（deepLinkOpen/deepLinkCollection）不在测试
                // target（LiteratureSearchApp 不进合成测试依赖）；可合成部分 =
                // toast 文案路径的键存在性（L10n 在 UI 层可测）。
                try expectFalse(L10n.deepLinkBookMissing.isEmpty)
                try expectFalse(L10n.deepLinkPageMissing.isEmpty)
                try expectFalse(L10n.deepLinkCollectionMissing.isEmpty)
            },
            TestDesc(suite: "History", name: "recordingDeduplicatesAndCaps") {
                let dir = Fixtures.makeTempDir("history")
                defer { Fixtures.cleanup(dir) }
                let store = SharedHistoryStore(fileURL: dir.appendingPathComponent("state.json"))
                for i in 0..<30 {
                    store.record(query: "query-\(i)", hitCount: i)
                }
                try expectEqual(store.history().count, SharedHistoryStore.maxHistoryEntries)
                try expectEqual(store.history().first?.query, "query-29")
                store.record(query: "query-10", hitCount: 3)
                try expectEqual(store.history().first?.query, "query-10")
                try expectEqual(store.history().filter { $0.query == "query-10" }.count, 1)
            },
            TestDesc(suite: "History", name: "ignoresBlankQueries") {
                let dir = Fixtures.makeTempDir("history-blank")
                defer { Fixtures.cleanup(dir) }
                let store = SharedHistoryStore(fileURL: dir.appendingPathComponent("state.json"))
                store.record(query: "   ", hitCount: 0)
                try expectTrue(store.history().isEmpty)
            },
            TestDesc(suite: "History", name: "coverageRoundTrip") {
                let dir = Fixtures.makeTempDir("history-coverage")
                defer { Fixtures.cleanup(dir) }
                let store = SharedHistoryStore(fileURL: dir.appendingPathComponent("state.json"))
                try expectNil(store.coverage())
                let snapshot = CoverageSnapshot(bookCount: 12, pageCount: 3456, lastIndexedAt: Date(), rootName: "文献库")
                store.update(coverage: snapshot)
                let decoded = try expectNotNil(store.coverage())
                // whole-struct equality is exact for counters; the date survives
                // seconds-precision encoding, so compare with a small tolerance
                try expectEqual(decoded.bookCount, snapshot.bookCount)
                try expectEqual(decoded.pageCount, snapshot.pageCount)
                try expectEqual(decoded.rootName, snapshot.rootName)
                let delta = abs((decoded.lastIndexedAt?.timeIntervalSince(snapshot.lastIndexedAt!)) ?? 1)
                try expectTrue(delta < 0.001, "date round-trips within 1ms")
            },
            TestDesc(suite: "History", name: "sharedSurfaceCarriesNoOriginalText") {
                let entry = HistoryEntry(query: "q", at: Date(), hitCount: 5)
                let data = try JSONEncoder().encode(entry)
                let json = String(data: data, encoding: .utf8) ?? ""
                try expectFalse(json.contains("snippet"))
                try expectFalse(json.contains("text"))
            },
            TestDesc(suite: "FTS5Probe", name: "probeReportsCapabilities") {
                let caps = try FTS5Probe.probe()
                try expectFalse(caps.sqliteVersion.isEmpty)
                if caps.fts5 && caps.trigramTokenizer {
                    let dir = Fixtures.makeTempDir("probe")
                    defer { Fixtures.cleanup(dir) }
                    let store = try Fixtures.openStore(in: dir)
                    try expectEqual(store.searchMode, IndexStore.SearchMode.fts5Trigram)
                    try expectEqual(try store.metaValue("search_mode"), "fts5-trigram")
                }
            },
            TestDesc(suite: "FTS5Probe", name: "forcedFallbackIsRecordedInMeta") {
                let dir = Fixtures.makeTempDir("probe-fallback")
                defer { Fixtures.cleanup(dir) }
                let store = try IndexStore(path: dir.appendingPathComponent("i.db"),
                                           options: IndexStore.Options(forceFallbackSearch: true))
                try expectEqual(store.searchMode, IndexStore.SearchMode.likeFallback)
                try expectEqual(try store.metaValue("search_mode"), "like-fallback")
            },
        ]
    }
}
