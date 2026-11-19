import Foundation
@testable import LiteratureCore

// MARK: - Smart Jump suite（引文接线）
//
// CitationPattern 扫描器分Kind断言（书内页码 / 《书名》页码 / 西文作者年份 /
// 中文数字页码）+ SearchService.resolveCitation 跨库解析（书内 clamp、
// 标题命中带页码、全库无命中返回 nil）。合成内存库，不触真书。

enum SmartJumpSuite {
    static func makeStore() throws -> (IndexStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lit-smartjump-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try IndexStore(path: dir.appendingPathComponent("index.db")), dir)
    }

    /// 只登记书目（不写道行；resolveCitation 只读 books 表 + 检索回退）。
    static func addBook(_ store: IndexStore, id: String, name: String,
                        title: String? = nil, author: String? = nil,
                        pageCount: Int) throws {
        let book = IndexStore.BookRow(
            id: id, realPath: "/tmp/lit-sj/\(name)", rootPath: "/tmp/lit-sj",
            relPath: name, fileName: name,
            title: title, author: author,
            firstFingerprint: "fp-\(id)", fingerprint: "fp-\(id)", fileSize: 1, mtime: 0,
            pageCount: pageCount, status: "ok", indexedAt: 0)
        try store.upsertBook(book)
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "SmartJump", name: "scanFindsChineseSeePage") {
                let matches = CitationPattern.scan(text: "本说的体系，参见第12页。")
                try expectEqual(matches.count, 1, "single citation expected")
                try expectEqual(matches[0].target, .sameBookPage(page: 12))
            },
            TestDesc(suite: "SmartJump", name: "scanParsesChineseNumeralPage") {
                let matches = CitationPattern.scan(text: "见第三页")
                try expectEqual(matches.count, 1, "single citation expected")
                try expectEqual(matches[0].target, .sameBookPage(page: 3))
            },
            TestDesc(suite: "SmartJump", name: "scanFindsBookTitleWithPage") {
                let matches = CitationPattern.scan(text: "参见《示例学科》第88页。")
                guard case .externalCitation(let author, let title, let year, let page, _)? =
                        matches.first?.target else {
                    try failTest("expected externalCitation, got \(String(describing: matches.first?.target))")
                }
                try expectNil(author)
                try expectEqual(title, "示例学科")
                try expectNil(year)
                try expectEqual(page, 88)
            },
            TestDesc(suite: "SmartJump", name: "scanFindsWesternAuthorYear") {
                let matches = CitationPattern.scan(text: "如 Quill (2001) 所论。")
                guard case .externalCitation(let author, let title, let year, let page, _)? =
                        matches.first?.target else {
                    try failTest("expected externalCitation, got \(String(describing: matches.first?.target))")
                }
                try expectEqual(author, "Quill")
                try expectNil(title)
                try expectEqual(year, 2001)
                try expectNil(page)
            },
            TestDesc(suite: "SmartJump", name: "resolveSameBookPageClampsToPageCount") {
                let (store, _) = try makeStore()
                try addBook(store, id: "b1", name: "b1.pdf", pageCount: 5)
                let service = SearchService(store: store)
                let resolved = try service.resolveCitation(target: .sameBookPage(page: 99), currentBookID: "b1")
                let target = try expectNotNil(resolved, "same-book resolution must succeed")
                try expectEqual(target.bookID, "b1")
                try expectEqual(target.pageNumber, 5, "page clamps to pageCount")
                let low = try service.resolveCitation(target: .sameBookPage(page: 0), currentBookID: "b1")
                try expectEqual(try expectNotNil(low).pageNumber, 1, "page clamps to 1")
            },
            TestDesc(suite: "SmartJump", name: "resolveExternalTitleMatchUsesCitationPage") {
                let (store, _) = try makeStore()
                try addBook(store, id: "b1", name: "a.pdf", title: "示例学科", pageCount: 100)
                try addBook(store, id: "b2", name: "b.pdf", title: "宪法学", pageCount: 60)
                let service = SearchService(store: store)
                let target: CitationTargetKind = .externalCitation(
                    author: nil, title: "示例学科", year: nil, page: 88, rawText: "《示例学科》第88页")
                let resolved = try service.resolveCitation(target: target, currentBookID: "b2")
                let hit = try expectNotNil(resolved, "title match must resolve")
                try expectEqual(hit.bookID, "b1")
                try expectEqual(hit.pageNumber, 88)
            },
            TestDesc(suite: "SmartJump", name: "resolveExternalNoMatchReturnsNil") {
                let (store, _) = try makeStore()
                try addBook(store, id: "b1", name: "a.pdf", title: "示例学科", pageCount: 100)
                let service = SearchService(store: store)
                let target: CitationTargetKind = .externalCitation(
                    author: "GhostAuthor999", title: "NoSuchTitle12345",
                    year: 1900, page: nil, rawText: "GhostAuthor999, NoSuchTitle12345 (1900)")
                let resolved = try service.resolveCitation(target: target, currentBookID: "b1")
                try expectNil(resolved, "unknown citation must not resolve")
            },
        ]
    }
}
