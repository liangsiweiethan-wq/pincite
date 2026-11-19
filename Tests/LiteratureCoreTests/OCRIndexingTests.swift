import Foundation
import CoreGraphics
@testable import LiteratureCore


enum OCRIndexingSuite {
    static var tests: [TestDesc] { [
        TestDesc(suite: "OCRIndexing", name: "end-to-end: Chinese search hits original page with OCR provenance; native kept; original untouched", body: endToEnd),
        TestDesc(suite: "OCRIndexing", name: "rejections: page-count mismatch, out-of-bounds, duplicates, offset, policy, symlink escape, unindexed original", body: rejections),
        TestDesc(suite: "OCRIndexing", name: "staleness: changed OCR or original file -> sweep purges pairing, old references die", body: staleness),
        TestDesc(suite: "OCRIndexing", name: "migration: v3 reopen keeps native books/pages; native and OCR coexist", body: migration),
    ] }

    // MARK: helpers

    static func textlessPage() -> SyntheticPDFPage {
        SyntheticPDFPage(lines: [], textlessDrawing: true)
    }

    static func writeManifest(_ json: String, in dir: URL, named: String = "pairs.json") -> URL {
        let url = dir.appendingPathComponent(named)
        try! Data(json.utf8).write(to: url)
        return url
    }

    @discardableResult
    static func addNativeBook(_ store: IndexStore, id: String, name: String, pages: [String]) throws -> IndexStore.BookRow {
        let book = IndexStore.BookRow(
            id: id, realPath: "/tmp/lit-tests/\(name)", rootPath: "/tmp/lit-tests",
            relPath: name, fileName: name,
            title: nil, author: nil, version: nil, language: nil, metaSource: nil,
            firstFingerprint: "fp-\(id)", fingerprint: "fp-\(id)", fileSize: 1, mtime: 0,
            pageCount: pages.count, status: "ok", error: nil, indexedAt: 0)
        try store.upsertBook(book)
        var rows: [IndexStore.PageRow] = []
        for (i, text) in pages.enumerated() {
            let n = normalizeForSearch(text)
            rows.append(IndexStore.PageRow(bookID: id, pageNumber: i + 1, label: nil, printedPage: nil,
                                           textOriginal: text, textNorm: n.text,
                                           normStarts: n.starts, normEnds: n.ends))
        }
        try store.replacePages(bookID: id, rows)
        return book
    }

    // MARK: end-to-end

