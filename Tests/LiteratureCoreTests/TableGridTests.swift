import Foundation
import PDFKit
@testable import LiteratureCore
@testable import LiteratureSearchUI

// MARK: - 表格圈选几何套件（TableGridGeometry 纯函数）

enum TableGridSuite {

    /// 词助手（页坐标系 rect）。
    static func word(_ text: String, _ x: CGFloat, _ y: CGFloat,
                     _ w: CGFloat = 30, _ h: CGFloat = 12) -> TableWord {
        TableWord(text: text, rect: CGRect(x: x, y: y, width: w, height: h))
    }

    static var tests: [TestDesc] {
        [
            // ── 3×2 规整表格：行列数与单元格文本逐格断言 ──
            TestDesc(suite: "TableGrid", name: "regularGridCellsExact") {
                var words: [TableWord] = []
                let colX: [CGFloat] = [10, 200, 400]
                // y 向上坐标系：rowY[0]=130 是页顶（表头行），rowY[1]=100 是次行。
                let rowY: [CGFloat] = [130, 100]
                let cells = [["名称", "作者", "年份"],
                             ["样式分析", "甲乙", "2001"]]
                for (r, row) in cells.enumerated() {
                    for (c, text) in row.enumerated() {
                        words.append(word(text, colX[c], rowY[r]))
                    }
                }
                let grid = try expectNotNil(TableGridGeometry.grid(words: words))
                try expectEqual(grid.count, 2)
                try expectEqual(grid[0].count, 3)
                try expectEqual(grid[0], ["名称", "作者", "年份"])
                try expectEqual(grid[1], ["样式分析", "甲乙", "2001"])
                let tsv = try expectNotNil(TableGridGeometry.tsv(from: grid))
                try expectEqual(tsv, "名称\t作者\t年份\n样式分析\t甲乙\t2001")
            },

            // ── ragged 行：2 列行 + 3 列行 → 短行右侧补空串 ──
            TestDesc(suite: "TableGrid", name: "raggedRowsPaddedWithEmptyStrings") {
                // y 向上：A 行（2 列）y=130 页顶在前，B 行（3 列）y=100。
                let words = [
                    word("A1", 10, 130), word("A2", 200, 130),
                    word("B1", 10, 100), word("B2", 200, 100), word("B3", 400, 100),
                ]
                let grid = try expectNotNil(TableGridGeometry.grid(words: words))
                try expectEqual(grid.count, 2)
                for row in grid { try expectEqual(row.count, 3) }
                try expectEqual(grid[0], ["A1", "A2", ""])
                try expectEqual(grid[1], ["B1", "B2", "B3"])
                let tsv = try expectNotNil(TableGridGeometry.tsv(from: words))
                try expectTrue(tsv.hasPrefix("A1\tA2\t\n"))
            },

            TestDesc(suite: "TableGrid", name: "cellWhitespaceFlattenedTSVSafe") {
                let words = [
                    word("标题", 10, 130), word("备注", 200, 130),
                    word("第一\t行", 10, 100), word("含\r\n换行", 200, 100),
                ]
                let tsv = try expectNotNil(TableGridGeometry.tsv(from: words))
                // 行列边界完整：2 行 × 2 列
                let lines = tsv.components(separatedBy: "\n")
                try expectEqual(lines.count, 2)
                for line in lines {
                    try expectEqual(line.components(separatedBy: "\t").count, 2)
                }
                // 压平：控制字符不再出现；词间空白折叠为单空格
                try expectFalse(tsv.contains("\r"))
                try expectEqual(lines[1], "第一 行\t含 换行")
                // flattenCell 直测：连续控制字符折叠为一个空格
                try expectEqual(TableGridGeometry.flattenCell("a\t\tb"), "a b")
                try expectEqual(TableGridGeometry.flattenCell("a\n\n\rb"), "a b")
            },

            // ── 零面积/零词/空表 → nil 拒绝（fail-closed）──
            TestDesc(suite: "TableGrid", name: "emptyInputsRejected") {
                try expectNil(TableGridGeometry.grid(words: []))
                try expectNil(TableGridGeometry.tsv(from: [TableWord]()))
                let zeroArea = TableWord(text: "零", rect: CGRect(x: 0, y: 0, width: 0, height: 10))
                try expectNil(TableGridGeometry.grid(words: [zeroArea]))
                try expectNil(TableGridGeometry.tsv(from: [[String]]()))
                let blank = TableWord(text: "", rect: CGRect(x: 0, y: 0, width: 10, height: 10))
                try expectNil(TableGridGeometry.grid(words: [blank]))
            },

            // ── 垂直 IoU 归行：交并比 ≥0.5 归同一行，<0.5 分行 ──
            TestDesc(suite: "TableGrid", name: "verticalIoUBoundaryRows") {
                // 字高 12：y 差 6 → 交集 6 / 并集 18 = 0.33 < 0.5 → 两行
                let apart = [word("A", 10, 100), word("B", 200, 106)]
                let gridApart = try expectNotNil(TableGridGeometry.grid(words: apart))
                try expectEqual(gridApart.count, 2)
                // y 差 0 → IoU 1.0 → 同行
                let same = [word("A", 10, 100), word("B", 200, 100)]
                let gridSame = try expectNotNil(TableGridGeometry.grid(words: same))
                try expectEqual(gridSame.count, 1)
                // 阈值边界：y 差 = 字高一半（6/18 = 0.333）归两行；完全重叠归一行
                // 行区间扩张语义：两词 y 差 4 → 交集 8 / 并集 16 = 0.5 → 同行
                let edge = [word("A", 10, 100), word("B", 200, 104)]
                let gridEdge = try expectNotNil(TableGridGeometry.grid(words: edge))
                try expectEqual(gridEdge.count, 1)
                // 直接函数断言
                try expectEqual(TableGridGeometry.verticalIoU(
                    CGRect(x: 0, y: 100, width: 1, height: 12), top: 100, bottom: 112), CGFloat(1))
                try expectEqual(TableGridGeometry.verticalIoU(
                    CGRect(x: 0, y: 200, width: 1, height: 12), top: 100, bottom: 112), CGFloat(0))
            },

            // ── 列间隙阈值：>1.5×字高断列，≤ 不断 ──
            TestDesc(suite: "TableGrid", name: "columnGapThresholdBoundary") {
                // 字高 12，词宽 30：gap = 1.5×12 = 18 为界
                // gap=18（=阈值）→ 同列合并；gap=19 → 断列
                let boundary = [word("AB", 10, 100, 30, 12), word("CD", 10 + 30 + 18, 100, 30, 12)]
                let gridB = try expectNotNil(TableGridGeometry.grid(words: boundary))
                try expectEqual(gridB[0].count, 1)
                try expectEqual(gridB[0][0], "AB CD")
                let beyond = [word("AB", 10, 100, 30, 12), word("CD", 10 + 30 + 19, 100, 30, 12)]
                let gridC = try expectNotNil(TableGridGeometry.grid(words: beyond))
                try expectEqual(gridC[0].count, 2)
                try expectEqual(gridC[0], ["AB", "CD"])
            },

            // ── 行序恢复：输入乱序（中心 y 乱序）输出仍按行顶升序 ──
            TestDesc(suite: "TableGrid", name: "rowOrderRestoredAfterSort") {
                // y 向上：上1/上2 在 y=200（页顶），下1/下2 在 y=100。
                let words = [
                    word("下1", 10, 100), word("上1", 10, 200),
                    word("下2", 200, 100), word("上2", 200, 200),
                ]
                let grid = try expectNotNil(TableGridGeometry.grid(words: words))
                try expectEqual(grid[0], ["上1", "上2"])
                try expectEqual(grid[1], ["下1", "下2"])
            },

            TestDesc(suite: "TableGrid", name: "tokenRangesPreserveSymbols") {
                let tokens = TableGridGeometry.tokenRanges(in: "温度 −3.5%  [3.5] 合计1,234件")
                let texts = tokens.map { $0.token }
                try expectEqual(texts, ["温度", "−3.5%", "[3.5]", "合计1,234件"])
                // utf16 range 与 token 一一对应（selection(for:) 消费契约）
                let src = "温度 −3.5%  [3.5] 合计1,234件" as NSString
                for (tok, r) in tokens {
                    try expectEqual(src.substring(with: r), tok)
                }
                // 空串/全空白 → 空
                try expectTrue(TableGridGeometry.tokenRanges(in: "").isEmpty)
                try expectTrue(TableGridGeometry.tokenRanges(in: "  \n\t ").isEmpty)
            },

            TestDesc(suite: "TableGrid", name: "pdfKitSelectionBoundsYIsUpward") {
                let dir = Fixtures.makeTempDir("tablegrid-ydir")
                defer { Fixtures.cleanup(dir) }
                let url = Fixtures.makePDF(pages: [
                    SyntheticPDFPage(lines: ["TOPWORD alpha", "BOTTOMWORD omega"]),
                ], in: dir, named: "ydir.pdf")
                let doc = try expectNotNil(PDFDocument(url: url))
                let page = try expectNotNil(doc.page(at: 0))
                let text = try expectNotNil(page.string)
                let ns = text as NSString
                var midY: [String: CGFloat] = [:]
                ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                                       options: [.byWords]) { sub, range, _, _ in
                    guard let sub, let sel = page.selection(for: range) else { return }
                    midY[sub] = sel.bounds(for: page).midY
                }
                let top = try expectNotNil(midY["TOPWORD"], "页顶词 bounds 缺失")
                let bottom = try expectNotNil(midY["BOTTOMWORD"], "页底词 bounds 缺失")
                try expectTrue(top > bottom,
                               "PDFKit 页坐标应为 y 向上（页顶词 midY 应更大）：top=\(top) bottom=\(bottom)")
            },

            // ── 行内相邻词拼接：同列小间隙词以单空格连接 ──
            TestDesc(suite: "TableGrid", name: "intraCellWordsJoinedWithSpace") {
                let words = [
                    word("计算", 10, 130), word("理论", 44, 130),
                    word("其他", 400, 130),
                ]
                let grid = try expectNotNil(TableGridGeometry.grid(words: words))
                try expectEqual(grid[0], ["计算 理论", "其他"])
            },
        ]
    }
}
