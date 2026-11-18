import Foundation
@testable import LiteratureCore
import LiteratureSearchUI

// //测试：检索过滤两态（工具书默认排除／开关放行）、
// BookRow 类别列回读接线、L10n 术语与键组。
enum ContentCategoryFilterSuite {
    typealias StoreFixture = (store: IndexStore, dir: URL)

    /// 合成双书库：bZ=著作（/Users/example/Library/Books/），bT=工具书（书名命中词表「引注手册」，
    /// 路径同在 Books/ 下——词表优先于路径）。两书均含查询词「权利」，拼音层
    /// 「shili」直中 bT 书名。使用合成数据，不依赖用户索引库。
    static func makeStore() throws -> StoreFixture {
        let saved = ContentCategoryFolders.current
        ContentCategoryFolders.current = .init(books: ["Books"], papers: ["Papers"], entries: ["Entries"])
        defer { ContentCategoryFolders.current = saved }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lit-ccfilter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try IndexStore(path: dir.appendingPathComponent("index.db"))
        try addBook(store, id: "bZ", realPath: "/Users/example/Library/Books/张三/样书一.pdf",
                    title: "样书一", author: "甲乙", pages: [
            "权利与义务 第一章。样书一。",
        ])
        try addBook(store, id: "bT", realPath: "/Users/example/Library/Books/示例引注手册编写组/示例引注手册（第二版）.pdf",
                    title: "示例引注手册（第二版）", author: "示例引注手册编写组", pages: [
            "权利 引注体例 第二章。",
        ])
        return (store, dir)
    }

    static func withFolders(_ body: () throws -> Void) throws {
        let saved = ContentCategoryFolders.current
        ContentCategoryFolders.current = .init(books: ["Books"], papers: ["Papers"], entries: ["Entries"])
        defer { ContentCategoryFolders.current = saved }
        try body()
    }

