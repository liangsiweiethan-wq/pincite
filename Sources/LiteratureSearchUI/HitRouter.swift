import Foundation
// macOS Xcode builds link LiteratureCore as a library; iOS/watch app targets
// compile the core sources directly into the same target (widget pattern), so
// the import exists only when the module does.
#if canImport(LiteratureCore)
import LiteratureCore
#endif

// MARK: - UI routing (pure, extracted for synthetic tests)
//
// Every "which file/page/ranges/fingerprints does this hit open in" decision
// lives here, free of I/O, so the test suite can verify OCR/native routing
// without launching the app or touching real books. The invariants:
//   - an OCR hit is DISPLAYED in the OCR file, at the OCR file's page, with
//     highlight ranges that belong to the OCR page text only;
//   - "open the original" is a separate view: original file, original physical
//     page, and NO highlights (OCR coordinates are never mapped back);
//   - an OCR hit without a complete pairing (file/page/fingerprint) fails
//     closed and is not displayable;
//   - AI previews carry the full provenance (source + ocrPage), so the user
//     sees exactly which file an excerpt came from BEFORE confirming a send.

public enum HitRouter {
    public struct OpenSpec: Equatable {
        public let fileURL: URL
        public let physicalPage: Int
        public let highlightRanges: [Range<Int>]
        public let expectedFingerprint: String
        /// Second file that must ALSO fingerprint-verify (OCR pair: the original).
        public let companionFileURL: URL?
        public let companionFingerprint: String?
        public let showsOCRText: Bool
    }

    /// The view a hit opens in by default: OCR-sourced text is shown in the OCR
    /// pdf (highlights on the OCR page only); native text in the original.
    public static func primaryOpenSpec(for hit: SearchHit) -> OpenSpec? {
        let ranges = hit.matches.map(\.originalUTF16Range)
        if hit.source == "ocr" {
            guard let ocrPath = hit.ocrFilePath, let ocrPage = hit.ocrPage, let ocrFP = hit.ocrFingerprint else {
                return nil // fail closed: incomplete pairing is not displayable
            }
            return OpenSpec(fileURL: URL(fileURLWithPath: ocrPath), physicalPage: ocrPage,
                            highlightRanges: ranges, expectedFingerprint: ocrFP,
                            companionFileURL: URL(fileURLWithPath: hit.filePath),
                            companionFingerprint: hit.fingerprint, showsOCRText: true)
        }
        return OpenSpec(fileURL: URL(fileURLWithPath: hit.filePath), physicalPage: hit.physicalPage,
                        highlightRanges: ranges, expectedFingerprint: hit.fingerprint,
                        companionFileURL: nil, companionFingerprint: nil, showsOCRText: false)
    }

    /// Explicit "open the ORIGINAL at its own physical page". For an OCR hit the
    /// highlight ranges are OCR-file coordinates and are NEVER applied here.
    public static func originalOpenSpec(for hit: SearchHit) -> OpenSpec {
        let isOCR = hit.source == "ocr"
        return OpenSpec(fileURL: URL(fileURLWithPath: hit.filePath), physicalPage: hit.physicalPage,
                        highlightRanges: isOCR ? [] : hit.matches.map(\.originalUTF16Range),
                        expectedFingerprint: hit.fingerprint,
                        companionFileURL: isOCR ? hit.ocrFilePath.map { URL(fileURLWithPath: $0) } : nil,
                        companionFingerprint: isOCR ? hit.ocrFingerprint : nil,
                        showsOCRText: false)
    }

    /// Full provenance for the send preview: source + ocrPage actually passed.
    public static func previewSelection(for hit: SearchHit) -> AIPreview.Selection {
        AIPreview.Selection(bookID: hit.bookID, fingerprint: hit.fingerprint,
                            physicalPage: hit.physicalPage, snippet: hit.snippet,
                            source: hit.source, ocrPage: hit.ocrPage)
    }

    /// Provenance shown BEFORE a send: for OCR text the preview names BOTH the
    /// original physical page and the OCR file page the excerpt came from.
    public static func previewProvenanceText(_ s: AIPreview.Selection) -> String {
        if s.source == "ocr" {
            return "书目: \(s.bookID) · 原件物理页 \(s.physicalPage) · \(L10n.ocrFilePage) \(s.ocrPage.map(String.init) ?? "未知")（来源: OCR 文字层）"
        }
        return "书目: \(s.bookID) · 物理页: \(s.physicalPage)（来源: 原生文字层）"
    }

    /// Pure part of the pre-open/pre-send guard (policy is checked separately).
    /// Fail closed: an OCR hit whose OCR fingerprint is unknown is rejected.
    public static func fingerprintGuard(isOCR: Bool, originalMatches: Bool, ocrMatches: Bool?) -> String? {
        if !originalMatches {
            return "打开/发送前复查失败：原件内容已变化（指纹不匹配），引用已拒绝"
        }
        if isOCR {
            guard let m = ocrMatches, m else {
                return "打开/发送前复查失败：OCR 文件缺失或内容已变化（指纹不匹配），该 OCR 引用已拒绝"
            }
        }
        return nil
    }

