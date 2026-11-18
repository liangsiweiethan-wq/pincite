import Foundation
import LiteratureCore
import LiteratureSearchUI

// MARK: - UI synthesis suite (app-layer routing only)
//
// Tests ONLY the extracted, pure UI routing/guard/display functions
// (HitRouter) plus store-backed display routing — synthetic data, no real
// books, no network, no credentials, no GUI launch. What is pinned here:
// - native hit opens the ORIGINAL at its physical page with its highlights;
// - OCR hit opens the OCR FILE at the OCR page with OCR-page highlights and
// re-verifies the ORIGINAL as companion fingerprint;
// - "open the original" for an OCR hit carries NO highlight ranges
// (OCR coordinates are never mapped onto the original page);
// - an OCR hit with incomplete pairing fails closed;
// - AI preview selections really carry source/ocrPage;
// - the pre-open/pre-send guard rejects fingerprint drift (fail closed);
// - zero-hit explanations and coverage classification render honest lines.

enum HitRouterSuite {
    static func makeHit(text: String) throws -> SearchHit {
        let (store, _) = try CoverageClassificationSuite.makeStore()
        try CoverageClassificationSuite.addBook(store, id: "b1", name: "orig.pdf", pages: [text])
        let service = SearchService(store: store)
        let hits = try service.searchDetailed("term").hits
        guard let hit = hits.first else { throw TestFailure(message: "expected a hit for synthetic term") }
        return hit
    }

    static func ocrVariant(of hit: SearchHit, ocrFile: String? = "/tmp/lit-synth/ocr.pdf",
                           ocrPage: Int? = 3, ocrFP: String? = "fp-ocr") -> SearchHit {
        var h = hit
        h.source = "ocr"
        h.ocrFilePath = ocrFile
        h.ocrPage = ocrPage
        h.ocrFingerprint = ocrFP
        return h
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "HitRouter", name: "nativeHitOpensOriginalWithItsHighlights") {
                let hit = try makeHit(text: "before term after")
                let spec = try expectNotNil(HitRouter.primaryOpenSpec(for: hit))
                try expectTrue(spec.fileURL.path.hasSuffix("orig.pdf"))
                try expectEqual(spec.physicalPage, 1)
                try expectTrue(spec.expectedFingerprint.isEmpty == false)
                try expectNil(spec.companionFileURL)
                try expectFalse(spec.showsOCRText)
                try expectTrue(!spec.highlightRanges.isEmpty, "native view keeps its highlights")
                let original = HitRouter.originalOpenSpec(for: hit)
                try expectTrue(!original.highlightRanges.isEmpty, "native original view keeps highlights")
                try expectEqual(HitRouter.sourceBadge(for: hit), L10n.sourceNative)
            },

            TestDesc(suite: "HitRouter", name: "ocrHitOpensOCRFileAtOCRPageWithOriginalCompanion") {
                let base = try makeHit(text: "before term after")
                let hit = ocrVariant(of: base)
                let spec = try expectNotNil(HitRouter.primaryOpenSpec(for: hit))
                try expectTrue(spec.fileURL.path.hasSuffix("ocr.pdf"), "OCR text is displayed in the OCR file")
                try expectEqual(spec.physicalPage, 3, "jump targets the OCR file's page")
                try expectEqual(spec.expectedFingerprint, "fp-ocr", "highlights bound to OCR fingerprint")
                try expectTrue(spec.showsOCRText)
                try expectNotNil(spec.companionFileURL, "original must re-verify as companion")
                try expectEqual(spec.companionFileURL?.path, base.filePath)
                try expectEqual(spec.companionFingerprint, base.fingerprint)
                try expectEqual(spec.highlightRanges, base.matches.map(\.originalUTF16Range))
            },

