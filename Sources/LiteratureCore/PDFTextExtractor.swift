import Foundation
import PDFKit
import CoreGraphics

// MARK: - PDF text extraction
//
// Invariants:
// - `physicalPage` is the 1-based index of the page inside the PDF file.
// - `label` comes only from the PDF's own /PageLabels tree; nil = unknown.
// - `printedPage` is never guessed by heuristics; nil = unknown in v1.
// - Original text is kept verbatim for display; normalized text is derived
//   separately at index time, with UTF-16 offset maps back into the original.
public struct ExtractedPage {
    public let physicalPage: Int
    public let label: String?
    public let printedPage: Int?
    public let text: String
    public let normalized: NormalizedText
}

public struct PDFExtractionResult {
    public let pageCount: Int
    public let pages: [ExtractedPage]

    public init(pageCount: Int, pages: [ExtractedPage]) {
        self.pageCount = pageCount
        self.pages = pages
    }
}

public enum PDFExtractionError: Error, CustomStringConvertible {
    case unreadablePDF(String)
    case noPages(String)
    case missingPage(Int)
    case fileTooLarge(bytes: Int64, limit: Int64)
    case pageLimitExceeded(pages: Int, limit: Int)
    case description(String)

    public var description: String {
        switch self {
        case .unreadablePDF(let m): return "unreadable PDF: \(m)"
        case .noPages(let m): return "PDF has no readable pages: \(m)"
        case .missingPage(let n): return "missing page at physical index \(n)"
        case .fileTooLarge(let b, let l): return "file too large: \(b) bytes exceeds limit \(l)"
        case .pageLimitExceeded(let p, let l): return "page limit exceeded: \(p)+ pages exceeds limit \(l) (file recorded as failure, not partially indexed)"
        case .description(let m): return m
        }
    }
}

/// Per-file extraction bounds. Large books are NOT assumed to be instantly
/// readable; exceeding a bound is an explicit per-file failure (never a
/// partial, silently-truncated index).
///
/// 默认 2 GiB（由 1 GiB 提高）：超过 1 GiB 的合法 OCR 缓存 PDF 并不少见，
/// 旧上限会把它们误判为失败。2 GiB 仍是防呆阈值——超限显式整件拒绝，
/// 不做部分索引。大型 PDF 应按页处理，避免一次性载入内存。
public struct PDFExtractionLimits: Equatable, Sendable {
    public var maxPages: Int?
    public var maxFileBytes: Int64?

    public init(maxPages: Int? = 2000, maxFileBytes: Int64? = 2 << 30) {
        self.maxPages = maxPages
        self.maxFileBytes = maxFileBytes
    }

    public static let unlimited = PDFExtractionLimits(maxPages: nil, maxFileBytes: nil)
}

public enum PDFTextExtractor {
    /// Extracts text page by page. Pages that yield no text (e.g. scans) are
    /// still indexed as empty pages — no OCR is attempted. Labels come from the
    /// PDF's own /PageLabels declaration only; nil = unknown.
    /// Cooperative cancellation is checked on every page; limits are enforced
    /// BEFORE any content is read (bytes) and before indexing partial results.
    public static func extract(url: URL, limits: PDFExtractionLimits = PDFExtractionLimits()) throws -> PDFExtractionResult {
        if let byteLimit = limits.maxFileBytes {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            if size > byteLimit {
                throw PDFExtractionError.fileTooLarge(bytes: size, limit: byteLimit)
            }
        }
        guard let document = PDFDocument(url: url) else {
            throw PDFExtractionError.unreadablePDF(url.lastPathComponent)
        }
        let count = document.pageCount
        guard count > 0 else { throw PDFExtractionError.noPages(url.lastPathComponent) }
        if let pageLimit = limits.maxPages, count > pageLimit {
            throw PDFExtractionError.pageLimitExceeded(pages: count, limit: pageLimit)
        }

        // Only trust PDFKit labels when the file itself declares /PageLabels;
        // otherwise PDFKit fabricates 1,2,3... which this project must not pass
        // off as known information.
        let declaresLabels = PageLabelDeclaration.declaresPageLabels(fileURL: url)
        var pages: [ExtractedPage] = []
        pages.reserveCapacity(count)

        for index in 0..<count {
            try Task.checkCancellation() // per-page cooperative cancellation
            guard let page = document.page(at: index) else { continue }
            let text = page.string ?? ""
            let normalized = normalizeForSearch(text)
            pages.append(ExtractedPage(
                physicalPage: index + 1,
                label: declaresLabels ? page.label : nil,
                printedPage: nil,
                text: text,
                normalized: normalized
            ))
        }
        return PDFExtractionResult(pageCount: count, pages: pages)
    }