    public static func sourceBadge(for hit: SearchHit) -> String {
        hit.source == "ocr" ? L10n.sourceOCR : L10n.sourceNative
    }

    /// Source badge from a raw source string (group headers / rows).
    public static func sourceBadgeText(_ source: String) -> String {
        source == "ocr" ? L10n.sourceOCR : L10n.sourceNative
    }

    /// Zero-hit explanation → display lines (summary first, then per book).
    public static func zeroHitLines(_ e: ZeroHitExplanation) -> [String] {
        var lines = [e.summary]
        for b in e.books {
            let reason: String
            switch b.reason {
            case .noTextLayer: reason = "无文字层（未OCR，不可检索）"
            case .termNotMatched: reason = "有文字层，词未命中"
            case .excludedByPolicy: reason = "被排除策略过滤"
            case .notAssessable: reason = "无法评估（错误书目或无页行）"
            }
            lines.append("· \(b.fileName)（\(b.bookID)）：\(reason)，有文字页 \(b.pagesWithText)/\(b.indexedPages)")
        }
        return lines
    }

    public static func coverageClassificationLines(_ c: CoverageClassification) -> [String] {
        ["覆盖分类：完整文字层 \(c.booksFull) 本 · 部分 \(c.booksPartial) 本 · 无文字层(未OCR) \(c.booksNeedsOCR) 本 · 无法评估 \(c.booksUnknown) 本"]
    }

    // MARK: 检索结果按书分组（客户端派生；不改检索协议与截断语义）

    /// One book's hits, aggregated for the grouped result list. Derived purely
    /// from the flat top-N hits — the search protocol and its truncation
    /// semantics are untouched.
    public struct HitGroup: Equatable {
        public let bookID: String
        public let fileName: String
        public let title: String?
        public let author: String?
        public let version: String?
        public let language: String?
        public let pageCount: Int
        public let hits: [SearchHit]
        /// True when this group holds the COMPLETE hit list for the book
        /// (loaded via the per-book full search, not the global top-N slice).
        public var isComplete: Bool

        public init(bookID: String, fileName: String, title: String?, author: String?,
                    version: String?, language: String?, pageCount: Int,
                    hits: [SearchHit], isComplete: Bool = false) {
            self.bookID = bookID
            self.fileName = fileName
            self.title = title
            self.author = author
            self.version = version
            self.language = language
            self.pageCount = pageCount
            self.hits = hits
            self.isComplete = isComplete
        }
        /// Badge shows the common source only when ALL hits share it; mixed
        /// groups leave the badge to the per-hit rows.
        public var commonSource: String? {
            let first = hits.first?.source
            return hits.allSatisfy { $0.source == first } ? first : nil
        }
        public var totalMatches: Int { hits.reduce(0) { $0 + $1.matches.count } }
    }

    /// Groups hits by bookID. Group order: match count desc, then author, then
    /// file name (asc). Within a group: physical page asc.
    public static func groupHits(_ hits: [SearchHit]) -> [HitGroup] {
        var byBook: [String: [SearchHit]] = [:]
        var order: [String] = []
        for hit in hits {
            if byBook[hit.bookID] == nil { order.append(hit.bookID) }
            byBook[hit.bookID, default: []].append(hit)
        }
        var groups = order.map { id -> HitGroup in
            let bookHits = byBook[id]!.sorted { $0.physicalPage < $1.physicalPage }
            let first = bookHits[0]
            return HitGroup(bookID: id, fileName: first.fileName, title: first.title,
                            author: first.author, version: first.version,
                            language: first.language, pageCount: first.pageCount,
                            hits: bookHits)
        }
        groups.sort { lhs, rhs in
            if lhs.hits.count != rhs.hits.count { return lhs.hits.count > rhs.hits.count }
            let la = lhs.author ?? "", ra = rhs.author ?? ""
            if la != ra { return la < ra }
            return lhs.fileName < rhs.fileName
        }
        return groups
    }

    /// Three-track page text: physical page / page label / printed page.
    /// Unknown stays "未知" — a physical page never poses as a printed page.
    /// OCR hits append their OCR file page (coordinates belong to that file).
    public static func threeTrackPageText(for hit: SearchHit) -> String {
        threeTrackPageText(for: hit, printed: hit.printedPage)
    }

    /// 统一取页重载：printed 由调用方经 PageNumberService 解析传入
    /// （page_map 表 > pages 列两路合成），本函数零猜测。nil = 未知照实显示。
    public static func threeTrackPageText(for hit: SearchHit, printed: Int?) -> String {
        var parts: [String] = []
        parts.append("\(L10n.physicalPageTrack) \(hit.physicalPage)/\(hit.pageCount)")
        parts.append("\(L10n.pageLabelTrack) \(hit.pageLabel ?? L10n.labelUnknown)")
        parts.append("\(L10n.printedPageTrack) \(printed.map(String.init) ?? L10n.printedPageUnknown)")
        if hit.source == "ocr" {
            parts.append("\(L10n.ocrFilePage) \(hit.ocrPage.map(String.init) ?? L10n.printedPageUnknown)")
        }
        return parts.joined(separator: " · ")
    }
}
