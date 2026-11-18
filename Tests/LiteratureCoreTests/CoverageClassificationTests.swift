import Foundation
@testable import LiteratureCore

// Kept separate from RunnerMain.swift so the suite
// definition stays with the other synthetic suites in LiteratureTestKit.
// Content below is verbatim; registration lives in AllSuites.swift.

// MARK: - Added slice: coverage classification / zero-hit
// explanation / snippet covering ALL term ranges / OCR pair manifest.

enum CoverageClassificationSuite {
    static func makeStore() throws -> (IndexStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lit-coverage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try IndexStore(path: dir.appendingPathComponent("index.db")), dir)
    }

    @discardableResult
    static func addBook(_ store: IndexStore, id: String, name: String,
                        pages: [String], status: String = "ok") throws -> IndexStore.BookRow {
        let book = IndexStore.BookRow(
            id: id, realPath: "/tmp/lit-tests/\(name)", rootPath: "/tmp/lit-tests",
            relPath: name, fileName: name,
            firstFingerprint: "fp-\(id)", fingerprint: "fp-\(id)", fileSize: 1, mtime: 0,
            pageCount: pages.count, status: status, indexedAt: 0)
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
        [
            TestDesc(suite: "CoverageClassification", name: "coverageClassifiesNeedsOCRPartialFullUnknown") {
                let (store, _) = try makeStore()
                try addBook(store, id: "bA", name: "a.pdf", pages: ["alpha one", "alpha two"])
                try addBook(store, id: "bB", name: "b.pdf", pages: ["alpha here", "", ""])
                try addBook(store, id: "bC", name: "c.pdf", pages: ["", ""])
                try addBook(store, id: "bE", name: "e.pdf", pages: [], status: "error")
                let stats = try store.perBookPageStats()
                let byID = Dictionary(stats.map { ($0.bookID, $0) }, uniquingKeysWith: { a, _ in a })
                try expectEqual(byID["bA"]?.coverage, .full)
                try expectEqual(byID["bB"]?.coverage, .partial)
                try expectEqual(byID["bC"]?.coverage, .needsOCR)
                try expectEqual(byID["bE"]?.coverage, .unknown)
                let cls = CoverageClassification(stats: stats)
                try expectEqual(cls.booksFull, 1)
                try expectEqual(cls.booksPartial, 1)
                try expectEqual(cls.booksNeedsOCR, 1)
                try expectEqual(cls.booksUnknown, 1)
            },

            TestDesc(suite: "CoverageClassification", name: "zeroHitExplainsNoTextLayerVsTermMiss") {
                let (store, _) = try makeStore()
                try addBook(store, id: "bA", name: "a.pdf", pages: ["alpha one", "alpha two"])
                try addBook(store, id: "bC", name: "c.pdf", pages: ["", ""])
                let service = SearchService(store: store)
                let zero = try service.searchDetailed("qqzzww")
                try expectTrue(zero.hits.isEmpty)
                let exp = try expectNotNil(zero.zeroHitExplanation)
                let a = exp.books.first { $0.bookID == "bA" }
                let c = exp.books.first { $0.bookID == "bC" }
                try expectEqual(a?.reason, .termNotMatched)
                try expectEqual(c?.reason, .noTextLayer)
                try expectTrue(exp.summary.contains("无文字层"))
                try expectTrue(exp.summary.contains("词未命中"))
                try expectFalse(exp.summary.contains("完成")) // must never claim OCR done
                let hitRun = try service.searchDetailed("alpha")
                try expectFalse(hitRun.hits.isEmpty)
                try expectNil(hitRun.zeroHitExplanation)
                let again = try service.explainZeroHit("qqzzww")
                try expectEqual(again.books.count, 2)
            },

            TestDesc(suite: "CoverageClassification", name: "snippetCoversAllTermRanges") {
                let pad = String(repeating: "x", count: 80)
                let (store, _) = try makeStore()
                try addBook(store, id: "bA", name: "a.pdf", pages: ["ALPHA \(pad) BETA tail"])
                let service = SearchService(store: store)
                let result = try service.searchDetailed("alpha beta")
                try expectEqual(result.hits.count, 1)
                let hit = try expectNotNil(result.hits.first)
                try expectEqual(hit.matches.count, 2)
                try expectTrue(hit.snippet.contains("ALPHA"))
                try expectTrue(hit.snippet.contains("BETA"))
                let direct = SearchService.snippet(in: "AAA \(pad) BBB", around: [0..<3, 85..<88])
                try expectTrue(direct.contains("AAA") && direct.contains("BBB"))
            },

            TestDesc(suite: "CoverageClassification", name: "ocrManifestParseAcceptsOnlyProvenMappings") {
                let same = #"{"pairs":[{"originalPath":"book.pdf","ocrPath":"book-ocr.pdf","mapping":{"type":"same-page-verified"}}]}"#
                let m1 = try OCRPairManifest.parse(Data(same.utf8))
                try expectEqual(m1.entries.count, 1)
                try expectEqual(m1.entries[0].mapping, .samePageVerified)

                let explicit = #"{"pairs":[{"originalPath":"o.pdf","ocrPath":"c.pdf","mapping":{"type":"explicit","pages":[{"original":1,"ocr":3},{"original":2,"ocr":4}]}}]}"#
                let m2 = try OCRPairManifest.parse(Data(explicit.utf8))
                guard case .explicit(let pairs) = m2.entries[0].mapping else {
                    try failTest("expected explicit mapping")
                }
                try expectEqual(pairs.count, 2)
                try expectEqual(pairs[1], OCRPagePair(originalPage: 2, ocrPage: 4))

                let fixed = #"{"pairs":[{"originalPath":"o.pdf","ocrPath":"c.pdf","mapping":{"type":"fixed-offset","offset":2}}]}"#
                try expectThrows(try OCRPairManifest.parse(Data(fixed.utf8)), "fixed-offset must be rejected")
                let dup = #"{"pairs":[{"originalPath":"o.pdf","ocrPath":"c.pdf","mapping":{"type":"explicit","pages":[{"original":1,"ocr":1},{"original":1,"ocr":2}]}}]}"#
                try expectThrows(try OCRPairManifest.parse(Data(dup.utf8)), "duplicate original page must be rejected")
                let noPath = #"{"pairs":[{"originalPath":"o.pdf","mapping":{"type":"same-page-verified"}}]}"#
                try expectThrows(try OCRPairManifest.parse(Data(noPath.utf8)), "missing ocrPath must be rejected")
                let emptyPages = #"{"pairs":[{"originalPath":"o.pdf","ocrPath":"c.pdf","mapping":{"type":"explicit","pages":[]}}]}"#
                try expectThrows(try OCRPairManifest.parse(Data(emptyPages.utf8)), "empty pages must be rejected")
                let identical = #"{"pairs":[{"originalPath":"o.pdf","ocrPath":"o.pdf","mapping":{"type":"same-page-verified"}}]}"#
                try expectThrows(try OCRPairManifest.parse(Data(identical.utf8)), "identical paths must be rejected")
                let unknown = #"{"pairs":[{"originalPath":"o.pdf","ocrPath":"c.pdf","mapping":{"type":"magic"}}]}"#
                try expectThrows(try OCRPairManifest.parse(Data(unknown.utf8)), "unknown mapping type must be rejected")
            },

            TestDesc(suite: "CoverageClassification", name: "ocrManifestValidationStatsOnlyRootBounded") {
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lit-manifest-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data("x".utf8).write(to: root.appendingPathComponent("book.pdf"))
                try Data("y".utf8).write(to: root.appendingPathComponent("book-ocr.pdf"))
                let outside = root.deletingLastPathComponent()
                    .appendingPathComponent("outside-\(UUID().uuidString).pdf")
                try Data("z".utf8).write(to: outside)

                let manifest = OCRPairManifest(entries: [
                    OCRPairEntry(originalPath: "book.pdf", ocrPath: "book-ocr.pdf", mapping: .samePageVerified),
                    OCRPairEntry(originalPath: outside.path, ocrPath: "book-ocr.pdf", mapping: .samePageVerified),
                    OCRPairEntry(originalPath: "book.pdf", ocrPath: "missing-ocr.pdf", mapping: .samePageVerified),
                ])
                let outcome = manifest.validated(rootURL: root)
                try expectEqual(outcome.accepted.count, 1)
                try expectEqual(outcome.accepted.first?.originalPath, "book.pdf")
                try expectEqual(outcome.rejected.count, 2)
                try expectTrue(outcome.rejected.contains { $0.reason.contains("outside the allowed root") })
                try expectTrue(outcome.rejected.contains { $0.reason.contains("missing or not a regular file") })
            },
        ]
    }
}
