import Foundation
@testable import LiteratureCore


enum RegressionSuite {
    static var tests: [TestDesc] {
        [
            // 1. Candidate completeness: the limit is applied (and reported) at the
            // service layer, never silently inside the store intersection.
            TestDesc(suite: "Regression", name: "candidateCompletenessAndTruncationFlag") {
                let dir = Fixtures.makeTempDir("reg-trunc")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                var lines: [String] = []
                for i in 0..<30 { lines.append("page \(i) 目标词 marker\(i)") }
                Fixtures.makePDF(pages: lines.map { SyntheticPDFPage(lines: [$0]) }, in: dir, named: "many.pdf")
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)

                let service = SearchService(store: store)
                let capped = try service.searchDetailed("目标词", options: SearchOptions(limit: 10))
                try expectEqual(capped.hits.count, 10)
                try expectEqual(capped.totalPageMatches, 30)
                try expectTrue(capped.truncated, "cap reported explicitly, never silently")
                let full = try service.searchDetailed("目标词", options: SearchOptions(limit: 100))
                try expectEqual(full.hits.count, 30)
                try expectFalse(full.truncated)
                // every page found with its own marker (no row lost in candidates)
                try expectTrue(full.hits.contains { $0.snippet.contains("marker29") })
            },

            TestDesc(suite: "Regression", name: "allOccurrencesPerPageWithBounds") {
                let dir = Fixtures.makeTempDir("reg-occur")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                Fixtures.makePDF(pages: [
                    .init(lines: ["关键词 appears once; 关键词 appears twice on this page."]),
                    .init(lines: ["irrelevant page"]),
                ], in: dir, named: "twice.pdf")
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                let service = SearchService(store: store)
                let hits = try service.search("关键词")
                try expectEqual(hits.count, 1)
                try expectEqual(hits[0].matches.count, 2, "both occurrences are located")
                let ranges = hits[0].matches.map(\.originalUTF16Range)
                try expectNotEqual(ranges[0].lowerBound, ranges[1].lowerBound)
                for range in ranges {
                    let bounds = PDFTextExtractor.selectionBounds(
                        fileURL: URL(fileURLWithPath: hits[0].filePath),
                        physicalPage: hits[0].physicalPage,
                        originalUTF16Range: range
                    )
                    try expectNotNil(bounds, "every occurrence is highlightable on the page")
                }
            },

            // 3. HTTPS-only AI configuration (Bearer key must not travel over HTTP).
            TestDesc(suite: "Regression", name: "aiConfigurationRejectsNonHTTPS") {
                let service = AIAssistantService()
                try expectThrows(try service.configure(AIConfiguration(
                    serviceURL: URL(string: "http://api.example.test/ask")!, model: "m")),
                    "plain HTTP config must be rejected")
                try expectNil(service.configuration)
                try service.configure(AIConfiguration(serviceURL: URL(string: "https://api.example.test/ask")!, model: "m"))
                try expectNotNil(service.configuration)
                try expectThrows(try service.configure(AIConfiguration(
                    serviceURL: URL(string: "https://api.example.test")!, model: "  ")),
                    "empty model rejected: identity is never inferred")
            },

            // 4. Cross-origin redirect detection (transport refuses to forward keys).
            TestDesc(suite: "Regression", name: "crossOriginRedirectDetection") {
                let same = try expectNoThrow(try isCrossOriginRedirect(
                    from: URL(string: "https://api.example.test/ask")!,
                    to: URL(string: "https://api.example.test/other")!))
                try expectFalse(same!)
                let crossHost = try expectNoThrow(try isCrossOriginRedirect(
                    from: URL(string: "https://api.example.test/ask")!,
                    to: URL(string: "https://evil.example.net/ask")!))
                try expectTrue(crossHost!)
                let crossScheme = try expectNoThrow(try isCrossOriginRedirect(
                    from: URL(string: "https://api.example.test/ask")!,
                    to: URL(string: "http://api.example.test/ask")!))
                try expectTrue(crossScheme!)
                let defaultPorts = try expectNoThrow(try isCrossOriginRedirect(
                    from: URL(string: "https://api.example.test/a")!,
                    to: URL(string: "https://api.example.test:443/a")!))
                try expectFalse(defaultPorts!, "implicit and explicit default ports are the same origin")
            },

            TestDesc(suite: "Regression", name: "schemaMigrationV1ToV2") {
                let dir = Fixtures.makeTempDir("reg-mig")
                defer { Fixtures.cleanup(dir) }
                let dbPath = dir.appendingPathComponent("old.db")
                let old = try SQLiteDatabase(path: dbPath.path)
                try old.exec("""
                CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE books(id TEXT PRIMARY KEY, real_path TEXT NOT NULL UNIQUE, root_path TEXT NOT NULL,
                    rel_path TEXT NOT NULL, file_name TEXT NOT NULL, title TEXT, author TEXT, version TEXT,
                    first_fingerprint TEXT NOT NULL, fingerprint TEXT NOT NULL, file_size INTEGER NOT NULL,
                    mtime REAL NOT NULL, page_count INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'ok',
                    error TEXT, indexed_at REAL NOT NULL);
                CREATE TABLE pages(book_id TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
                    page_number INTEGER NOT NULL, label TEXT, printed_page INTEGER, text_original TEXT NOT NULL,
                    text_norm TEXT NOT NULL, norm_starts BLOB NOT NULL, norm_ends BLOB NOT NULL,
                    PRIMARY KEY(book_id, page_number));
                INSERT INTO meta VALUES('schema_version','1');
                INSERT INTO books(id, real_path, root_path, rel_path, file_name, first_fingerprint, fingerprint,
                    file_size, mtime, page_count, status, indexed_at)
                    VALUES('bold','/tmp/old.pdf','/tmp','old.pdf','old.pdf','ff','ff',1,0,1,'ok',0);
                """)
                // Open with the current store: migration must run and keep data.
                let store = try IndexStore(path: dbPath)
                let book = try store.book(byID: "bold")
                try expectNotNil(book, "v1 rows survive migration")
                try expectEqual(try store.metaValue("schema_version"), String(IndexStore.currentSchemaVersion))
                try expectNil(book?.language, "migrated rows keep unknown metadata unknown")
                // migrated store still indexes and serves new columns
                try store.updateMetadata(bookID: "bold", title: "T", author: nil, version: nil, language: "zh", source: "manual")
                let updated = try store.book(byID: "bold")
                try expectEqual(updated?.title, "T")
                try expectEqual(updated?.language, "zh")
                try expectEqual(updated?.metaSource, "manual")
                try expectNil(updated?.author, "fields not provided stay unknown")
            },

            // 6. Metadata sidecar (JSON) import; originals untouched; no guessing.
            TestDesc(suite: "Regression", name: "sidecarJSONImport") {
                let dir = Fixtures.makeTempDir("reg-sidecar")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let pdf = Fixtures.makePDF(pages: [.init(lines: ["some 内容"])], in: dir, named: "a.pdf")
                let before = try Fingerprint.sha256Hex(ofFileAt: pdf)
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)

                let sidecar = #"{"books":[{"file":"a.pdf","title":"书名","author":"作者甲","version":"第2版","language":"zh"},{"file":"missing.pdf","title":"幽灵"}]}"#
                let records = try MetadataImporter.parseJSON(Data(sidecar.utf8))
                try expectEqual(records.count, 2)
                let report = MetadataImporter.apply(records, store: store)
                try expectEqual(report.applied, 1)
                try expectEqual(report.skipped.count, 1)
                try expectTrue(report.skipped[0].reason.contains("no matching"))

                let book = try store.allBooks().first!
                try expectEqual(book.title, "书名")
                try expectEqual(book.author, "作者甲")
                try expectEqual(book.version, "第2版")
                try expectEqual(book.language, "zh")
                try expectEqual(book.metaSource, "sidecar")
                let after = try Fingerprint.sha256Hex(ofFileAt: pdf)
                try expectEqual(before, after, "import never modifies the original file")
            },

