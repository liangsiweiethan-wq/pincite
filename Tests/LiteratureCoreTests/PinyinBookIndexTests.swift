import Foundation
@testable import LiteratureCore

// MARK: - 拼音书目检索合成套件（PinyinNorm + IndexStore.book_pinyin）
//
// 覆盖：归一投影（汉字连写/多音字上下文/西文标点剥离）、查询判定、
// backfill 幂等、matchingBooks 拼音追加（页面命中语义零改动）、
// deleteBook 投影同步清理。

enum PinyinBookIndexSuite {
    static var tests: [TestDesc] {
        [
            TestDesc(suite: "PinyinBookIndex", name: "transformCJKConcatenatesAndStrips") {
                try expectEqual(PinyinNorm.transform("《样书一》"), "yangshuyi")
                try expectEqual(PinyinNorm.transform("Example, H. L. A."), "examplehla")
                try expectTrue(PinyinNorm.transform("重庆：从传统到现代").hasPrefix("chongqing"),
                               "多音字按词组上下文（重庆→chongqing）")
                try expectEqual(PinyinNorm.transform("　"), "")
            },
            TestDesc(suite: "PinyinBookIndex", name: "isPinyinQueryGatesToASCIILetters") {
                try expectTrue(PinyinNorm.isPinyinQuery("lvxue"))
                try expectTrue(PinyinNorm.isPinyinQuery("example"))
                try expectFalse(PinyinNorm.isPinyinQuery("f"), "单字母不触发")
                try expectFalse(PinyinNorm.isPinyinQuery("法律"), "中文词不触发")
                try expectFalse(PinyinNorm.isPinyinQuery("norm2"), "含数字不触发")
            },
            TestDesc(suite: "PinyinBookIndex", name: "backfillIsIdempotentAndMatchAppends") {
                let dir = Fixtures.makeTempDir("pinyin-idx")
                defer { Fixtures.cleanup(dir) }
                IndexSearchSuite.buildLibrary(dir)
                let store = try Fixtures.openStore(in: dir)
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                let first = try store.backfillPinyinIfNeeded()
                let second = try store.backfillPinyinIfNeeded()
                try expectEqual(second, 0, "backfill 幂等：第二次无缺行")
                // upsertBook 现于落库事务内同步写
                // 投影行——新建库不再欠账，backfill 退化为存量 NULL 行降级处理
                // （首次计数可为 0）。「两书投影齐备」改由查询正锚断言。
                let bookAID = try expectNotNil(try store.allBooks().first { $0.fileName == "bookA.pdf" }).id
                let bookBID = try expectNotNil(try store.allBooks().first { $0.fileName == "bookB.pdf" }).id
                let projected = Set(try store.bookIDsMatchingPinyin("bookap"))
                    .union(try store.bookIDsMatchingPinyin("bookbpdf"))
                try expectTrue(projected.contains(bookAID) && projected.contains(bookBID),
                               "两本夹具书都有投影（upsert 即写；backfill 降级处理存量）")
                // "bookap" 不是任何页面文本的子串：页面命中为空，拼音投影
                // （bookapdf）包含之 → 该书以 matchingPages=0 被追加。
                let hits = try SearchService(store: store).matchingBooks("bookap")
                try expectTrue(hits.contains { $0.fileName == "bookA.pdf" },
                               "拼音投影命中应追加书目")
                try expectTrue(hits.allSatisfy { $0.matchingPages == 0 },
                               "纯拼音命中不带页面命中数")
                // 页面命中语义零改动：正常内容词仍按页面命中返回。
                let content = try SearchService(store: store).matchingBooks("计算理论")
                try expectTrue(content.contains { $0.matchingPages > 0 })
            },
            TestDesc(suite: "PinyinBookIndex", name: "deleteBookCleansProjection") {
                let dir = Fixtures.makeTempDir("pinyin-del")
                defer { Fixtures.cleanup(dir) }
                IndexSearchSuite.buildLibrary(dir)
                let store = try Fixtures.openStore(in: dir)
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                _ = try store.backfillPinyinIfNeeded()
                let bookA = try expectNotNil(try store.allBooks().first { $0.fileName == "bookA.pdf" })
                try store.deleteBook(id: bookA.id)
                try expectTrue(try store.bookIDsMatchingPinyin("bookap").isEmpty,
                               "删书后投影行同步清理，不产生孤儿命中")
            },
            TestDesc(suite: "PinyinBookIndex", name: "westernSubstringViaBigramMachinesNoTrigramTable") {
                // 调研 B 组条目 3（FTS5 trigram 补西文子串）验证性免建：现有
                // bigram+倒排机对 ≥2 字符查询的 bigram AND 交集天然就是子串
                // 语义（子串的相邻对必然都在目标词的 bigram 集合里）。本测
                // 试锁定该语义，若未来失效再立项 trigram。
                let dir = Fixtures.makeTempDir("pinyin-substr")
                defer { Fixtures.cleanup(dir) }
                IndexSearchSuite.buildLibrary(dir)
                let store = try Fixtures.openStore(in: dir)
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                // 置 wfts_dirty=1 锁定本测的 bigram 子串机语义（纯字母
                // 数字片段词在词路就绪态改走整词 token 语义——
                // 词桶合法变化；子串机的子串语义在子串轨恒可用，本测断言之）。
                try store.setMetaValue("wfts_dirty", "1")
                let hits = try SearchService(store: store).searchDetailed("COMPU")
                try expectTrue(hits.hits.contains { $0.fileName == "bookA.pdf" && $0.physicalPage == 1 },
                               "西文子串 COMPUT→computation 应命中（无需 trigram 表）")
            },
        ]
    }
}