    /// Programmatic in-page location: maps a UTF-16 character range of the
    /// original page text to a rectangle in page space via PDFKit selections.
    /// Returns nil when the range cannot be located (caller must treat that as
    /// "no highlight", never as a guess).
    public static func selectionBounds(document: PDFDocument, physicalPage: Int, originalUTF16Range: Range<Int>) -> CGRect? {
        guard physicalPage >= 1, let page = document.page(at: physicalPage - 1) else { return nil }
        let lower = originalUTF16Range.lowerBound
        let upper = originalUTF16Range.upperBound
        guard lower >= 0, upper > lower, upper <= (page.string?.utf16.count ?? 0) else { return nil }
        let range = NSRange(location: lower, length: upper - lower)
        guard let selection = page.selection(for: range) else { return nil }
        return selection.bounds(for: page)
    }

    /// Convenience for callers that hold a URL (e.g. app open-by-path flows).
    public static func selectionBounds(fileURL: URL, physicalPage: Int, originalUTF16Range: Range<Int>) -> CGRect? {
        guard let document = PDFDocument(url: fileURL) else { return nil }
        return selectionBounds(document: document, physicalPage: physicalPage, originalUTF16Range: originalUTF16Range)
    }

    // MARK: - 缓存接入入口
    //
    // 上方 `extract(url:limits:)` 保持逐字节不动。此重载是缓存化外壳：
    // cache 命中则重建结果，未命中则照原语义抽取后落缓存（写失败不影响索引）。
    public static func extract(url: URL, limits: PDFExtractionLimits = PDFExtractionLimits(),
                               cache: ExtractionTextCache?, precomputedSHA256: String?,
                               onPageExtracted: ((Int, Int) -> Void)? = nil) throws -> PDFExtractionResult {
        if let byteLimit = limits.maxFileBytes {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            if size > byteLimit {
                throw PDFExtractionError.fileTooLarge(bytes: size, limit: byteLimit)
            }
        }
        guard let document = PDFDocument(url: url) else {
            throw PDFExtractionError.unreadablePDF(url.lastPathComponent)
        }
        let count = document.pageCount
        guard count > 0 else { throw PDFExtractionError.noPages(url.lastPathComponent) }
        if let pageLimit = limits.maxPages, count > pageLimit {
            throw PDFExtractionError.pageLimitExceeded(pages: count, limit: pageLimit)
        }

        if let cache {
            let sha = try precomputedSHA256 ?? Fingerprint.sha256Hex(ofFileAt: url)
            if let cached = cache.result(fileSHA256: sha) {
                return cached
            }
            let result = try extractUncached(document: document, url: url,
                                             limits: limits, onPageExtracted: onPageExtracted)
            do {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
                try cache.store(fileSHA256: sha, result, fileSize: size)
            } catch {
                FileHandle.standardError.write(Data(
                    "[PDFTextExtractor] 抽取缓存写入失败（本次不缓存，索引不受影响）: \(error)\n".utf8))
            }
            return result
        }
        return try extractUncached(document: document, url: url, limits: limits,
                                   onPageExtracted: onPageExtracted)
    }

    /// 缓存 miss 侧的逐页抽取（与原 `extract(url:limits:)` 循环逐行同逻辑；
    private static func extractUncached(document: PDFDocument, url: URL, limits: PDFExtractionLimits,
                                        onPageExtracted: ((Int, Int) -> Void)?) throws -> PDFExtractionResult {
        let count = document.pageCount
        // Only trust PDFKit labels when the file itself declares /PageLabels;
        // otherwise PDFKit fabricates 1,2,3... which this project must not pass
        // off as known information.
        let declaresLabels = PageLabelDeclaration.declaresPageLabels(fileURL: url)
        var pages: [ExtractedPage] = []
        pages.reserveCapacity(count)
        for index in 0..<count {
            try Task.checkCancellation() // per-page cooperative cancellation
            guard let page = document.page(at: index) else { continue }
            let text = page.string ?? ""
            let normalized = normalizeForSearch(text)
            pages.append(ExtractedPage(
                physicalPage: index + 1,
                label: declaresLabels ? page.label : nil,
                printedPage: nil,
                text: text,
                normalized: normalized
            ))
            onPageExtracted?(index + 1, text.utf16.count)   // 进度落表回调（默认 nil 零开销）
        }
        return PDFExtractionResult(pageCount: count, pages: pages)
    }
}
