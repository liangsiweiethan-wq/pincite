import Foundation
@testable import LiteratureCore

// MARK: -：ORDER BY 顺序契约四场景

enum PinyinOrderContractSuite {

    /// 主形态书：拉丁 fileName/title 直落投影，投影含字面 falv、不含 falu。
    static func addMainBook(_ store: IndexStore, id: String) throws {
        try IndexingRegressionSuite.addBook(store, id: id, fileName: "\(id)-falv-page.pdf",
                                       title: "\(id) Falv Page", author: nil,
                                       pages: ["main form page"])
    }

    /// 别名书：汉字书名（律 lǜ→lu）投影只含 falu 面、不含字面 falv。
    static func addAliasBook(_ store: IndexStore, id: String, label: String) throws {
        try IndexingRegressionSuite.addBook(store, id: id, fileName: "\(id)-law.pdf",
                                       title: "法律\(label)", author: nil,
                                       pages: ["alias form page"])
    }

    /// 两形态书：拉丁 fileName/title 同时含 falv 与 falu 字面。
    static func addBothBook(_ store: IndexStore, id: String) throws {
        try IndexingRegressionSuite.addBook(store, id: id, fileName: "\(id)-falv-falu.pdf",
                                       title: "\(id) Falv Falu", author: nil,
                                       pages: ["both forms page"])
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "PinyinOrderContract", name: "dedupBothFormsBookStaysInMainGroup") {
                let dir = Fixtures.makeTempDir("pinyin-order-x1")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                // 插入序刻意与期望序正交：c → a → b。
                try addAliasBook(store, id: "c-alias-falu", label: "丙")
                try addMainBook(store, id: "a-main-falv")
                try addBothBook(store, id: "b-both-forms")
                try store.backfillPinyinIfNeeded()
                let ids = try store.bookIDsMatchingPinyin("falv")
                try expectEqual(ids, ["a-main-falv", "b-both-forms", "c-alias-falu"],
                                "两形态书去重后必须落在主形态组位置（先于别名-only 书）——ORDER BY 契约场景①")
            },

            TestDesc(suite: "PinyinOrderContract", name: "mainEmptyAliasGroupSortedBookIdAsc") {
                let dir = Fixtures.makeTempDir("pinyin-order-x2")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                try addAliasBook(store, id: "z-alias", label: "三")
                try addAliasBook(store, id: "a-alias", label: "一")
                try addAliasBook(store, id: "m-alias", label: "二")
                try store.backfillPinyinIfNeeded()
                let ids = try store.bookIDsMatchingPinyin("falv")
                try expectEqual(ids, ["a-alias", "m-alias", "z-alias"],
                                "主形态空时别名组必须按 book_id ASC——ORDER BY 契约场景②")
            },

            TestDesc(suite: "PinyinOrderContract", name: "sharedBookIdKeepsOrderNoDuplication") {
                let dir = Fixtures.makeTempDir("pinyin-order-x3")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                // 插入序刻意全逆：z → m → b → a。
                try addAliasBook(store, id: "z-alias", label: "丁")
                try addBothBook(store, id: "m-both")
                try addAliasBook(store, id: "b-alias", label: "乙")
                try addBothBook(store, id: "a-both")
                try store.backfillPinyinIfNeeded()
                let ids = try store.bookIDsMatchingPinyin("falv")
                try expectEqual(ids,
                                ["a-both", "m-both", "b-alias", "z-alias"],
                                "alias∩primary 同 book_id 去重后落主形态组，别名-only 按 ASC 续后，无重复——ORDER BY 契约场景③")
                try expectEqual(Set(ids).count, ids.count, "全序列无重复")
            },

            TestDesc(suite: "PinyinOrderContract", name: "nonVWordCollectsExactlyOnce") {
                // 缝面：非 v 词（可解析与否）恒单形态；可解析 v 词恰两形态。
                try expectEqual(PinyinSyllables.collectForms(for: "renmin"), ["renmin"],
                                "非 v 可解析词 collect 恰一次（renmin）")
                try expectEqual(PinyinSyllables.collectForms(for: "nihao"), ["nihao"],
                                "非 v 可解析词 collect 恰一次（nihao）")
                try expectEqual(PinyinSyllables.collectForms(for: "van"), ["van"],
                                "不可解析词 collect 恰一次（van，门控仅主形态）")
                try expectEqual(PinyinSyllables.collectForms(for: "falv"), ["falv", "falu"],
                                "可解析 v 词恰两次（主＋别名）——对照组")
                try expectEqual(PinyinSyllables.collectForms(for: "nvren"), ["nvren", "nuren"],
                                "可解析 v 词恰两次（nvren）——对照组")
                // 行为面：非 v 词检索结果 ≡ 直接 SQL（ORDER BY book_id ASC 全量
                // 查询）——一次等价 collect 即该查询本身。三书投影均含
                // yangshuyi（样书一）面，对照非空。
                let dir = Fixtures.makeTempDir("pinyin-order-x4")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                try IndexingRegressionSuite.addBook(store, id: "z-law", fileName: "z-law3.pdf",
                                               title: "样书一第三版", author: nil,
                                               pages: ["alias page"])
                try IndexingRegressionSuite.addBook(store, id: "a-law", fileName: "a-law1.pdf",
                                               title: "样书一", author: nil,
                                               pages: ["alias page"])
                try IndexingRegressionSuite.addBook(store, id: "m-law", fileName: "m-law2.pdf",
                                               title: "样书一导读", author: nil,
                                               pages: ["alias page"])
                try store.backfillPinyinIfNeeded()
                let ids = try store.bookIDsMatchingPinyin("yangshuyi") // 非 v 可解析词
                try expectTrue(!ids.isEmpty, "行为对照须非空（防测试库失效假绿）")
                try expectEqual(Set(ids).count, 3, "三书投影均含 faludegailun 面，应全命中")
                var sqlIds: [String] = []
                let stmt = try store.db.prepare(
                    "SELECT book_id FROM book_pinyin WHERE instr(pinyin_norm, 'yangshuyi') > 0 ORDER BY book_id ASC;")
                while try stmt.step() { sqlIds.append(stmt.text(0)) }
                try expectEqual(ids, sqlIds,
                                "非 v 词一次等价 collect ≡ 直接 SQL ORDER BY 全量查询（行为面对照）")
            },
        ]
    }
}
