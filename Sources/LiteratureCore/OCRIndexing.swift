import Foundation

// MARK: - OCR pair import & lifecycle (manifest-driven; nothing automatic)

public struct OCRPairOutcome: Equatable, Sendable {
    public var originalPath: String
    public var ocrPath: String
    /// "imported" | "skipped-unchanged" | "rejected" | "failed" | "stale-purged" | "verified"
    public var status: String
    public var detail: String
    public var pagesImported: Int
    public var pagesKeptNative: Int
    public var pagesTextless: Int

    public init(originalPath: String, ocrPath: String, status: String, detail: String,
                pagesImported: Int, pagesKeptNative: Int, pagesTextless: Int) {
        self.originalPath = originalPath
        self.ocrPath = ocrPath
        self.status = status
        self.detail = detail
        self.pagesImported = pagesImported
        self.pagesKeptNative = pagesKeptNative
        self.pagesTextless = pagesTextless
    }
}

public struct OCRImportSummary: Equatable, Sendable {
    public var pairsTotal = 0
    public var pairsImported = 0
    public var pairsSkippedUnchanged = 0
    public var pairsRejected = 0
    public var pairsFailed = 0
    public var pairsStalePurged = 0
    public var pairsVerified = 0
    public var pagesImported = 0
    public var pagesKeptNative = 0
    public var pagesTextless = 0
    public var outcomes: [OCRPairOutcome] = []

    public init() {}
}

public final class OCRIndexingEngine {
    private let store: IndexStore
    private let policy: ExclusionPolicy
    private let limits: PDFExtractionLimits

    public init(store: IndexStore, policy: ExclusionPolicy,
                limits: PDFExtractionLimits = PDFExtractionLimits()) {
        self.store = store
        self.policy = policy
        self.limits = limits
    }

    /// Deterministic validation failure (the pair is refused, the run continues).
    private struct PairRejected: Error { let reason: String }

    // MARK: Import an explicitly provided manifest against two explicit roots

    /// Imports every manifest pair. Both allowed roots are explicit caller
    /// input; nothing is scanned, auto-detected or auto-OCR'd. Rejected pairs
    /// are reported per pair — one bad pair never blocks the others.
    @discardableResult
    public func importManifest(_ manifest: OCRPairManifest, originalRoot: URL, ocrRoot: URL) -> OCRImportSummary {
        var summary = OCRImportSummary()
        summary.pairsTotal = manifest.entries.count
        for entry in manifest.entries {
            do {
                let r = try importPair(entry, originalRoot: originalRoot, ocrRoot: ocrRoot)
                summary.pagesImported += r.imported
                summary.pagesKeptNative += r.keptNative
                summary.pagesTextless += r.textless
                if r.status == "imported" { summary.pairsImported += 1 }
                if r.status == "skipped-unchanged" { summary.pairsSkippedUnchanged += 1 }
                summary.outcomes.append(OCRPairOutcome(
                    originalPath: entry.originalPath, ocrPath: entry.ocrPath,
                    status: r.status, detail: r.detail,
                    pagesImported: r.imported, pagesKeptNative: r.keptNative, pagesTextless: r.textless))
            } catch let rejection as PairRejected {
                summary.pairsRejected += 1
                summary.outcomes.append(OCRPairOutcome(
                    originalPath: entry.originalPath, ocrPath: entry.ocrPath,
                    status: "rejected", detail: rejection.reason,
                    pagesImported: 0, pagesKeptNative: 0, pagesTextless: 0))
            } catch {
                summary.pairsFailed += 1
                summary.outcomes.append(OCRPairOutcome(
                    originalPath: entry.originalPath, ocrPath: entry.ocrPath,
                    status: "failed", detail: String(describing: error),
                    pagesImported: 0, pagesKeptNative: 0, pagesTextless: 0))
            }
        }
        return summary
    }

