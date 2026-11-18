import Foundation
@testable import LiteratureCore

// MARK: - 改名路径重绑定套件
//
// 覆盖
//  基本回绑：盘上真文件建→库有行→盘上改名→回绑→新路径命中同 id／旧路径 nil／
//     file_name·rel_path 对／页行仍在（pages 只按 book_id 关联，无需改）
//  拼音投影随改名重建（新 file_name 的拼音可查）
//  OCR 独立两例：只改名书文件→ocr_books 不动；回执含 OCR 旧→新→ocr_real_path 更新
//    且 ocrPairing 仍解析
// 守卫逐个断言：新路径不存在／已属别的书／旧盘路径仍在／换库根仍拒，
// 放宽后「作者文件夹改名」放行、「挪到别的作者目录」仍拒
//  多行回执全有或全无：首行合法＋次行被拒→failed=true 且首行也没写
//     （库文件 shasum 前后相等）
//  幂等重跑：二次跑全 ALREADY_REBOUND、库 sha 不变
//  dry-run：报告为 DRY_RUN_HIT、库 sha 不变
//  有效回绑后书内候选页／阅读侧查询仍按同 id 解析（book_id 稳定）
// 回执壳解析与空批拒绝（CLI 侧同构逻辑经 JSON 往返断言）
enum RenameRebindSuite {

    // MARK: 夹具

