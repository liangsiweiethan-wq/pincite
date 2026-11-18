import Foundation
@testable import LiteratureCore

// MARK: - sha256 单册重索引测试（unchanged / updated / missing /
// force；只动这一本——绝不扫描库根）

enum ReindexBookSuite {
    static var tests: [TestDesc] {
        [
            // 合成库：两本 PDF 真文件（Fixtures）索引后逐场景验证。
            TestDesc(suite: "ReindexBook", name: "unchangedSkipsWhenFingerprintMatches") {
                let dir = Fixtures.makeTempDir("reindex-unchanged")
                defer { Fixtures.cleanup(dir) }
                Fixtures.makePDF(pages: [
                    .init(lines: ["单册重索引 场景一 权利法理文本。"]),
                ], in: dir, named: "book1.pdf")
                Fixtures.makePDF(pages: [
                    .init(lines: ["另一本 无关书 规范体系。"]),
                ], in: dir, named: "book2.pdf")
                let store = try Fixtures.openStore(in: dir)
                let engine = IndexingEngine(store: store, policy: ExclusionPolicy())
                let run = try await engine.run(rootURL: dir)
                try expectEqual(run.indexedNew, 2)
                let book1 = try expectNotNil(try store.allBooks().first { $0.fileName == "book1.pdf" })
                // 页行基线。
                let pagesBefore = try store.pages(rowIDs: (1...book1.pageCount).compactMap {
                    let row = try? store.page(bookID: book1.id, pageNumber: $0)
                    return row != nil ? String($0) : nil
                })
                _ = pagesBefore
                // 未变 → unchanged 且页行不动。
                let result = try await engine.reindexBook(bookID: book1.id)
                try expectEqual(result.verdict, .unchanged)
                try expectEqual(result.pages, book1.pageCount)
                let pageAfter = try store.page(bookID: book1.id, pageNumber: 1)
                try expectNotNil(pageAfter)
                try expectTrue(pageAfter?.textOriginal.contains("权利法理") == true,
                               "page rows untouched")
            },

            TestDesc(suite: "ReindexBook", name: "updatedReplacesPagesOldHitsDisappearNewHitsFound") {
                let dir = Fixtures.makeTempDir("reindex-updated")
                defer { Fixtures.cleanup(dir) }
                let pdfURL = dir.appendingPathComponent("book.pdf")
                Fixtures.makePDF(pages: [
                    .init(lines: ["旧内容 独特标记词甲乙丙丁。"]),
                ], in: dir, named: "book.pdf")
                let store = try Fixtures.openStore(in: dir)
                let engine = IndexingEngine(store: store, policy: ExclusionPolicy())
                _ = try await engine.run(rootURL: dir)
                let book = try expectNotNil(try store.allBooks().first)
                let service = SearchService(store: store)
                let oldHit = try service.searchDetailed("甲乙丙丁")
                try expectEqual(oldHit.totalPageMatches, 1)
                // 改写文件内容（Fixtures 重生成同路径）。
                try FileManager.default.removeItem(at: pdfURL)
                Fixtures.makePDF(pages: [
                    .init(lines: ["新内容 截然不同的戊己庚辛词。"]),
                ], in: dir, named: "book.pdf")
                let result = try await engine.reindexBook(bookID: book.id)
                try expectEqual(result.verdict, .updated)
                // 新内容可检索、旧命中消失；bookID 保持（首指纹身份）。
                try expectEqual(try store.book(byID: book.id)?.pageCount, 1)
                let newHit = try service.searchDetailed("戊己庚辛")
                try expectEqual(newHit.totalPageMatches, 1)
                try expectEqual(newHit.hits.first?.bookID, book.id)
                let gone = try service.searchDetailed("甲乙丙丁")
                try expectEqual(gone.totalPageMatches, 0, "old content must vanish")
            },

            TestDesc(suite: "ReindexBook", name: "missingBookIDAndMissingFile") {
                let dir = Fixtures.makeTempDir("reindex-missing")
                defer { Fixtures.cleanup(dir) }
                Fixtures.makePDF(pages: [.init(lines: ["存在书文本。"])], in: dir, named: "here.pdf")
                let store = try Fixtures.openStore(in: dir)
                let engine = IndexingEngine(store: store, policy: ExclusionPolicy())
                _ = try await engine.run(rootURL: dir)
                // 不存在 book_id → missing。
                let r1 = try await engine.reindexBook(bookID: "bNoSuchBook")
                try expectEqual(r1.verdict, .missing)
                // 文件删除 → missing（书还在库、文件没了）。
                let book = try expectNotNil(try store.allBooks().first)
                try FileManager.default.removeItem(at: URL(fileURLWithPath: book.realPath))
                let r2 = try await engine.reindexBook(bookID: book.id)
                try expectEqual(r2.verdict, .missing)
            },

            TestDesc(suite: "ReindexBook", name: "forceRebuildsUnchangedFileWithIdenticalContent") {
                let dir = Fixtures.makeTempDir("reindex-force")
                defer { Fixtures.cleanup(dir) }
                Fixtures.makePDF(pages: [
                    .init(lines: ["强制重建 内容恒等 权利文本。"]),
                ], in: dir, named: "forced.pdf")
                let store = try Fixtures.openStore(in: dir)
                let engine = IndexingEngine(store: store, policy: ExclusionPolicy())
                _ = try await engine.run(rootURL: dir)
                let book = try expectNotNil(try store.allBooks().first)
                let result = try await engine.reindexBook(bookID: book.id, force: true)
                try expectEqual(result.verdict, .updated, "force reports updated")
                // 内容恒等：页行同文本。
                let page = try store.page(bookID: book.id, pageNumber: 1)
                try expectTrue(page?.textOriginal.contains("权利文本") == true)
            },

            TestDesc(suite: "ReindexBook", name: "reindexOneBookNeverTouchesOthers") {
                let dir = Fixtures.makeTempDir("reindex-isolation")
                defer { Fixtures.cleanup(dir) }
                Fixtures.makePDF(pages: [.init(lines: ["A书 隔离验证 权利。"])], in: dir, named: "a.pdf")
                Fixtures.makePDF(pages: [.init(lines: ["B书 隔离验证 义务。"])], in: dir, named: "b.pdf")
                let store = try Fixtures.openStore(in: dir)
                let engine = IndexingEngine(store: store, policy: ExclusionPolicy())
                _ = try await engine.run(rootURL: dir)
                let books = try store.allBooks().sorted { $0.fileName < $1.fileName }
                try expectEqual(books.count, 2)
                // 只重索引 a：b 的 indexed_at/指纹/页行原样。
                let before = try store.book(byID: books[1].id)
                _ = try await engine.reindexBook(bookID: books[0].id, force: true)
                let after = try store.book(byID: books[1].id)
                try expectEqual(before?.indexedAt, after?.indexedAt)
                try expectEqual(before?.fingerprint, after?.fingerprint)
            },
        ]
    }
}
