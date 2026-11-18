import Foundation
import CoreGraphics
import CoreText

// MARK: - Synthetic PDF generation (fixtures only)
//
// Used by tests, the CLI `genpdf` command and end-to-end verification to build
// known-content PDFs. Real books are never read; fixtures are written to
// explicit output paths supplied by the caller (tests use temp directories).

public struct SyntheticPDFPage {
    public var lines: [String]
    public var fontSize: CGFloat
    /// Draw only graphics (no text) — models a scanned/image-only page.
    public var textlessDrawing: Bool

    public init(lines: [String], fontSize: CGFloat = 14, textlessDrawing: Bool = false) {
        self.lines = lines
        self.fontSize = fontSize
        self.textlessDrawing = textlessDrawing
    }
}

public enum SyntheticPDFError: Error, CustomStringConvertible {
    case cannotCreateContext(String)
    case description(String)
    public var description: String {
        switch self {
        case .cannotCreateContext(let m): return "cannot create PDF context: \(m)"
        case .description(let m): return m
        }
    }
}

public enum SyntheticPDFMaker {
    public static let defaultPageSize = CGSize(width: 612, height: 792) // US Letter, points

    /// Writes a multi-page PDF with the given content. Text is drawn with
    /// CoreText so the PDF contains real, extractable text runs (including CJK
    /// via the system PingFang SC font).
    public static func write(pages: [SyntheticPDFPage], to url: URL, pageSize: CGSize = SyntheticPDFMaker.defaultPageSize) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw SyntheticPDFError.cannotCreateContext("no data consumer for \(url.path)")
        }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw SyntheticPDFError.cannotCreateContext("CGContext(consumer:) failed")
        }

        for page in pages {
            context.beginPDFPage(nil)
            draw(page: page, in: context, pageSize: pageSize)
            context.endPDFPage()
        }
        context.closePDF()
    }

    private static func draw(page: SyntheticPDFPage, in context: CGContext, pageSize: CGSize) {
        if page.textlessDrawing {
            // Graphics only: nothing for the text extractor to find.
            context.setFillColor(CGColor(gray: 0.8, alpha: 1))
            context.fill(CGRect(x: 40, y: 40, width: pageSize.width - 80, height: pageSize.height - 80))
            context.setFillColor(CGColor(gray: 0.3, alpha: 1))
            context.fill(CGRect(x: 80, y: 80, width: 200, height: 120))
            return
        }

        let margin: CGFloat = 56
        var y = pageSize.height - margin
        for line in page.lines {
            guard !line.isEmpty else {
                y -= page.fontSize * 1.6
                continue
            }
            drawText(line, at: CGPoint(x: margin, y: y), fontSize: page.fontSize, in: context)
            y -= page.fontSize * 1.6
            if y < margin { break }
        }
    }

    private static func drawText(_ text: String, at point: CGPoint, fontSize: CGFloat, in context: CGContext) {
        // PingFang SC covers Latin + CJK; CTFont falls back for anything else.
        let font = CTFontCreateWithName("PingFang SC" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font]
        let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
        guard let attributed else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = point
        CTLineDraw(line, context)
    }

    // MARK: Minimal hand-assembled PDF with /PageLabels (fixture for label tests)
    //
    // CoreGraphics cannot write /PageLabels, so labeled fixtures are assembled
    // byte by byte (uncompressed objects, computed xref). Latin-1 ASCII text only.

    public struct LabeledPage {
        public var text: String
        public init(text: String) { self.text = text }
    }

    /// Writes a minimal valid PDF whose /Nums declare labels per page.
    /// `labels[i]` is the label rule applied from page i+1 onward:
    /// pass e.g. [.init(prefix: "", style: "D", startValue: 1)] for decimal pages.
    public static func writeLabeledPDF(pages: [LabeledPage],
                                       labelRules: [(page: Int, prefix: String, style: String?, startValue: Int)],
                                       to url: URL) throws {
        precondition(!pages.isEmpty)
        let contentCount = pages.count
        let firstPageObj = 3
        let firstContent = 3 + contentCount          // page objects are 3..(3+n-1)
        let fontObj = firstContent + contentCount
        let labelObj = fontObj + 1

        var objects: [Int: String] = [:]
        objects[1] = "<< /Type /Catalog /Pages 2 0 R /PageLabels \(labelObj) 0 R >>"
        let kids = (0..<contentCount).map { "\(3 + $0) 0 R" }.joined(separator: " ")
        objects[2] = "<< /Type /Pages /Kids [\(kids)] /Count \(contentCount) >>"
        for (i, _) in pages.enumerated() {
            let pageObj = firstPageObj + i
            let contentObj = firstContent + i
            objects[pageObj] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(contentObj) 0 R /Resources << /Font << /F1 \(fontObj) 0 R >> >> >>"
        }
        for (i, page) in pages.enumerated() {
            let contentObj = firstContent + i
            let escaped = page.text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "(", with: "\\(")
                .replacingOccurrences(of: ")", with: "\\)")
            let stream = "BT /F1 24 Tf 72 720 Td (\(escaped)) Tj ET"
            objects[contentObj] = "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"
        }
        objects[fontObj] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        let nums = labelRules.map { rule -> String in
            var dict = "<<"
            if !rule.prefix.isEmpty { dict += " /P (\(rule.prefix))" }
            if let style = rule.style { dict += " /S /\(style)" }
            if rule.startValue != 1 { dict += " /St \(rule.startValue)" }
            dict += " >>"
            return "\(rule.page) \(dict)"
        }.joined(separator: " ")
        objects[labelObj] = "<< /Nums [\(nums)] >>"

        var pdf = "%PDF-1.4\n"
        var offsets: [Int: Int] = [:]
        for n in (1...labelObj).sorted() {
            offsets[n] = pdf.utf8.count
            pdf += "\(n) 0 obj\n\(objects[n] ?? "<< >>")\nendobj\n"
        }
        let xrefStart = pdf.utf8.count
        pdf += "xref\n0 \(labelObj + 1)\n0000000000 65535 f \n"
        for n in 1...labelObj {
            pdf += String(format: "%010d 00000 n \n", offsets[n] ?? 0)
        }
        pdf += "trailer\n<< /Size \(labelObj + 1) /Root 1 0 R >>\nstartxref\n\(xrefStart)\n%%EOF\n"

        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(pdf.utf8).write(to: url)
    }
}