            TestDesc(suite: "HitRouter", name: "originalViewNeverAppliesOCRCoordinates") {
                let base = try makeHit(text: "before term after")
                let hit = ocrVariant(of: base)
                let original = HitRouter.originalOpenSpec(for: hit)
                try expectTrue(original.fileURL.path.hasSuffix("orig.pdf"))
                try expectEqual(original.physicalPage, base.physicalPage, "original opens at ITS OWN page")
                try expectTrue(original.highlightRanges.isEmpty,
                               "OCR coordinates are never mapped onto the original page")
                try expectEqual(original.expectedFingerprint, base.fingerprint)
                try expectEqual(original.companionFingerprint, "fp-ocr", "OCR file still re-verifies")
            },

            TestDesc(suite: "HitRouter", name: "incompleteOCRPairingFailsClosed") {
                let base = try makeHit(text: "before term after")
                try expectNil(HitRouter.primaryOpenSpec(for: ocrVariant(of: base, ocrFile: nil, ocrPage: nil, ocrFP: nil)),
                              "missing OCR file")
                try expectNil(HitRouter.primaryOpenSpec(for: ocrVariant(of: base, ocrPage: nil)),
                              "missing OCR page")
                try expectNil(HitRouter.primaryOpenSpec(for: ocrVariant(of: base, ocrFP: nil)),
                              "missing OCR fingerprint")
            },

            TestDesc(suite: "HitRouter", name: "previewSelectionCarriesOCRProvenance") {
                let base = try makeHit(text: "before term after")
                let nativeSel = HitRouter.previewSelection(for: base)
                try expectEqual(nativeSel.source, "native")
                try expectNil(nativeSel.ocrPage)
                try expectEqual(nativeSel.physicalPage, base.physicalPage)
                let sel = HitRouter.previewSelection(for: ocrVariant(of: base))
                try expectEqual(sel.source, "ocr", "source must actually reach the AI preview")
                try expectEqual(sel.ocrPage, 3, "ocrPage must actually reach the AI preview")
                try expectEqual(sel.fingerprint, base.fingerprint, "original fingerprint rides along")
                try expectTrue(HitRouter.previewProvenanceText(sel).contains("OCR 文件页 3"),
                               "preview text shows the OCR page before any send")
            },

            TestDesc(suite: "HitRouter", name: "fingerprintGuardRejectsDriftFailClosed") {
                try expectNil(HitRouter.fingerprintGuard(isOCR: false, originalMatches: true, ocrMatches: nil))
                try expectNotNil(HitRouter.fingerprintGuard(isOCR: false, originalMatches: false, ocrMatches: nil),
                                 "original drift refuses")
                try expectNil(HitRouter.fingerprintGuard(isOCR: true, originalMatches: true, ocrMatches: true))
                try expectNotNil(HitRouter.fingerprintGuard(isOCR: true, originalMatches: true, ocrMatches: false),
                                 "ocr drift refuses")
                try expectNotNil(HitRouter.fingerprintGuard(isOCR: true, originalMatches: true, ocrMatches: nil),
                                 "unknown ocr fingerprint refuses (fail closed)")
                try expectNotNil(HitRouter.fingerprintGuard(isOCR: true, originalMatches: false, ocrMatches: true),
                                 "either side drifting refuses")
            },

