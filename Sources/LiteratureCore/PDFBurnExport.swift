import Foundation
import PDFKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif


/// 导出输入（自有库读出的四类；调用方从 HighlightStore/InkStrokesStore 组装）。
public struct BurnExportSource {
    public struct Highlight: Equatable, Sendable {
        public var pageNumber: Int          // 物理 1 起
        public var utf16Start: Int
        public var utf16End: Int
        /// #RRGGBB（HighlightColor.colorHex 同源）。
        public var colorHex: String
        /// "highlight" | "underline"（其余按 highlight 处理，如实计数）。
        public var style: String
        /// 批注文本（空 = 纯高亮）。
        public var note: String
        /// 锚文本（utf16 区间失效时的回退定位串；定位仍失败 = 跳过并计数）。
        public var anchorText: String

        public init(pageNumber: Int, utf16Start: Int, utf16End: Int,
                    colorHex: String, style: String, note: String, anchorText: String) {
            self.pageNumber = pageNumber
            self.utf16Start = utf16Start
            self.utf16End = utf16End
            self.colorHex = colorHex
            self.style = style
            self.note = note
            self.anchorText = anchorText
        }
    }

    public var highlights: [Highlight]
    /// 全书 ink 笔迹（active；墓碑行调用方排除）。
    public var inkStrokes: [InkStroke]

    public init(highlights: [Highlight], inkStrokes: [InkStroke]) {
        self.highlights = highlights
        self.inkStrokes = inkStrokes
    }
}

public struct BurnExportReport: Equatable {
    public var destination: URL
    /// 导出前记录的原件 fingerprint（SHA-256 hex）。
    public var originalFingerprint: String
    public var pageCount: Int
    public var highlightsApplied: Int
    public var highlightsSkipped: Int
    public var inkApplied: Int
    public var inkSkipped: Int
    public var reopenedOK: Bool
    public var pageCountConsistent: Bool
    public var samplePageTextNonEmpty: Bool
    public var originalUnchanged: Bool

    public init(destination: URL, originalFingerprint: String, pageCount: Int,
                highlightsApplied: Int, highlightsSkipped: Int,
                inkApplied: Int, inkSkipped: Int,
                reopenedOK: Bool, pageCountConsistent: Bool,
                samplePageTextNonEmpty: Bool, originalUnchanged: Bool) {
        self.destination = destination
        self.originalFingerprint = originalFingerprint
        self.pageCount = pageCount
        self.highlightsApplied = highlightsApplied
        self.highlightsSkipped = highlightsSkipped
        self.inkApplied = inkApplied
        self.inkSkipped = inkSkipped
        self.reopenedOK = reopenedOK
        self.pageCountConsistent = pageCountConsistent
        self.samplePageTextNonEmpty = samplePageTextNonEmpty
        self.originalUnchanged = originalUnchanged
    }
}

public enum BurnExportError: Error, CustomStringConvertible {
    case destinationExists(URL)
    case symlinkRejected(URL, resolvedTo: String)
    case originalUnreadable(URL)
    case verificationFailed(String)

    public var description: String {
        switch self {
        case .destinationExists(let url):
            return "导出目标已存在，拒导（绝不覆盖既有文件）：\(url.lastPathComponent)"
        case .symlinkRejected(let url, let resolved):
            return "导出目标是符号链接（解析指向 \(resolved)），fail-closed 拒写：\(url.path)"
        case .originalUnreadable(let url):
            return "原件无法只读打开：\(url.lastPathComponent)"
        case .verificationFailed(let why):
            return "导出副本校验失败（已保留副本供检查，未触原件）：\(why)"
        }
    }
}

public enum PDFBurnExporter {

    public static func defaultWriteTransform(_ document: PDFDocument, to target: URL) throws {
        guard document.write(to: target) else {
            throw BurnExportError.verificationFailed("PDFKit 写出返回失败（写中途失败，已清理临时文件）")
        }
    }

