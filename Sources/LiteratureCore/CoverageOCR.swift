import Foundation

// MARK: - Honest coverage classification (needsOCR vs partial vs full)
//
// 此前的 CoverageStats 只有一个全局 pagesWithoutText 计数，把"整本扫描无文字层"
// 和"部分页无文字层"混在一起。这里给出单书与全局的明确分类：
//   full      所有已索引页均有文字层
//   partial   部分页有、部分页无 —— 仅无文字页不可检索
//   needsOCR  已索引成功但 0 页有文字层 —— 整本对检索完全不可达（本工具不做 OCR，
//             该状态是最终状态，不是"待完成"承诺）
//   unknown   status != "ok" 或没有页行 —— 无法评估，不假装可评估

public enum BookTextCoverage: String, Equatable, Sendable {
    case full = "full"
    case partial = "partial"
    case needsOCR = "needs-ocr"
    case unknown = "unknown"
}

/// Per-book page statistics straight from the store (no content leaves the DB).
public struct BookPageStat: Equatable, Sendable {
    public var bookID: String
    public var status: String        // "ok" | "error"
    public var indexedPages: Int     // rows in pages for this book
    public var pagesWithText: Int    // rows whose normalized text is non-empty

    public init(bookID: String, status: String, indexedPages: Int, pagesWithText: Int) {
        self.bookID = bookID
        self.status = status
        self.indexedPages = indexedPages
        self.pagesWithText = pagesWithText
    }

    public var coverage: BookTextCoverage {
        guard status == "ok", indexedPages > 0 else { return .unknown }
        if pagesWithText == 0 { return .needsOCR }
        if pagesWithText < indexedPages { return .partial }
        return .full
    }
}

/// Global roll-up of per-book coverage.
public struct CoverageClassification: Equatable, Sendable {
    public var booksFull: Int
    public var booksPartial: Int
    public var booksNeedsOCR: Int
    public var booksUnknown: Int

    public init(stats: [BookPageStat]) {
        var full = 0, partial = 0, needsOCR = 0, unknown = 0
        for s in stats {
            switch s.coverage {
            case .full: full += 1
            case .partial: partial += 1
            case .needsOCR: needsOCR += 1
            case .unknown: unknown += 1
            }
        }
        booksFull = full
        booksPartial = partial
        booksNeedsOCR = needsOCR
        booksUnknown = unknown
    }
}

// MARK: - Zero-hit explanation
//
// 零命中必须可解释：无文字层（needsOCR，检索根本到不了这本书）与词确实未命中
// 是两种完全不同的事实。这里逐书给出原因；绝不声称"OCR 已完成"——本工具不做
// OCR，无文字层就是不可检索。

public struct ZeroHitExplanation: Equatable, Sendable {
    public enum BookReason: String, Equatable, Sendable {
        case noTextLayer = "no-text-layer"           // 全书 0 页有文字层 → 零命中是必然，与词无关
        case termNotMatched = "term-not-matched"     // 有文字层，词未出现在任何有文字页上
        case excludedByPolicy = "excluded-by-policy" // 候选存在但被查询时排除策略过滤
        case notAssessable = "not-assessable"        // error 书目 / 0 页行
    }

    public struct BookExplanation: Equatable, Sendable {
        public var bookID: String
        public var fileName: String
        public var indexedPages: Int
        public var pagesWithText: Int
        public var reason: BookReason
    }

    public var books: [BookExplanation]
    /// One-line human-readable summary (Chinese), e.g.
    /// "0 命中：2 本无文字层（未OCR，不可检索）；1 本有文字层但词未命中"。
    public var summary: String
}

// MARK: - OCR pair manifest (explicit, user-authored; nothing auto-detected)

public struct OCRPagePair: Equatable, Hashable, Sendable {
    /// 1-based physical page in the ORIGINAL pdf.
    public var originalPage: Int
    /// 1-based physical page in the OCR pdf.
    public var ocrPage: Int

    public init(originalPage: Int, ocrPage: Int) {
        self.originalPage = originalPage
        self.ocrPage = ocrPage
    }
}

public enum OCRPageMapping: Equatable, Sendable {
    /// User-verified statement: OCR pdf page N corresponds to original page N.
    case samePageVerified
    /// Explicit page-by-page mapping; every pair is individually stated.
    case explicit([OCRPagePair])
}

public struct OCRPairEntry: Equatable, Sendable {
    public var originalPath: String
    public var ocrPath: String
    public var mapping: OCRPageMapping

    public init(originalPath: String, ocrPath: String, mapping: OCRPageMapping) {
        self.originalPath = originalPath
        self.ocrPath = ocrPath
        self.mapping = mapping
    }
}

public struct OCRManifestError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

public struct OCRPairManifest: Equatable, Sendable {
    public var entries: [OCRPairEntry]

    public init(entries: [OCRPairEntry]) { self.entries = entries }