            TestDesc(suite: "HitRouter", name: "zeroHitAndCoverageRenderHonestLines") {
                let (store, _) = try CoverageClassificationSuite.makeStore()
                try CoverageClassificationSuite.addBook(store, id: "bA", name: "a.pdf", pages: ["alpha one"])
                try CoverageClassificationSuite.addBook(store, id: "bC", name: "c.pdf", pages: ["", ""])
                let service = SearchService(store: store)
                let zero = try service.searchDetailed("qqzzww")
                try expectTrue(zero.hits.isEmpty)
                let exp = try expectNotNil(zero.zeroHitExplanation)
                let lines = HitRouter.zeroHitLines(exp)
                try expectTrue(lines[0].contains("0 命中"), "summary line leads")
                try expectTrue(lines.contains { $0.contains("c.pdf") && $0.contains("无文字层") },
                               "no-text-layer book is named with its honest reason")
                try expectTrue(lines.contains { $0.contains("a.pdf") && $0.contains("词未命中") },
                               "term-miss book is separated from no-text-layer")
                let cls = CoverageClassification(stats: try store.perBookPageStats())
                let clines = HitRouter.coverageClassificationLines(cls)
                try expectTrue(clines[0].contains("完整文字层 1 本"))
                try expectTrue(clines[0].contains("无文字层(未OCR) 1 本"), "needsOCR is never called finished OCR")
            },
            TestDesc(suite: "HitRouter", name: "groupHitsAggregatesByBookAndSorts") {
                let (store, _) = try CoverageClassificationSuite.makeStore()
                try CoverageClassificationSuite.addBook(store, id: "b1", name: "one.pdf", pages: ["term x", "term y"])
                try CoverageClassificationSuite.addBook(store, id: "b2", name: "two.pdf", pages: ["term z"])
                let service = SearchService(store: store)
                let hits = try service.searchDetailed("term").hits
                let groups = HitRouter.groupHits(hits)
                try expectEqual(groups.count, 2)
                // More matches first (one.pdf has 2 pages, two.pdf 1).
                try expectEqual(groups[0].fileName, "one.pdf")
                try expectEqual(groups[0].hits.count, 2)
                try expectEqual(groups[0].totalMatches, 2)
                try expectEqual(groups[1].hits.count, 1)
                // Within a group: physical page ascending.
                try expectTrue(groups[0].hits[0].physicalPage <= groups[0].hits[1].physicalPage)
                try expectEqual(groups[0].commonSource, "native")
                try expectEqual(HitRouter.groupHits([]).count, 0)
            },

            TestDesc(suite: "HitRouter", name: "threeTrackPageTextShowsUnknownHonestly") {
                let base = try makeHit(text: "before term after")
                let native = HitRouter.threeTrackPageText(for: base)
                try expectTrue(native.contains("物理页 1/"), native)
                try expectTrue(native.contains("印刷页 印刷页码未知"), "printed page stays honest: \(native)")
                try expectFalse(native.contains("OCR 文件页"), "native row has no OCR track")
                let ocr = ocrVariant(of: base, ocrPage: 3)
                let ocrText = HitRouter.threeTrackPageText(for: ocr)
                try expectTrue(ocrText.contains("OCR 文件页 3"), ocrText)
                try expectTrue(HitRouter.sourceBadgeText("ocr") == L10n.sourceOCR)
                try expectTrue(HitRouter.sourceBadgeText("native") == L10n.sourceNative)
            },

