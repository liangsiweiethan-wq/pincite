import Foundation
@testable import LiteratureCore

// Regression coverage for indexing, search ordering, OCR cleanup, and CLI output.
// CLI behavior is checked through source assertions and subprocess tests where the
// test target cannot import the executable target.

enum IndexingRegressionSuite {

    // MARK: 夹具

    /// 手工建书（不生成 PDF；页文本直接落库）。
    static func addBook(_ store: IndexStore, id: String, fileName: String,
                        title: String?, author: String?, pages: [String],
                        pageCount override: Int? = nil) throws -> IndexStore.BookRow {
        var book = IndexStore.BookRow(
            id: id, realPath: "/tmp/lit-finalfix/\(id)/\(fileName)", rootPath: "/tmp/lit-finalfix",
            relPath: fileName, fileName: fileName,
            firstFingerprint: "fp-\(id)", fingerprint: "fp-\(id)", fileSize: 1, mtime: 0,
            pageCount: override ?? max(pages.count, 1), status: "ok", indexedAt: 0)
        book.title = title
        book.author = author
        try store.upsertBook(book)
        var rows: [IndexStore.PageRow] = []
        for (i, text) in pages.enumerated() {
            let n = normalizeForSearch(text)
            rows.append(IndexStore.PageRow(bookID: id, pageNumber: i + 1, textOriginal: text,
                                           textNorm: n.text, normStarts: n.starts, normEnds: n.ends))
        }
        if !rows.isEmpty { try store.replacePages(bookID: id, rows) }
        return book
    }

    /// 混合书夹具：3 页全映射；页 1 原生文本保留（kept-native），页 2/3 无
    /// 文本层由 OCR 供文。回归点：purgeOCR 不得按全映射清空，页 1 原生层须保留。
    static func makeMixedOCRBook() throws -> (IndexStore, URL, String) {
        let dir = Fixtures.makeTempDir("finalfix-f1")
        let store = try Fixtures.openStore(in: dir)
        let id = "bk-mixed"
        try addBook(store, id: id, fileName: "mixed-native-ocr.pdf",
                    title: "混合书", author: nil,
                    pages: ["native chapter one 原生第一章", "", ""])
        let ocrBook = IndexStore.OCRBookRow(
            bookID: id, ocrRealPath: "/tmp/lit-finalfix/mixed-ocr.pdf",
            ocrFingerprint: "fp-ocr", mappingKind: "same-page-verified",
            createdAt: 0)
        let mapping = [OCRPagePair(originalPage: 1, ocrPage: 1),
                       OCRPagePair(originalPage: 2, ocrPage: 2),
                       OCRPagePair(originalPage: 3, ocrPage: 3)]
        func upd(_ page: Int, _ text: String) -> IndexStore.OCRPageTextUpdate {
            let n = normalizeForSearch(text)
            return IndexStore.OCRPageTextUpdate(originalPage: page, ocrPage: page,
                                                textOriginal: text, textNorm: n.text,
                                                normStarts: n.starts, normEnds: n.ends)
        }
        try store.applyOCRPages(bookID: id, ocrBook: ocrBook, mapping: mapping, updates: [
            upd(2, "ocr page two 非derivativesTuition 术语页"),
            upd(3, "ocr page three 尾页"),
        ])
        return (store, dir, id)
    }