    /// 在给定根下建真 PDF 文件并入索引（页面文本直接落库，不再读盘）。
    private static func addBook(_ store: IndexStore, id: String, rootPath: String,
                                 fileName: String, title: String?, author: String?,
                                 pages: [String]) throws -> IndexStore.BookRow {
        var book = IndexStore.BookRow(
            id: id, realPath: "\(rootPath)/\(fileName)", rootPath: rootPath,
            relPath: fileName, fileName: fileName,
            firstFingerprint: "fp-\(id)", fingerprint: "fp-\(id)", fileSize: 12, mtime: 0,
            pageCount: max(pages.count, 1), status: "ok", indexedAt: 0)
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

    /// 盘上写真文件（rename 语义要求旧路径真消失）。
    private static func writeFile(_ path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("rebind-fixture".utf8).write(to: url)
    }

    private static func renameOnDisk(_ old: String, _ new: String) throws {
        try FileManager.default.moveItem(atPath: old, toPath: new)
    }

    private static func shaOf(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return Fingerprint.sha256Hex(of: data)
    }

    private static func makeStore() throws -> (IndexStore, URL) {
        let dir = Fixtures.makeTempDir("rebind")
        return (try Fixtures.openStore(in: dir), dir)
    }

    static var tests: [TestDesc] {
        [
            // MARK: 基本回绑

            TestDesc(suite: "RenameRebind", name: "basicRebindKeepsBookIDAndPages") {
                let (store, dir) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let root = dir.appendingPathComponent("library", isDirectory: true).path
                let old = "\(root)/书名旧.pdf"
                let new = "\(root)/书名新.pdf"
                try writeFile(old)
                let book = try addBook(store, id: "bk-1", rootPath: root, fileName: "书名旧.pdf",
                                       title: "示例方法论", author: "作者丁",
                                       pages: ["示例方法论 第一章", "第二章 法律解释"])
                try renameOnDisk(old, new)

                let report = try store.rebindRenamedBooks(
                    [RenameReceipt(oldPath: old, newPath: new)])
                try expectEqual(report.results.first?.status, "UP_REBOUND", "首行应 UP_REBOUND")
                try expectFalse(report.failed, "无拒绝则 failed=false")

                let rebound = try expectNotNil(try store.book(byRealPath: new), "新路径应命中")
                try expectEqual(rebound.id, book.id, "book id 不变")
                try expectEqual(rebound.fileName, "书名新.pdf", "file_name 取新末段")
                try expectEqual(rebound.relPath, "书名新.pdf", "relPath 去掉根前缀")
                try expectEqual(rebound.rootPath, root, "同根移动 root_path 不变")
                try expectNil(try store.book(byRealPath: old), "旧路径应查无此书")
                // 页行随 book_id 自动跟随（pages 不存路径）。
                let pages = try store.candidateRowIDs(bookID: book.id)
                try expectEqual(pages.count, 2, "页行仍挂在同一 book id 下")
                try expectEqual(try store.book(byID: book.id)?.pageCount, 2, "页数不变")
            },

            // MARK: 拼音投影重建

            TestDesc(suite: "RenameRebind", name: "pinyinProjectionRebuiltOnFileNameChange") {
                let (store, dir) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let root = dir.appendingPathComponent("library", isDirectory: true).path
                let old = "\(root)/falv.pdf"
                let new = "\(root)/falvdegailun.pdf"
                try writeFile(old)
                let book = try addBook(store, id: "bk-pinyin", rootPath: root, fileName: "falv.pdf",
                                       title: "样书一", author: nil, pages: ["样书一"])
                try renameOnDisk(old, new)
                try expectTrue(try store.bookIDsMatchingPinyin("falvpdf").contains(book.id),
                               "回绑前旧文件名投影可查")
                _ = try store.rebindRenamedBooks(
                    [RenameReceipt(oldPath: old, newPath: new)])
                try expectTrue(try store.bookIDsMatchingPinyin("falvdegailunpdf").contains(book.id),
                               "file_name 真变化后新文件名拼音可查（投影已重建）")
                let hits = try SearchService(store: store).matchingBooks("falvdegailun")
                try expectTrue(hits.contains { $0.bookID == book.id }, "matchingBooks 命中回绑后的书")
            },

            TestDesc(suite: "RenameRebind", name: "pinyinProjectionUntouchedWhenFileNameUnchanged") {
                let (store, dir) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let root = dir.appendingPathComponent("library", isDirectory: true).path
                // 只改子目录，末段不变→file_name 不变→投影源不变。
                let old = "\(root)/falv.pdf"
                let new = "\(root)/sub/falv.pdf"
                try writeFile(old)
                let book = try addBook(store, id: "bk-same-name", rootPath: root, fileName: "falv.pdf",
                                       title: "样书一", author: nil, pages: ["样书一"])
                try FileManager.default.createDirectory(atPath: "\(root)/sub",
                                                        withIntermediateDirectories: true)
                try renameOnDisk(old, new)
                _ = try store.rebindRenamedBooks([RenameReceipt(oldPath: old, newPath: new)])
                try expectEqual(try store.book(byRealPath: new)?.relPath, "sub/falv.pdf",
                                "同根换子目录：relPath 含子目录")
                try expectTrue(try store.bookIDsMatchingPinyin("falvpdf").contains(book.id),
                               "file_name 未变，投影行仍在")
            },

            // MARK: OCR 独立两例

            TestDesc(suite: "RenameRebind", name: "ocrPairingUntouchedWhenOnlyBookFileRenamed") {
                let (store, dir) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let root = dir.appendingPathComponent("library", isDirectory: true).path
                let bookPath = "\(root)/scan.pdf"
                let ocrPath = "\(root)/scan-ocr.pdf"
                try writeFile(bookPath)
                try writeFile(ocrPath)
                let book = try addBook(store, id: "bk-ocr-only", rootPath: root, fileName: "scan.pdf",
                                       title: "扫描书", author: nil, pages: ["扫描页一"])
                try store.applyOCRPages(bookID: book.id,
                                        ocrBook: IndexStore.OCRBookRow(
                                            bookID: book.id, ocrRealPath: ocrPath,
                                            ocrFingerprint: "fp-ocr", mappingKind: "same-page-verified",
                                            createdAt: 0),
                                        mapping: [OCRPagePair(originalPage: 1, ocrPage: 1)], updates: [])
                let newBookPath = "\(root)/scan-new.pdf"
                try renameOnDisk(bookPath, newBookPath)
                let report = try store.rebindRenamedBooks(
                    [RenameReceipt(oldPath: bookPath, newPath: newBookPath)])
                try expectEqual(report.results.first?.status, "UP_REBOUND")
                // 只改名书文件：OCR 配对行零改动（按路径匹配，不按 book_id）。
                let pairing = try expectNotNil(try store.ocrPairing(bookID: book.id))
                try expectEqual(pairing.ocrRealPath, ocrPath, "OCR 路径未被误改")
            },

            TestDesc(suite: "RenameRebind", name: "ocrPairingRebindsWhenOCRFileRenamed") {
                let (store, dir) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let root = dir.appendingPathComponent("library", isDirectory: true).path
                let bookPath = "\(root)/scan.pdf"
                let ocrOld = "\(root)/scan-ocr.pdf"
                let ocrNew = "\(root)/scan-ocr-new.pdf"
                try writeFile(bookPath)
                try writeFile(ocrOld)
                let book = try addBook(store, id: "bk-ocr-both", rootPath: root, fileName: "scan.pdf",
                                       title: "扫描书", author: nil, pages: ["扫描页一"])
                try store.applyOCRPages(bookID: book.id,
                                        ocrBook: IndexStore.OCRBookRow(
                                            bookID: book.id, ocrRealPath: ocrOld,
                                            ocrFingerprint: "fp-ocr", mappingKind: "same-page-verified",
                                            createdAt: 0),
                                        mapping: [OCRPagePair(originalPage: 1, ocrPage: 1)], updates: [])
                // 该书自身没改名：旧路径仍合法，OCR 改名单独记账（全有或全无的粒度）。
                try renameOnDisk(ocrOld, ocrNew)
                let report = try store.rebindRenamedBooks(
                    [RenameReceipt(oldPath: ocrOld, newPath: ocrNew)])
                try expectEqual(report.results.first?.status, "UP_REBOUND")
                try expectEqual(try store.book(byRealPath: bookPath)?.id, book.id, "书行未被误改")
                try expectNil(try store.ocrBookByOCRRealPath(ocrOld), "旧 OCR 路径已无行")
                let pairing = try expectNotNil(try store.ocrPairing(bookID: book.id))
                try expectEqual(pairing.ocrRealPath, ocrNew, "OCR 路径已回绑")
                try expectEqual(pairing.mappingKind, "same-page-verified", "配对映射仍在")
                try expectEqual(Set(pairing.ocrPages.keys), [1], "页映射仍在")
                let rebound = try expectNotNil(try store.ocrBookByOCRRealPath(ocrNew))
                try expectEqual(rebound.bookID, book.id, "OCR 行仍挂同一 book id")

                // 同批混一条书改名＋一条 OCR 改名：两处都回绑（互不依赖、互不问题）。
                let mixedOld = "\(root)/mixed.pdf"
                let mixedNew = "\(root)/mixed-new.pdf"
                let mixedOCRNew = "\(root)/mixed-ocr-new.pdf"
                try writeFile(mixedOld)
                try writeFile("\(root)/mixed-ocr.pdf")
                let mixed = try addBook(store, id: "bk-mixed", rootPath: root, fileName: "mixed.pdf",
                                        title: "混合书", author: nil, pages: ["混合页"])
                try store.applyOCRPages(bookID: mixed.id,
                                        ocrBook: IndexStore.OCRBookRow(
                                            bookID: mixed.id, ocrRealPath: "\(root)/mixed-ocr.pdf",
                                            ocrFingerprint: "fp-ocr2", mappingKind: "same-page-verified",
                                            createdAt: 0),
                                        mapping: [OCRPagePair(originalPage: 1, ocrPage: 1)], updates: [])
                try renameOnDisk(mixedOld, mixedNew)
                try renameOnDisk("\(root)/mixed-ocr.pdf", mixedOCRNew)
                let mixedReport = try store.rebindRenamedBooks([
                    RenameReceipt(oldPath: mixedOld, newPath: mixedNew),
                    RenameReceipt(oldPath: "\(root)/mixed-ocr.pdf", newPath: mixedOCRNew),
                ])
                try expectEqual(Set(mixedReport.results.map(\.status)), ["UP_REBOUND"], "两行都回绑")
                try expectEqual(try store.book(byRealPath: mixedNew)?.id, mixed.id, "书行回绑")
                try expectEqual(try store.ocrPairing(bookID: mixed.id)?.ocrRealPath, mixedOCRNew,
                                "同批 OCR 行也回绑")
            },

            // MARK: 拒绝四条

            TestDesc(suite: "RenameRebind", name: "refusesWhenNewPathMissing") {
                let (store, dir) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let root = dir.appendingPathComponent("library", isDirectory: true).path
                let old = "\(root)/a.pdf"
                try writeFile(old)
                try addBook(store, id: "bk-missing", rootPath: root, fileName: "a.pdf",
                            title: "甲", author: nil, pages: ["甲"])
                try renameOnDisk(old, "\(root)/b.pdf")
                let report = try store.rebindRenamedBooks(
                    [RenameReceipt(oldPath: old, newPath: "\(root)/ghost.pdf")])
                try expectEqual(report.results.first?.status, "REFUSED", "新路径不存在必须拒")
                try expectTrue(report.results.first?.reason.contains("新路径不存在") == true)
                try expectTrue(report.failed, "有 REFUSED 即 failed")
                try expectNil(try store.book(byRealPath: "\(root)/b.pdf"), "拒则零写")
            },

            TestDesc(suite: "RenameRebind", name: "refusesWhenNewPathOwnedByAnotherBook") {
                let (store, dir) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let root = dir.appendingPathComponent("library", isDirectory: true).path
                let a = "\(root)/a.pdf"
                let b = "\(root)/b.pdf"
                try writeFile(a)
                try writeFile(b)
                let bookA = try addBook(store, id: "bk-a", rootPath: root, fileName: "a.pdf",
                                        title: "甲", author: nil, pages: ["甲"])
                try addBook(store, id: "bk-b", rootPath: root, fileName: "b.pdf",
                            title: "乙", author: nil, pages: ["乙"])
                try renameOnDisk(a, "\(root)/a-moved.pdf")
                let report = try store.rebindRenamedBooks(
                    [RenameReceipt(oldPath: a, newPath: b)])
                try expectEqual(report.results.first?.status, "REFUSED")
                try expectTrue(report.results.first?.reason.contains("新路径已属别的书") == true)
                try expectEqual(try store.book(byRealPath: b)?.id, "bk-b", "原属主未被改")
                try expectEqual(try store.book(byRealPath: a)?.id, bookA.id, "旧行也未动")
            },

            TestDesc(suite: "RenameRebind", name: "refusesWhenOldDiskPathStillPresent") {
                let (store, dir) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let root = dir.appendingPathComponent("library", isDirectory: true).path
                let old = "\(root)/a.pdf"
                let new = "\(root)/a-copy.pdf"
                try writeFile(old)
                try writeFile(new)   // 复制而非改名：旧路径仍在盘上
                try addBook(store, id: "bk-copy", rootPath: root, fileName: "a.pdf",
                            title: "甲", author: nil, pages: ["甲"])
                let report = try store.rebindRenamedBooks(
                    [RenameReceipt(oldPath: old, newPath: new)])
                try expectEqual(report.results.first?.status, "REFUSED")
                try expectTrue(report.results.first?.reason.contains("旧盘路径仍在") == true,
                               "复制场景按守卫文案拒")
                try expectEqual(try store.book(byRealPath: old)?.fileName, "a.pdf", "零写")
            },

            // 换库根（书库根目录整段换名）⇒ 仍拒：这是搬库，不是改名。
            TestDesc(suite: "RenameRebind", name: "refusesCrossRootMove") {
                let (store, dir) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let rootA = dir.appendingPathComponent("libA", isDirectory: true).path
                let rootB = dir.appendingPathComponent("libB", isDirectory: true).path
                let old = "\(rootA)/author/a.pdf"
                let new = "\(rootB)/author/a.pdf"
                try writeFile(old)
                try addBook(store, id: "bk-cross", rootPath: rootA, fileName: "author/a.pdf",
                            title: "甲", author: nil, pages: ["甲"])
                try FileManager.default.createDirectory(atPath: "\(rootB)/author", withIntermediateDirectories: true)
                // 整库搬到另一个盘/根：源目录还在（不是改名），必须拒。
                try FileManager.default.copyItem(atPath: old, toPath: new)
                let report = try store.rebindRenamedBooks(
                    [RenameReceipt(oldPath: old, newPath: new)])
                // 复制而非改名：先被「旧盘路径仍在」拦下（更具体），同属拒绝。
                try expectEqual(report.results.first?.status, "REFUSED")
                try expectEqual(try store.book(byRealPath: old)?.id, "bk-cross", "零写")
                try expectEqual(try store.book(byRealPath: new)?.id, nil, "新路径没被绑")
            },

            // 放宽批（真实形状）：root_path 记到**作者文件夹本身**，书直接
            // 放在该目录下（合成库中的多数条目采用这种结构）。作者文件夹改译名后，
            // 新旧目录段末段不同、其余相同 ⇒ 放行，root_path 跟到新作者目录。
            TestDesc(suite: "RenameRebind", name: "acceptsAuthorFolderRename") {
                let (store, dir) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let lib = dir.appendingPathComponent("library", isDirectory: true).path
                let oldDir = "\(lib)/甲乙（Quill, Avery）"
                let newDir = "\(lib)/丙丁（Marlowe, Jordan）"
                let old = "\(oldDir)/Quill, A Sample Treatise, 2001.pdf"
                let new = "\(newDir)/Quill, A Sample Treatise, 2001.pdf"
                try writeFile(old)
                try addBook(store, id: "bk-author", rootPath: oldDir,
                            fileName: "Quill, A Sample Treatise, 2001.pdf",
                            title: "甲", author: nil, pages: ["甲"])
                try FileManager.default.createDirectory(atPath: newDir, withIntermediateDirectories: true)
                try renameOnDisk(old, new)
                let report = try store.rebindRenamedBooks(
                    [RenameReceipt(oldPath: old, newPath: new)])
                try expectEqual(report.results.first?.status, "UP_REBOUND")
                try expectEqual(report.upReboundCount, 1)
                let moved = try store.book(byRealPath: new)
                try expectEqual(moved?.id, "bk-author", "同 id 改到新路径")
                try expectEqual(moved?.rootPath, newDir, "root_path 跟到新作者目录")
                try expectEqual(try store.book(byRealPath: old)?.id, nil, "旧路径已无行")
            },

            // 放宽批第二种形状：root_path 记到书库根，作者目录在 rel_path 里。
            TestDesc(suite: "RenameRebind", name: "acceptsAuthorFolderRenameUnderLibRoot") {
                let (store, dir) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let root = dir.appendingPathComponent("library", isDirectory: true).path
                let old = "\(root)/Avery Quill/a.pdf"
                let new = "\(root)/埃弗里·奎尔/a.pdf"
                try writeFile(old)
                // addBook 的 realPath 由 rootPath/fileName 拼出，必须与盘上一致；
                // rel_path 另改成含作者目录的形式（模拟 root 记在库根的书）。
                var book = try addBook(store, id: "bk-under-root", rootPath: root,
                                       fileName: "Avery Quill/a.pdf",
                                       title: "甲", author: nil, pages: ["甲"])
                try store.upsertBook(book)
                try FileManager.default.createDirectory(atPath: "\(root)/埃弗里·奎尔",
                                                        withIntermediateDirectories: true)
                try renameOnDisk(old, new)
                let report = try store.rebindRenamedBooks(
                    [RenameReceipt(oldPath: old, newPath: new)])
                try expectEqual(report.results.first?.status, "UP_REBOUND")
                let moved = try store.book(byRealPath: new)
                try expectEqual(moved?.rootPath, root, "root_path 不漂移")
                try expectEqual(moved?.relPath, "埃弗里·奎尔/a.pdf", "rel_path 走新目录名")
            },

            // 仍须拒：同名但**不是同一份文档**被挪进本库（旧目录还在盘上＝复制/挪入，
            // 不是改名）。判据是「旧目录整棵消失」，不是「路径长得像」。
            TestDesc(suite: "RenameRebind", name: "refusesMoveToOtherAuthorFolder") {
                let (store, dir) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let root = dir.appendingPathComponent("library", isDirectory: true).path
                let old = "\(root)/张三/a.pdf"
                let new = "\(root)/李四/a.pdf"
                try writeFile(old)
                try addBook(store, id: "bk-move", rootPath: root, fileName: "张三/a.pdf",
                            title: "甲", author: nil, pages: ["甲"])
                try FileManager.default.createDirectory(atPath: "\(root)/李四", withIntermediateDirectories: true)
                try FileManager.default.copyItem(atPath: old, toPath: new)
                let report = try store.rebindRenamedBooks(
                    [RenameReceipt(oldPath: old, newPath: new)])
                try expectEqual(report.results.first?.status, "REFUSED")
                try expectEqual(try store.book(byRealPath: old)?.id, "bk-move", "零写")
                try expectEqual(try store.book(byRealPath: new)?.id, nil, "挪入的新路径没被绑")
            },

            TestDesc(suite: "RenameRebind", name: "refusesUnknownOldPathAndDirectoryTarget") {
                let (store, dir) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let root = dir.appendingPathComponent("library", isDirectory: true).path
                let unknown = try store.rebindRenamedBooks(
                    [RenameReceipt(oldPath: "\(root)/never-indexed.pdf",
                                   newPath: "\(root)/whatever.pdf")])
                try expectEqual(unknown.results.first?.status, "REFUSED")
                try expectTrue(unknown.results.first?.reason.contains("旧路径不在索引") == true)
                try expectTrue(unknown.failed, "空批外的单行被拒也置 failed")

                let old = "\(root)/c.pdf"
                try writeFile(old)
                try addBook(store, id: "bk-dir", rootPath: root, fileName: "c.pdf",
                            title: "丙", author: nil, pages: ["丙"])
                let dirReport = try store.rebindRenamedBooks(
                    [RenameReceipt(oldPath: old, newPath: root)])
                try expectEqual(dirReport.results.first?.status, "REFUSED", "目录目标必须拒")
            },

            // MARK: 全有或全无

            TestDesc(suite: "RenameRebind", name: "multiRowBatchIsAllOrNothing") {
                let (store, dir) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let root = dir.appendingPathComponent("library", isDirectory: true).path
                let okOld = "\(root)/ok.pdf"
                let okNew = "\(root)/ok-new.pdf"
                let badOld = "\(root)/bad.pdf"
                try writeFile(okOld)
                try writeFile(badOld)
                let okBook = try addBook(store, id: "bk-ok", rootPath: root, fileName: "ok.pdf",
                                         title: "合法书", author: nil, pages: ["合法"])
                try addBook(store, id: "bk-bad", rootPath: root, fileName: "bad.pdf",
                            title: "被拒书", author: nil, pages: ["被拒"])
                try renameOnDisk(okOld, okNew)
                try renameOnDisk(badOld, "\(root)/bad-moved.pdf")
                let dbURL = dir.appendingPathComponent("index.db")
                let before = try shaOf(dbURL)

                let report = try store.rebindRenamedBooks([
                    RenameReceipt(oldPath: okOld, newPath: okNew),
                    RenameReceipt(oldPath: badOld, newPath: "\(root)/does-not-exist.pdf"),
                ])
                try expectTrue(report.failed, "次行被拒→整批 failed")
                // 首行本身合法，但整批零写入⇒逐行如实标 REFUSED（不伪装成命中）。
                try expectEqual(report.results[0].status, "REFUSED", "首行因整批作废记 REFUSED")
                try expectEqual(report.results[1].status, "REFUSED")
                try expectEqual(report.refusedCount, 2)
                try expectEqual(report.upReboundCount, 0, "零写入")
                let after = try shaOf(dbURL)
                try expectEqual(before, after, "库文件 shasum 前后相等＝首行也没写")
                try expectEqual(try store.book(byRealPath: okOld)?.id, okBook.id, "首行未落库")
                try expectNil(try store.book(byRealPath: okNew), "新路径未落库")
            },

            // MARK: 幂等

            TestDesc(suite: "RenameRebind", name: "secondRunIsIdempotentAlreadyRebound") {
                let (store, dir) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let root = dir.appendingPathComponent("library", isDirectory: true).path
                let old = "\(root)/x.pdf"
                let new = "\(root)/x-new.pdf"
                try writeFile(old)
                let book = try addBook(store, id: "bk-idem", rootPath: root, fileName: "x.pdf",
                                       title: "幂等书", author: nil, pages: ["幂等"])
                try renameOnDisk(old, new)
                let first = try store.rebindRenamedBooks(
                    [RenameReceipt(oldPath: old, newPath: new)])
                try expectEqual(first.results.first?.status, "UP_REBOUND")
                let dbURL = dir.appendingPathComponent("index.db")
                let afterFirst = try shaOf(dbURL)
                let second = try store.rebindRenamedBooks(
                    [RenameReceipt(oldPath: old, newPath: new)])
                try expectEqual(second.results.first?.status, "ALREADY_REBOUND",
                                "重跑同一回执＝幂等命中")
                try expectFalse(second.failed, "幂等不算失败")
                try expectEqual(second.upReboundCount, 0, "二次零写")
                let afterSecond = try shaOf(dbURL)
                try expectEqual(afterFirst, afterSecond, "库 sha 不变")
                try expectEqual(try store.book(byRealPath: new)?.id, book.id, "书仍挂同 id")
            },

            // MARK: dry-run

            TestDesc(suite: "RenameRebind", name: "dryRunHitsAndWritesNothing") {
                let (store, dir) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let root = dir.appendingPathComponent("library", isDirectory: true).path
                let old = "\(root)/d.pdf"
                let new = "\(root)/d-new.pdf"
                try writeFile(old)
                try addBook(store, id: "bk-dry", rootPath: root, fileName: "d.pdf",
                            title: "空跑书", author: nil, pages: ["空跑"])
                try renameOnDisk(old, new)
                let dbURL = dir.appendingPathComponent("index.db")
                let before = try shaOf(dbURL)
                let report = try store.rebindRenamedBooks(
                    [RenameReceipt(oldPath: old, newPath: new)], dryRun: true)
                try expectEqual(report.results.first?.status, "DRY_RUN_HIT")
                try expectFalse(report.failed, "dry-run 无 REFUSED")
                try expectEqual(report.dryRunHitCount, 1)
                try expectNil(try store.book(byRealPath: new), "dry-run 零写")
                let after = try shaOf(dbURL)
                try expectEqual(before, after, "dry-run 后库 sha 不变")

                let refused = try store.rebindRenamedBooks(
                    [RenameReceipt(oldPath: old, newPath: "\(root)/nope.pdf")], dryRun: true)
                try expectEqual(refused.results.first?.status, "REFUSED", "dry-run 也全量校验")
            },

            // MARK: book_id 稳定性

            TestDesc(suite: "RenameRebind", name: "candidatesAndReadingQueriesStayOnSameBookID") {
                let (store, dir) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let root = dir.appendingPathComponent("library", isDirectory: true).path
                let old = "\(root)/reading.pdf"
                let new = "\(root)/reading-new.pdf"
                try writeFile(old)
                let book = try addBook(store, id: "bk-reading", rootPath: root, fileName: "reading.pdf",
                                       title: "阅读记录书", author: nil,
                                       pages: ["契约法 第一章 术语页", "第二章 判例页"])
                try renameOnDisk(old, new)
                let beforeRowIDs = try store.candidateRowIDs(bookID: book.id)
                let svc = SearchService(store: store)
                let beforeHits = try svc.searchDetailed("契约法")
                _ = try store.rebindRenamedBooks([RenameReceipt(oldPath: old, newPath: new)])

                let afterHits = try svc.searchDetailed("契约法")
                try expectEqual(beforeHits.hits.count, afterHits.hits.count, "命中数不变")
                try expectEqual(Set(afterHits.hits.map(\.bookID)), [book.id],
                                "命中仍解析到同一 book id")
                try expectEqual(try store.candidateRowIDs(bookID: book.id), beforeRowIDs,
                                "候选页 rowid 集合不变")
                let light = try store.lightPages(rowIDs: Array(beforeRowIDs))
                try expectTrue(light.contains { $0.bookID == book.id },
                               "lightPages 仍按 book id 解析")
                try expectEqual(try store.page(bookID: book.id, pageNumber: 1)?.textOriginal,
                                "契约法 第一章 术语页", "页内容随 id 零改动")
            },

            // MARK: 回执壳解析（CLI 同构）

            TestDesc(suite: "RenameRebind", name: "receiptShellDecodingRoundTrip") {
                let json = """
                {"renames":[{"old_path":"/a/旧.pdf","new_path":"/a/新.pdf"},
                            {"old_path":"/b/一.pdf","new_path":"/b/二.pdf"}]}
                """
                let data = try expectNotNil(json.data(using: .utf8))
                let decoded = try JSONDecoder().decode(RenameReceipt.self,
                                                       from: try expectNotNil(
                                                           #"{"old_path":"/x/y.pdf","new_path":"/x/z.pdf"}"#.data(using: .utf8)))
                try expectEqual(decoded.oldPath, "/x/y.pdf", "CodingKeys old_path")
                try expectEqual(decoded.newPath, "/x/z.pdf", "CodingKeys new_path")
                let report = RebindReport(results: [RebindResult(oldPath: "/a", newPath: "/b",
                                                                 status: "UP_REBOUND", reason: "回绑成功")],
                                          failed: false, upReboundCount: 1,
                                          alreadyReboundCount: 0, dryRunHitCount: 0, refusedCount: 0)
                let roundTrip = try JSONDecoder().decode(
                    RebindReport.self, from: try JSONEncoder().encode(report))
                try expectEqual(roundTrip, report, "RebindReport JSON 往返同构（--report 落盘格式）")
            },
        ]
    }
}
