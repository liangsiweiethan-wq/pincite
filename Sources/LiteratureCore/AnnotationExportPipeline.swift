import Foundation

// MARK: - 批量导出管道（全库批注/引注 → MD/CSV，进度＋断点续跑）

// MARK: - 选项与进度

/// 导出内容勾选（MD/CSV × 批注/引注；README 与 export_state.json 恒写）。
/// 功能扩展：增批注 HTML/TXT 两格式（默认 false 不破旧调用；
/// 本结构不落 export_state.json，无格式 ID 迁移问题）。
public struct AnnotationExportSelection: Sendable, Equatable {
    public var annotationsMarkdown: Bool = true
    public var annotationsCSV: Bool = true
    public var citationsMarkdown: Bool = true
    public var citationsCSV: Bool = true
    public var annotationsHTML: Bool = false
    public var annotationsTXT: Bool = false

    public init(annotationsMarkdown: Bool = true, annotationsCSV: Bool = true,
                citationsMarkdown: Bool = true, citationsCSV: Bool = true,
                annotationsHTML: Bool = false, annotationsTXT: Bool = false) {
        self.annotationsMarkdown = annotationsMarkdown
        self.annotationsCSV = annotationsCSV
        self.citationsMarkdown = citationsMarkdown
        self.citationsCSV = citationsCSV
        self.annotationsHTML = annotationsHTML
        self.annotationsTXT = annotationsTXT
    }
}

/// 进度回执（回调上抛 @MainActor 更新进度条）。total = books 全表书目数
public struct AnnotationExportProgress: Sendable, Equatable {
    public var total: Int
    public var done: Int
    public var failed: Int
    public var currentBook: String?

    public init(total: Int, done: Int, failed: Int, currentBook: String?) {
        self.total = total
        self.done = done
        self.failed = failed
        self.currentBook = currentBook
    }
}

/// 引注行（调用方经 CitationFormatter 组装好 citation 字符串后传入；
/// Core 不依赖 UI 模块）。字段投影 books 表：author/title/version/language
/// 未知即空串（不编造）。
public struct AnnotationExportCitationRow: Sendable, Equatable {
    public var author: String
    public var title: String
    public var version: String
    public var language: String
    public var fileName: String
    public var citation: String

    public init(author: String, title: String, version: String, language: String,
                fileName: String, citation: String) {
        self.author = author
        self.title = title
        self.version = version
        self.language = language
        self.fileName = fileName
        self.citation = citation
    }
}

// MARK: - 断点续跑记账

/// export_state.json 载荷（formatID 拒识照 HighlightStore.backupFormatID 与
/// AnnotationBundle.parse 双先例：不认识即整体拒跑，绝不半读）。
public struct AnnotationExportState: Codable, Equatable {
    public static let formatID = "literaturesearch-export-state/1"

    public struct BookRecord: Codable, Equatable {
        /// "done" | "failed"
        public var status: String
        /// 该书导出的批注条数（README 索引用）。
        public var count: Int
        public var error: String?

        public init(status: String, count: Int, error: String? = nil) {
            self.status = status
            self.count = count
            self.error = error
        }
    }

    public var format: String
    public var userHighlightsSubSchema: Int
    public var startedAt: Date
    public var updatedAt: Date
    /// book_id → 记账。重跑跳过 done，failed/缺记重处理。
    public var books: [String: BookRecord]

    public init(userHighlightsSubSchema: Int, startedAt: Date, updatedAt: Date,
                books: [String: BookRecord]) {
        self.format = Self.formatID
        self.userHighlightsSubSchema = userHighlightsSubSchema
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.books = books
    }

    /// 日期策略统一 ISO8601（encode/decode 同策略，错位即拒收）。
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// fail-closed 解析：未知 format / 解码失败 → nil（拒跑）。
    public static func parse(_ data: Data) -> AnnotationExportState? {
        guard let state = try? decoder.decode(AnnotationExportState.self, from: data),
              state.format == formatID else { return nil }
        return state
    }
}

// MARK: - 组装器（纯函数，无 I/O）

