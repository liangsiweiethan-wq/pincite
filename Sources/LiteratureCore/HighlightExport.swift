import Foundation

// MARK: - Highlight Markdown export (前端批)
//
// Pure assembler: no I/O, no store access. The caller (App layer) resolves
// highlight text (verified slice or anchor fallback), the per-page three-track
// page line (via HitRouter.threeTrackPageText) and color display names, then
// hands everything over as entries. Format contract (task book, verbatim):
//   # 书名
//   ## 第 N 页
//   <三轨页码行>
//   > 高亮内容
//   笔记（如有）

/// One highlight row prepared for export. `pageTrackText` is the caller-built
/// three-track page line (physical / label / printed, OCR track only when the
/// caller says so — user highlights always anchor native pages).
public struct HighlightExportEntry: Equatable, Sendable {
    public let pageNumber: Int
    public let pageTrackText: String
    public let text: String
    public let note: String
    public let colorName: String

    public init(pageNumber: Int, pageTrackText: String, text: String,
                note: String, colorName: String) {
        self.pageNumber = pageNumber
        self.pageTrackText = pageTrackText
        self.text = text
        self.note = note
        self.colorName = colorName
    }
}

public enum HighlightExport {
    /// Groups entries by page (ascending), keeps the caller's within-page
    /// order (the store returns page/utf16 order). Multi-line highlight text
    /// gets a `> ` prefix on every line so the quote block never breaks.
    public static func markdown(bookTitle: String, entries: [HighlightExportEntry]) -> String {
        var out = "# \(bookTitle)\n"
        let byPage = Dictionary(grouping: entries, by: \.pageNumber)
        for page in byPage.keys.sorted() {
            guard let group = byPage[page], let first = group.first else { continue }
            out += "\n## 第 \(page) 页\n\n"
            out += first.pageTrackText + "\n"
            for entry in group {
                out += "\n**\(entry.colorName)**\n\n"
                for line in entry.text.split(separator: "\n", omittingEmptySubsequences: false) {
                    out += "> \(line)\n"
                }
                out += "\n"
                if !entry.note.isEmpty {
                    out += entry.note + "\n\n"
                }
            }
        }
        return out
    }
}
