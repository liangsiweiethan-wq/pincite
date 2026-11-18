import Foundation
@testable import LiteratureCore

// MARK: - Coverage publication gate suite (all synthetic)
//
// The App Group shared snapshot is Widget-facing production state. This suite
// pins the rule that only the canonical app database publishes coverage, so a
// index can never overwrite it; --publish-coverage is the
// only override. (Found:  every E2E run clobbered the real library's
// Widget coverage with fixture counters.)

enum CoveragePublicationSuite {
    static func scratchDB() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lit-covpub-\(UUID().uuidString)", isDirectory: true)
        return dir.appendingPathComponent("index.db")
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "CoveragePublication", name: "scratchDatabaseDoesNotPublishByDefault") {
                try expectFalse(
                    CoveragePublication.shouldPublish(dbURL: scratchDB(), explicit: false),
                    "a scratch database must never publish coverage by default")
            },

            TestDesc(suite: "CoveragePublication", name: "explicitFlagPublishesAnyDatabase") {
                try expectTrue(
                    CoveragePublication.shouldPublish(dbURL: scratchDB(), explicit: true),
                    "explicit operator request must publish even for a scratch database")
            },

            TestDesc(suite: "CoveragePublication", name: "canonicalDatabasePublishes") {
                try expectTrue(
                    CoveragePublication.shouldPublish(dbURL: CoveragePublication.canonicalAppDatabaseURL, explicit: false),
                    "the canonical app database must publish coverage")
            },

            TestDesc(suite: "CoveragePublication", name: "canonicalPathComparisonIsStandardized") {
                let canonical = CoveragePublication.canonicalAppDatabaseURL.standardizedFileURL.path
                let dir = CoveragePublication.canonicalAppDatabaseURL.deletingLastPathComponent().path
                let redundant = URL(fileURLWithPath: dir + "/./x/../index.db")
                try expectEqual(redundant.standardizedFileURL.path, canonical,
                                "precondition: the constructed path standardizes to the canonical path")
                try expectTrue(
                    CoveragePublication.shouldPublish(dbURL: redundant, explicit: false),
                    "redundant path components must not defeat the canonical check")
            },

            TestDesc(suite: "CoveragePublication", name: "copiedDatabaseDoesNotPublish") {
                // The performance workflow queries copy-on-write copies of the
                // real database; a copy next to the canonical file must still
                // not publish.
                let dir = CoveragePublication.canonicalAppDatabaseURL.deletingLastPathComponent()
                try expectFalse(
                    CoveragePublication.shouldPublish(dbURL: dir.appendingPathComponent("index-copy.db"), explicit: false),
                    "a copy of the database must not publish coverage")
            },

            TestDesc(suite: "CoveragePublication", name: "canonicalURLMatchesAppDatabaseLayout") {
                let url = CoveragePublication.canonicalAppDatabaseURL
                try expectEqual(url.lastPathComponent, "index.db", "canonical database file name")
                try expectEqual(url.deletingLastPathComponent().lastPathComponent, "LiteratureSearch",
                                "canonical database directory")
                try expectTrue(url.path.hasSuffix("Application Support/LiteratureSearch/index.db"),
                               "canonical database lives in Application Support")
            },

            TestDesc(suite: "CoveragePublication", name: "resolveCanonicalFallbacksOnEmptyURLs") {
                // 空 urls（Application Support 不可枚举的异常环境）
                // → 家目录降级处理不陷阱，并给出降级警告（resolveBase 同款语义）。
                let r = CoveragePublication.resolveCanonicalAppDatabaseURL(from: [])
                try expectTrue(r.url.lastPathComponent == "index.db"
                               && r.url.deletingLastPathComponent().lastPathComponent == "LiteratureSearch",
                               "fallback keeps the LiteratureSearch/index.db layout")
                try expectTrue(r.url.path.contains("Library/Application Support"),
                               "fallback lands under the home Library")
                try expectNotNil(r.warning, "empty urls must produce a downgrade warning")
            },

            TestDesc(suite: "CoveragePublication", name: "resolveCanonicalKeepsProvidedURLs") {
                let custom = [URL(fileURLWithPath: "/tmp/custom-support"), URL(fileURLWithPath: "/tmp/second")]
                let r = CoveragePublication.resolveCanonicalAppDatabaseURL(from: custom)
                try expectEqual(r.url.standardizedFileURL.path,
                                "/tmp/custom-support/LiteratureSearch/index.db")
                try expectNil(r.warning, "regular urls must not warn")
            },

            TestDesc(suite: "CoveragePublication", name: "queryCacheInvalidatedOnOCRPagesUpdate") {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lit-qc-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: dir) }
                let store = try IndexStore(path: dir.appendingPathComponent("index.db"))

                let book = IndexStore.BookRow(
                    id: "b1", realPath: "/tmp/lit-tests/book1.pdf", rootPath: "/tmp/lit-tests",
                    relPath: "book1.pdf", fileName: "book1.pdf",
                    title: nil, author: nil, version: nil, language: nil, metaSource: nil,
                    firstFingerprint: "fp-1", fingerprint: "fp-1", fileSize: 1, mtime: 0,
                    pageCount: 1, status: "ok", error: nil, indexedAt: 0)
                try store.upsertBook(book)

                let initialText = "考古发掘甲骨文缀合研究"
                let normInitial = normalizeForSearch(initialText)
                try store.replacePages(bookID: "b1", [
                    IndexStore.PageRow(
                        bookID: "b1", pageNumber: 1, label: nil, printedPage: nil,
                        textOriginal: initialText, textNorm: normInitial.text,
                        normStarts: normInitial.starts, normEnds: normInitial.ends)
                ])

                let service = SearchService(store: store)
                let firstResult = try service.searchDetailed("甲骨文")
                try expectEqual(firstResult.hits.count, 1, "initial search should match 1 hit")
                try expectEqual(firstResult.totalPageMatches, 1, "initial total matches should be 1")
                try expectNotNil(try store.cachedCandidateRowIDs(normalizedQuery: normalizeQuery("甲骨文")),
                                 "query cache must be populated")

                let ocrText = "西汉简牍整理报告汇编"
                let normOCR = normalizeForSearch(ocrText)
                let ocrBook = IndexStore.OCRBookRow(
                    bookID: "b1", ocrRealPath: "/tmp/lit-tests/book1-ocr.pdf", ocrFingerprint: "fp-ocr",
                    mappingKind: "same-page-verified", createdAt: 0)
                let updates = [
                    IndexStore.OCRPageTextUpdate(
                        originalPage: 1, ocrPage: 1,
                        textOriginal: ocrText, textNorm: normOCR.text,
                        normStarts: normOCR.starts, normEnds: normOCR.ends)
                ]
                try store.applyOCRPages(bookID: "b1", ocrBook: ocrBook,
                                        mapping: [OCRPagePair(originalPage: 1, ocrPage: 1)],
                                        updates: updates)

                try expectNil(try store.cachedCandidateRowIDs(normalizedQuery: normalizeQuery("甲骨文")),
                              "query cache must be invalidated after applyOCRPages")
                let secondResult = try service.searchDetailed("甲骨文")
                try expectEqual(secondResult.hits.count, 0, "subsequent search must not return old hit")
                try expectEqual(secondResult.totalPageMatches, 0, "totalPageMatches must be 0 after cache invalidation")

                // Also verify search over new OCR text populates cache and purgeOCR invalidates it
                let ocrResult = try service.searchDetailed("简牍")
                try expectEqual(ocrResult.hits.count, 1, "search for OCR text should find hit")
                try expectNotNil(try store.cachedCandidateRowIDs(normalizedQuery: normalizeQuery("简牍")),
                                 "OCR query cache must be populated")

                try store.purgeOCR(bookID: "b1")
                try expectNil(try store.cachedCandidateRowIDs(normalizedQuery: normalizeQuery("简牍")),
                              "query cache must be invalidated after purgeOCR")
                let purgedResult = try service.searchDetailed("简牍")
                try expectEqual(purgedResult.hits.count, 0, "search for purged OCR text must return 0 hits")
                try expectEqual(purgedResult.totalPageMatches, 0, "totalPageMatches must be 0 after purgeOCR")
            },
        ]
    }
}
