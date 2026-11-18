import Foundation
@testable import LiteratureCore

// MARK: - 自动目录生成合成套件（HeadingDetector + IndexStore.auto_toc）

enum AutoTOCSuite {
    static var tests: [TestDesc] {
        [
            TestDesc(suite: "AutoTOC", name: "headingDetectorLevelsAndPatterns") {
                let part = HeadingDetector.detectHeading(inPageText: "第一编 总论\n正文……")
                try expectEqual(try expectNotNil(part).level, 0)
                let chapter = HeadingDetector.detectHeading(inPageText: "第三章 语言的确定性")
                try expectEqual(try expectNotNil(chapter).level, 1)
                let en = HeadingDetector.detectHeading(inPageText: "Chapter 12  A Sample Treatise")
                try expectEqual(try expectNotNil(en).level, 1)
                let section = HeadingDetector.detectHeading(inPageText: "第二节 权威的证成")
                try expectEqual(try expectNotNil(section).level, 2)
                let list = HeadingDetector.detectHeading(inPageText: "三、法律与强制")
                try expectEqual(try expectNotNil(list).level, 3)
                try expectNil(HeadingDetector.detectHeading(inPageText: "正文第一行没有标题模式，直接陈述命题。"))
            },
            TestDesc(suite: "AutoTOC", name: "extractSkipsTOCPagesAndDedupes") {
                let tocPage = (page: 2, text: (1...8).map { "第\($0)章 条目\($0)……12" }.joined(separator: "\n"))
                let entries = HeadingDetector.extract(pageTexts: [
                    (1, "前言\n这是前言页。"),
                    tocPage,
                    (7, "第一章 导论\n本章讨论……"),
                    (9, "第二章 方法\n本章讨论……"),
                    (10, "第二章 方法\n续页不重复收录。"),
                ])
                try expectEqual(entries.count, 2, "目录页跳过、续页去重")
                try expectEqual(entries[0].page, 7)
                try expectEqual(entries[0].label, "第一章 导论")
                try expectEqual(entries[1].page, 9)
            },
            TestDesc(suite: "AutoTOC", name: "storeRoundTripAndIdempotentRebuild") {
                let dir = Fixtures.makeTempDir("autotoc-store")
                defer { Fixtures.cleanup(dir) }
                IndexSearchSuite.buildLibrary(dir)
                let store = try Fixtures.openStore(in: dir)
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                let bookA = try expectNotNil(try store.allBooks().first { $0.fileName == "bookA.pdf" })
                // 夹具页首页二各含「第一章/第二章」标题行。
                let rebuilt = try store.rebuildAutoTOCIfNeeded(bookID: bookA.id)
                try expectTrue(rebuilt)
                let toc = try store.autoTOC(for: bookA.id)
                try expectEqual(toc.count, 2)
                try expectEqual(toc[0].page, 1)
                try expectTrue(toc[0].label.contains("第一章"))
                try expectEqual(toc[1].level, 1)
                // 幂等：页数未变第二次不再重建。
                try expectFalse(try store.rebuildAutoTOCIfNeeded(bookID: bookA.id))
                // bookB 也盖戳后，全库批扫对未变化书为空转。
                let bookB = try expectNotNil(try store.allBooks().first { $0.fileName == "bookB.pdf" })
                _ = try store.rebuildAutoTOCIfNeeded(bookID: bookB.id)
                let allAgain = try store.rebuildAutoTOCAll()
                try expectEqual(allAgain, 0, "全库批扫对未变化书为空转")
                // 无目录书（bookB 无标题模式）= 空目录但有 state 戳。
                try expectTrue(try store.autoTOC(for: bookB.id).isEmpty)
            },
            TestDesc(suite: "AutoTOC", name: "runningHeaderWithPageJunkDeduped") {
                // 生产实况：章续页页眉带页码尾巴（"第一章 公平正义 5 6 2.
                // 原文…"），清洗后同标签 → 页眉去重生效，一章只留起点。
                let entries = HeadingDetector.extract(pageTexts: [
                    (80, "第一章 公平正义 5 6 2. 原文: “ the exposition is inform”\n正文"),
                    (82, "第一章 公平正义 7 6 12. 原文: “my guiding aim”\n正文"),
                    (84, "第二章 方法 9 7 1. 按语\n正文"),
                ])
                try expectEqual(entries.count, 2, "页眉尾巴清洗后同章去重")
                try expectEqual(entries[0].label, "第一章 公平正义")
                try expectEqual(entries[1].page, 84)
            },
        ]
    }
}