    /// Parses the manifest JSON:
    /// {"pairs":[{"originalPath": "...", "ocrPath": "...",
    ///            "mapping": {"type":"same-page-verified"}
    ///                     | {"type":"explicit","pages":[{"original":1,"ocr":3},...]} }]}
    /// Strictness:
    ///   - "fixed-offset"/"offset" mappings are REJECTED explicitly (an
    ///     unverified constant shift is exactly the guesswork this project
    ///     refuses to pass off as page identity);
    ///   - unknown mapping types are rejected;
    ///   - explicit mappings must be non-empty with positive, deduplicated
    ///     page numbers on both sides;
    ///   - original and ocr paths must differ.
    public static func parse(_ json: Data) throws -> OCRPairManifest {
        let obj: Any
        do { obj = try JSONSerialization.jsonObject(with: json) }
        catch { throw OCRManifestError("manifest is not valid JSON: \(error)") }
        guard let root = obj as? [String: Any], let arr = root["pairs"] as? [[String: Any]] else {
            throw OCRManifestError("manifest must be a JSON object with a non-empty 'pairs' array")
        }
        guard !arr.isEmpty else { throw OCRManifestError("manifest has no pairs") }

        var entries: [OCRPairEntry] = []
        for (i, item) in arr.enumerated() {
            guard let orig = item["originalPath"] as? String, !orig.isEmpty else {
                throw OCRManifestError("pair \(i): missing originalPath")
            }
            guard let ocr = item["ocrPath"] as? String, !ocr.isEmpty else {
                throw OCRManifestError("pair \(i): missing ocrPath")
            }
            guard orig != ocr else {
                throw OCRManifestError("pair \(i): originalPath and ocrPath are identical")
            }
            guard let map = item["mapping"] as? [String: Any] else {
                throw OCRManifestError("pair \(i): missing mapping")
            }
            let type = map["type"] as? String ?? ""
            let mapping: OCRPageMapping
            switch type {
            case "same-page-verified":
                mapping = .samePageVerified
            case "explicit":
                guard let pages = map["pages"] as? [[String: Any]], !pages.isEmpty else {
                    throw OCRManifestError("pair \(i): explicit mapping requires a non-empty 'pages' array")
                }
                var pairs: [OCRPagePair] = []
                var seenOriginal = Set<Int>()
                var seenOCR = Set<Int>()
                for p in pages {
                    guard let o = p["original"] as? Int, o >= 1 else {
                        throw OCRManifestError("pair \(i): every page mapping needs a positive 'original' page number")
                    }
                    guard let c = p["ocr"] as? Int, c >= 1 else {
                        throw OCRManifestError("pair \(i): every page mapping needs a positive 'ocr' page number")
                    }
                    guard seenOriginal.insert(o).inserted else {
                        throw OCRManifestError("pair \(i): duplicate original page \(o) in explicit mapping")
                    }
                    guard seenOCR.insert(c).inserted else {
                        throw OCRManifestError("pair \(i): duplicate ocr page \(c) in explicit mapping")
                    }
                    pairs.append(OCRPagePair(originalPage: o, ocrPage: c))
                }
                mapping = .explicit(pairs)
            case "offset", "fixed-offset":
                throw OCRManifestError("pair \(i): fixed-offset mapping is rejected — provide 'same-page-verified' or an explicit per-page 'pages' mapping")
            default:
                throw OCRManifestError("pair \(i): unknown mapping type '\(type)' — allowed: same-page-verified | explicit")
            }
            entries.append(OCRPairEntry(originalPath: orig, ocrPath: ocr, mapping: mapping))
        }
        return OCRPairManifest(entries: entries)
    }

    public struct OCRPairRejection: Equatable, Sendable {
        public var entry: OCRPairEntry
        public var reason: String
    }

    public struct OCRManifestValidation: Equatable, Sendable {
        public var accepted: [OCRPairEntry]
        public var rejected: [OCRPairRejection]
    }

    /// Structural validation. NO file content is read (stat + realpath only):
    /// both files must exist as regular files and resolve inside the allowed
    /// root. Relative manifest paths are resolved against the root.
    public func validated(rootURL: URL) -> OCRManifestValidation {
        var out = OCRManifestValidation(accepted: [], rejected: [])
        let fm = FileManager.default
        let rootReal = rootURL.resolvingSymlinksInPath().standardizedFileURL.path

        func resolved(_ p: String) -> URL {
            p.hasPrefix("/") ? URL(fileURLWithPath: p) : rootURL.appendingPathComponent(p)
        }
        func structuralProblem(_ url: URL, role: String, path: String) -> String? {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                return "\(role) file missing or not a regular file: \(path)"
            }
            let real = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard real.hasPrefix(rootReal + "/") else {
                return "\(role) resolves outside the allowed root: \(path)"
            }
            return nil
        }

        for entry in entries {
            if let why = structuralProblem(resolved(entry.originalPath), role: "original", path: entry.originalPath) {
                out.rejected.append(.init(entry: entry, reason: why))
                continue
            }
            if let why = structuralProblem(resolved(entry.ocrPath), role: "ocr", path: entry.ocrPath) {
                out.rejected.append(.init(entry: entry, reason: why))
                continue
            }
            out.accepted.append(entry)
        }
        return out
    }

    /// Full validation incl. the exclusion policy: BOTH files of a pair are
    /// policy-checked, and if EITHER is excluded the WHOLE pair is rejected —
    /// an OCR derivative of a forbidden book must never become readable by
    /// importing it through a manifest.
    public func validated(rootURL: URL, policy: ExclusionPolicy) -> OCRManifestValidation {
        var out = validated(rootURL: rootURL)
        let stillAccepted = out.accepted
        out.accepted = []
        for entry in stillAccepted {
            let origURL = Self.resolvedPath(entry.originalPath, root: rootURL)
            let ocrURL = Self.resolvedPath(entry.ocrPath, root: rootURL)
            let vOrig = policy.evaluate(candidateFileURL: origURL, rootURL: rootURL)
            let vOCR = policy.evaluate(candidateFileURL: ocrURL, rootURL: rootURL)
            if vOrig == .allowed && vOCR == .allowed {
                out.accepted.append(entry)
            } else {
                out.rejected.append(.init(
                    entry: entry,
                    reason: "exclusion policy rejects at least one of the two files; the pair is rejected as a whole"))
            }
        }
        return out
    }

    static func resolvedPath(_ p: String, root: URL) -> URL {
        p.hasPrefix("/") ? URL(fileURLWithPath: p) : root.appendingPathComponent(p)
    }
}
