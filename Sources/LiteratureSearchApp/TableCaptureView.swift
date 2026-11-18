import SwiftUI
import PDFKit
import VisionKit
import LiteratureCore
import LiteratureSearchUI


/// 表格圈选错误（显式报错，不静默）。
enum TableCaptureError: Error, CustomStringConvertible {
    case renderFailed
    case noRecognizableContent

    var description: String {
        switch self {
        case .renderFailed: return L10n.tableCaptureRenderFailed
        case .noRecognizableContent: return L10n.tableCaptureNoContent
        }
    }
}

enum TableCapture {

    // MARK: 文字层档（主路线）

    /// 圈选区内词序列（页坐标系 captureRect；词中心点落在圈内才算——
    /// 跨界词不带入邻列，矩形拖选 bounds 语义）。
    static func words(in page: PDFPage, intersecting captureRect: CGRect) -> [TableWord] {
        guard let text = page.string, !text.isEmpty else { return [] }
        var out: [TableWord] = []
        for (token, range) in TableGridGeometry.tokenRanges(in: text) {
            guard let selection = page.selection(for: range) else { continue }
            let bounds = selection.bounds(for: page)
            if bounds.width > 0, bounds.height > 0,
               captureRect.contains(CGPoint(x: bounds.midX, y: bounds.midY)) {
                out.append(TableWord(text: token, rect: bounds))
            }
        }
        return out
    }

    static func pageHasNoTextLayer(_ page: PDFPage) -> Bool {
        guard let text = page.string else { return true }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 文字层档结果：TSV＋行数（nil = 圈内无词 → 调用方走图像回退档）。
    static func textLayerTSV(page: PDFPage, captureRect: CGRect) -> (tsv: String, rows: Int)? {
        let words = Self.words(in: page, intersecting: captureRect)
        guard let tsv = TableGridGeometry.tsv(from: words) else { return nil }
        let rows = TableGridGeometry.grid(words: words)?.count ?? 0
        return (tsv, rows)
    }

    // MARK: 图像回退档（无文字层圈选区；如实降级——无表格结构）

    /// 圈选区页位图（只读内存位图，零落盘；1600px 预算 = 快照管线同款）。
    static func renderCrop(page: PDFPage, captureRect: CGRect) throws -> CGImage {
        let pageBounds = page.bounds(for: .cropBox)
        let budget: CGFloat = 1600
        let longEdge = max(pageBounds.width, pageBounds.height)
        let scale = longEdge > 0 ? budget / longEdge : 1
        let pixel = CGSize(width: max(pageBounds.width * scale, 1),
                           height: max(pageBounds.height * scale, 1))
        let thumbnail = page.thumbnail(of: pixel, for: .cropBox)
        guard let full = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw TableCaptureError.renderFailed
        }
        // 圈选区裁剪：SnapshotGeometry.cropRatio 交集语义（fail-closed），
        // CGImage 原点左下 y 翻转（SnapshotWindowController 同款公式）。
        guard let ratio = SnapshotGeometry.cropRatio(pageBounds: pageBounds,
                                                     selectionRect: captureRect) else {
            throw TableCaptureError.renderFailed
        }
        let crop = CGRect(
            x: (ratio.minX * CGFloat(full.width)).rounded(.down),
            y: ((1 - ratio.maxY) * CGFloat(full.height)).rounded(.down),
            width: (ratio.width * CGFloat(full.width)).rounded(),
            height: (ratio.height * CGFloat(full.height)).rounded())
        let clamped = crop.intersection(CGRect(x: 0, y: 0,
                                               width: full.width, height: full.height))
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1,
              let cropped = full.cropping(to: clamped) else {
            throw TableCaptureError.renderFailed
        }
        return cropped
    }

    /// VisionKit 图像识别（Configuration 只开 .text；产物 = transcript
    /// 原样文本——SDK 无表格结构 API，本档绝不猜列）。
    static func imageFallbackTranscript(page: PDFPage, captureRect: CGRect) async throws -> String {
        let image = try renderCrop(page: page, captureRect: captureRect)
        let analyzer = ImageAnalyzer()
        let configuration = ImageAnalyzer.Configuration(.text)
        let analysis = try await analyzer.analyze(image, orientation: .up,
                                                  configuration: configuration)
        let transcript = analysis.transcript
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TableCaptureError.noRecognizableContent
        }
        return transcript
    }
}