    static func endToEnd() async throws {
        let dir = Fixtures.makeTempDir("ocr-e2e")
        defer { Fixtures.cleanup(dir) }
        let origRoot = dir.appendingPathComponent("original", isDirectory: true)
        let ocrRoot = dir.appendingPathComponent("ocr", isDirectory: true)
        try FileManager.default.createDirectory(at: origRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ocrRoot, withIntermediateDirectories: true)

        // Scan book: 3 physical pages, graphics only (no text layer).
        let scanURL = Fixtures.makePDF(pages: [textlessPage(), textlessPage(), textlessPage()],
                                       in: origRoot, named: "scan-book.pdf")
        let scanBytesBefore = try Data(contentsOf: scanURL)
        // Native control book: page 1 has a real native text layer, page 2 is scanned.
        _ = Fixtures.makePDF(pages: [SyntheticPDFPage(lines: ["本土文字层：河西志异"]),
                                     textlessPage()],
                             in: origRoot, named: "native-book.pdf")

        // OCR text PDFs (already carry a text layer — this tool performs no OCR).
        // Deliberately SHUFFLED page order: explicit mapping 1->2, 2->3, 3->1.
        _ = Fixtures.makePDF(pages: [
            SyntheticPDFPage(lines: ["橘子洲头按语（原件第三页）"]),
            SyntheticPDFPage(lines: ["敦煌文献研究札记（原件第一页）"]),
            SyntheticPDFPage(lines: ["丝绸之路商队记录（原件第二页）"]),
        ], in: ocrRoot, named: "scan-book-ocr.pdf")
        _ = Fixtures.makePDF(pages: [
            SyntheticPDFPage(lines: ["本土文字层：河西志异（OCR重复件，不得并入）"]),
            SyntheticPDFPage(lines: ["补充扫描文字：月氏迁徙"]),
        ], in: ocrRoot, named: "native-book-ocr.pdf")

        let manifestURL = writeManifest("""
        {"pairs":[
          {"originalPath":"scan-book.pdf","ocrPath":"scan-book-ocr.pdf",
           "mapping":{"type":"explicit","pages":[{"original":1,"ocr":2},{"original":2,"ocr":3},{"original":3,"ocr":1}]}},
          {"originalPath":"native-book.pdf","ocrPath":"native-book-ocr.pdf",
           "mapping":{"type":"same-page-verified"}}
        ]}
        """, in: dir)

        let policy = ExclusionPolicy()
        let store = try Fixtures.openStore(in: dir)
        let engine = IndexingEngine(store: store, policy: policy)
        let indexSummary = try await engine.run(rootURL: origRoot)
        try expectEqual(indexSummary.indexedNew, 2)

        // Before OCR: the scan book is honestly needs-ocr (0 pages with text).
        let statsBefore = try store.perBookPageStats()
        let scanStatBefore = statsBefore.first { $0.pagesWithText == 0 && $0.indexedPages == 3 }
        try expectNotNil(scanStatBefore, "scan book should be indexed with 3 textless pages")

        let manifest = try OCRPairManifest.parse(try Data(contentsOf: manifestURL))
        let ocrEngine = OCRIndexingEngine(store: store, policy: policy)
        let summary = ocrEngine.importManifest(manifest, originalRoot: origRoot, ocrRoot: ocrRoot)
        try expectEqual(summary.pairsTotal, 2)
        try expectEqual(summary.pairsImported, 2, "both pairs should import")
        try expectEqual(summary.pairsRejected, 0)
        try expectEqual(summary.pagesImported, 4, "3 scan pages + 1 scanned page of native book")
        try expectEqual(summary.pagesKeptNative, 1, "native page 1 keeps its native text")

        // The OCR files themselves never become books.
        let allBooks = try store.allBooks()
        try expectEqual(allBooks.count, 2)
        try expectEqual(try store.allOCRBooks().count, 2)

        // Original PDF byte-identical: OCR import is strictly read-only.
        try expectEqual(try Data(contentsOf: scanURL), scanBytesBefore, "original pdf must not be written")

        let service = SearchService(store: store, policy: policy)

        // Chinese term on OCR page 2 must resolve to ORIGINAL page 1 (explicit mapping).
        let hitsDunhuang = try service.search("敦煌文献")
        try expectEqual(hitsDunhuang.count, 1)
        let h1 = hitsDunhuang[0]
        try expectEqual(h1.source, "ocr")
        try expectEqual(h1.physicalPage, 1, "hit page is the ORIGINAL physical page, not the OCR page")
        try expectEqual(h1.ocrPage, 2)
        try expectNotNil(h1.ocrFilePath)
        try expectNotNil(h1.ocrFingerprint)
        try expectTrue(h1.snippet.contains("敦煌"), "snippet comes from the OCR text")

        // Shuffled mapping: OCR page 3 -> original page 2; OCR page 1 -> original page 3.
        let hitsSilk = try service.search("丝绸之路")
        try expectEqual(hitsSilk.count, 1)
        try expectEqual(hitsSilk[0].physicalPage, 2)
        try expectEqual(hitsSilk[0].ocrPage, 3)
        let hitsOrange = try service.search("橘子洲头")
        try expectEqual(hitsOrange.count, 1)
        try expectEqual(hitsOrange[0].physicalPage, 3)
        try expectEqual(hitsOrange[0].ocrPage, 1)

        // Native control: scanned page 2 got OCR text; native page 1 keeps its version.
        let hitsSupplement = try service.search("补充扫描文字")
        try expectEqual(hitsSupplement.count, 1)
        try expectEqual(hitsSupplement[0].source, "ocr")
        try expectEqual(hitsSupplement[0].physicalPage, 2)
        try expectEqual(hitsSupplement[0].ocrPage, 2)
        let hitsNative = try service.search("河西志异")
        try expectEqual(hitsNative.count, 1, "OCR duplicate text of a native page must NOT be imported")
        try expectEqual(hitsNative[0].source, "native")
        try expectNil(hitsNative[0].ocrPage)
        try expectNil(hitsNative[0].ocrFingerprint)

        // Coverage is honest afterwards: the scan book now has searchable text.
        let statsAfter = try store.perBookPageStats()
        let scanStatAfter = statsAfter.first { $0.indexedPages == 3 }
        try expectNotNil(scanStatAfter)
        try expectEqual(scanStatAfter!.pagesWithText, 3)
    }

    // MARK: rejections