    /// 副本命名（重名避让的调用方助手）：<stem>-annotated.pdf，重名 -2/-3…。
    public static func exportDestination(for originalURL: URL, in directory: URL) -> URL {
        let stem = originalURL.deletingPathExtension().lastPathComponent
        var candidate = directory.appendingPathComponent("\(stem)-annotated.pdf")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem)-annotated-\(n).pdf")
            n += 1
        }
        return candidate
    }

    /// symlink 防线：目标是 symlink、或路径解析后与字面路径不一致（任一
    /// 组件是 symlink）→ 拒写。resolved 指向原件同径更是显式拒绝理由。
    static func validateDestinationSymlinks(_ destination: URL,
                                            originalURL: URL) throws {
        let fm = FileManager.default
        if let target = try? fm.destinationOfSymbolicLink(atPath: destination.path) {
            throw BurnExportError.symlinkRejected(destination, resolvedTo: target)
        }
        let literal = destination.standardizedFileURL.path
        let resolved = destination.resolvingSymlinksInPath().standardizedFileURL.path
        if resolved != literal {
            throw BurnExportError.symlinkRejected(destination, resolvedTo: resolved)
        }
        let originalResolved = originalURL.resolvingSymlinksInPath().standardizedFileURL.path
        if resolved == originalResolved {
            throw BurnExportError.symlinkRejected(destination, resolvedTo: originalResolved)
        }
    }

    /// #RRGGBB → PDFKit 色（坏值回退中性黄——与 PDFDetailView 同基准）。
    static func pdfColor(hex: String) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return (247 / 255, 215 / 255, 116 / 255) }
        return (CGFloat((v >> 16) & 0xFF) / 255,
                CGFloat((v >> 8) & 0xFF) / 255,
                CGFloat(v & 0xFF) / 255)
    }

    /// 执行导出（同步；调用方放后台任务）。
    public static func export(source: BurnExportSource,
                              from originalURL: URL,
                              to destination: URL,
                              fingerprint: (URL) throws -> String,
                              writeTransform: (PDFDocument, URL) throws -> Void = defaultWriteTransform) throws -> BurnExportReport {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            throw BurnExportError.destinationExists(destination)
        }
        try validateDestinationSymlinks(destination, originalURL: originalURL)
        let originalFP = try fingerprint(originalURL)
        guard let document = PDFDocument(url: originalURL) else {
            throw BurnExportError.originalUnreadable(originalURL)
        }
        let pageCount = document.pageCount

        // 四类内容烧录（只加进内存文档；原件文件零接触）。
        var applied = 0
        var skipped = 0
        for highlight in source.highlights {
            guard highlight.pageNumber >= 1, highlight.pageNumber <= pageCount,
                  let page = document.page(at: highlight.pageNumber - 1),
                  let pageText = page.string else {
                skipped += 1
                continue
            }
            let utf16 = pageText.utf16
            var range = highlight.utf16Start..<highlight.utf16End
            if range.lowerBound < 0 || range.upperBound > utf16.count || range.lowerBound >= range.upperBound {
                // utf16 区间失效：锚文本回退定位（找不到 = 跳过计数，不猜）。
                let ns = pageText as NSString
                let found = highlight.anchorText.isEmpty
                    ? NSRange(location: NSNotFound, length: 0)
                    : ns.range(of: highlight.anchorText)
                guard found.location != NSNotFound, found.length > 0 else {
                    skipped += 1
                    continue
                }
                range = found.location..<(found.location + found.length)
            }
            guard let selection = page.selection(for: NSRange(location: range.lowerBound,
                                                              length: range.upperBound - range.lowerBound)) else {
                skipped += 1
                continue
            }
            let bounds = selection.bounds(for: page)
            guard !bounds.isEmpty else {
                skipped += 1
                continue
            }
            let isUnderline = highlight.style == "underline"
            let annotation = PDFAnnotation(
                bounds: bounds,
                forType: isUnderline ? .underline : .highlight,
                withProperties: nil)
            let c = pdfColor(hex: highlight.colorHex)
            annotation.color = annotationColor(r: c.r, g: c.g, b: c.b)
            if !highlight.note.isEmpty {
                annotation.contents = highlight.note
            }
            page.addAnnotation(annotation)
            applied += 1
        }

        var inkApplied = 0
        var inkSkipped = 0
        for stroke in source.inkStrokes {
            guard stroke.pageNumber >= 1, stroke.pageNumber <= pageCount,
                  stroke.deletedAt == nil,
                  let page = document.page(at: stroke.pageNumber - 1) else {
                inkSkipped += 1
                continue
            }
            if let annotation = makeInkAnnotation(stroke: stroke, page: page) {
                page.addAnnotation(annotation)
                inkApplied += 1
            } else {
                inkSkipped += 1
            }
        }

        let tmp = destination.deletingLastPathComponent()
            .appendingPathComponent(".tmp-burn-\(UUID().uuidString).pdf")
        do {
            try writeTransform(document, tmp)
            try FileManager.default.moveItem(at: tmp, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: tmp)   // 清场 fail-closed
            throw error
        }

        guard let reopened = PDFDocument(url: destination) else {
            throw BurnExportError.verificationFailed("副本无法重开")
        }
        guard reopened.pageCount == pageCount else {
            throw BurnExportError.verificationFailed("页数不一致：原 \(pageCount) → 副本 \(reopened.pageCount)")
        }
        var sampleNonEmpty = true
        let sampleIndexes = [0, pageCount / 2, pageCount - 1].filter { $0 >= 0 && $0 < reopened.pageCount }
        for idx in sampleIndexes {
            if reopened.page(at: idx)?.string?.isEmpty != false { sampleNonEmpty = false; break }
        }
        let fpAfter = try fingerprint(originalURL)
        guard fpAfter == originalFP else {
            throw BurnExportError.verificationFailed("原件 fingerprint 变化（绝不允许）")
        }
        return BurnExportReport(
            destination: destination,
            originalFingerprint: originalFP,
            pageCount: pageCount,
            highlightsApplied: applied,
            highlightsSkipped: skipped,
            inkApplied: inkApplied,
            inkSkipped: inkSkipped,
            reopenedOK: true,
            pageCountConsistent: true,
            samplePageTextNonEmpty: sampleNonEmpty,
            originalUnchanged: true)
    }

    // MARK: ink → PDFAnnotation .ink

    /// 页相对 0-1（y 自页顶向下）→ PDF 页坐标（y 自页底向上）折线。
    /// 条件编译说明件：路径类型平台分叉一处（见文件头注记）。
    static func makeInkAnnotation(stroke: InkStroke, page: PDFPage) -> PDFAnnotation? {
        guard stroke.points.count >= 2 else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let pts = stroke.points.map { p in
            CGPoint(x: bounds.minX + CGFloat(p.x) * bounds.width,
                    y: bounds.minY + CGFloat(1 - p.y) * bounds.height)
        }
        var minX = pts[0].x, maxX = pts[0].x, minY = pts[0].y, maxY = pts[0].y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let margin = max(stroke.lineWidth, 1)
        let annotationBounds = CGRect(x: minX - margin, y: minY - margin,
                                      width: max(maxX - minX, 0.5) + margin * 2,
                                      height: max(maxY - minY, 0.5) + margin * 2)
        let annotation = PDFAnnotation(bounds: annotationBounds, forType: .ink, withProperties: nil)
        let c = pdfColor(hex: stroke.color)
        annotation.color = annotationColor(r: c.r, g: c.g, b: c.b)
        #if os(macOS)
        let path = NSBezierPath()
        path.move(to: pts[0])
        for p in pts.dropFirst() { path.line(to: p) }
        path.lineWidth = max(stroke.lineWidth, 1)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        annotation.add(path)
        #else
        let path = UIBezierPath()
        path.move(to: pts[0])
        for p in pts.dropFirst() { path.addLine(to: p) }
        path.lineWidth = max(stroke.lineWidth, 1)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        annotation.add(path)
        #endif
        return annotation
    }
}

/// 注记色构造（平台分型：macOS=NSColor / iOS=UIColor——与 makeInkAnnotation
/// 同一说明件）。
#if os(macOS)
private func annotationColor(r: CGFloat, g: CGFloat, b: CGFloat) -> NSColor {
    NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
}
#else
private func annotationColor(r: CGFloat, g: CGFloat, b: CGFloat) -> UIColor {
    UIColor(red: r, green: g, blue: b, alpha: 1)
}
#endif
