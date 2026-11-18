import Foundation
@testable import LiteratureCore

enum EdgeCaseSuite {
    static var tests: [TestDesc] {
        [
            TestDesc(suite: "EdgeCase", name: "corruptPDFDoesNotCrashAndIsRecordedAsFailure") {
                let dir = Fixtures.makeTempDir("edge-corrupt")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let garbage = Data("this is definitely not a pdf".utf8) + Data(repeating: 0xFF, count: 128)
                Fixtures.makeRawFile(garbage, in: dir, named: "corrupt.pdf")
                Fixtures.makePDF(pages: [.init(lines: ["good page 好页"])], in: dir, named: "good.pdf")
                let summary = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                try expectEqual(summary.failed, 1, "corrupt file must be a recorded failure")
                try expectEqual(summary.indexedNew, 1, "indexing must continue past the corrupt file")
                try expectFalse(summary.failures.isEmpty)
                let books = try store.allBooks()
                try expectEqual(books.count, 2, "good book + explicit error row for the corrupt file")
                let errorBook = try expectNotNil(books.first { $0.status == "error" })
                try expectEqual(errorBook.pageCount, 0)
                try expectNil(books.first { $0.status == "ok" }?.error)
            },
            TestDesc(suite: "EdgeCase", name: "emptyFileIsAFailure") {
                let dir = Fixtures.makeTempDir("edge-empty")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                Fixtures.makeRawFile(Data(), in: dir, named: "empty.pdf")
                let summary = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                try expectEqual(summary.failed, 1)
                let books = try store.allBooks()
                try expectEqual(books.count, 1, "empty file leaves an explicit error row")
                try expectEqual(books.first?.status, "error")
                try expectEqual(books.first?.pageCount, 0)
            },
            TestDesc(suite: "EdgeCase", name: "truncatedPDFIsAFailure") {
                let dir = Fixtures.makeTempDir("edge-trunc")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let good = Fixtures.makePDF(pages: [.init(lines: ["to truncate"])], in: dir, named: "tmp.pdf")
                let bytes = try Data(contentsOf: good)
                Fixtures.makeRawFile(bytes.prefix(bytes.count / 3), in: dir, named: "truncated.pdf")
                let summary = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                try expectEqual(summary.failed, 1)
            },
            TestDesc(suite: "EdgeCase", name: "scannedPageIsIndexedWithoutTextAndWithoutOCR") {
                let dir = Fixtures.makeTempDir("edge-scan")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                Fixtures.makePDF(pages: [
                    .init(lines: [], textlessDrawing: true),
                    .init(lines: ["real text on page two 第二页"]),
                ], in: dir, named: "scan.pdf")
                let summary = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                try expectEqual(summary.indexedNew, 1)
                let book = try expectNotNil(try store.allBooks().first)
                try expectEqual(book.pageCount, 2, "the scanned page is still a physical page")
                let p1 = try expectNotNil(try store.page(bookID: book.id, pageNumber: 1))
                try expectTrue(p1.textOriginal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                let service = SearchService(store: store)
                try expectEqual(try service.search("scan").count, 0, "no text extracted from the scan — no OCR, no fake hits")
                try expectEqual(try service.search("第二页").count, 1)
            },
            TestDesc(suite: "EdgeCase", name: "unicodePunctuationQueryDoesNotCrashFTS") {
                let dir = Fixtures.makeTempDir("edge-fts")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                Fixtures.makePDF(pages: [.init(lines: ["quotes \" and (parens) and NEAR tokens"])], in: dir, named: "p.pdf")
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                let service = SearchService(store: store)
                for query in ["\"", "NEAR(", "(parens)", "a OR b"] {
                    do {
                        _ = try service.search(query) // must not throw; results are irrelevant
                    } catch {
                        try failTest("FTS syntax must be treated as literal text, query '\(query)' threw: \(error)")
                    }
                }
            },
            TestDesc(suite: "EdgeCase", name: "storePersistsAcrossReopen") {
                let dir = Fixtures.makeTempDir("edge-persist")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                Fixtures.makePDF(pages: [.init(lines: ["persist me 持久化"])], in: dir, named: "p.pdf")
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                let dbPath = dir.appendingPathComponent("index.db")
                let reopened = try IndexStore(path: dbPath)
                let hits = try SearchService(store: reopened).search("持久化")
                try expectEqual(hits.count, 1)
                try expectEqual(reopened.searchMode, store.searchMode, "search mode is sticky across opens")
            },
        ]
    }
}
