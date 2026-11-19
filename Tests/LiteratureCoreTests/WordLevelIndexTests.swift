import Foundation
import SQLite3
@testable import LiteratureCore

enum WordLevelIndexSuite {
    // MARK: 夹具

    static func makeStore() throws -> (IndexStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lit-wfts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try IndexStore(path: dir.appendingPathComponent("index.db")), dir)
    }

    @discardableResult
    static func addBook(_ store: IndexStore, id: String, name: String, pages: [String]) throws -> IndexStore.BookRow {
        let book = IndexStore.BookRow(
            id: id, realPath: "/tmp/lit-wfts/\(name)", rootPath: "/tmp/lit-wfts",
            relPath: name, fileName: name,
            firstFingerprint: "fp-\(id)", fingerprint: "fp-\(id)", fileSize: 1, mtime: 0,
            pageCount: max(pages.count, 1), status: "ok", indexedAt: 0)
        try store.upsertBook(book)
        var rows: [IndexStore.PageRow] = []
        for (i, text) in pages.enumerated() {
            let n = normalizeForSearch(text)
            rows.append(IndexStore.PageRow(bookID: id, pageNumber: i + 1, textOriginal: text,
                                           textNorm: n.text, normStarts: n.starts, normEnds: n.ends))
        }
        try store.replacePages(bookID: id, rows)
        return book
    }

    /// 断言1 断言2 共用小库
    /// rights 整词页 ×2 / copyrights 词内片段页 / 权利rights义务 CJK 贴邻页 /
    /// rights-based 连字符页 / RIGHTS 大写归一页 / 纯 CJK 页。
    static func makeParityLibrary() throws -> (IndexStore, URL) {
        let (store, dir) = try makeStore()
        try addBook(store, id: "w1", name: "w1.pdf", pages: [
            "the rights of man",              // 整词（两轨都命中）
            "copyrights and copies",          // 词内片段（词路剔、子串路收）
            "权利rights义务",                  // CJK 贴邻（投影分隔符语义，两轨都收）
            "rights-based obligations",       // 连字符（投影为 rights 与 based 两 token）
            "RIGHTS reserved",                // 大写归一（norm 折小写，两轨都收）
            "纯中文页无论其他",
        ])
        try addBook(store, id: "w2", name: "w2.pdf", pages: [
            "states rights doctrine",         // w2 整词页
        ])
        return (store, dir)
    }

    static func wordPathRowIDs(_ store: IndexStore, terms: [String]) throws -> Set<Int64> {
        let query = terms.map { quoteForFTS($0) }.joined(separator: " ")
        return Set(try store.wordPathCandidateRowIDs(match: query))
    }

    static func substringRowIDs(_ store: IndexStore, terms: [String]) throws -> Set<Int64> {
        var intersection: Set<String>? = nil
        for term in terms {
            let ids = try store.candidatePageIDs(term: term)
            intersection = intersection.map { $0.intersection(ids) } ?? Set(ids)
        }
        return Set((intersection ?? []).compactMap { Int64($0) })
    }

    // MARK: 断言1a——投影与 FTS5 token 集对拍

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "WordLevelIndex", name: "latinProjectionTokenParityWithFTS5") {
                // 投影基准：[a-z0-9]+ 极大串保留，其余折叠单空格。
                try expectEqual(LatinProjection.transform("the rights of man"), "the rights of man")
                try expectEqual(LatinProjection.transform("权利rights义务"), "rights")
                try expectEqual(LatinProjection.transform("rights-based"), "rights based")
                try expectEqual(LatinProjection.transform("法律 与 国家"), "")
                try expectEqual(LatinProjection.transform("r1ghts 2024x"), "r1ghts 2024x")
                try expectEqual(LatinProjection.transform(""), "")
                try expectEqual(LatinProjection.transform("   "), "")
                try expectEqual(LatinProjection.transform("ABC"), "")   // 大写不折叠不保留（fail-closed）
                // parity：合成页逐 token 查询——投影串的每个 token 经 FTS5
                // MATCH 恰命中该页（index/query 两侧分词对称性由构造保证）。
                let (store, dir) = try makeParityLibrary()
                defer { Fixtures.cleanup(dir) }
                let rows = try store.db.prepare("SELECT rowid, text_latin FROM pages ORDER BY rowid;")
                var checked = 0
                while try rows.step() {
                    let rowid = rows.int(0)
                    let projection = rows.text(1)
                    for token in projection.split(separator: " ") {
                        let hit = try store.wordPathCandidateRowIDs(match: quoteForFTS(String(token)))
                        try expectTrue(hit.contains(rowid),
                                       "token「\(token)」MATCH 必命中其所在页（rowid=\(rowid)）")
                        checked += 1
                    }
                }
                try expectTrue(checked > 5, "对拍必须真实覆盖多 token（got \(checked)）")
            },

            // MARK: 断言1b——词路 ⊆ 子串路，差集逐个可解释

            TestDesc(suite: "WordLevelIndex", name: "wordPathSubsetOfSubstringPathDiffExplainable") {
                let (store, dir) = try makeParityLibrary()
                defer { Fixtures.cleanup(dir) }
                let word = try wordPathRowIDs(store, terms: ["rights"])
                let sub = try substringRowIDs(store, terms: ["rights"])
                try expectTrue(word.isSubset(of: sub), "词路命中集 ⊆ 旧子串路命中集")
                try expectTrue(word.contains(where: { _ in true }) && word.count >= 4,
                               "整词页必须命中（rights×3+贴邻+连字符+大写+states rights）")
                let diff = sub.subtracting(word)
                // 差集＝词内片段页（copyrights 中的 rights），逐个可解释：
                // 差集页的 text_latin 必不含独立 token「rights」。
                for rowid in diff {
                    let stmt = try store.db.prepare("SELECT text_latin FROM pages WHERE rowid = ?;")
                    try stmt.bindInt(1, rowid)
                    guard try stmt.step() else { continue }
                    let tokens = stmt.text(0).split(separator: " ")
                    try expectFalse(tokens.contains { $0 == "rights" },
                                    "差集页 rowid=\(rowid) 必为词内片段（无独立 rights token），实际：\(stmt.text(0))")
                }
                // 服务级对照：searchDetailed 词路 count ≤ 子串路 count（同库同词）。
                try store.setMetaValue("wfts_dirty", "1")   // 切子串轨
                let service = SearchService(store: store)
                let subResult = try service.searchDetailed("rights")
                try store.setMetaValue("wfts_dirty", "0")   // 切回词路
                let wordResult = try service.searchDetailed("rights")
                try expectTrue(wordResult.totalPageMatches <= subResult.totalPageMatches,
                               "词路 count \(wordResult.totalPageMatches) ≤ 子串路 count \(subResult.totalPageMatches)")
                try expectEqual(wordResult.countCaliber, CountCaliber.wordLevel)
                try expectEqual(subResult.countCaliber, CountCaliber.characterLevel)
            },

            // MARK: 断言2（合成侧）——基准、零命中文案、复跑确定性

            TestDesc(suite: "WordLevelIndex", name: "countCaliberAndZeroHitWordHintPins") {
                let (store, dir) = try makeParityLibrary()
                defer { Fixtures.cleanup(dir) }
                let service = SearchService(store: store)
                // 词级基准如实透传 + 词内片段不计入。
                let r = try service.searchDetailed("rights")
                try expectEqual(r.countCaliber, CountCaliber.wordLevel)
                let diag = try expectNotNil(service.lastQueryDiagnostics)
                try expectEqual(diag.countCaliber, CountCaliber.wordLevel)
                try expectEqual(diag.routedTerms["rights"], "latinWordPath")
                // CJK 查询：字符级 + 路由 cjkPath（字节不动）。
                let zh = try service.searchDetailed("权利")
                try expectEqual(zh.countCaliber, CountCaliber.characterLevel)
                let zhDiag = try expectNotNil(service.lastQueryDiagnostics)
                try expectEqual(zhDiag.routedTerms["权利"], "cjkPath")
                // 拼音零命中行（faludegailun 形态）：保持零命中 + 字符级 +
                // 无词级提示（既有文案逐字节不变）。
                let pinyin = try service.searchDetailed("faludegailun")
                try expectEqual(pinyin.totalPageMatches, 0)
                try expectEqual(pinyin.countCaliber, CountCaliber.characterLevel)
                let pinyinExp = try expectNotNil(pinyin.zeroHitExplanation)
                try expectFalse(pinyinExp.summary.contains("词级基准"))
                // 词路零命中：附词级基准提示（不误导为库内无此内容）。
                let wordZero = try service.searchDetailed("qqzzww")
                try expectEqual(wordZero.totalPageMatches, 0)
                try expectEqual(wordZero.countCaliber, CountCaliber.wordLevel)
                let wordExp = try expectNotNil(wordZero.zeroHitExplanation)
                try expectTrue(wordExp.summary.contains("词级基准"), "词路零命中附基准提示")
                try expectTrue(wordExp.summary.contains("变位"), "提示含变位/复数归因")
                // 复跑确定性（词路无持久缓存，两次进程内输出恒等）。
                let again = try service.searchDetailed("rights")
                try expectEqual(again, r, "词路复跑逐字节恒等")
            },

            // MARK: 断言3——39 既有输出基线查询逐词项路由 + 音节判定边界


            TestDesc(suite: "WordLevelIndex", name: "pinyinSyllableRoutingBoundaryPins") {
                // lv/nv 惯用形可解析；全音节表可解析闭环（表级断言在
                // PinyinSyllableComplete，此处断言路由消费侧）；非音节串拒绝；
                // 数字词走词路。
                try expectTrue(PinyinSyllables.isParseable("falv"))
                try expectTrue(PinyinSyllables.isParseable("faludegailun"))
                try expectTrue(PinyinSyllables.isParseable("nvren"))
                try expectTrue(PinyinSyllables.isParseable("lvzhou"))
                try expectFalse(PinyinSyllables.isParseable("rights"))
                try expectFalse(PinyinSyllables.isParseable("law"))
                try expectFalse(PinyinSyllables.isParseable("state"))
                try expectFalse(PinyinSyllables.isParseable("mind"))
                try expectFalse(PinyinSyllables.isParseable("van"))
                let (store, dir) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let service = SearchService(store: store)
                try expectEqual(service.routeTerm("1848"), .latinWordPath, "数字词走词路（非纯字母，跳过拼音判定）")
                try expectEqual(service.routeTerm("r1ghts"), .latinWordPath, "字母数字混串走词路")
            },

            // MARK: 断言4——五写点增量同步

            TestDesc(suite: "WordLevelIndex", name: "fiveWritePointsKeepWordIndexInSync") {
                let (store, dir) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                let service = SearchService(store: store)
                try addBook(store, id: "wp", name: "wp.pdf", pages: ["sovereignty text one"])
                try expectTrue(try service.searchDetailed("sovereignty").totalPageMatches == 1)
                try addBook(store, id: "wp", name: "wp.pdf", pages: ["obligation text two"])
                try expectEqual(try service.searchDetailed("sovereignty").totalPageMatches, 0, "旧页 token 消失")
                try expectEqual(try service.searchDetailed("obligation").totalPageMatches, 1, "新页 token 入索引")
                try addBook(store, id: "wo", name: "wo.pdf", pages: ["native text", "", ""])
                let ocrBook = IndexStore.OCRBookRow(bookID: "wo", ocrRealPath: "/tmp/wo-ocr.pdf",
                                                    ocrFingerprint: "fp-ocr", mappingKind: "same-page-verified",
                                                    createdAt: 0)
                let n = normalizeForSearch("ocr injected sovereignty passage")
                try store.applyOCRPages(bookID: "wo", ocrBook: ocrBook,
                                        mapping: [OCRPagePair(originalPage: 2, ocrPage: 1)],
                                        updates: [IndexStore.OCRPageTextUpdate(
                                            originalPage: 2, ocrPage: 1,
                                            textOriginal: "ocr injected sovereignty passage",
                                            textNorm: n.text, normStarts: n.starts, normEnds: n.ends)])
                let ocrHits = try service.searchDetailed("sovereignty")
                try expectTrue(ocrHits.hits.contains { $0.bookID == "wo" && $0.physicalPage == 2 && $0.source == "ocr" },
                               "OCR 页词级命中且来源标注 ocr")
                try store.purgeOCR(bookID: "wo")
                try expectEqual(try service.searchDetailed("sovereignty").totalPageMatches, 0, "清退后词级命中归零")
                try addBook(store, id: "wd", name: "wd.pdf", pages: ["freedom page one", "freedom page two"])
                try expectEqual(try service.searchDetailed("freedom").totalPageMatches, 2)
                let ownedRowids: [Int64] = {
                    var out: [Int64] = []
                    let stmt = try! store.db.prepare("SELECT rowid FROM pages WHERE book_id = 'wd';")
                    while (try! stmt.step()) { out.append(stmt.int(0)) }
                    return out
                }()
                try expectTrue(ownedRowids.count >= 2)
                try store.deleteBook(id: "wd")
                for rowid in ownedRowids {
                    let stmt = try store.db.prepare("SELECT 1 FROM pages_wfts WHERE rowid = ?;")
                    try stmt.bindInt(1, rowid)
                    try expectFalse(try stmt.step(), "删书后 wfts 不得留孤儿 doclist（rowid=\(rowid)）")
                }
                try expectEqual(try service.searchDetailed("freedom").totalPageMatches, 0)
                var book = try store.book(byID: "wo")!
                book.fileName = "renamed-wo.pdf"
                try store.upsertBook(book)
                let afterRename = try store.wordPathCandidateRowIDs(match: quoteForFTS("obligation"))
                try expectTrue(afterRename.contains(where: { _ in true }), "改名后词级索引原样可用")
                let bareText = "bare sql democracy"
                let bareNorm = normalizeForSearch(bareText)
                func leData(_ values: [Int32]) -> Data {
                    var d = Data(capacity: values.count * 4)
                    for v in values {
                        var le = v.littleEndian
                        withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
                    }
                    return d
                }
                let bareIns = try store.db.prepare("""
                INSERT INTO pages(book_id, page_number, text_original, text_norm, norm_starts, norm_ends, text_latin)
                VALUES(?,?,?,?,?,?,?);
                """)
                bareIns.reset(); bareIns.clearBindings()
                try bareIns.bindText(1, "wo")
                try bareIns.bindInt(2, 4)
                try bareIns.bindText(3, bareText)
                try bareIns.bindText(4, bareNorm.text)
                try bareIns.bindBlob(5, leData(bareNorm.starts))
                try bareIns.bindBlob(6, leData(bareNorm.ends))
                try bareIns.bindText(7, LatinProjection.transform(bareNorm.text))
                try bareIns.run()
                let bareRowids = try store.wordPathCandidateRowIDs(match: quoteForFTS("democracy"))
                let barePageRowid: Int64 = {
                    let stmt = try! store.db.prepare("SELECT rowid FROM pages WHERE book_id='wo' AND page_number=4;")
                    _ = try! stmt.step()
                    return stmt.int(0)
                }()
                try expectTrue(bareRowids.contains(barePageRowid),
                               "绕写点写页必须自动进词级索引（触发器降级处理，rowid=\(barePageRowid)）")
                try store.purgeQueryCaches()   // 等价「重启后缓存冷启」场景
                try expectTrue(try service.searchDetailed("democracy").hits.contains { $0.bookID == "wo" && $0.physicalPage == 4 },
                               "缓存失效后查询层可见裸写页")
            },

            // MARK: 断言5——迁移幂等与回填断点续跑

            TestDesc(suite: "WordLevelIndex", name: "migrationV10ObjectsAndBackfillResumeEquivalence") {
                let (store, dir) = try makeStore()
                defer { Fixtures.cleanup(dir) }
                try expectTrue(try store.tableColumns("pages").contains("text_latin"))
                let pageSchema = store.fulltextAttached ? "ft" : "main"
                for (type, name) in [("table", "pages_wfts"), ("trigger", "pages_wfts_ai"),
                                     ("trigger", "pages_wfts_ad"), ("trigger", "pages_wfts_au")] {
                    let stmt = try store.db.prepare(
                        "SELECT 1 FROM \(pageSchema).sqlite_master WHERE type=? AND name=?;")
                    try stmt.bindText(1, type)
                    try stmt.bindText(2, name)
                    try expectTrue(try stmt.step(), "\(type) \(name) 必须在位")
                }
                try expectEqual(try store.metaValue("schema_version"), "13")
                try expectEqual(try store.metaValue("wfts_ready"), "1", "空库开箱即结算 ready=1")
                // 幂等：重开零副作用（对象不重建、ready 保持）。
                let path = dir.appendingPathComponent("index.db")
                _ = try IndexStore(path: path)   // 重开
                let reopened = try IndexStore(path: path)
                try expectEqual(try reopened.metaValue("schema_version"), "13")
                try expectEqual(try reopened.metaValue("wfts_ready"), "1")

                try reopened.db.exec("UPDATE meta SET value='999' WHERE key='index_schema_version';")
                do {
                    _ = try IndexStore(path: path)
                    try failTest("v999 库必须被门禁拒绝")
                } catch IndexStore.StoreError.description(let message) {
                    try expectTrue(message.contains("升级"), "门禁文案须含升级（got: \(message)）")
                }
                try reopened.db.exec("UPDATE meta SET value='10' WHERE key='index_schema_version';")

                // (3) 断点续跑等价：断点库（前缀手工投影＋checkpoint）续跑后
                //     与一次成型库逐 rowid 对拍。页文本恒等（投影为常量），
                //     中断态的前缀手工值与 transform 逐字节同串。
                let oneShot = try makeStore()
                defer { Fixtures.cleanup(oneShot.1) }
                let pageText = "resume page alpha omega"
                try addBook(oneShot.0, id: "rb", name: "rb.pdf",
                            pages: Array(repeating: pageText, count: 2000))
                try oneShot.0.backfillLatinProjection(progress: nil)
                try expectEqual(try oneShot.0.metaValue("wfts_ready"), "1")

                let resumed = try makeStore()
                defer { Fixtures.cleanup(resumed.1) }
                try addBook(resumed.0, id: "rb", name: "rb.pdf",
                            pages: Array(repeating: pageText, count: 2000))
                let resumeSchema = resumed.0.fulltextAttached ? "ft." : ""
                let bounds = try resumed.0.db.prepare(
                    "SELECT MIN(rowid), MAX(rowid) FROM \(resumeSchema)pages;")
                guard try bounds.step() else { try failTest("pages 必须非空") }
                let minRow = bounds.int(0), maxRow = bounds.int(1)
                let cut = minRow + (maxRow - minRow) / 2
                try resumed.0.db.exec("UPDATE \(resumeSchema)pages SET text_latin = '\(LatinProjection.transform(pageText))' WHERE rowid <= \(cut);")
                try resumed.0.setMetaValue("wfts_backfill_rowid", String(cut))
                try resumed.0.db.exec("DELETE FROM meta WHERE key='wfts_ready';")
                let n = try resumed.0.backfillLatinProjection(progress: nil)
                try expectTrue(n > 0, "续跑必须处理剩余行（got \(n)）")
                try expectEqual(try resumed.0.metaValue("wfts_ready"), "1")
                // 逐 rowid 对拍：终态与一次成型完全一致。
                let oneShotSchema = oneShot.0.fulltextAttached ? "ft." : ""
                let mine = try resumed.0.db.prepare(
                    "SELECT rowid, text_latin FROM \(resumeSchema)pages ORDER BY rowid;")
                let theirs = try oneShot.0.db.prepare(
                    "SELECT rowid, text_latin FROM \(oneShotSchema)pages ORDER BY rowid;")
                while try mine.step() {
                    guard try theirs.step() else { try failTest("行数不一致") }
                    try expectEqual(mine.text(1), theirs.text(1), "rowid \(mine.int(0)) 投影必须与一次成型一致")
                }
                try expectFalse(try theirs.step(), "两库行数必须一致")
            },

            TestDesc(suite: "WordLevelIndex", name: "wftsNotReadyRoutesToSubstringDegradation") {
                let (store, dir) = try makeParityLibrary()
                defer { Fixtures.cleanup(dir) }
                let service = SearchService(store: store)
                try expectEqual(service.routeTerm("rights"), .latinWordPath, "就绪态走词路")
                // 降级开关一：置脏 → 子串路（回填期/自愈失败窗）。
                try store.setMetaValue("wfts_dirty", "1")
                try expectEqual(service.routeTerm("rights"), .latinSubstringPath)
                try expectEqual(service.routeTerm("law"), .latinSubstringPath)
                try store.setMetaValue("wfts_dirty", "0")
                // 降级开关二：ready 键缺失 → 子串路。
                try store.db.exec("DELETE FROM meta WHERE key='wfts_ready';")
                try expectEqual(service.routeTerm("rights"), .latinSubstringPath)
                // 降级窗内查询行为与 一致（子串语义）。
                try store.setMetaValue("wfts_ready", "1")
                try store.setMetaValue("wfts_dirty", "1")
                let degraded = try service.searchDetailed("rights")
                try expectTrue(degraded.totalPageMatches >= 5, "降级窗保有子串语义命中（含 copyrights 片段页）")
                try expectEqual(degraded.countCaliber, CountCaliber.characterLevel)
            },

            // MARK: 断言8——词边界八例

            TestDesc(suite: "WordLevelIndex", name: "wordMatchesEightBoundaryCases") {
                func matches(_ pageText: String, _ term: String) -> [SearchService.MatchRange] {
                    let n = normalizeForSearch(pageText)
                    let page = IndexStore.PageRow(bookID: "t", pageNumber: 1, textOriginal: pageText,
                                                  textNorm: n.text, normStarts: n.starts, normEnds: n.ends)
                    return SearchService.wordMatches(page: page, pageNormBytes: Array(n.text.utf8),
                                                     preparedTerm: SearchService.PreparedSearchTerm(term: term))
                }
                try expectTrue(matches("copyrights hold", "rights").isEmpty, "词内片段必须剔")
                try expectEqual(matches("权利rights义务", "rights").count, 1, "CJK 贴邻算词命中")
                try expectEqual(matches("acknowledge rights, truly", "rights").count, 1, "标点邻算词命中")
                try expectEqual(matches("rights-based rule", "rights").count, 1, "连字符邻算词命中")
                try expectEqual(matches("RIGHTS reserved", "rights").count, 1, "大小写归一后命中")
                try expectTrue(matches("r1ghts of use", "rights").isEmpty, "数字混串必须剔")
                try expectEqual(matches("rights at start", "rights").count, 1, "页首（左无邻）算词命中")
                try expectEqual(matches("page ends with rights", "rights").count, 1, "页尾（右无邻）算词命中")
                // 全量报告：多出现逐个报告。
                try expectEqual(matches("rights and rights", "rights").count, 2)
            },
        ]
    }
}