// MARK: - 拼音检索修复测试（方案 C 节四组测试落地）
enum PinyinDualFormSuite {
    /// 合成书行（手动 upsert，title/author 进拼音投影源；不生成 PDF 文件）。
    static func addBook(_ store: IndexStore, id: String, fileName: String,
                        title: String?, author: String?, pages: [String]) throws {
        var book = IndexStore.BookRow(
            id: id, realPath: "/tmp/lit-dualform/\(fileName)", rootPath: "/tmp/lit-dualform",
            relPath: fileName, fileName: fileName,
            firstFingerprint: "fp-\(id)", fingerprint: "fp-\(id)", fileSize: 1, mtime: 0,
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
        try store.replacePages(bookID: id, rows)
    }

    /// 测试共用小库：
    /// - bk-law 《律学样本》——页文本无 lv/xu 相邻对 ⇒ 页级对 lvxue 零
    /// 命中，纯拼音命中（投影 luxueyangben…）。
    /// - bk-flv Sample Index Notes——页文本含 Vexley/lvxue ⇒ 页级 bigram 碎片命中
    /// （页级基准）。
    /// - bk-zorvex The Zorvex Reader——西文 v 保真对照。
    /// - bk-zh 样学原理页——非拼音查询对照。
    static func makeLibrary() throws -> (IndexStore, URL) {
        let dir = Fixtures.makeTempDir("pinyin-dualform")
        let store = try Fixtures.openStore(in: dir)
        try addBook(store, id: "bk-law", fileName: "sample-law.pdf",
                    title: "律学样本", author: "甲乙",
                    pages: ["the sample chapter one"])
        try addBook(store, id: "bk-flv", fileName: "notes-examplelaw.pdf",
                    title: "Sample Index Notes", author: nil,
                    pages: ["Example Scholar economics department vexley lvxue fragment"])
        try addBook(store, id: "bk-zorvex", fileName: "zorvex-reader.pdf",
                    title: "The Zorvex Reader", author: nil,
                    pages: ["fear of the state"])
        try addBook(store, id: "bk-zh", fileName: "economics-zh.pdf",
                    title: "样学原理", author: nil,
                    pages: ["样学原理。律学样本是示例学科经典。国家与社会。"])
        try store.backfillPinyinIfNeeded()
        return (store, dir)
    }

    static var tests: [TestDesc] {
        [
            // 方案测试 1（testTransformDualForm_V_Matches_U）
            TestDesc(suite: "PinyinDualForm", name: "dualFormVMatchesU") {
                let (store, dir) = try makeLibrary()
                defer { Fixtures.cleanup(dir) }
                // 投影基准锚定：律经 MandarinLatin+StripDiacritics 落为 lu，
                // 库内不存在 lvxue 字面投影——查询含 v 必须靠别名才命中。
                try expectTrue(PinyinNorm.transform("律学样本").hasPrefix("luxueyangben"),
                               "投影侧基准：律学样本→luxueyangben（律→lu），非 lvxue")
                try expectTrue(try store.bookIDsMatchingPinyin("luxue").contains("bk-law"),
                               "原生 luxue 形态命中（存量投影开箱即用）")
                try expectTrue(try store.bookIDsMatchingPinyin("lvxue").contains("bk-law"),
                               "lvxue 经 v→u 别名点查命中《律学样本》")
                try expectTrue(try store.bookIDsMatchingPinyin("lvxueyangben").contains("bk-law"),
                               "全拼 v 形态命中（别名 luxueyangben）")
                // 书目级三形态 100% 检索到（matchingBooks 全链路）。
                let service = SearchService(store: store)
                for q in ["lvxue", "lvxueyangben", "luxue"] {
                    let hits = try service.matchingBooks(q)
                    try expectTrue(hits.contains { $0.bookID == "bk-law" },
                                   "matchingBooks(\(q)) 必中《律学样本》")
                }
                // 无意义 v 词不引入假命中（别名形态 uqqzz 库内零投影）。
                try expectTrue(try store.bookIDsMatchingPinyin("vqqzz").isEmpty,
                               "别名逻辑不得无中生有")
            },
            // 方案测试 2（testWesternWordsWithV_RemainIntact）
            TestDesc(suite: "PinyinDualForm", name: "westernWordsWithVRemainIntact") {
                let (store, dir) = try makeLibrary()
                defer { Fixtures.cleanup(dir) }
                try expectEqual(try store.bookIDsMatchingPinyin("zorvex"), ["bk-zorvex"],
                                "西文点查保真：恰命中原书（别名 uermeule 零命中，不冲淡不引入）")
                try expectTrue(try store.bookIDsMatchingPinyin("calvic").isEmpty,
                               "库无 calvic 投影，别名 caualin 亦不得引入假命中")
                try expectTrue(try store.bookIDsMatchingPinyin("davik").isEmpty,
                               "v→u 别名（dauid）不得污染西文元数据点查")
                let hits = try SearchService(store: store).matchingBooks("zorvex")
                try expectEqual(hits.map(\.bookID), ["bk-zorvex"],
                                "matchingBooks 西文查询结果集不受别名逻辑影响")
            },
            // 方案测试 3（testMatchingBooks_PinyinPreemption）
            TestDesc(suite: "PinyinDualForm", name: "matchingBooksPinyinPreemption") {
                let (store, dir) = try makeLibrary()
                defer { Fixtures.cleanup(dir) }
                let service = SearchService(store: store)
                let hits = try service.matchingBooks("lvxue")
                try expectEqual(hits.first?.bookID, "bk-law",
                                "拼音书目命中置前：书名直中书排位于 bigram 碎片页级伪候选之前")
                try expectTrue(hits.contains { $0.bookID == "bk-flv" && $0.matchingPages > 0 },
                                "Vexley 碎片页级命中保留不丢（页面命中集合语义零改动）")
                let again = try service.matchingBooks("lvxue")
                try expectEqual(hits, again, "置前序仍为库状态纯函数（全序决胜）")
                // 约束对照 1：ASCII 含 v 的西文词同样实走双形态
                //（vexley＋fauley 别名—— 归因更正：vexley 含 v，
                // 原注释"无 v 单形态"失实；断言本身有效）。两形态在投影层
                // 均零命中（库内书名/作者/文件名无 vexley/fauley 投影），
                // 命中仅来自页级 Vexley 碎片，别名不得引入书名书。
                let westernV = try service.matchingBooks("vexley")
                try expectEqual(westernV.map(\.bookID), ["bk-flv"],
                                "含 v 西文词：双形态零投影命中，页级碎片语义不受别名扰动")
                // 约束对照 2：非拼音查询（中文）不进拼音层——输出全部为页级
                // 命中（matchingPages>0），拼音 extra（恒 0 页）不得混入。
                let zh = try service.matchingBooks("样学")
                try expectTrue(zh.contains { $0.bookID == "bk-zh" && $0.matchingPages > 0 },
                               "中文页级查询照常命中")
                try expectTrue(zh.allSatisfy { $0.matchingPages > 0 },
                               "非拼音查询输出不得含拼音追加书（matchingPages=0）")
            },
            // 回归断言：updateMetadata 改
            // title/author 后拼音投影必须按新值重建。book_pinyin 以
            // file_name/title/author 为源，backfill 只补 NULL 行不覆盖已有
            // 投影——不失效则旧投影永久过期（存量缺口顺带修）。
            TestDesc(suite: "PinyinDualForm", name: "updateMetadataRebuildsPinyinProjection") {
                let (store, dir) = try makeLibrary()
                defer { Fixtures.cleanup(dir) }
                try expectTrue(try store.bookIDsMatchingPinyin("luxueyangben").contains("bk-law"),
                               "改前：旧名《律学样本》投影命中")
                try expectTrue(try store.bookIDsMatchingPinyin("yangshuyi").isEmpty,
                               "改前：新名《样书一》投影不存在")
                let updated = try store.updateMetadata(bookID: "bk-law", title: "样书一",
                                                       author: nil, version: nil,
                                                       language: nil, source: "revise-pin")
                try expectTrue(updated, "updateMetadata 必须命中该行")
                try expectTrue(try store.bookIDsMatchingPinyin("yangshuyi").contains("bk-law"),
                               "改后：新名《样书一》拼音当次会话内即可查（投影按新值重建）")
                try expectTrue(try store.bookIDsMatchingPinyin("luxueyangben").isEmpty,
                               "改后：旧名权威投影必须失效，不残留过期命中")
                let hits = try SearchService(store: store).matchingBooks("yangshuyi")
                try expectTrue(hits.contains { $0.bookID == "bk-law" },
                               "书目级全链路：新名拼音命中")
                // 失败语义断言：不存在的 bookID 走 guard
                // 早退返回 false，不进事务段，既有投影零扰动。
                let miss = try store.updateMetadata(bookID: "bk-void", title: "无所谓",
                                                    author: nil, version: nil,
                                                    language: nil, source: "revise-pin")
                try expectFalse(miss, "未知 bookID 必须返回 false")
                try expectTrue(try store.bookIDsMatchingPinyin("yangshuyi").contains("bk-law"),
                               "早退路径不得扰动既有投影")
            },
            // T 生效性核验断言：ü 直书形态（lüxue）经 normalizeForSearch
            // NFD 剥变音符落为 luxue，过 ASCII 门进拼音层，直中原生 u 形态投影
            //（无需别名）；与 lvxue（v→u 别名）在书名级同汇于同一命中。
            TestDesc(suite: "PinyinDualForm", name: "umlautFormFaluLandsOnNativeProjection") {
                let (store, dir) = try makeLibrary()
                defer { Fixtures.cleanup(dir) }
                try expectEqual(normalizeQuery("lüxue"), "luxue", "ü 剥变音符→u（NFD 去 Mn）")
                try expectTrue(PinyinNorm.isPinyinQuery("luxue"), "归一后 luxue 过 ASCII 门")
                let service = SearchService(store: store)
                try expectTrue(service.matchingBooks("lüxue").contains { $0.bookID == "bk-law" },
                               "lüxue 书级命中（原生 luxue 投影，无需别名）")
            },
        ]
    }
}