    /// Re-validates every registered pairing against the CURRENT files:
    /// fingerprints of the original AND the OCR file, plus the exclusion policy.
    /// Any drift purges the pairing (OCR text restored to textless) so stale
    /// references die instead of silently surviving.
    @discardableResult
    public func verifyRegisteredPairs() -> OCRImportSummary {
        var summary = OCRImportSummary()
        let registered = (try? store.allOCRBooks()) ?? []
        summary.pairsTotal = registered.count
        for ob in registered {
            func outcome(_ status: String, _ detail: String) -> OCRPairOutcome {
                OCRPairOutcome(originalPath: ob.bookID, ocrPath: ob.ocrRealPath,
                               status: status, detail: detail,
                               pagesImported: 0, pagesKeptNative: 0, pagesTextless: 0)
            }
            guard let book = try? store.book(byID: ob.bookID) else {
                try? store.purgeOCR(bookID: ob.bookID)
                summary.pairsStalePurged += 1
                summary.outcomes.append(outcome("stale-purged", "original book is no longer indexed"))
                continue
            }
            var reasons: [String] = []
            if !policy.allowsBook(realPath: book.realPath, rootPath: book.rootPath, bookID: book.id) {
                reasons.append("exclusion policy now rejects this book")
            }
            if (try? Fingerprint.sha256Hex(ofFileAt: URL(fileURLWithPath: book.realPath))) != book.fingerprint {
                reasons.append("original file changed or is unreadable (fingerprint mismatch)")
            }
            if (try? Fingerprint.sha256Hex(ofFileAt: URL(fileURLWithPath: ob.ocrRealPath))) != ob.ocrFingerprint {
                reasons.append("ocr file changed or is unreadable (fingerprint mismatch)")
            }
            if reasons.isEmpty {
                summary.pairsVerified += 1
                summary.outcomes.append(outcome("verified", "both fingerprints unchanged"))
            } else {
                try? store.purgeOCR(bookID: ob.bookID)
                summary.pairsStalePurged += 1
                summary.outcomes.append(outcome("stale-purged", reasons.joined(separator: "; ")))
            }
        }
        return summary
    }

    // MARK: Per-pair import

