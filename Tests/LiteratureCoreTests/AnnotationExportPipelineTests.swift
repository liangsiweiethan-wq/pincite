import Foundation
@testable import LiteratureCore

// MARK: - 批量导出管道套件（全部合成库 + 临时目录）
//
// 断言固定：每书一文件且三段分层、state 记账 done/failed、断点续跑（跳 done
// 补 failed/未处理，annotations.csv 全库单文件无缺口）、formatID 拒识、
// 取消保留已写文件、CSV 转义四例、书名阶梯三级、空库如实、引注行数=书数、
// 导出对批注库只读（逐字节不变）、页级/下划线类型投影、目录冲突后缀。

enum AnnotationExportPipelineSuite {

    // MARK: 合成库

    struct Library {
        let index: IndexStore
        let highlights: HighlightStore
        let root: URL
    }

    static func makeLibrary() throws -> Library {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lit-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = try IndexStore(path: root.appendingPathComponent("index.db"))
        let highlights = HighlightStore(indexStore: index)
        return Library(index: index, highlights: highlights, root: root)
    }

    @discardableResult
    static func addBook(_ lib: Library, id: String, fileName: String, title: String?,
                        pages: [String]) throws -> IndexStore.BookRow {
        var book = IndexStore.BookRow(
            id: id, realPath: "/tmp/lit-tests/\(fileName)", rootPath: "/tmp/lit-tests",
            relPath: fileName, fileName: fileName,
            firstFingerprint: "fp-\(id)", fingerprint: "fp-\(id)", fileSize: 1, mtime: 0,
            pageCount: max(pages.count, 1), status: "ok", indexedAt: 0)
        book.title = title
        try lib.index.upsertBook(book)
        var rows: [IndexStore.PageRow] = []
        for (i, text) in pages.enumerated() {
            let n = normalizeForSearch(text)
            rows.append(IndexStore.PageRow(bookID: id, pageNumber: i + 1, textOriginal: text,
                                           textNorm: n.text, normStarts: n.starts, normEnds: n.ends))
        }
        try lib.index.replacePages(bookID: id, rows)
        return book
    }

    @discardableResult
    static func addHighlight(_ lib: Library, book: String, page: Int, note: String = "",
                             createdAt: Date = Date(timeIntervalSince1970: 1_000),
                             style: String = "highlight", anchor: String = "锚句") throws -> Int64 {
        let pending = HighlightStore.PendingHighlight(
            bookID: book, pageNumber: page, utf16Start: 0, utf16End: 6,
            color: .yellow, note: note, createdAt: createdAt.timeIntervalSince1970,
            anchorText: anchor, anchorVerified: 1, style: style,
            viewSource: HighlightStore.viewSourceOCR)
        lib.highlights.lock.lock(); defer { lib.highlights.lock.unlock() }
        return try lib.highlights.insertRowLocked(pending)
    }

    @discardableResult
    static func addPageNote(_ lib: Library, book: String, page: Int, note: String,
                            createdAt: Date = Date(timeIntervalSince1970: 1_001)) throws -> Int64 {
        let pending = HighlightStore.PendingHighlight(
            bookID: book, pageNumber: page, utf16Start: 0, utf16End: 0,
            color: .yellow, note: note, createdAt: createdAt.timeIntervalSince1970,
            anchorText: "", anchorVerified: 0, style: "highlight",
            viewSource: HighlightStore.viewSourceOCR)
        lib.highlights.lock.lock(); defer { lib.highlights.lock.unlock() }
        return try lib.highlights.insertRowLocked(pending)
    }

    // MARK: 注入桩（App 层三条注入的最小等价物）

    static let trackText: AnnotationExportAssembler.PageTrackTexter = { _, page in
        "物理页 \(page)（测试桩）"
    }
    static let colorName: AnnotationExportAssembler.ColorNamer = { _ in "黄" }
    /// 测试用清洗（生产为 CitationFormatter.cleanFileName：剥 .pdf 等）。
    static let cleanName: (String) -> String = { name in
        name.hasSuffix(".pdf") ? String(name.dropLast(4)) : name
    }