public enum AnnotationExportAssembler {

    /// 颜色显示名注入点类型（App 层传 L10n 包装）。
    public typealias ColorNamer = (HighlightColor) -> String
    /// 三轨页码行注入点类型（App 层传 HitRouter 组装）。
    public typealias PageTrackTexter = (_ bookID: String, _ pageNumber: Int) -> String

    /// 页级批注判定（与 AnnotationSidebarView sourceBadge 同一语义：
    /// 无 utf16 锚点——(0,0) 占位且锚文本空）。
    public static func isPageNote(_ h: UserHighlight) -> Bool {
        h.utf16Start == 0 && h.utf16End == 0 && h.anchorText.isEmpty
    }

    /// CSV 字段转义（RFC 4180：含引号/逗号/换行即整体加引号，内部引号翻倍）。
    public static func csvEscape(_ field: String) -> String {
        if field.contains("\"") || field.contains(",") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    static func csvLine(_ fields: [String]) -> String {
        fields.map(csvEscape).joined(separator: ",")
    }

    /// 单条导出记录（Pipeline 与测试共同的数据形态）。
    public struct ExportEntry {
        public var section: ExportSection
        public var pageNumber: Int
        public var pageTrackText: String
        public var colorName: String
        public var text: String
        public var note: String

        public init(section: ExportSection, pageNumber: Int, pageTrackText: String,
                    colorName: String, text: String, note: String) {
            self.section = section
            self.pageNumber = pageNumber
            self.pageTrackText = pageTrackText
            self.colorName = colorName
            self.text = text
            self.note = note
        }
    }

    /// 导出段（三段分层；标题照 HighlightExport「第 N 页」中文既有惯例，
    /// Core 层组装器与 HighlightExport 同源）。
    public enum ExportSection: String, CaseIterable, Sendable {
        case highlights
        case annotated
        case pageNotes

        public var heading: String {
            switch self {
            case .highlights: return "高亮"
            case .annotated: return "带注批注"
            case .pageNotes: return "页级批注"
            }
        }
    }

    /// 单书 MD（三段分层）。段内按页分组（页升序），页内保持输入序；
    /// 页块格式复用 HighlightExport.markdown 契约（### 深一级于段标题）。
    public static func bookMarkdown(bookTitle: String, entries: [ExportEntry]) -> String {
        var out = "# \(bookTitle)\n"
        for section in ExportSection.allCases {
            let group = entries.filter { $0.section == section }
            guard !group.isEmpty else { continue }
            out += "\n## \(section.heading)\n"
            var pageOrder: [Int] = []
            var byPage: [Int: [ExportEntry]] = [:]
            for e in group {
                if byPage[e.pageNumber] == nil { pageOrder.append(e.pageNumber) }
                byPage[e.pageNumber, default: []].append(e)
            }
            for page in pageOrder {
                let rows = byPage[page] ?? []
                out += "\n### 第 \(page) 页\n\n"
                // 页码行取组内首条的注入值；空值回退纯页码。
                // pageTrackText 使用 optional binding。
                if let first = rows.first, !first.pageTrackText.isEmpty {
                    out += first.pageTrackText + "\n"
                } else {
                    out += "第 \(page) 页\n"
                }
                for row in rows {
                    out += "\n**\(row.colorName)**\n\n"
                    for line in row.text.split(separator: "\n", omittingEmptySubsequences: false) {
                        out += "> \(line)\n"
                    }
                    if !row.note.isEmpty {
                        out += "\n\(row.note)\n"
                    }
                }
            }
        }
        return out
    }

    /// annotations.csv 行。
    public struct AnnotationCSVRow: Equatable, Sendable {
        public var bookID: String
        public var bookTitle: String
        public var pageNumber: Int
        /// highlight | underline | page_note
        public var type: String
        public var color: String
        public var text: String
        public var note: String
        public var createdAtISO8601: String
        public var viewSource: String
        public var anchorVerified: Int

        public init(bookID: String, bookTitle: String, pageNumber: Int, type: String,
                    color: String, text: String, note: String, createdAtISO8601: String,
                    viewSource: String, anchorVerified: Int) {
            self.bookID = bookID
            self.bookTitle = bookTitle
            self.pageNumber = pageNumber
            self.type = type
            self.color = color
            self.text = text
            self.note = note
            self.createdAtISO8601 = createdAtISO8601
            self.viewSource = viewSource
            self.anchorVerified = anchorVerified
        }
    }

    /// annotations.csv 全文（表头 + 数据行；顺序 = 输入序）。
    public static func annotationsCSV(rows: [AnnotationCSVRow]) -> String {
        var out = csvLine(["book_id", "book_title", "page", "type", "color", "text",
                           "note", "created_at_iso8601", "view_source", "anchor_verified"]) + "\n"
        for r in rows {
            out += csvLine([r.bookID, r.bookTitle, String(r.pageNumber), r.type, r.color,
                            r.text, r.note, r.createdAtISO8601, r.viewSource,
                            String(r.anchorVerified)]) + "\n"
        }
        return out
    }

    /// citations.csv 全文（列：author, title, version, language, file_name, citation）。
    public static func citationsCSV(rows: [AnnotationExportCitationRow]) -> String {
        var out = csvLine(["author", "title", "version", "language", "file_name", "citation"]) + "\n"
        for r in rows {
            out += csvLine([r.author, r.title, r.version, r.language, r.fileName, r.citation]) + "\n"
        }
        return out
    }

    // MARK: 功能扩展 —— 批注 HTML/TXT（格式补缺）
    //
    // 列集合与 annotations.csv 完全一致（同一 AnnotationCSVRow 单一事实，
    // 不造第二套字段）；引注不加新格式；README 索引如实列新文件。

    /// HTML 转义（& < > " ' 五字符；先转 & 防二次转义）。
    public static func htmlEscape(_ field: String) -> String {
        field.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// annotations.html 全库单文件：表头 + 每行一 <tr>，列集合＝annotations.csv。
    public static func annotationsHTML(rows: [AnnotationCSVRow]) -> String {
        let columns = ["book_id", "book_title", "page", "type", "color", "text",
                       "note", "created_at_iso8601", "view_source", "anchor_verified"]
        var out = "<!DOCTYPE html>\n<html lang=\"zh-CN\">\n<head>\n<meta charset=\"utf-8\">\n"
        out += "<title>批注导出</title>\n</head>\n<body>\n<table>\n"
        out += "<tr>" + columns.map { "<th>\(htmlEscape($0))</th>" }.joined() + "</tr>\n"
        for r in rows {
            let cells = [r.bookID, r.bookTitle, String(r.pageNumber), r.type, r.color,
                         r.text, r.note, r.createdAtISO8601, r.viewSource,
                         String(r.anchorVerified)]
            out += "<tr>" + cells.map { "<td>\(htmlEscape($0))</td>" }.joined() + "</tr>\n"
        }
        out += "</table>\n</body>\n</html>\n"
        return out
    }

    /// annotations.txt 全库单文件：`书名 [第 N 页] 类型/颜色 摘句 —— 笔记`
    /// 逐行，无任何标记。摘句空（页级批注）与笔记空各自省段；行内换行
    /// 压为空格（一行一批注）。
    public static func annotationsTXT(rows: [AnnotationCSVRow]) -> String {
        var out = ""
        for r in rows {
            var line = "\(r.bookTitle) [第 \(r.pageNumber) 页] \(r.type)/\(r.color)"
            let text = r.text.replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { line += " \(text)" }
            let note = r.note.replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if !note.isEmpty { line += " —— \(note)" }
            out += line + "\n"
        }
        return out
    }

    /// README 索引（各书计数＋文件清单＋生成时间；失败书目如实列出）。
    public static func readme(generatedAtISO8601: String,
                              bookCounts: [(title: String, count: Int)],
                              files: [String],
                              failedBooks: [(id: String, error: String)]) -> String {
        var out = "# 批注导出索引\n\n"
        out += "- 生成时间：\(generatedAtISO8601)\n"
        if !failedBooks.isEmpty {
            out += "- 失败书目（\(failedBooks.count)）——未入导出，重跑同目录可补：\n"
            for f in failedBooks { out += "  - \(f.id)：\(f.error)\n" }
        }
        out += "\n## 各书批注数\n\n"
        if bookCounts.isEmpty {
            out += "（无书目）\n"
        } else {
            for b in bookCounts { out += "- \(b.title)：\(b.count)\n" }
        }
        out += "\n## 文件清单\n\n"
        if files.isEmpty {
            out += "（无文件）\n"
        } else {
            for f in files { out += "- \(f)\n" }
        }
        return out
    }
}

// MARK: - 管道

public final class AnnotationExportPipeline {

    public struct Summary: Sendable {
        public var directory: URL
        public var processedBooks: Int = 0
        /// 记账跳过的 done 书数。
        public var skippedDoneBooks: Int = 0
        public var writtenFiles: [String] = []
        public var annotationRows: Int = 0
        public var failedBooks: [(id: String, error: String)] = []
        public var cancelled: Bool = false
        /// 全部书目失败（报错不假称完成的判定依据）。
        public var allFailed: Bool { processedBooks > 0 && failedBooks.count == processedBooks }

        public init(directory: URL) {
            self.directory = directory
        }
    }

    /// 导出目录前缀（管道命名与视图层续跑扫描共用同一常量；目录名是数据
    /// 契约，非 UI 文案）。
    public static let runDirectoryPrefix = "批注导出-"

    /// 新导出目录：<root>/批注导出-<yyyyMMdd-HHmmss>/（同名冲突追加 -2/-3…）。
    public static func newRunDirectory(in root: URL, at date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(runDirectoryPrefix)\(formatter.string(from: date))"
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }

    private let highlightStore: HighlightStore
    private let indexStore: IndexStore

    public init(highlightStore: HighlightStore, indexStore: IndexStore) {
        self.highlightStore = highlightStore
        self.indexStore = indexStore
    }

    /// 跑一次导出。`directory` 由 newRunDirectory 创建（续跑 = 传入既有目录，
    /// 内含合法 export_state.json 时跳过 done 书；不识别即拒跑）。同步执行，
    /// 调用方放后台 Task；书间与文件间检查 shouldCancel（Task.isCancelled）。
    @discardableResult
    public func run(directory: URL,
                    selection: AnnotationExportSelection,
                    citations: [AnnotationExportCitationRow],
                    citationsMarkdown: String,
                    pageTrackText: AnnotationExportAssembler.PageTrackTexter,
                    colorName: AnnotationExportAssembler.ColorNamer,
                    cleanName: (String) -> String,
                    shouldCancel: () -> Bool = { false },
                    progress: (AnnotationExportProgress) -> Void = { _ in }) throws -> Summary {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        // 断点续跑：读既有 state（存在但不识别 → 拒跑）。
        let stateURL = directory.appendingPathComponent("export_state.json")
        let state: AnnotationExportState
        if let data = try? Data(contentsOf: stateURL) {
            guard let loaded = AnnotationExportState.parse(data) else {
                throw HighlightStore.HighlightError("导出状态文件格式不识别（export_state.json），拒绝续跑")
            }
            state = loaded
        } else {
            state = AnnotationExportState(
                userHighlightsSubSchema: highlightStore.userHighlightsSubSchemaVersion(),
                startedAt: Date(), updatedAt: Date(), books: [:])
        }
        var mutableState = state

        let books = try indexStore.allBooks()
        var summary = Summary(directory: directory)
        summary.skippedDoneBooks = books.filter { state.books[$0.id]?.status == "done" }.count
        var csvRows: [AnnotationExportAssembler.AnnotationCSVRow] = []
        var written: [String] = []
        var processed = 0
        var cancelled = false
        var usedFileNames: Set<String> = []

        // 逐书切片：annotations/<清洗后名>.md（每书一文件，即写即落盘）。
        let annotationsDir = directory.appendingPathComponent("annotations", isDirectory: true)
        if selection.annotationsMarkdown {
            try fm.createDirectory(at: annotationsDir, withIntermediateDirectories: true)
        }
        for book in books {
            if shouldCancel() { cancelled = true; break }
            let displayName = book.title ?? book.fileName
            if state.books[book.id]?.status == "done" {
                // 续跑跳过 MD 重写；annotations.csv/html/txt 是全库单文件，
                // 行仍全量重建（只读补齐，不产生写库）。
                if selection.annotationsCSV || selection.annotationsHTML || selection.annotationsTXT,
                   let highlights = try? highlightStore.highlightsForBook(book.id, viewSource: nil) {
                    csvRows.append(contentsOf: csvRowsForBook(book, highlights: highlights,
                                                              displayName: displayName))
                }
                continue
            }
            progress(AnnotationExportProgress(total: books.count, done: processed,
                                              failed: summary.failedBooks.count,
                                              currentBook: displayName))
            do {
                let highlights = try highlightStore.highlightsForBook(book.id, viewSource: nil)
                if selection.annotationsMarkdown, !highlights.isEmpty {
                    let entries = highlights.map { h -> AnnotationExportAssembler.ExportEntry in
                        let track = pageTrackText(book.id, h.pageNumber)
                        let color = colorName(h.color)
                        let text: String
                        let note: String
                        if AnnotationExportAssembler.isPageNote(h) {
                            text = ""; note = h.note
                        } else {
                            text = resolvedText(h); note = h.note
                        }
                        let section: AnnotationExportAssembler.ExportSection =
                            AnnotationExportAssembler.isPageNote(h) ? .pageNotes
                            : (h.note.isEmpty ? .highlights : .annotated)
                        return AnnotationExportAssembler.ExportEntry(
                            section: section, pageNumber: h.pageNumber, pageTrackText: track,
                            colorName: color, text: text, note: note)
                    }
                    let md = AnnotationExportAssembler.bookMarkdown(bookTitle: displayName,
                                                                    entries: entries)
                    let fileName = uniqueFileName(base: baseName(for: book, cleanName: cleanName),
                                                  ext: "md", used: &usedFileNames)
                    try Self.atomicWrite(Data(md.utf8),
                                         to: annotationsDir.appendingPathComponent(fileName))
                    written.append("annotations/\(fileName)")
                }
                if selection.annotationsCSV || selection.annotationsHTML || selection.annotationsTXT {
                    csvRows.append(contentsOf: csvRowsForBook(book, highlights: highlights,
                                                              displayName: displayName))
                }
                mutableState.books[book.id] = .init(status: "done", count: highlights.count)
                processed += 1
            } catch {
                mutableState.books[book.id] = .init(status: "failed", count: 0,
                                                    error: String(describing: error))
                summary.failedBooks.append((id: book.id, error: String(describing: error)))
                processed += 1
            }
            mutableState.updatedAt = Date()
            try Self.atomicWrite(try AnnotationExportState.encoder.encode(mutableState), to: stateURL)
        }
        summary.processedBooks = processed
        summary.cancelled = cancelled

        // 全库单文件产物：取消即停不写收尾件（未处理书重跑续补）；正常收尾
        // 才写 CSV/引注/README。
        if !cancelled {
            if selection.annotationsCSV {
                let url = directory.appendingPathComponent("annotations.csv")
                try Self.atomicWrite(
                    Data(AnnotationExportAssembler.annotationsCSV(rows: csvRows).utf8), to: url)
                written.append("annotations.csv")
            }
            // HTML/TXT 同一 csvRows 单一事实（列集合与 CSV 一致）；
            // 取消即停不写（同 CSV 语义——未处理书重跑续补）。
            if selection.annotationsHTML {
                let url = directory.appendingPathComponent("annotations.html")
                try Self.atomicWrite(
                    Data(AnnotationExportAssembler.annotationsHTML(rows: csvRows).utf8), to: url)
                written.append("annotations.html")
            }
            if selection.annotationsTXT {
                let url = directory.appendingPathComponent("annotations.txt")
                try Self.atomicWrite(
                    Data(AnnotationExportAssembler.annotationsTXT(rows: csvRows).utf8), to: url)
                written.append("annotations.txt")
            }
            if selection.citationsMarkdown {
                let url = directory.appendingPathComponent("citations.md")
                try Self.atomicWrite(Data(citationsMarkdown.utf8), to: url)
                written.append("citations.md")
            }
            if selection.citationsCSV {
                let url = directory.appendingPathComponent("citations.csv")
                try Self.atomicWrite(
                    Data(AnnotationExportAssembler.citationsCSV(rows: citations).utf8), to: url)
                written.append("citations.csv")
            }
            let bookCounts = books.map { book in
                (title: book.title ?? book.fileName, count: mutableState.books[book.id]?.count ?? 0)
            }
            let readme = AnnotationExportAssembler.readme(
                generatedAtISO8601: Self.iso8601.string(from: mutableState.updatedAt),
                bookCounts: bookCounts, files: written,
                failedBooks: summary.failedBooks)
            try Self.atomicWrite(Data(readme.utf8),
                                 to: directory.appendingPathComponent("README.md"))
            written.append("README.md")
        }
        summary.writtenFiles = written
        summary.annotationRows = csvRows.count
        progress(AnnotationExportProgress(total: books.count, done: processed,
                                          failed: summary.failedBooks.count, currentBook: nil))
        return summary
    }

    // MARK: 内部组装

    /// 摘句解析（照 AppState.highlightsExportMarkdown 语义：活切片优先，
    /// 锚文本回退，不猜不编造）。只读索引页文本。
    private func resolvedText(_ h: UserHighlight) -> String {
        if h.anchorVerified == 1,
           let page = try? indexStore.page(bookID: h.bookID, pageNumber: h.pageNumber) {
            let utf16 = page.textOriginal.utf16
            if h.utf16Start >= 0, h.utf16End <= utf16.count, h.utf16Start < h.utf16End {
                let s = utf16.index(utf16.startIndex, offsetBy: h.utf16Start)
                let e = utf16.index(utf16.startIndex, offsetBy: h.utf16End)
                let slice = String(decoding: utf16[s..<e], as: UTF16.self)
                if !slice.isEmpty { return slice }
            }
        }
        return h.anchorText
    }

    private func csvRowsForBook(_ book: IndexStore.BookRow, highlights: [UserHighlight],
                                displayName: String) -> [AnnotationExportAssembler.AnnotationCSVRow] {
        highlights.map { h in
            let type: String
            let text: String
            if AnnotationExportAssembler.isPageNote(h) {
                type = "page_note"; text = ""
            } else if h.style == "underline" {
                type = "underline"; text = resolvedText(h)
            } else {
                type = "highlight"; text = resolvedText(h)
            }
            return AnnotationExportAssembler.AnnotationCSVRow(
                bookID: h.bookID, bookTitle: displayName, pageNumber: h.pageNumber,
                type: type, color: h.color.rawValue, text: text, note: h.note,
                createdAtISO8601: Self.iso8601.string(from: h.createdAt),
                viewSource: h.viewSource, anchorVerified: h.anchorVerified)
        }
    }

    /// 书名解析阶梯：books.title → fileName → bookID（CSV/README 如实用到
    /// 哪级显示哪级）；文件名一律过 cleanName 清洗。
    private func baseName(for book: IndexStore.BookRow, cleanName: (String) -> String) -> String {
        if let title = book.title, !title.isEmpty { return cleanName(title) }
        return cleanName(book.fileName.isEmpty ? book.id : book.fileName)
    }

    private func uniqueFileName(base: String, ext: String, used: inout Set<String>) -> String {
        var candidate = "\(base).\(ext)"
        var n = 2
        while used.contains(candidate) {
            candidate = "\(base)-\(n).\(ext)"
            n += 1
        }
        used.insert(candidate)
        return candidate
    }

    /// ISO8601（UTC，固定格式；CSV/state 时间戳确定性）。
    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// 原子覆盖写（照 HighlightStore.swift:463-471 先例：.atomic 临时文件 +
    /// 落位；此处统一走 FileManager 原子选项）。
    static func atomicWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}
