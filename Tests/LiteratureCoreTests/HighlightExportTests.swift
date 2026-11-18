import Foundation
@testable import LiteratureCore

// MARK: - HighlightExport synthetic suite (前端批：标注导出 Markdown 组装器)
//
// 纯函数测试：不碰库、不碰文件。三轨页码行由调用方（App 层，经
// HitRouter.threeTrackPageText）生成后传入，此处以固定串代入验证版式契约：
//   # 书名 / ## 第 N 页 / 三轨行 / **颜色** / > 高亮 / 笔记（如有）

enum HighlightExportSuite {
    static var tests: [TestDesc] {
        [
            TestDesc(suite: "HighlightExport", name: "emptyEntriesYieldTitleOnly") {
                let md = HighlightExport.markdown(bookTitle: "测试书", entries: [])
                try expectEqual(md, "# 测试书\n")
            },

            TestDesc(suite: "HighlightExport", name: "singlePageFormatContract") {
                let entries = [
                    HighlightExportEntry(pageNumber: 3, pageTrackText: "物理页 3/10 · 页码标签 iii · 印刷页码 5",
                                         text: "高亮内容", note: "我的笔记", colorName: "黄色高亮"),
                ]
                let md = HighlightExport.markdown(bookTitle: "书名", entries: entries)
                let expected = """
                # 书名

                ## 第 3 页

                物理页 3/10 · 页码标签 iii · 印刷页码 5

                **黄色高亮**

                > 高亮内容

                我的笔记

                """ + "\n"
                try expectEqual(md, expected)
            },

            TestDesc(suite: "HighlightExport", name: "pagesGroupAscendingOrderKeptWithinPage") {
                let entries = [
                    HighlightExportEntry(pageNumber: 7, pageTrackText: "track-7",
                                         text: "后页", note: "", colorName: "红色高亮"),
                    HighlightExportEntry(pageNumber: 2, pageTrackText: "track-2a",
                                         text: "前页一", note: "", colorName: "黄色高亮"),
                    HighlightExportEntry(pageNumber: 2, pageTrackText: "track-2a",
                                         text: "前页二", note: "", colorName: "蓝色高亮"),
                ]
                let md = HighlightExport.markdown(bookTitle: "书", entries: entries)
                let page2 = try expectNotNil(md.range(of: "## 第 2 页"))
                let first = try expectNotNil(md.range(of: "前页一"))
                let second = try expectNotNil(md.range(of: "前页二"))
                let page7 = try expectNotNil(md.range(of: "## 第 7 页"))
                // 页分组升序；页内保持调用方顺序（前页一在 前页二 前）。
                try expectTrue(page2.lowerBound < first.lowerBound
                               && first.lowerBound < second.lowerBound
                               && second.lowerBound < page7.lowerBound,
                               "page sections must ascend; within-page order preserved")
                try expectEqual(md.components(separatedBy: "## 第 2 页").count - 1, 1,
                                "same page must appear once (track line from first entry)")
                // 笔记为空不输出笔记段
                try expectFalse(md.contains("我的笔记"), "empty note must be omitted")
            },

            TestDesc(suite: "HighlightExport", name: "multilineQuoteEveryLinePrefixed") {
                let entries = [
                    HighlightExportEntry(pageNumber: 1, pageTrackText: "track-1",
                                         text: "第一行\n第二行", note: "", colorName: "绿色高亮"),
                ]
                let md = HighlightExport.markdown(bookTitle: "书", entries: entries)
                try expectTrue(md.contains("> 第一行\n> 第二行\n"),
                               "every quote line must carry the > prefix")
            },
        ]
    }
}