    static func run(_ pipeline: AnnotationExportPipeline, directory: URL,
                    selection: AnnotationExportSelection = AnnotationExportSelection(),
                    citations: [AnnotationExportCitationRow] = [],
                    citationsMarkdown: String = "",
                    shouldCancel: () -> Bool = { false }) throws -> AnnotationExportPipeline.Summary {
        try pipeline.run(directory: directory, selection: selection,
                         citations: citations, citationsMarkdown: citationsMarkdown,
                         pageTrackText: trackText, colorName: colorName,
                         cleanName: cleanName, shouldCancel: shouldCancel)
    }

    static func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        // 简易指纹：字节计数 + Swift 内建哈希组合（只需「不变」断言，非密码学）。
        var h = UInt64(1_469_598_103_934_665_603)
        for byte in data { h = (h &* 31) &+ UInt64(byte) }
        return "\(data.count)-\(h)"
    }

    // MARK: 用例

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "AnnotationExportPipeline", name: "perBookFileWrittenWithThreeSections") {
                let lib = try makeLibrary()
                try addBook(lib, id: "bA", fileName: "a.pdf", title: "书名甲",
                            pages: ["甲页原文内容"])
                try addHighlight(lib, book: "bA", page: 1, note: "")
                try addHighlight(lib, book: "bA", page: 2, note: "带注批注内容")
                try addPageNote(lib, book: "bA", page: 3, note: "整页批注")
                let dir = try AnnotationExportPipeline.newRunDirectory(in: lib.root)
                let summary = try run(AnnotationExportPipeline(highlightStore: lib.highlights,
                                                               indexStore: lib.index),
                                      directory: dir)
                let md = try String(contentsOf: dir.appendingPathComponent("annotations/书名甲.md"),
                                    encoding: .utf8)
                try expectTrue(md.hasPrefix("# 书名甲"), "首行 = 书名（格式契约复用 HighlightExport）")
                // 三段分层，段序固定。
                let hl = try expectNotNil(md.range(of: "## 高亮"))
                let ann = try expectNotNil(md.range(of: "## 带注批注"))
                let pn = try expectNotNil(md.range(of: "## 页级批注"))
                try expectTrue(hl.lowerBound < ann.lowerBound && ann.lowerBound < pn.lowerBound)
                try expectTrue(md.contains("### 第 1 页"), "段内页块照契约")
                try expectTrue(md.contains("> 甲页原文内容"), "摘句 = 活切片（verified=1 走索引切片）")
                try expectTrue(md.contains("带注批注内容"), "note 落段内")
                try expectTrue(md.contains("整页批注"), "页级批注正文")
                try expectTrue(md.contains("物理页 1（测试桩）"), "三轨页码行注入生效")
                try expectEqual(summary.annotationRows, 3)
                try expectEqual(summary.failedBooks.count, 0)
            },

            TestDesc(suite: "AnnotationExportPipeline", name: "stateRecordsDoneAndSubSchema") {
                let lib = try makeLibrary()
                try addBook(lib, id: "bA", fileName: "a.pdf", title: "甲", pages: ["x"])
                try addBook(lib, id: "bB", fileName: "b.pdf", title: "乙", pages: ["y"])
                try addHighlight(lib, book: "bA", page: 1)
                let dir = try AnnotationExportPipeline.newRunDirectory(in: lib.root)
                _ = try run(AnnotationExportPipeline(highlightStore: lib.highlights,
                                                     indexStore: lib.index),
                            directory: dir)
                let data = try Data(contentsOf: dir.appendingPathComponent("export_state.json"))
                let state = try expectNotNil(AnnotationExportState.parse(data))
                try expectTrue(state.format == AnnotationExportState.formatID)
                try expectEqual(state.books["bA"]?.status, "done")
                try expectEqual(state.books["bA"]?.count, 1)
                try expectEqual(state.books["bB"]?.status, "done")
                try expectEqual(state.books["bB"]?.count, 0, "无批注书也记账 done（0 条）")
                try expectEqual(state.userHighlightsSubSchema, 8, "子 schema 随录")
            },

            TestDesc(suite: "AnnotationExportPipeline", name: "resumeSkipsDoneAndCSVHasNoGap") {
                let lib = try makeLibrary()
                try addBook(lib, id: "bA", fileName: "a.pdf", title: "甲", pages: ["x"])
                try addBook(lib, id: "bB", fileName: "b.pdf", title: "乙", pages: ["y"])
                try addHighlight(lib, book: "bA", page: 1)
                try addHighlight(lib, book: "bB", page: 1)
                let dir = try AnnotationExportPipeline.newRunDirectory(in: lib.root)
                // 预置记账：bA done、bB 失败（模拟上次中断）。
                let preset = AnnotationExportState(
                    userHighlightsSubSchema: 8, startedAt: Date(), updatedAt: Date(),
                    books: ["bA": .init(status: "done", count: 1),
                            "bB": .init(status: "failed", count: 0, error: "上次中断")])
                try AnnotationExportState.encoder.encode(preset)
                    .write(to: dir.appendingPathComponent("export_state.json"))
                // bA 的 MD 文件先删掉——若续跑错误地重写会被重建，断言抓得住。
                try FileManager.default.createDirectory(
                    at: dir.appendingPathComponent("annotations"), withIntermediateDirectories: true)
                let pipeline = AnnotationExportPipeline(highlightStore: lib.highlights,
                                                        indexStore: lib.index)
                let summary = try run(pipeline, directory: dir)
                try expectEqual(summary.skippedDoneBooks, 1, "done 书跳过重写")
                try expectFalse(FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("annotations/甲.md").path),
                    "跳过书不重写 MD")
                try expectTrue(FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("annotations/乙.md").path),
                    "failed 书重处理补写")
                // annotations.csv 全库单文件：跳过书的行也全量重建，无缺口。
                let csv = try String(contentsOf: dir.appendingPathComponent("annotations.csv"),
                                     encoding: .utf8)
                try expectTrue(csv.contains("bA"), "done 书行不缺口")
                try expectTrue(csv.contains("bB"))
                try expectEqual(summary.annotationRows, 2)
                try expectEqual(summary.processedBooks, 1, "本轮只处理 bB")
            },

            TestDesc(suite: "AnnotationExportPipeline", name: "unrecognizedStateFormatRefusesToRun") {
                let lib = try makeLibrary()
                try addBook(lib, id: "bA", fileName: "a.pdf", title: "甲", pages: ["x"])
                let dir = try AnnotationExportPipeline.newRunDirectory(in: lib.root)
                try Data("不是导出状态文件".utf8)
                    .write(to: dir.appendingPathComponent("export_state.json"))
                let pipeline = AnnotationExportPipeline(highlightStore: lib.highlights,
                                                        indexStore: lib.index)
                try expectThrows(try run(pipeline, directory: dir),
                                 "formatID 不识别即拒跑（fail-closed）")
            },

            TestDesc(suite: "AnnotationExportPipeline", name: "cancelKeepsWrittenFilesAndSkipsFinishingFiles") {
                let lib = try makeLibrary()
                try addBook(lib, id: "bA", fileName: "a.pdf", title: "甲", pages: ["x"])
                try addBook(lib, id: "bB", fileName: "b.pdf", title: "乙", pages: ["y"])
                try addHighlight(lib, book: "bA", page: 1)
                try addHighlight(lib, book: "bB", page: 1)
                let dir = try AnnotationExportPipeline.newRunDirectory(in: lib.root)
                var seen = 0
                let summary = try run(AnnotationExportPipeline(highlightStore: lib.highlights,
                                                               indexStore: lib.index),
                                      directory: dir,
                                      shouldCancel: { seen += 1; return seen > 1 })
                try expectTrue(summary.cancelled)
                try expectEqual(summary.processedBooks, 1, "取消在书间生效（第一本完成）")
                try expectTrue(FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("annotations/甲.md").path),
                    "已写文件保留")
                try expectFalse(FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("README.md").path),
                    "取消不写收尾索引（README 属完成件）")
                try expectFalse(FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("annotations.csv").path))
            },

            TestDesc(suite: "AnnotationExportPipeline", name: "csvEscapeCoversCommaQuoteNewlineAndEmptyNote") {
                // 转义四例（逗号/引号/换行/空 note）直接打纯函数 + 全文形态。
                try expectEqual(AnnotationExportAssembler.csvEscape("普"), "普")
                try expectEqual(AnnotationExportAssembler.csvEscape("含,逗号"), "\"含,逗号\"")
                try expectEqual(AnnotationExportAssembler.csvEscape("含\"引号"),
                                "\"含\"\"引号\"")
                try expectEqual(AnnotationExportAssembler.csvEscape("含\n换行"), "\"含\n换行\"")
                let row = AnnotationExportAssembler.AnnotationCSVRow(
                    bookID: "b,1", bookTitle: "书\"名", pageNumber: 2, type: "highlight",
                    color: "yellow", text: "多行\n摘句", note: "",
                    createdAtISO8601: "2026-09-30T00:00:00Z", viewSource: "ocr",
                    anchorVerified: 1)
                let csv = AnnotationExportAssembler.annotationsCSV(rows: [row])
                // 朴素按 \n 切：表头 + 数据行（含 1 个字段内换行拆成 2 物理行）
                // + 末尾空串 = 4——换行在引号字段内属同一 CSV 记录。
                let lines = csv.components(separatedBy: "\n")
                try expectEqual(lines.count, 4)
                try expectTrue(lines[0].hasPrefix("book_id,book_title"))
                try expectTrue(lines[1].hasPrefix("\"b,1\",\"书\"\"名\",2,highlight,yellow,\"多行"))
                try expectTrue(lines[2].hasPrefix("摘句\",,"))
                try expectTrue(csv.contains("2026-09-30T00:00:00Z"), "ISO8601 列在位")
            },

            TestDesc(suite: "AnnotationExportPipeline", name: "titleLadderTitleThenFileNameThenBookID") {
                let lib = try makeLibrary()
                try addBook(lib, id: "bA", fileName: "有书名.pdf", title: "书名甲", pages: ["x"])
                try addBook(lib, id: "bB", fileName: "乙书_异版00000001.pdf", title: nil, pages: ["y"])
                try addBook(lib, id: "bid-3", fileName: "", title: nil, pages: ["z"])
                try addHighlight(lib, book: "bA", page: 1)
                try addHighlight(lib, book: "bB", page: 1)
                try addHighlight(lib, book: "bid-3", page: 1)
                let dir = try AnnotationExportPipeline.newRunDirectory(in: lib.root)
                _ = try run(AnnotationExportPipeline(highlightStore: lib.highlights,
                                                     indexStore: lib.index),
                            directory: dir)
                let files = try FileManager.default.contentsOfDirectory(
                    at: dir.appendingPathComponent("annotations"), includingPropertiesForKeys: nil)
                    .map(\.lastPathComponent).sorted()
                try expectEqual(files, ["bid-3.md", "乙书_异版00000001.md", "书名甲.md"],
                                "阶梯：title → 清洗后 fileName → bookID")
            },

            TestDesc(suite: "AnnotationExportPipeline", name: "emptyLibraryExportsHonestSkeleton") {
                let lib = try makeLibrary()
                let dir = try AnnotationExportPipeline.newRunDirectory(in: lib.root)
                let summary = try run(AnnotationExportPipeline(highlightStore: lib.highlights,
                                                               indexStore: lib.index),
                                      directory: dir)
                try expectEqual(summary.processedBooks, 0)
                let readme = try String(contentsOf: dir.appendingPathComponent("README.md"),
                                        encoding: .utf8)
                try expectTrue(readme.contains("（无书目）"))
                let csv = try String(contentsOf: dir.appendingPathComponent("annotations.csv"),
                                     encoding: .utf8)
                try expectTrue(csv.hasPrefix("book_id,book_title,page"), "空库 = 仅表头")
                try expectEqual(summary.annotationRows, 0)
            },

            TestDesc(suite: "AnnotationExportPipeline", name: "citationsRowsMatchBooks") {
                let lib = try makeLibrary()
                try addBook(lib, id: "bA", fileName: "a.pdf", title: "甲", pages: ["x"])
                try addBook(lib, id: "bB", fileName: "b.pdf", title: "乙", pages: ["y"])
                let citations = [
                    AnnotationExportCitationRow(author: "", title: "甲", version: "",
                                                language: "zh", fileName: "a.pdf", citation: "甲."),
                    AnnotationExportCitationRow(author: "某作者", title: "乙", version: "第二版",
                                                language: "zh", fileName: "b.pdf", citation: "乙."),
                ]
                let dir = try AnnotationExportPipeline.newRunDirectory(in: lib.root)
                _ = try run(AnnotationExportPipeline(highlightStore: lib.highlights,
                                                     indexStore: lib.index),
                            directory: dir,
                            citations: citations, citationsMarkdown: "甲.\n乙.")
                let md = try String(contentsOf: dir.appendingPathComponent("citations.md"),
                                    encoding: .utf8)
                try expectEqual(md.components(separatedBy: "\n").count, 2, "一行一书")
                let csv = try String(contentsOf: dir.appendingPathComponent("citations.csv"),
                                     encoding: .utf8)
                try expectEqual(csv.components(separatedBy: "\n").count, 4,
                                "表头 + 2 行（books 数）+ 末尾空串")
                try expectTrue(csv.contains("某作者"))
            },

            TestDesc(suite: "AnnotationExportPipeline", name: "citationOnlySelectionWritesNoAnnotationFiles") {
                let lib = try makeLibrary()
                try addBook(lib, id: "bA", fileName: "a.pdf", title: "甲", pages: ["x"])
                try addHighlight(lib, book: "bA", page: 1)
                let dir = try AnnotationExportPipeline.newRunDirectory(in: lib.root)
                _ = try run(AnnotationExportPipeline(highlightStore: lib.highlights,
                                                     indexStore: lib.index),
                            directory: dir,
                            selection: AnnotationExportSelection(annotationsMarkdown: false,
                                                                 annotationsCSV: false,
                                                                 citationsMarkdown: true,
                                                                 citationsCSV: true),
                            citationsMarkdown: "甲.")
                try expectFalse(FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("annotations.csv").path))
                try expectFalse(FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("annotations").path))
                try expectTrue(FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("citations.md").path))
                try expectTrue(FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("citations.csv").path))
            },

            TestDesc(suite: "AnnotationExportPipeline", name: "exportDoesNotMutateHighlightDatabase") {
                let lib = try makeLibrary()
                try addBook(lib, id: "bA", fileName: "a.pdf", title: "甲", pages: ["甲页原文内容"])
                try addHighlight(lib, book: "bA", page: 1, anchor: "甲页原文")
                let dbURL = lib.root.appendingPathComponent("index.db")
                let before = try sha256(dbURL)
                let dir = try AnnotationExportPipeline.newRunDirectory(in: lib.root)
                _ = try run(AnnotationExportPipeline(highlightStore: lib.highlights,
                                                     indexStore: lib.index),
                            directory: dir)
                let after = try sha256(dbURL)
                try expectEqual(before, after, "导出全程只读批注库（逐字节不变）")
                // 批注行数与内容不变（读侧再断言）。
                try expectEqual(try lib.highlights.allHighlightsCount(), 1)
            },

            TestDesc(suite: "AnnotationExportPipeline", name: "csvTypesProjectHighlightUnderlinePageNote") {
                let lib = try makeLibrary()
                try addBook(lib, id: "bA", fileName: "a.pdf", title: "甲", pages: ["原文"])
                try addHighlight(lib, book: "bA", page: 1, style: "underline")
                try addHighlight(lib, book: "bA", page: 2)
                try addPageNote(lib, book: "bA", page: 3, note: "页批")
                let dir = try AnnotationExportPipeline.newRunDirectory(in: lib.root)
                _ = try run(AnnotationExportPipeline(highlightStore: lib.highlights,
                                                     indexStore: lib.index),
                            directory: dir)
                let csv = try String(contentsOf: dir.appendingPathComponent("annotations.csv"),
                                     encoding: .utf8)
                try expectTrue(csv.contains(",underline,"), "下划线类型投影")
                try expectTrue(csv.contains(",highlight,"), "高亮类型投影")
                try expectTrue(csv.contains(",page_note,"), "页级批注类型投影")
                let pageNoteLine = csv.components(separatedBy: "\n").first { $0.contains("page_note") }
                let line = try expectNotNil(pageNoteLine)
                try expectTrue(line.contains("yellow,,页批"),
                               "page_note 行 text 列为空、note 在 note 列")
                try expectTrue(line.hasSuffix(",ocr,0"), "view_source/anchor_verified 列在位")
            },

            TestDesc(suite: "AnnotationExportPipeline", name: "failedBookRecordedOthersContinue") {
                let lib = try makeLibrary()
                try addBook(lib, id: "bA", fileName: "a.pdf", title: "失败书", pages: ["x"])
                try addBook(lib, id: "bB", fileName: "b.pdf", title: "顺利书", pages: ["y"])
                try addHighlight(lib, book: "bA", page: 1)
                try addHighlight(lib, book: "bB", page: 1)
                let dir = try AnnotationExportPipeline.newRunDirectory(in: lib.root)
                // 预埋写盘障碍：annotations/失败书.md 是目录 → atomicWrite 抛错
                // → bA 记 failed，管道继续 bB（单书失败不拖垮整批）。
                try FileManager.default.createDirectory(
                    at: dir.appendingPathComponent("annotations"), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(
                    at: dir.appendingPathComponent("annotations/失败书.md"),
                    withIntermediateDirectories: true)
                let summary = try run(AnnotationExportPipeline(highlightStore: lib.highlights,
                                                               indexStore: lib.index),
                                      directory: dir)
                try expectEqual(summary.failedBooks.count, 1)
                try expectEqual(summary.failedBooks.first?.id, "bA")
                try expectEqual(summary.processedBooks, 2, "失败后继续下一书")
                try expectFalse(summary.allFailed, "未全失败不算整体失败")
                let readme = try String(contentsOf: dir.appendingPathComponent("README.md"),
                                        encoding: .utf8)
                try expectTrue(readme.contains("失败书目"), "README 如实列出失败书")
                try expectTrue(readme.contains("bA"))
                try expectTrue(FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("annotations/顺利书.md").path))
            },

            TestDesc(suite: "AnnotationExportPipeline", name: "newRunDirectorySuffixesOnCollision") {
                let lib = try makeLibrary()
                let date = Date(timeIntervalSince1970: 1_791_768_000)
                let first = try AnnotationExportPipeline.newRunDirectory(in: lib.root, at: date)
                let second = try AnnotationExportPipeline.newRunDirectory(in: lib.root, at: date)
                try expectTrue(second.lastPathComponent.hasSuffix("-2"),
                               "同名冲突追加 -2 后缀：\(second.lastPathComponent)")
                try expectNotEqual(first, second)
            },

            TestDesc(suite: "AnnotationExportPipeline", name: "stateRoundTripAndRejectForeignFormats") {
                let state = AnnotationExportState(
                    userHighlightsSubSchema: 8,
                    startedAt: Date(timeIntervalSince1970: 1_791_768_000),
                    updatedAt: Date(timeIntervalSince1970: 1_791_768_100),
                    books: ["bA": .init(status: "done", count: 3)])
                let data = try AnnotationExportState.encoder.encode(state)
                let parsed = try expectNotNil(AnnotationExportState.parse(data))
                try expectEqual(parsed, state, "ISO8601 策略下 round-trip 等值")
                // 外来 format / 坏 JSON 一律拒识。
                let foreign = #"{"format":"someone-elses-export/9","books":{}}"#
                try expectNil(AnnotationExportState.parse(Data(foreign.utf8)))
                try expectNil(AnnotationExportState.parse(Data("{}".utf8)))
            },
        ]
    }
}