            // 7. CSV sidecar with quotes; empty fields stay unknown.
            TestDesc(suite: "Regression", name: "sidecarCSVImport") {
                let dir = Fixtures.makeTempDir("reg-csv")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                Fixtures.makePDF(pages: [.init(lines: ["csv 内容"])], in: dir, named: "b,1.pdf")
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)

                let csv = "file,title,author,version,language\n\"b,1.pdf\",\"Quoted, Title\",Someone,,en\n"
                let records = try MetadataImporter.parseCSV(Data(csv.utf8))
                try expectEqual(records.count, 1)
                try expectEqual(records[0].title, "Quoted, Title", "quoted commas survive")
                let report = MetadataImporter.apply(records, store: store)
                try expectEqual(report.applied, 1)
                let book = try store.allBooks().first!
                try expectEqual(book.language, "en")
                try expectNil(book.version, "empty CSV cell stays unknown")
            },

            // 8. Metadata filters; positive filters never match unknown fields.
            TestDesc(suite: "Regression", name: "metadataFiltersExcludeUnknown") {
                let dir = Fixtures.makeTempDir("reg-filter")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                Fixtures.makePDF(pages: [.init(lines: ["shared term 甲书"])], in: dir, named: "a.pdf")
                Fixtures.makePDF(pages: [.init(lines: ["shared term 乙书"])], in: dir, named: "b.pdf")
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                let books = try store.allBooks().sorted { $0.fileName < $1.fileName }
                try store.updateMetadata(bookID: books[0].id, title: nil, author: "鲁先", version: nil, language: "zh", source: "manual")

                let service = SearchService(store: store)
                let all = try service.searchDetailed("shared", options: SearchOptions(limit: 10))
                try expectEqual(all.totalPageMatches, 2)
                let filtered = try service.searchDetailed("shared", options: SearchOptions(
                    limit: 10, filter: SearchFilter(authorContains: "鲁先")))
                try expectEqual(filtered.hits.count, 1)
                try expectEqual(filtered.hits[0].fileName, "a.pdf")
                let byLanguage = try service.searchDetailed("shared", options: SearchOptions(
                    limit: 10, filter: SearchFilter(languageEquals: "ZH")))
                try expectEqual(byLanguage.hits.count, 1, "language filter is case-insensitive equality")
                let unknownNeverMatches = try service.searchDetailed("shared", options: SearchOptions(
                    limit: 10, filter: SearchFilter(authorContains: "未知作者")))
                try expectEqual(unknownNeverMatches.totalPageMatches, 0, "nil author is never treated as a match")
            },

            // 9. Query-time policy re-check (not only at index time).
            TestDesc(suite: "Regression", name: "queryTimePolicyReCheck") {
                let dir = Fixtures.makeTempDir("reg-policy")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                Fixtures.makePDF(pages: [.init(lines: ["renamed content 内容"])], in: dir, named: "harmless-name.pdf")
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                let lenient = SearchService(store: store)
                try expectEqual(try lenient.search("renamed").count, 1)

                // A newly added identifier removes the hit from results WITHOUT reindex
                // (path/ID-level re-check only; no content is read for this).
                let strictPolicy = ExclusionPolicy(config: ExclusionConfig(excludedIdentifiers: ["harmless-name"]))
                let strict = SearchService(store: store, policy: strictPolicy)
                let book = try store.allBooks()[0]
                try expectEqual(try strict.search("renamed").count, 0)
            },

            // 10. Extraction limits: byte and page bounds are explicit failures.
            TestDesc(suite: "Regression", name: "extractionLimitsAreExplicitFailures") {
                let dir = Fixtures.makeTempDir("reg-limits")
                defer { Fixtures.cleanup(dir) }
                let pdf = Fixtures.makePDF(pages: [.init(lines: ["x"])], in: dir, named: "s.pdf")
                // byte limit below the actual size -> failure before content is parsed
                try expectThrows(try PDFTextExtractor.extract(url: pdf, limits: PDFExtractionLimits(maxPages: nil, maxFileBytes: 16)))
                // page limit
                let many = Fixtures.makePDF(
                    pages: (0..<5).map { SyntheticPDFPage(lines: ["page \($0)"]) },
                    in: dir, named: "m.pdf")
                try expectThrows(try PDFTextExtractor.extract(url: many, limits: PDFExtractionLimits(maxPages: 3, maxFileBytes: nil)))
                // within limits works
                let ok = try PDFTextExtractor.extract(url: many, limits: PDFExtractionLimits(maxPages: 5, maxFileBytes: nil))
                try expectEqual(ok.pageCount, 5)
            },

            // 10a. Pin: default byte limit is 2 GiB (raised from 1 GiB so the
            // legitimate OCR-cache PDFs larger than 1 GiB are not falsely rejected;
            // the guard stays as an explicit anti-fool threshold — over-limit is still an
            // explicit whole-file failure, never a partial index).
            TestDesc(suite: "Regression", name: "defaultLimitsMaxFileBytesIsTwoGiB") {
                let defaults = PDFExtractionLimits()
                try expectEqual(defaults.maxFileBytes, Int64(2 << 30))
                try expectEqual(defaults.maxPages, 2000)
            },

            // 10b. Pin: .unlimited must keep both bounds nil (no accidental regression to
            // a bounded "unlimited", which would re-introduce silent large-file failure).
            TestDesc(suite: "Regression", name: "unlimitedLimitsMaxFileBytesStaysNil") {
                try expectEqual(PDFExtractionLimits.unlimited.maxFileBytes, Int64?.none)
                try expectEqual(PDFExtractionLimits.unlimited.maxPages, Int?.none)
            },

            // 11. Engine records unsupported files and persists the run record.
            TestDesc(suite: "Regression", name: "unsupportedCountAndRunRecordPersistence") {
                let dir = Fixtures.makeTempDir("reg-unsupported")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                Fixtures.makePDF(pages: [.init(lines: ["pdf 内容"])], in: dir, named: "a.pdf")
                Fixtures.makeRawFile(Data("notes".utf8), in: dir, named: "n.txt")
                let summary = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                try expectEqual(summary.unsupported, 1, "non-PDF is counted, not silently ignored (own db files are skipped)")
                try expectEqual(summary.indexedNew, 1)
                let recordJSON = try store.metaValue("last_run_summary")
                let record = try expectNotNil(recordJSON).data(using: .utf8)
                    .flatMap { try? JSONDecoder().decode(IndexingEngine.RunRecord.self, from: $0) }
                try expectEqual(record?.unsupported, 1)
                try expectEqual(record?.indexedNew, 1)
            },

            // 12. Coverage statistics across categories.
            TestDesc(suite: "Regression", name: "coverageStatsCategories") {
                let dir = Fixtures.makeTempDir("reg-coverage")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                Fixtures.makePDF(pages: [.init(lines: ["text ok 文本"])], in: dir, named: "ok.pdf")
                Fixtures.makePDF(pages: [.init(lines: [], textlessDrawing: true)], in: dir, named: "scan.pdf")
                Fixtures.makeRawFile(Data("junk".utf8), in: dir, named: "corrupt.pdf")
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                let stats = try store.coverageStats()
                try expectEqual(stats.booksOK, 2)
                try expectEqual(stats.booksError, 1, "corrupt file recorded as error book (new files too)")
                try expectEqual(stats.pages, 2, "ok.pdf 1 page + scan.pdf 1 textless page")
                try expectEqual(stats.pagesWithoutText, 1, "scanned page counted as no-text (OCR is not performed)")
            },

            // 13. Valid PDFs pass by default; configured identifiers still exclude.
            TestDesc(suite: "Regression", name: "defaultConfigAllowsAllBookNames") {
                let dir = Fixtures.makeTempDir("forbidden-set")
                defer { Fixtures.cleanup(dir) }
                let policy = ExclusionPolicy(config: ExclusionConfig.conservativeDefaults)
                try expectEqual(policy.evaluate(candidateFileURL: dir.appendingPathComponent("Drafts-某书.pdf"), rootURL: dir),
                                .allowed)
                try expectEqual(policy.evaluate(candidateFileURL: dir.appendingPathComponent("Archive著作.pdf"), rootURL: dir),
                                .allowed)
                try expectEqual(policy.evaluate(candidateFileURL: dir.appendingPathComponent("BOOK-0001-v2.pdf"), rootURL: dir),
                                .allowed)
                // custom identifiers are honored too
                let custom = ExclusionPolicy(config: ExclusionConfig(excludedIdentifiers: ["MySet"]))
                try expectEqual(custom.evaluateBookID("bMySet-derived"), .excludedByID("MySet"))
            },

            // 14. Widget deep-link safety: no URL for empty queries (no file:/// fallbacks).
            TestDesc(suite: "Regression", name: "deepLinkBuildNilForEmptyQuery") {
                try expectNil(DeepLink.search(query: "").build())
                try expectNil(DeepLink.search(query: "   ").build())
                // parse still accepts an explicitly crafted empty-q URL (app side)
                let crafted = URL(string: "literaturesearch://search?q=")!
                try expectEqual(DeepLink.parse(crafted), .search(query: ""))
            },

            // 15. indexExplicitFiles: single named file, read-only, no scan of siblings.
            TestDesc(suite: "Regression", name: "explicitFileIndexingOnlyNamedFiles") {
                let dir = Fixtures.makeTempDir("reg-index-file")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let chosen = Fixtures.makePDF(pages: [.init(lines: ["chosen book 选定书"])], in: dir, named: "chosen.pdf")
                Fixtures.makePDF(pages: [.init(lines: ["sibling book 兄弟书"])], in: dir, named: "sibling.pdf")
                let summary = try await IndexingEngine(store: store, policy: ExclusionPolicy())
                    .indexExplicitFiles(urls: [chosen])
                try expectEqual(summary.indexedNew, 1)
                try expectEqual(try store.allBooks().count, 1, "siblings are NOT touched by explicit-file indexing")
                try expectEqual(try SearchService(store: store).search("兄弟书").count, 0)
                try expectEqual(try SearchService(store: store).search("选定书").count, 1)
            },

            // 16. pages(rowIDs:) batching: preserves input order and handles duplicates / unordered IDs.
            TestDesc(suite: "Regression", name: "pagesBatchPreservesInputOrderAndDuplicates") {
                let dir = Fixtures.makeTempDir("reg-pages-order")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let bookID = "b-order-test"
                let book = IndexStore.BookRow(
                    id: bookID, realPath: "/tmp/\(bookID).pdf", rootPath: "/tmp",
                    relPath: "\(bookID).pdf", fileName: "\(bookID).pdf",
                    firstFingerprint: "fp1", fingerprint: "fp1", fileSize: 100, mtime: 0,
                    pageCount: 5, status: "ok", error: nil, indexedAt: 0
                )
                try store.upsertBook(book)
                let pageRows = (1...5).map { i in
                    IndexStore.PageRow(
                        bookID: bookID, pageNumber: i, label: "L\(i)", printedPage: i * 10,
                        textOriginal: "Original page \(i) content",
                        textNorm: "original page \(i) content",
                        normStarts: [0], normEnds: [Int32("Original page \(i) content".count)]
                    )
                }
                try store.replacePages(bookID: bookID, pageRows)

                let rowIDsSet = try store.candidateRowIDs(bookID: bookID)
                let sortedRowIDs = rowIDsSet.sorted { (Int64($0) ?? 0) < (Int64($1) ?? 0) }
                try expectEqual(sortedRowIDs.count, 5)

                // 1) Test scrambled/disordered input order: [3, 0, 4, 1, 2]
                let scrambledIDs = [sortedRowIDs[3], sortedRowIDs[0], sortedRowIDs[4], sortedRowIDs[1], sortedRowIDs[2]]
                let fetched = try store.pages(rowIDs: scrambledIDs)
                try expectEqual(fetched.count, 5)
                try expectEqual(fetched.map(\.pageNumber), [4, 1, 5, 2, 3])
                try expectEqual(fetched[0].label, "L4")
                try expectEqual(fetched[0].printedPage, 40)
                try expectEqual(fetched[1].pageNumber, 1)

                // 2) Test duplicate rowIDs preserved in output order
                let dupIDs = [sortedRowIDs[2], sortedRowIDs[0], sortedRowIDs[2]]
                let fetchedDups = try store.pages(rowIDs: dupIDs)
                try expectEqual(fetchedDups.count, 3)
                try expectEqual(fetchedDups.map(\.pageNumber), [3, 1, 3])
            },

            // 17. pages(rowIDs:) cross-chunk correctness: > 500 rowids chunked in <= 500 batches.
            TestDesc(suite: "Regression", name: "pagesBatchCrossBlockCompleteness") {
                let dir = Fixtures.makeTempDir("reg-pages-chunk")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let bookID = "b-chunk-test"
                let totalPages = 550 // > 500 to force cross-chunk execution
                let book = IndexStore.BookRow(
                    id: bookID, realPath: "/tmp/\(bookID).pdf", rootPath: "/tmp",
                    relPath: "\(bookID).pdf", fileName: "\(bookID).pdf",
                    firstFingerprint: "fp-chunk", fingerprint: "fp-chunk", fileSize: 100, mtime: 0,
                    pageCount: totalPages, status: "ok", error: nil, indexedAt: 0
                )
                try store.upsertBook(book)
                let pageRows = (1...totalPages).map { i in
                    IndexStore.PageRow(
                        bookID: bookID, pageNumber: i, label: nil, printedPage: nil,
                        textOriginal: "Chunk page \(i) text",
                        textNorm: "chunk page \(i) text",
                        normStarts: [], normEnds: []
                    )
                }
                try store.replacePages(bookID: bookID, pageRows)

                let rowIDsSet = try store.candidateRowIDs(bookID: bookID)
                let sortedRowIDs = rowIDsSet.sorted { (Int64($0) ?? 0) < (Int64($1) ?? 0) }
                try expectEqual(sortedRowIDs.count, totalPages)

                // Forward query across chunks
                let fetchedAll = try store.pages(rowIDs: sortedRowIDs)
                try expectEqual(fetchedAll.count, totalPages)
                try expectEqual(fetchedAll.map(\.pageNumber), Array(1...totalPages))

                // Reversed query across chunks
                let reversedRowIDs = Array(sortedRowIDs.reversed())
                let fetchedReversed = try store.pages(rowIDs: reversedRowIDs)
                try expectEqual(fetchedReversed.count, totalPages)
                try expectEqual(fetchedReversed.map(\.pageNumber), Array((1...totalPages).reversed()))
            },

            // 18. pages(rowIDs:) empty and missing input handling.
            TestDesc(suite: "Regression", name: "pagesBatchEmptyAndMissingInput") {
                let dir = Fixtures.makeTempDir("reg-pages-empty")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)

                // Empty input returns empty
                let empty = try store.pages(rowIDs: [])
                try expectEqual(empty.count, 0)

                // Non-existent or non-numeric rowIDs return empty
                let nonExistent = try store.pages(rowIDs: ["-1", "999999", "not_a_number"])
                try expectEqual(nonExistent.count, 0)
            },

            // 19. OCR indexing engine respects extraction limits (max-pages / max-bytes).
            TestDesc(suite: "Regression", name: "ocrIndexingRespectsExtractionLimits") {
                let dir = Fixtures.makeTempDir("reg-ocr-limits")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)

                let origDir = dir.appendingPathComponent("orig", isDirectory: true)
                let ocrDir = dir.appendingPathComponent("ocr", isDirectory: true)
                try FileManager.default.createDirectory(at: origDir, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: ocrDir, withIntermediateDirectories: true)

                let origPDF = Fixtures.makePDF(pages: [
                    .init(lines: [""]), .init(lines: [""]), .init(lines: [""])
                ], in: origDir, named: "book.pdf")
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).indexExplicitFiles(urls: [origPDF])

                let ocrPDF = Fixtures.makePDF(pages: [
                    .init(lines: ["p1 ocr"]), .init(lines: ["p2 ocr"]), .init(lines: ["p3 ocr"])
                ], in: ocrDir, named: "book-ocr.pdf")

                let manifestData = Data("""
                {"pairs":[{"originalPath":"book.pdf","ocrPath":"book-ocr.pdf","mapping":{"type":"same-page-verified"}}]}
                """.utf8)
                let manifest = try OCRPairManifest.parse(manifestData)

                // Engine with maxPages limit of 2 (< 3 pages of OCR file) -> fails whole pair
                let strictPagesEngine = OCRIndexingEngine(store: store, policy: ExclusionPolicy(),
                                                          limits: PDFExtractionLimits(maxPages: 2, maxFileBytes: nil))
                let failSummary = strictPagesEngine.importManifest(manifest, originalRoot: origDir, ocrRoot: ocrDir)
                try expectEqual(failSummary.pairsFailed, 1)
                try expectEqual(failSummary.pairsImported, 0)

                // Engine with lifted limit -> succeeds
                let okEngine = OCRIndexingEngine(store: store, policy: ExclusionPolicy(),
                                                 limits: PDFExtractionLimits(maxPages: nil, maxFileBytes: nil))
                let okSummary = okEngine.importManifest(manifest, originalRoot: origDir, ocrRoot: ocrDir)
                try expectEqual(okSummary.pairsImported, 1)
                try expectEqual(okSummary.pairsFailed, 0)
                try expectEqual(okSummary.pagesImported, 3)
            },

            TestDesc(suite: "Regression", name: "utf8MatchingParityWithLegacyMatches") {
                let testPages: [String] = [
                    // Mixed CJK + Latin + diacritics + ligatures + sharp-S + fullwidth + numbers
                    """
                    在知识生产的流程之中，伪劣知识充斥知识市场。法律难题第42条：\
                    the rule of recognition and Rechtsstaat für sięños búsqueda. \
                    Übergröße, Straße und STRASSE! ＡＢＣ fi ﬁ.
                    """,
                    // Pure CJK with repeating and boundary-crossing sequences
                    "一二三四五六七八九十一二三四五，测试边界与多字节重叠：计算理论与计算方法，知行合一知知知。",
                    // English / Latin with special boundaries, punctuation, repeated tokens
                    "alpha beta gamma alpha alpha beta delta and some words: recognized recognition recognize.",
                    // Boundary cases with multi-byte characters mixed directly with ASCII (no space)
                    "pre前缀word中字post后缀12345end结尾，符号混合：[测试] (括号) 【中文】"
                ]

                let testQueries: [[String]] = [
                    // CJK occurrences & multiple hits
                    ["知识"],
                    ["法律"],
                    ["难题"],
                    ["第42条"],
                    ["生产"],
                    ["知"],
                    // Latin & diacritics & casing & NFKC
                    ["rule"],
                    ["rechtsstaat"],
                    ["fur"],
                    ["sienos"],
                    ["busqueda"],
                    ["ubergrosse"],
                    ["strasse"],
                    ["fi"],
                    ["abc"],
                    // Multi-term AND queries
                    ["知识", "法律"],
                    ["rule", "recognition"],
                    ["一二", "三四五"],
                    ["计算理论", "计算方法"],
                    // Boundary-adjacent hits (ASCII glued to CJK)
                    ["pre前缀word"],
                    ["word中字post"],
                    ["post后缀12345end"],
                    ["测试"],
                    ["括号"],
                    ["中文"],
                    // Non-matching queries
                    ["不存在的词汇"],
                    ["nonexistent"]
                ]

                for (pageIdx, textOriginal) in testPages.enumerated() {
                    let norm = normalizeForSearch(textOriginal)
                    let page = IndexStore.PageRow(
                        bookID: "b_parity_\(pageIdx)",
                        pageNumber: pageIdx + 1,
                        textOriginal: textOriginal,
                        textNorm: norm.text,
                        normStarts: norm.starts,
                        normEnds: norm.ends
                    )

                    for queryTerms in testQueries {
                        let legacyMatches = SearchService.legacyMatches(page: page, terms: queryTerms)
                        let utf8Matches = SearchService.utf8Matches(page: page, terms: queryTerms)

                        // Strict parity assertion: identical count, order, and elements
                        try expectEqual(legacyMatches, utf8Matches,
                                        "Matches must be strictly equal for page \(pageIdx), terms: \(queryTerms)")

                        let legacySet = Set(legacyMatches)
                        let utf8Set = Set(utf8Matches)
                        let diffLegacyToUtf8 = legacySet.subtracting(utf8Set)
                        let diffUtf8ToLegacy = utf8Set.subtracting(legacySet)
                        try expectTrue(diffLegacyToUtf8.isEmpty,
                                       "Legacy produced matches missing from UTF-8: \(diffLegacyToUtf8)")
                        try expectTrue(diffUtf8ToLegacy.isEmpty,
                                       "UTF-8 produced matches missing from legacy: \(diffUtf8ToLegacy)")
                    }
                }
            },

            //GUI 侧 OCR 导入与复查同走
            // runOCREngine，purge-only 复查（pairsImported==0、pairsStalePurged>0）
            // 一样把 OCR 页翻回 native，门控必须含失效清除数——只看导入数会漏刷
            // bigram/native 计数与「索引就绪后自动上传」。AppState 属 App 可执行
            // 目标，不在 SwiftPM 测试内，故以源文本守卫断言住两处门控（同
            // ShareReceiveTests 源码守卫基准；非行为测试，行为面靠 CLI 同型修复）。
            TestDesc(suite: "Regression", name: "ocrRefreshGateIncludesPurgeOnly") {
                let repoRoot = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                let text = try String(contentsOf: repoRoot.appendingPathComponent(
                    "Sources/LiteratureSearchApp/AppState.swift"), encoding: .utf8)
                let gate = "if summary.pairsImported > 0 || summary.pairsStalePurged > 0"
                let legacy = "if summary.pairsImported > 0 {"
                try expectFalse(text.contains(legacy),
                                "AppState 不得残留只看导入数的旧门控（purge-only 复查会漏刷索引/计数）")
                try expectEqual(text.components(separatedBy: gate).count - 1, 2,
                                "两处 OCR 门控（索引刷新＋自动上传）都必须含 pairsStalePurged")
            },
        ]
    }
}