    private func importPair(_ entry: OCRPairEntry, originalRoot: URL, ocrRoot: URL) throws
        -> (status: String, detail: String, imported: Int, keptNative: Int, textless: Int) {
        let origURL = OCRPairManifest.resolvedPath(entry.originalPath, root: originalRoot)
        let ocrURL = OCRPairManifest.resolvedPath(entry.ocrPath, root: ocrRoot)

        // Unified exclusion policy over BOTH files; either excluded => the whole
        // pair is rejected (an OCR derivative of a forbidden book must never
        // become readable through a manifest).
        let vOrig = policy.evaluate(candidateFileURL: origURL, rootURL: originalRoot)
        let vOCR = policy.evaluate(candidateFileURL: ocrURL, rootURL: ocrRoot)
        guard vOrig == .allowed, vOCR == .allowed else {
            throw PairRejected(reason: "exclusion policy rejects at least one file of the pair " +
                "(\(verdictText(vOrig)) / \(verdictText(vOCR))) — the pair is rejected as a whole")
        }

        let fm = FileManager.default
        var origIsDir: ObjCBool = false
        guard fm.fileExists(atPath: origURL.path, isDirectory: &origIsDir), !origIsDir.boolValue else {
            throw PairRejected(reason: "original file missing or not a regular file: \(entry.originalPath)")
        }
        var ocrIsDir: ObjCBool = false
        guard fm.fileExists(atPath: ocrURL.path, isDirectory: &ocrIsDir), !ocrIsDir.boolValue else {
            throw PairRejected(reason: "ocr file missing or not a regular file: \(entry.ocrPath)")
        }

        let origReal = origURL.resolvingSymlinksInPath().standardizedFileURL.path
        let ocrReal = ocrURL.resolvingSymlinksInPath().standardizedFileURL.path
        // Fingerprints of BOTH files — taken only after the policy gate.
        let origFP = try Fingerprint.sha256Hex(ofFileAt: origURL)
        let ocrFP = try Fingerprint.sha256Hex(ofFileAt: ocrURL)

        // The ORIGINAL must already be indexed, under its CURRENT fingerprint.
        guard let book = try store.book(byRealPath: origReal) else {
            throw PairRejected(reason: "original is not indexed — run `index` / `index-file` on the original root first")
        }
        guard book.status == "ok", book.fingerprint == origFP else {
            throw PairRejected(reason: "original changed since indexing (fingerprint mismatch) — " +
                "re-index the original first; the stale pairing is refused")
        }
        guard book.pageCount >= 1 else {
            throw PairRejected(reason: "original book has no indexed pages")
        }
        // One OCR file pairs with at most one book; one book holds at most one pair.
        if let other = try store.ocrBookByOCRRealPath(ocrReal), other.bookID != book.id {
            throw PairRejected(reason: "ocr file is already paired with another book (\(other.bookID))")
        }
        if let existing = try store.ocrBook(bookID: book.id),
           existing.ocrRealPath == ocrReal, existing.ocrFingerprint == ocrFP {
            return (status: "skipped-unchanged", detail: "both fingerprints unchanged",
                    imported: 0, keptNative: 0, textless: 0)
        }

        // The OCR file must already carry its own text layer; this tool performs no OCR.
        let extraction = try PDFTextExtractor.extract(url: ocrURL, limits: limits)
        let ocrPageCount = extraction.pageCount
        let originalPageCount = book.pageCount

        let pairs: [OCRPagePair]
        switch entry.mapping {
        case .samePageVerified:
            guard ocrPageCount == originalPageCount else {
                throw PairRejected(reason: "same-page declaration rejected: original has \(originalPageCount) page(s) " +
                    "but the OCR file has \(ocrPageCount) page(s)")
            }
            pairs = (1...originalPageCount).map { OCRPagePair(originalPage: $0, ocrPage: $0) }
        case .explicit(let stated):
            for p in stated {
                guard p.originalPage >= 1, p.originalPage <= originalPageCount else {
                    throw PairRejected(reason: "explicit mapping out of bounds: original page \(p.originalPage) " +
                        "(book has \(originalPageCount) page(s))")
                }
                guard p.ocrPage >= 1, p.ocrPage <= ocrPageCount else {
                    throw PairRejected(reason: "explicit mapping out of bounds: ocr page \(p.ocrPage) " +
                        "(ocr file has \(ocrPageCount) page(s))")
                }
            }
            pairs = stated
        }

        var updates: [IndexStore.OCRPageTextUpdate] = []
        var imported = 0, keptNative = 0, textless = 0
        for p in pairs {
            guard let nativeRow = try store.page(bookID: book.id, pageNumber: p.originalPage) else {
                throw PairRejected(reason: "original page \(p.originalPage) has no indexed page row")
            }
            if !nativeRow.textNorm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                keptNative += 1 // native text wins; the two versions are never mixed on one page
                continue
            }
            guard let ocrPage = extraction.pages.first(where: { $0.physicalPage == p.ocrPage }) else {
                throw PairRejected(reason: "ocr page \(p.ocrPage) missing from extraction result")
            }
            updates.append(IndexStore.OCRPageTextUpdate(
                originalPage: p.originalPage, ocrPage: p.ocrPage,
                textOriginal: ocrPage.text, textNorm: ocrPage.normalized.text,
                normStarts: ocrPage.normalized.starts, normEnds: ocrPage.normalized.ends))
            if ocrPage.normalized.text.isEmpty { textless += 1 } else { imported += 1 }
        }

        try store.applyOCRPages(
            bookID: book.id,
            ocrBook: IndexStore.OCRBookRow(
                bookID: book.id, ocrRealPath: ocrReal, ocrFingerprint: ocrFP,
                mappingKind: Self.mappingKindText(entry.mapping),
                createdAt: Date().timeIntervalSince1970),
            mapping: pairs, updates: updates)

        return (status: "imported",
                detail: "imported \(imported) ocr page(s), kept native \(keptNative), still textless \(textless)",
                imported: imported, keptNative: keptNative, textless: textless)
    }

    static func mappingKindText(_ mapping: OCRPageMapping) -> String {
        switch mapping {
        case .samePageVerified: return "same-page-verified"
        case .explicit: return "explicit"
        }
    }

    private func verdictText(_ v: ExclusionVerdict) -> String {
        switch v {
        case .allowed: return "allowed"
        case .excludedByPathSubstring(let s): return "substring:\(s)"
        case .excludedByGlob(let g): return "glob:\(g)"
        case .excludedByID(let id): return "id:\(id)"
        case .symlinkEscape: return "symlink-escape"
        case .unsupportedFileType: return "not-pdf"
        }
    }
}