    static func rejections() async throws {
        let dir = Fixtures.makeTempDir("ocr-reject")
        defer { Fixtures.cleanup(dir) }
        let origRoot = dir.appendingPathComponent("original", isDirectory: true)
        let ocrRoot = dir.appendingPathComponent("ocr", isDirectory: true)
        try FileManager.default.createDirectory(at: origRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ocrRoot, withIntermediateDirectories: true)

        // A: same-page-verified but page counts differ (2 vs 3).
        _ = Fixtures.makePDF(pages: [textlessPage(), textlessPage()], in: origRoot, named: "a-scan.pdf")
        _ = Fixtures.makePDF(pages: [SyntheticPDFPage(lines: ["甲"]), SyntheticPDFPage(lines: ["乙"]), SyntheticPDFPage(lines: ["丙"])],
                             in: ocrRoot, named: "a-ocr.pdf")
        // B: explicit mapping out of bounds (original page 9 of a 3-page book).
        _ = Fixtures.makePDF(pages: [textlessPage(), textlessPage(), textlessPage()], in: origRoot, named: "b-scan.pdf")
        _ = Fixtures.makePDF(pages: [SyntheticPDFPage(lines: ["甲"]), SyntheticPDFPage(lines: ["乙"])],
                             in: ocrRoot, named: "b-ocr.pdf")
        // C: policy-excluded file (explicit config excludes "Drafts-c"; the
        // exclusion comes from the policy's own configuration here).
        _ = Fixtures.makePDF(pages: [textlessPage()], in: origRoot, named: "Drafts-c-scan.pdf")
        _ = Fixtures.makePDF(pages: [SyntheticPDFPage(lines: ["甲"])], in: ocrRoot, named: "c-ocr.pdf")
        // D: OCR file is a symlink escaping the ocr root.
        _ = Fixtures.makePDF(pages: [textlessPage()], in: origRoot, named: "d-scan.pdf")
        let outsideDir = dir.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        let outsideOCR = Fixtures.makePDF(pages: [SyntheticPDFPage(lines: ["越界文字"])], in: outsideDir, named: "real-d-ocr.pdf")
        _ = Fixtures.makeSymlink(to: outsideOCR, in: ocrRoot, named: "d-ocr.pdf")

        let policy = ExclusionPolicy(config: ExclusionConfig(excludedPathSubstrings: ["Drafts-c"]))
        let store = try Fixtures.openStore(in: dir)
        let engine = IndexingEngine(store: store, policy: policy)
        let indexSummary = try await engine.run(rootURL: origRoot)
        try expectEqual(indexSummary.indexedNew, 3, "a/b/d indexed; Drafts-c excluded by explicit config")

        // E: original exists on disk but was never indexed (created after the run).
        _ = Fixtures.makePDF(pages: [textlessPage()], in: origRoot, named: "e-scan.pdf")
        _ = Fixtures.makePDF(pages: [SyntheticPDFPage(lines: ["甲"])], in: ocrRoot, named: "e-ocr.pdf")

        let manifestURL = writeManifest("""
        {"pairs":[
          {"originalPath":"a-scan.pdf","ocrPath":"a-ocr.pdf","mapping":{"type":"same-page-verified"}},
          {"originalPath":"b-scan.pdf","ocrPath":"b-ocr.pdf",
           "mapping":{"type":"explicit","pages":[{"original":1,"ocr":1},{"original":9,"ocr":2}]}},
          {"originalPath":"Drafts-c-scan.pdf","ocrPath":"c-ocr.pdf","mapping":{"type":"same-page-verified"}},
          {"originalPath":"d-scan.pdf","ocrPath":"d-ocr.pdf","mapping":{"type":"same-page-verified"}},
          {"originalPath":"e-scan.pdf","ocrPath":"e-ocr.pdf","mapping":{"type":"same-page-verified"}}
        ]}
        """, in: dir)

        let manifest = try OCRPairManifest.parse(try Data(contentsOf: manifestURL))
        let ocrEngine = OCRIndexingEngine(store: store, policy: policy)
        let summary = ocrEngine.importManifest(manifest, originalRoot: origRoot, ocrRoot: ocrRoot)
        try expectEqual(summary.pairsTotal, 5)
        try expectEqual(summary.pairsRejected, 5, "every malformed/excluded/unindexed pair must be rejected")
        try expectEqual(summary.pairsImported, 0)
        try expectEqual(try store.allOCRBooks().count, 0, "no rejected pair may leave a registration behind")
        let zero = try SearchService(store: store, policy: policy).searchDetailed("越界文字").totalPageMatches
        try expectEqual(zero, 0, "symlink-escaped OCR text must stay unreachable")

        // Parse-level strictness: duplicate page numbers and fixed-offset mappings.
        try expectThrows(try OCRPairManifest.parse(Data(
            #"{"pairs":[{"originalPath":"a.pdf","ocrPath":"b.pdf","mapping":{"type":"explicit","pages":[{"original":1,"ocr":1},{"original":1,"ocr":2}]}}]}"#.utf8)),
            "duplicate original page must be rejected at parse time")
        try expectThrows(try OCRPairManifest.parse(Data(
            #"{"pairs":[{"originalPath":"a.pdf","ocrPath":"b.pdf","mapping":{"type":"explicit","pages":[{"original":1,"ocr":1},{"original":2,"ocr":1}]}}]}"#.utf8)),
            "duplicate ocr page must be rejected at parse time")
        try expectThrows(try OCRPairManifest.parse(Data(
            #"{"pairs":[{"originalPath":"a.pdf","ocrPath":"b.pdf","mapping":{"type":"fixed-offset","offset":1}}]}"#.utf8)),
            "fixed-offset mapping must be rejected at parse time")
    }

    // MARK: staleness

    static func staleness() async throws {
        let dir = Fixtures.makeTempDir("ocr-stale")
        defer { Fixtures.cleanup(dir) }
        let origRoot = dir.appendingPathComponent("original", isDirectory: true)
        let ocrRoot = dir.appendingPathComponent("ocr", isDirectory: true)
        try FileManager.default.createDirectory(at: origRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ocrRoot, withIntermediateDirectories: true)

        let scanURL = Fixtures.makePDF(pages: [textlessPage(), textlessPage()], in: origRoot, named: "s-scan.pdf")
        Fixtures.makePDF(pages: [SyntheticPDFPage(lines: ["甲编序跋文字"]), SyntheticPDFPage(lines: ["乙编图录说明"])],
                         in: ocrRoot, named: "s-ocr.pdf")

        let policy = ExclusionPolicy()
        let store = try Fixtures.openStore(in: dir)
        _ = try await IndexingEngine(store: store, policy: policy).run(rootURL: origRoot)

        let manifestURL = writeManifest("""
        {"pairs":[{"originalPath":"s-scan.pdf","ocrPath":"s-ocr.pdf","mapping":{"type":"same-page-verified"}}]}
        """, in: dir)
        let manifest = try OCRPairManifest.parse(try Data(contentsOf: manifestURL))
        let ocrEngine = OCRIndexingEngine(store: store, policy: policy)
        let first = ocrEngine.importManifest(manifest, originalRoot: origRoot, ocrRoot: ocrRoot)
        try expectEqual(first.pairsImported, 1)

        let service = SearchService(store: store, policy: policy)
        let hits = try service.search("甲编序跋")
        try expectEqual(hits.count, 1)
        try expectEqual(hits[0].source, "ocr")

        // Unchanged sweep: everything verified, nothing purged.
        let cleanSweep = ocrEngine.verifyRegisteredPairs()
        try expectEqual(cleanSweep.pairsVerified, 1)
        try expectEqual(cleanSweep.pairsStalePurged, 0)

        // OCR file changes (page count AND content): sweep must purge the pairing.
        _ = Fixtures.makePDF(pages: [SyntheticPDFPage(lines: ["甲编序跋文字改"]), SyntheticPDFPage(lines: ["乙编图录说明改"]), SyntheticPDFPage(lines: ["丙编新增"])],
                             in: ocrRoot, named: "s-ocr.pdf")
        let staleSweep = ocrEngine.verifyRegisteredPairs()
        try expectEqual(staleSweep.pairsStalePurged, 1, "changed OCR file must purge the pairing")
        try expectEqual(try store.allOCRBooks().count, 0)

        // Old references die: the page is textless again, search explains zero hits.
        let result = try service.searchDetailed("甲编序跋")
        try expectEqual(result.totalPageMatches, 0)
        let explanation = try expectNotNil(result.zeroHitExplanation)
        try expectTrue(explanation.books.contains { $0.reason == .noTextLayer },
                       "purged book must be explained as no-text-layer again")
        let allBooks = try store.allBooks()
        let scanBook = allBooks.first { $0.fileName == "s-scan.pdf" }
        try expectNotNil(scanBook)
        let page1 = try store.page(bookID: scanBook!.id, pageNumber: 1)
        try expectNotNil(page1)
        try expectTrue(page1!.textNorm.isEmpty, "purged OCR text must be restored to textless")

        // Re-import against a NEW explicit mapping (OCR now has 3 pages, original 2).
        let manifest2URL = writeManifest("""
        {"pairs":[{"originalPath":"s-scan.pdf","ocrPath":"s-ocr.pdf",
                   "mapping":{"type":"explicit","pages":[{"original":1,"ocr":1},{"original":2,"ocr":2}]}}]}
        """, in: dir)
        let manifest2 = try OCRPairManifest.parse(try Data(contentsOf: manifest2URL))
        let reimport = ocrEngine.importManifest(manifest2, originalRoot: origRoot, ocrRoot: ocrRoot)
        try expectEqual(reimport.pairsImported, 1)
        let hits2 = try service.search("甲编序跋")
        try expectEqual(hits2.count, 1)
        try expectEqual(hits2[0].ocrPage, 1)

        // ORIGINAL file changes: the pairing is purged by the sweep, old refs die.
        let originalBytes = try Data(contentsOf: scanURL)
        try SyntheticPDFMaker.write(pages: [textlessPage(), textlessPage()], to: scanURL,
                                    pageSize: CGSize(width: 595, height: 842)) // different bytes
        try expectNotEqual(try Data(contentsOf: scanURL), originalBytes)
        let origStaleSweep = ocrEngine.verifyRegisteredPairs()
        try expectEqual(origStaleSweep.pairsStalePurged, 1, "changed original must purge the pairing")
        try expectTrue(origStaleSweep.outcomes.contains { $0.status == "stale-purged" && $0.detail.contains("original") },
                       "the purge reason must name the original-file mismatch")
        try expectEqual(try service.searchDetailed("甲编序跋").totalPageMatches, 0)
    }

    // MARK: migration / coexistence

    static func migration() async throws {
        let dir = Fixtures.makeTempDir("ocr-migrate")
        defer { Fixtures.cleanup(dir) }

        // "Old" database content written through the public API only.
        let store = try Fixtures.openStore(in: dir)
        try addNativeBook(store, id: "b-old", name: "old-native.pdf",
                          pages: ["旧库原生文字第一章", "第二章 旧库正文"])
        try expectEqual(try store.allBooks().count, 1)

        let origRoot = dir.appendingPathComponent("original", isDirectory: true)
        let ocrRoot = dir.appendingPathComponent("ocr", isDirectory: true)
        try FileManager.default.createDirectory(at: origRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ocrRoot, withIntermediateDirectories: true)
        _ = Fixtures.makePDF(pages: [textlessPage(), textlessPage()], in: origRoot, named: "m-scan.pdf")
        _ = Fixtures.makePDF(pages: [SyntheticPDFPage(lines: ["新配对OCR文字甲"]), SyntheticPDFPage(lines: ["旧库正文新印"])],
                             in: ocrRoot, named: "m-ocr.pdf")

        // Reopen (migration re-runs, idempotent) and index + import alongside the old data.
        let store2 = try Fixtures.openStore(in: dir)
        try expectEqual(try store2.metaValue("schema_version") ?? "nil", String(IndexStore.currentSchemaVersion))
        let policy = ExclusionPolicy()
        _ = try await IndexingEngine(store: store2, policy: policy).run(rootURL: origRoot)
        let manifestURL = writeManifest("""
        {"pairs":[{"originalPath":"m-scan.pdf","ocrPath":"m-ocr.pdf","mapping":{"type":"same-page-verified"}}]}
        """, in: dir)
        let manifest = try OCRPairManifest.parse(try Data(contentsOf: manifestURL))
        let summary = OCRIndexingEngine(store: store2, policy: policy)
            .importManifest(manifest, originalRoot: origRoot, ocrRoot: ocrRoot)
        try expectEqual(summary.pairsImported, 1)

        // Old native book/pages fully intact, still searchable, still native.
        try expectEqual(try store2.allBooks().count, 2, "existing bibliography must survive")
        let oldPage = try store2.page(bookID: "b-old", pageNumber: 2)
        try expectNotNil(oldPage)
        try expectTrue(oldPage!.textNorm.contains("旧库正文"), "native text must survive migration + OCR import")
        let service = SearchService(store: store2, policy: policy)
        let shared = try service.searchDetailed("旧库正文")
        try expectEqual(shared.totalPageMatches, 2, "one native hit + one OCR hit, side by side")
        let sources = Set(shared.hits.map(\.source))
        try expectEqual(sources, Set(["native", "ocr"]), "the two versions must stay distinguishable")
        let nativeHit = shared.hits.first { $0.source == "native" }
        try expectNotNil(nativeHit)
        try expectEqual(nativeHit!.bookID, "b-old")
        let ocrHit = shared.hits.first { $0.source == "ocr" }
        try expectNotNil(ocrHit)
        try expectEqual(ocrHit!.physicalPage, 2, "OCR hit keeps the original physical page")
    }
}