    static var tests: [TestDesc] {
        [
            // MARK: purgeOCR 保留原生页文本

            TestDesc(suite: "IndexingRegression", name: "purgeOCRSparcesKeptNativePages") {
                let (store, dir, id) = try makeMixedOCRBook()
                defer { Fixtures.cleanup(dir) }
                let p1 = try expectNotNil(try store.page(bookID: id, pageNumber: 1))
                try expectTrue(p1.textNorm.contains("native chapter"), "页 1 必须是原生文本")
                let pairing = try expectNotNil(try store.ocrPairing(bookID: id))
                try expectEqual(pairing.ocrSourcedPages, [2, 3], "OCR 源页恰为 2/3（页 1 kept-native）")

                try store.purgeOCR(bookID: id)

                // 主断言：kept-native 页 1 的文本层与 FTS 索引零扰动。
                let p1After = try expectNotNil(try store.page(bookID: id, pageNumber: 1))
                try expectTrue(p1After.textNorm.contains("native chapter"),
                               "purgeOCR 不得清空 kept-native 原生页文本")
                try expectEqual(p1After.textOriginal, p1.textOriginal, "原生页原文逐字节保留")
                let svc = SearchService(store: store)
                let nativeHits = try svc.searchDetailed("native chapter")
                try expectTrue(nativeHits.hits.contains { $0.bookID == id && $0.physicalPage == 1 },
                               "purge 后原生文本仍可检索（FTS 同步只删 OCR 页）")
                // OCR 文本确已清退：清退词零命中、页 2/3 回到无文本态。
                let ocrHits = try svc.searchDetailed("derivativestuition")
                try expectTrue(ocrHits.hits.isEmpty, "OCR 供文页的词必须随清退从 FTS 消失")
                let p2After = try expectNotNil(try store.page(bookID: id, pageNumber: 2))
                try expectTrue(p2After.textNorm.isEmpty, "OCR 页清退为无文本")
                try expectNil(try store.ocrPairing(bookID: id), "配对记录整体删除")
            },

            // MARK: 阶段二按页主键配对

            TestDesc(suite: "IndexingRegression", name: "pairStage2ExactUnderDroppedRows") {
                func skel(_ book: String, _ page: Int) -> SearchHit {
                    SearchHit(bookID: book, filePath: "/tmp/\(book).pdf", fileName: "\(book).pdf",
                              fingerprint: "fp", physicalPage: page, pageLabel: nil, printedPage: nil,
                              pageCount: 3, title: nil, author: nil, version: nil, language: nil,
                              matches: [], snippet: "")
                }
                func row(_ book: String, _ page: Int) -> IndexStore.PageRow {
                    IndexStore.PageRow(bookID: book, pageNumber: page,
                                       textOriginal: "t\(page)", textNorm: "t\(page)",
                                       normStarts: [], normEnds: [])
                }
                let skeletons = [skel("b1", 1), skel("b1", 2), skel("b1", 3)]
                // 并发删页形态：中间行（b1#2）在 Stage1→Stage2 间隙消失。
                let shortRows = [row("b1", 1), row("b1", 3)]
                let paired = SearchService.pairStage2Rows(skeletons: skeletons, fullRows: shortRows)
                try expectEqual(paired.count, 2, "消失页只跳过不补位")
                try expectEqual(paired[0].skeleton.physicalPage, 1)
                try expectEqual(paired[0].row.pageNumber, 1)
                try expectEqual(paired[1].skeleton.physicalPage, 3, "骨架 3 必须配页 3 的行")
                try expectEqual(paired[1].row.pageNumber, 3,
                                "并发缩行时骨架必须按页主键配对（不得张冠李戴）")
                // 无并发（等长）形态：与 zip 逐项同配对。
                let full = [row("b1", 1), row("b1", 2), row("b1", 3)]
                let pairedFull = SearchService.pairStage2Rows(skeletons: skeletons, fullRows: full)
                try expectEqual(pairedFull.count, 3)
                for (i, p) in pairedFull.enumerated() {
                    try expectEqual(p.skeleton, skeletons[i], "等长时骨架序与 zip 一致")
                    try expectEqual(p.row.pageNumber, i + 1, "等长时行序与 zip 一致")
                }
                // 真实链路端到端：正常库上配对语义不漂（结果与既有语义恒等）。
                let dir = Fixtures.makeTempDir("finalfix-f2")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                try addBook(store, id: "b1", fileName: "b1.pdf", title: nil, author: nil,
                            pages: ["anchor here", "anchor again", "anchor more"])
                let r1 = try SearchService(store: store).searchDetailed("anchor")
                try expectEqual(r1.hits.count, 3)
                try expectEqual(r1.totalPageMatches, 3)
            },

            // MARK: detect-body-start（源文本断言＋子进程行为断言）

            TestDesc(suite: "IndexingRegression", name: "detectBodyStartZeroPageBookAndFortyPageCap") {
                let url = DesignGuardSuite.repoRoot
                    .appendingPathComponent("Sources/literaturesearch-cli/LiteratureSearchCLI.swift")
                let text = try expectNotNil(try? String(contentsOf: url, encoding: .utf8))
                guard let start = text.range(of: "static func detectBodyStartCommand"),
                      let end = text.range(of: "\n    static func ",
                                           range: start.upperBound..<text.endIndex) else {
                    try failTest("detectBodyStartCommand 函数体定位失败（源结构漂移？）")
                }
                let body = String(text[start.lowerBound..<end.lowerBound])
                // 源断言：零页书 guard 在位。
                try expectTrue(body.contains("book.pageCount >= 1"),
                               "detect-body-start 缺零页书 guard")
                // 源断言：扫描上限与 docstring 一致，为 40 页。
                try expectTrue(body.contains("min(book.pageCount, 40)"),
                               "detect-body-start 缺 40 页扫描上限")

                let bin = DesignGuardSuite.repoRoot
                    .appendingPathComponent(".build/debug/literaturesearch-cli")
                try expectTrue(FileManager.default.fileExists(atPath: bin.path),
                               "CLI 二进制不存在——本测试要求先 swift build 再跑测试")

                // 行为断言：status=ok pageCount=0 的书不得越界 fatal。
                let dir0 = Fixtures.makeTempDir("finalfix-f3")
                defer { Fixtures.cleanup(dir0) }
                let store0 = try Fixtures.openStore(in: dir0)
                try addBook(store0, id: "bk-zero", fileName: "zero-pager.pdf",
                            title: "零页书", author: nil, pages: [], pageCount: 0)
                var p0 = Process()
                p0.executableURL = bin
                p0.arguments = ["detect-body-start", "--db", dir0.appendingPathComponent("index.db").path,
                                "--book", "bk-zero"]
                let pipe0 = Pipe()
                p0.standardOutput = pipe0; p0.standardError = pipe0
                try p0.run(); p0.waitUntilExit()
                let out0 = String(data: pipe0.fileHandleForReading.readDataToEndOfFile(),
                                  encoding: .utf8) ?? ""
                try expectEqual(p0.terminationStatus, 0,
                                "零页书必须跳过不崩溃；输出：\(out0)")
                try expectTrue(out0.contains("1 本书扫描"), "汇总行缺失；输出：\(out0)")

                // 行为断言：41 页书，最强信号（印刷页码从 1 重启）在第 41 页——
                // 上限生效时探测器看不到第 41 页，回退候选＝版权页后首个非目录页
                //（第 4 页）；若越限全书扫描则会误报 41。
                let dir4 = Fixtures.makeTempDir("finalfix-f4")
                defer { Fixtures.cleanup(dir4) }
                let store4 = try Fixtures.openStore(in: dir4)
                var pages: [String] = []
                pages.append("前言 preface")
                pages.append("ISBN 978-7-01-001-001-1 版权所有 侵权必究")
                pages.append("目录\n第一章……1\n第二章……5\n第三章……9")
                for p in 4...40 { pages.append("正文片段 fragment\n\(p + 2)") }
                pages.append("正文第一章 真正的起始\n1")
                try addBook(store4, id: "bk-long", fileName: "long-book.pdf",
                            title: "长书", author: nil, pages: pages)
                var p4 = Process()
                p4.executableURL = bin
                p4.arguments = ["detect-body-start", "--db", dir4.appendingPathComponent("index.db").path,
                                "--book", "bk-long"]
                let pipe4 = Pipe()
                p4.standardOutput = pipe4; p4.standardError = pipe4
                try p4.run(); p4.waitUntilExit()
                let out4 = String(data: pipe4.fileHandleForReading.readDataToEndOfFile(),
                                  encoding: .utf8) ?? ""
                try expectEqual(p4.terminationStatus, 0, "41 页书必须正常扫描；输出：\(out4)")
                try expectTrue(out4.contains("候选正文起始物理页 4（"),
                               "40 页上限生效：回退候选应为第 4 页；输出：\(out4)")
                try expectFalse(out4.contains("物理页 41"),
                                "越限全书扫描复现（第 41 页的信号不得被看到）；输出：\(out4)")
            },

            // MARK: 拼音别名门控

            TestDesc(suite: "IndexingRegression", name: "pinyinAliasOnlyWhenPrimaryMisses") {
                let dir = Fixtures.makeTempDir("finalfix-f5")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                // 主形态命中书：西文 van 直落投影。
                try addBook(store, id: "bk-van", fileName: "van-records.pdf",
                            title: "Zorvex Sample Records", author: nil,
                            pages: ["van records text"])
                try addBook(store, id: "bk-yuan", fileName: "yuanli.pdf",
                            title: "元理", author: nil, pages: ["元理正文"])
                try addBook(store, id: "bk-quan", fileName: "quanguan.pdf",
                            title: "全观", author: nil, pages: ["全观正文"])
                try store.backfillPinyinIfNeeded()

                // 主断言：van 主形态有命中 → 别名不启用，uan 系书不得被拖入。
                let hits = try store.bookIDsMatchingPinyin("van")
                try expectEqual(hits, ["bk-van"],
                                "van 主形态命中时别名（uan）不得参与（并集不得误伤置前）")
                // falv 语义不回退：主形态零命中 → 别名补位。
                try addBook(store, id: "bk-law", fileName: "sample.pdf",
                            title: "法律样本", author: nil, pages: ["sample archive records"])
                try store.backfillPinyinIfNeeded()
                try expectTrue(try store.bookIDsMatchingPinyin("falv").contains("bk-law"),
                               "falv 主形态零命中必须经 v→u 别名命中《法律样本》（拼音别名不回退）")
                // 降级处理语义断言：库内无 van 投影时，van 经别名回落 uan 命中（别名
                // 只在零命中时启用的另一面）。
                try expectTrue(try store.bookIDsMatchingPinyin("yuanli").contains("bk-yuan"),
                               "uan 主形态点查照常命中")
            },

            // MARK: 改名后投影当次可查

            TestDesc(suite: "IndexingRegression", name: "upsertBookRenameRebuildsPinyinProjection") {
                let dir = Fixtures.makeTempDir("finalfix-f6")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                try addBook(store, id: "bk-ren", fileName: "old-法律名.pdf",
                            title: "法律样本", author: nil, pages: ["text"])
                try store.backfillPinyinIfNeeded()
                try expectTrue(try store.bookIDsMatchingPinyin("faluyangben").contains("bk-ren"),
                               "改前：title 投影命中")
                // 改名重索引形态：同 id upsert 换 file_name（title/author 不变，
                // upsert 的 ON CONFLICT 不更新它们——与真实重索引一致）。
                var renamed = try expectNotNil(try store.book(byID: "bk-ren"))
                renamed.fileName = "new-sample.pdf"
                try store.upsertBook(renamed)
                // 主断言：新名拼音当次会话即可查（不依赖 backfill）。
                try expectTrue(try store.bookIDsMatchingPinyin("newsamplepdf").contains("bk-ren"),
                               "改名后新 file_name 投影必须当次可查（投影须重建，不得永久过期）")
                try expectTrue(try store.bookIDsMatchingPinyin("oldpdf").isEmpty,
                               "旧 file_name 投影必须失效")
                try expectTrue(try store.bookIDsMatchingPinyin("faluyangben").contains("bk-ren"),
                               "title 部分投影保留（upsert 不改 title）")
                // 书目级全链路：新名拼音命中可经 matchingBooks 检出。
                let hits = try SearchService(store: store).matchingBooks("newsample")
                try expectTrue(hits.contains { $0.bookID == "bk-ren" },
                               "matchingBooks 新名拼音命中")
            },

            // MARK: 同名书并列排序

            TestDesc(suite: "IndexingRegression", name: "matchingBooksSyntaxTieResolvedByBookID") {
                let dir = Fixtures.makeTempDir("finalfix-f7")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                // 两书同 fileName、同级页计数（各 1 页命中）——旧比较器在
                // (matchingPages, fileName) 全并列时非严格全序，输出随迭代序漂移。
                for id in ["bk-009", "bk-002"] {
                    try addBook(store, id: id, fileName: "same-name.pdf",
                                title: "同名书 \(id)", author: nil,
                                pages: ["anchor syntax \(id)"])
                }
                let svc = SearchService(store: store)
                var last: [SearchService.BookHitSummary] = []
                for run in 0..<5 {
                    // 扰动：清查询缓存强制不同代码路径（缓存命中/未命中）。
                    try store.purgeQueryCaches()
                    // 正则查询（~ 语法字符）强制走 matchingBooksSyntax。
                    let hits = try svc.matchingBooks("~anchor")
                    try expectEqual(hits.count, 2, "两书均须命中（run \(run)）")
                    if !last.isEmpty {
                        try expectEqual(hits, last, "语法层排序必须为库状态纯函数（run \(run)）")
                    }
                    // 并列段（matchingPages 与 fileName 均同）必须以 bookID 升序结算。
                    if hits.count == 2 {
                        try expectTrue(hits[0].bookID < hits[1].bookID,
                                       "同名书并列必须 bookID 升序；实得 \(hits.map(\.bookID))")
                    }
                    last = hits
                }
            },

            // MARK: reindex-book JSON 转义（源文本断言）

            TestDesc(suite: "IndexingRegression", name: "reindexBookJSONEscapesControlChars") {
                let url = DesignGuardSuite.repoRoot
                    .appendingPathComponent("Sources/literaturesearch-cli/LiteratureSearchCLI.swift")
                let text = try expectNotNil(try? String(contentsOf: url, encoding: .utf8))
                guard let start = text.range(of: "static func reindexBookCommand"),
                      let end = text.range(of: "\n    static func ",
                                           range: start.upperBound..<text.endIndex) else {
                    try failTest("reindexBookCommand 函数体定位失败（源结构漂移？）")
                }
                let body = String(text[start.lowerBound..<end.lowerBound])
                for esc in ["\\n", "\\r", "\\t"] {
                    try expectTrue(body.contains("replacingOccurrences(of: \"\(esc)\""),
                                   "reindex-book JSON message 缺 \(esc) 控制字符转义")
                }
            },
            // MARK: purgeOCR 完整性四断言

            TestDesc(suite: "IndexingRegression", name: "purgeOCRCrossBookMappingIsolation") {
                let dir = Fixtures.makeTempDir("finalfix-f1-iso")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                // 两本混合书各自成对：页 1 原生 kept，页 2/3 OCR 供文。
                func makeMixed(_ id: String) throws {
                    try IndexingRegressionSuite.addBook(store, id: id, fileName: "\(id).pdf",
                                                   title: id, author: nil,
                                                   pages: ["native kept \(id)", "", ""])
                    let ocrBook = IndexStore.OCRBookRow(
                        bookID: id, ocrRealPath: "/tmp/lit-finalfix/\(id)-ocr.pdf",
                        ocrFingerprint: "fp-ocr-\(id)", mappingKind: "same-page-verified",
                        createdAt: 0)
                    let mapping = [OCRPagePair(originalPage: 1, ocrPage: 1),
                                   OCRPagePair(originalPage: 2, ocrPage: 2),
                                   OCRPagePair(originalPage: 3, ocrPage: 3)]
                    func upd(_ p: Int, _ t: String) -> IndexStore.OCRPageTextUpdate {
                        let n = normalizeForSearch(t)
                        return IndexStore.OCRPageTextUpdate(originalPage: p, ocrPage: p,
                                                            textOriginal: t, textNorm: n.text,
                                                            normStarts: n.starts, normEnds: n.ends)
                    }
                    try store.applyOCRPages(bookID: id, ocrBook: ocrBook, mapping: mapping, updates: [
                        upd(2, "ocr shared term \(id)"), upd(3, "ocr tail \(id)"),
                    ])
                }
                try makeMixed("isoa")
                try makeMixed("isob")
                try store.purgeOCR(bookID: "isoa")
                // A 清退，B 全量无扰动（映射/页文本/检索面）＝跨书映射隔离。
                try expectNil(try store.ocrPairing(bookID: "isoa"), "A 配对已清")
                let b = try expectNotNil(try store.ocrPairing(bookID: "isob"),
                                         "purge A 不得触及 B 的配对（跨书映射隔离）")
                try expectEqual(b.ocrSourcedPages, [2, 3], "B 的 OCR 源页集合原样")
                let b2 = try expectNotNil(try store.page(bookID: "isob", pageNumber: 2))
                try expectTrue(b2.textNorm.contains("shared"), "B 的 OCR 页文本零扰动")
                let svc = SearchService(store: store)
                try expectTrue(try svc.searchDetailed("ocr shared term isob").hits
                    .contains { $0.bookID == "isob" }, "B 的 OCR 词照常可检索")
                try expectTrue(try svc.searchDetailed("ocr shared term isoa").hits.isEmpty,
                               "A 的 OCR 词已清退")
            },

            TestDesc(suite: "IndexingRegression", name: "purgeOCRUniqueTargetsOnMixedLayerBook") {
                let (store, dir, id) = try makeMixedOCRBook()
                defer { Fixtures.cleanup(dir) }
                // 同书混合层：映射覆盖 1/2/3（含 kept-native 页 1），清退目标
                // 恰为 {2,3}；逐页 UPDATE 经 pages PK(book_id, page_number)
                // 每页恰一行——页行不删、不重复、不越界。
                try store.purgeOCR(bookID: id)
                let p1 = try expectNotNil(try store.page(bookID: id, pageNumber: 1))
                try expectTrue(p1.textNorm.contains("native"), "kept-native 页行保留且文本在")
                for pn in 2...3 {
                    let p = try expectNotNil(try store.page(bookID: id, pageNumber: pn),
                                             "页行 \(pn) 必须在（清退≠删行）")
                    try expectTrue(p.textNorm.isEmpty, "页 \(pn) 清退为无文本态")
                }
                try expectNil(try store.page(bookID: id, pageNumber: 4), "不得产生越界行")
                try expectNil(try store.ocrPairing(bookID: id), "映射整体删除")
            },

            TestDesc(suite: "IndexingRegression", name: "purgeOCRMissingMappedRowStaysIdempotent") {
                let dir = Fixtures.makeTempDir("finalfix-f1-miss")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                try IndexingRegressionSuite.addBook(store, id: "bk-miss", fileName: "miss.pdf",
                                               title: "缺行书", author: nil,
                                               pages: ["native kept", "", ""])
                let ocrBook = IndexStore.OCRBookRow(
                    bookID: "bk-miss", ocrRealPath: "/tmp/lit-finalfix/miss-ocr.pdf",
                    ocrFingerprint: "fp-miss", mappingKind: "same-page-verified",
                    createdAt: 0)
                let mapping = [OCRPagePair(originalPage: 1, ocrPage: 1),
                               OCRPagePair(originalPage: 2, ocrPage: 2),
                               OCRPagePair(originalPage: 3, ocrPage: 3),
                               OCRPagePair(originalPage: 99, ocrPage: 99)]
                func upd(_ p: Int, _ t: String) -> IndexStore.OCRPageTextUpdate {
                    let n = normalizeForSearch(t)
                    return IndexStore.OCRPageTextUpdate(originalPage: p, ocrPage: p,
                                                        textOriginal: t, textNorm: n.text,
                                                        normStarts: n.starts, normEnds: n.ends)
                }
                try store.applyOCRPages(bookID: "bk-miss", ocrBook: ocrBook,
                                        mapping: mapping, updates: [
                    upd(2, "ocr missing row page"), upd(3, "ocr tail page"),
                ])
                try store.purgeOCR(bookID: "bk-miss")
                let p1 = try expectNotNil(try store.page(bookID: "bk-miss", pageNumber: 1))
                try expectTrue(p1.textNorm.contains("native"), "kept-native 页零扰动")
                let p2 = try expectNotNil(try store.page(bookID: "bk-miss", pageNumber: 2))
                try expectTrue(p2.textNorm.isEmpty, "OCR 页照常清退")
                try expectNil(try store.ocrPairing(bookID: "bk-miss"), "含缺失行的映射整体删除")
                // 顺带断言幂等面：对已清退书重复 purge 无害（空集 guard 早退）。
                try store.purgeOCR(bookID: "bk-miss")
                try expectNil(try store.ocrPairing(bookID: "bk-miss"), "重复 purge 幂等")
            },

            TestDesc(suite: "IndexingRegression", name: "purgeOCRRerunIsHarmless") {
                let (store, dir, id) = try makeMixedOCRBook()
                defer { Fixtures.cleanup(dir) }
                try store.purgeOCR(bookID: id)
                let p1First = try expectNotNil(try store.page(bookID: id, pageNumber: 1))
                try store.purgeOCR(bookID: id)   // 第二次：映射已空，guard 早退重删 ocr_books
                let p1 = try expectNotNil(try store.page(bookID: id, pageNumber: 1))
                try expectEqual(p1.textNorm, p1First.textNorm, "二次 purge 对原生页零扰动")
                try expectTrue(p1.textNorm.contains("native"), "原生页仍完好")
                let p2 = try expectNotNil(try store.page(bookID: id, pageNumber: 2))
                try expectTrue(p2.textNorm.isEmpty, "OCR 页保持清退态")
                try expectNil(try store.ocrPairing(bookID: id), "配对保持删除")
                let svc = SearchService(store: store)
                try expectTrue(try svc.searchDetailed("native chapter").hits
                    .contains { $0.bookID == id && $0.physicalPage == 1 }, "原生词可检索")
                try expectTrue(try svc.searchDetailed("derivativestuition").hits.isEmpty,
                               "OCR 词无复活")
            },

        ]
    }
}