    @discardableResult
    static func addBook(_ store: IndexStore, id: String, realPath: String,
                        title: String, author: String, pages: [String]) throws -> IndexStore.BookRow {
        let name = (realPath as NSString).lastPathComponent
        let book = IndexStore.BookRow(
            id: id, realPath: realPath, rootPath: "/Users/example/Library/Books",
            relPath: name, fileName: name,
            title: title, author: author, version: nil, language: "zh", metaSource: nil,
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
        return book
    }

    static var tests: [TestDesc] {
        var t: [TestDesc] = []
        // 接线断言：BookRow 三处 SELECT 列清单＋bookRow(from:) 回读类别列。
        t.append(TestDesc(suite: "ContentCategoryFilter", name: "bookRowRoundTripsContentCategory") {
            let fx = try makeStore()
            defer { Fixtures.cleanup(fx.dir) }
            try expectTrue(fx.store.book(byID: "bZ")?.contentCategory == "著作",
                           "著作行类别回读: \(fx.store.book(byID: "bZ")?.contentCategory ?? "nil")")
            try expectTrue(fx.store.book(byID: "bT")?.contentCategory == "工具书",
                           "工具书行类别回读（词表优先于路径）: \(fx.store.book(byID: "bT")?.contentCategory ?? "nil")")
            try expectTrue(fx.store.allBooks().first { $0.id == "bT" }?.contentCategory == "工具书",
                           "allBooks 路类别回读")
        })
        t.append(TestDesc(suite: "ContentCategoryFilter", name: "matchingBooksToolbookTwoStates") {
            let fx = try makeStore()
            defer { Fixtures.cleanup(fx.dir) }
            let service = SearchService(store: fx.store)
            let deflt = try service.matchingBooks("权利")
            try expectTrue(deflt.map(\.bookID) == ["bZ"], "默认不含工具书: \(deflt.map(\.bookID))")
            let all = try service.matchingBooks("权利", filter: SearchFilter(includeToolBooks: true))
            try expectTrue(Set(all.map(\.bookID)) == ["bZ", "bT"], "开关打开两书齐列: \(all.map(\.bookID))")
        })
        t.append(TestDesc(suite: "ContentCategoryFilter", name: "searchDetailedToolbookTwoStates") {
            let fx = try makeStore()
            defer { Fixtures.cleanup(fx.dir) }
            let service = SearchService(store: fx.store)
            let deflt = try service.searchDetailed("权利")
            try expectFalse(deflt.hits.isEmpty, "著作页命中不应为空")
            try expectTrue(deflt.hits.allSatisfy { $0.bookID == "bZ" }, "默认不含工具书页: \(deflt.hits.map(\.bookID))")
            let all = try service.searchDetailed("权利", options: SearchOptions(
                limit: 20, filter: SearchFilter(includeToolBooks: true)))
            try expectTrue(all.hits.contains { $0.bookID == "bT" }, "开关打开工具书页入结果")
        })
        t.append(TestDesc(suite: "ContentCategoryFilter", name: "syntaxLayersToolbookTwoStates") {
            let fx = try makeStore()
            defer { Fixtures.cleanup(fx.dir) }
            let service = SearchService(store: fx.store)
            let q = "\"权利\""
            let booksDeflt = try service.matchingBooks(q)
            try expectTrue(booksDeflt.map(\.bookID) == ["bZ"], "语法书级默认不含工具书: \(booksDeflt.map(\.bookID))")
            let booksAll = try service.matchingBooks(q, filter: SearchFilter(includeToolBooks: true))
            try expectTrue(Set(booksAll.map(\.bookID)) == ["bZ", "bT"], "语法书级开关放行: \(booksAll.map(\.bookID))")
            let detailDeflt = try service.searchDetailed(q)
            try expectTrue(detailDeflt.hits.allSatisfy { $0.bookID == "bZ" }, "语法页级默认不含工具书")
            let detailAll = try service.searchDetailed(q, options: SearchOptions(
                limit: 20, filter: SearchFilter(includeToolBooks: true)))
            try expectTrue(detailAll.hits.contains { $0.bookID == "bT" }, "语法页级开关放行")
        })
        t.append(TestDesc(suite: "ContentCategoryFilter", name: "pinyinBookHitsToolbookTwoStates") {
            let fx = try makeStore()
            defer { Fixtures.cleanup(fx.dir) }
            let service = SearchService(store: fx.store)
            let deflt = try service.matchingBooks("shili")
            try expectTrue(deflt.isEmpty, "拼音命中工具书默认剔除: \(deflt.map(\.bookID))")
            let all = try service.matchingBooks("shili", filter: SearchFilter(includeToolBooks: true))
            try expectTrue(all.map(\.bookID) == ["bT"], "拼音命中开关放行: \(all.map(\.bookID))")
        })
        // 语义断言：includeToolBooks 不并入 isActive（纯放行开关，无字段过滤义）。
        t.append(TestDesc(suite: "ContentCategoryFilter", name: "includeToolBooksNotInIsActive") {
            try expectFalse(SearchFilter(includeToolBooks: true).isActive)
            try expectFalse(SearchFilter().isActive)
            try expectTrue(SearchFilter(authorContains: "甲乙").isActive)
        })
        // 断言：UI 术语「书籍」→「著作」（键值＋漂移双保险）。
        t.append(TestDesc(suite: "ContentCategoryFilter", name: "l10nBookTerminologyIsZhuzuo") {
            try expectTrue(L10n.domainBook == "著作", "domainBook: \(L10n.domainBook)")
            try expectTrue(L10n.smartCollectionCondBook == "仅著作", "smartCollectionCondBook: \(L10n.smartCollectionCondBook)")
            try expectFalse(L10n.domainBook.contains("书籍"), "domainBook 残留旧术语")
            try expectFalse(L10n.smartCollectionCondBook.contains("书籍"), "smartCollectionCondBook 残留旧术语")
        })
        // /断言：设置页键组在位（开关＋说明＋扫描按钮文案非空）。
        t.append(TestDesc(suite: "ContentCategoryFilter", name: "settingsKeysPresent") {
            try expectFalse(L10n.contentCategorySection.isEmpty)
            try expectFalse(L10n.includeToolBooksToggle.isEmpty)
            try expectTrue(L10n.includeToolBooksNote.contains("工具书"), "说明行须点名工具书")
            try expectFalse(L10n.scanToolbookButton.isEmpty)
            try expectTrue(L10n.scanToolbookNote.contains("跳过") || L10n.scanToolbookNote.contains("未变更"),
                           "扫描说明须写明 skip-unchanged 语义")
            try expectFalse(L10n.scanToolbookRunning.isEmpty)
            try expectTrue(L10n.scanToolbookDone(added: 1, updated: 2, skipped: 3).contains("3"), "完成回执带计数")
        })
        return t
    }
}