            TestDesc(suite: "HitRouter", name: "searchFilterBookIDScopesToOneBook") {
                let (store, _) = try CoverageClassificationSuite.makeStore()
                try CoverageClassificationSuite.addBook(store, id: "b1", name: "one.pdf", pages: ["term here", "term again"])
                try CoverageClassificationSuite.addBook(store, id: "b2", name: "two.pdf", pages: ["term there"])
                let service = SearchService(store: store)
                let all = try service.searchDetailed("term", options: SearchOptions(limit: 10))
                try expectEqual(Set(all.hits.map(\.bookID)).count, 2)
                let scoped = try service.searchDetailed("term", options: SearchOptions(
                    limit: 10, filter: SearchFilter(bookIDEquals: "b1")))
                try expectTrue(!scoped.hits.isEmpty)
                try expectTrue(scoped.hits.allSatisfy { $0.bookID == "b1" })
                try expectEqual(scoped.hits.count, 2)
                try expectEqual(scoped.totalPageMatches, 2)
                try expectFalse(scoped.truncated)
            },
            TestDesc(suite: "HitRouter", name: "perBookLimitDiversifiesSliceAcrossBooks") {
                let (store, _) = try CoverageClassificationSuite.makeStore()
                try CoverageClassificationSuite.addBook(store, id: "b1", name: "one.pdf", pages: ["term a", "term b", "term c"])
                try CoverageClassificationSuite.addBook(store, id: "b2", name: "two.pdf", pages: ["term d", "term e", "term f"])
                try CoverageClassificationSuite.addBook(store, id: "b3", name: "three.pdf", pages: ["term g"])
                let service = SearchService(store: store)
                // Flat legacy slice: first 5 rows would all be b1+b2 by insertion order.
                let flat = try service.searchDetailed("term", options: SearchOptions(limit: 5))
                try expectEqual(flat.hits.count, 5)
                // Diversified slice: round-robin → b1,b2,b3,b1,b2 with per-book quota 2.
                let div = try service.searchDetailed("term", options: SearchOptions(limit: 5, perBookLimit: 2))
                try expectEqual(div.hits.count, 5)
                try expectEqual(div.hits[0].bookID, "b1")
                try expectEqual(div.hits[1].bookID, "b2")
                try expectEqual(div.hits[2].bookID, "b3")
                try expectEqual(div.hits[3].bookID, "b1")
                try expectEqual(div.hits[4].bookID, "b2")
                try expectTrue(div.truncated, "total 7 > 5")
                try expectEqual(div.totalPageMatches, 7)
                // Quota respected: no book exceeds 2 pages in the slice.
                var counts: [String: Int] = [:]
                for h in div.hits { counts[h.bookID, default: 0] += 1 }
                try expectEqual(counts["b1"], 2)
                try expectEqual(counts["b2"], 2)
                try expectEqual(counts["b3"], 1)
            },
            TestDesc(suite: "HitRouter", name: "citationFormatterHandlesZhEnAndPiracyTags") {
                // 中文书名形态：文件名即引注主体，追加页码。
                let zh = CitationFormatter.citation(
                    fileName: "戊己：《样书三》，子虚、乌有译，示范书局2002年版.pdf",
                    title: nil, physicalPage: 5, style: .faxueYinzhuShouce)
                try expectTrue(zh.hasSuffix("示范书局2002年版，第5页。"), zh)
                // 异版哈希后缀剥离。
                let yiban = CitationFormatter.citation(
                    fileName: "Example Author, A Sample Treatise, Example Press, 2001_异版00000001.pdf",
                    title: nil, physicalPage: 12, style: .faxueYinzhuShouce)
                try expectFalse(yiban.contains("异版"), yiban)
                try expectTrue(yiban.contains(", p. 12."), yiban)
                // 间接引用加"参见"。
                let indirect = CitationFormatter.citation(
                    fileName: "丙丁：《样书二》，子虚、乌有译，示范书局2002年版.pdf",
                    title: nil, physicalPage: 9, style: .zhongguoFaxue, indirect: true)
                try expectTrue(indirect.hasPrefix("参见"), indirect)
                try expectTrue(indirect.hasSuffix("第9页。"), indirect)
                // 书目级（无页码）。
                let book = CitationFormatter.bookCitation(
                    fileName: "Avery Quill, A Sample Treatise, Example Press, 2001.pdf", title: nil)
                try expectTrue(book.hasSuffix("2001"), book)
            },

            TestDesc(suite: "HitRouter", name: "matchingBooksAggregatesCountsAndHonorsFilter") {
                let (store, _) = try CoverageClassificationSuite.makeStore()
                try CoverageClassificationSuite.addBook(store, id: "b1", name: "one.pdf", pages: ["term a", "term b", "term c"])
                try CoverageClassificationSuite.addBook(store, id: "b2", name: "two.pdf", pages: ["term d"])
                try CoverageClassificationSuite.addBook(store, id: "b3", name: "three.pdf", pages: ["nothing here"])
                let service = SearchService(store: store)
                let books = try service.matchingBooks("term")
                try expectEqual(books.count, 2, "book with zero hits is not listed")
                try expectEqual(books[0].bookID, "b1")
                try expectEqual(books[0].matchingPages, 3)
                try expectEqual(books[1].matchingPages, 1)
                // bookIDEquals 范围过滤同样作用于书目级。
                let scoped = try service.matchingBooks("term", filter: SearchFilter(bookIDEquals: "b2"))
                try expectEqual(scoped.count, 1)
                try expectEqual(scoped[0].bookID, "b2")
            },
        ]
    }
}
