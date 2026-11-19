import Foundation
@testable import LiteratureCore

// MARK: - 功能扩展：批注导出 HTML/TXT 补缺测试
//
// 断言面：htmlEscape 五字符转义；annotations.html 列集合与 annotations.csv
// 完全一致（单一事实，不造第二套字段）＋行数对齐＋转义生效；
// annotations.txt 行格式（书名 [第 N 页] 类型/颜色 摘句 —— 笔记；摘句空/
// 笔记空各自省段；行内换行压空格）；选择器默认值不破旧调用。

enum AnnotationExportHTMLTXTSuite {
    static func row(id: Int, page: Int, type: String, text: String, note: String) ->
        AnnotationExportAssembler.AnnotationCSVRow {
        AnnotationExportAssembler.AnnotationCSVRow(
            bookID: "b1", bookTitle: "测试书", pageNumber: page, type: type,
            color: "yellow", text: text, note: note,
            createdAtISO8601: "2026-10-07T00:00:00Z",
            viewSource: "ocr", anchorVerified: type == "page_note" ? 0 : 1)
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "AnnotationExportHTMLTXT", name: "htmlEscapePinsFiveCharacters") {
                try expectEqual(AnnotationExportAssembler.htmlEscape("&"), "&amp;")
                try expectEqual(AnnotationExportAssembler.htmlEscape("<"), "&lt;")
                try expectEqual(AnnotationExportAssembler.htmlEscape(">"), "&gt;")
                try expectEqual(AnnotationExportAssembler.htmlEscape("\""), "&quot;")
                try expectEqual(AnnotationExportAssembler.htmlEscape("'"), "&#39;")
                // 复合串一次转义到位，且 & 不二次转义。
                try expectEqual(AnnotationExportAssembler.htmlEscape("<b>&'\""),
                                "&lt;b&gt;&amp;&#39;&quot;")
                try expectEqual(AnnotationExportAssembler.htmlEscape("无特殊字符"),
                                "无特殊字符")
            },
            TestDesc(suite: "AnnotationExportHTMLTXT", name: "htmlColumnSetMatchesCSVAndEscapes") {
                let rows = [
                    row(id: 1, page: 2, type: "highlight", text: "含<b>标签</b>&引号\"摘句", note: ""),
                    row(id: 2, page: 5, type: "page_note", text: "", note: "页级批注"),
                ]
                let html = AnnotationExportAssembler.annotationsHTML(rows: rows)
                // 列集合单一事实：表头 th 序列与 CSV 表头字段序列逐字一致。
                try expectTrue(html.contains("<tr><th>book_id</th><th>book_title</th><th>page</th><th>type</th><th>color</th><th>text</th><th>note</th><th>created_at_iso8601</th><th>view_source</th><th>anchor_verified</th></tr>"),
                               "表头必须与 CSV 列集合一致：\\(html.prefix(300))")
                // 行数对齐：数据行恰两行（每行一 <tr>）。
                try expectEqual(html.components(separatedBy: "<tr>").count - 1, 3,
                                "表头一 tr + 数据两 tr")
                // 转义生效：原文 <b> 不得裸出现。
                try expectTrue(html.contains("&lt;b&gt;标签&lt;/b&gt;&amp;引号&quot;摘句"),
                               "text 必须经 htmlEscape")
                try expectFalse(html.contains("<b>"))
                // 结构完整结算。
                try expectTrue(html.hasPrefix("<!DOCTYPE html>"))
                try expectTrue(html.hasSuffix("</html>\n"))
            },
            TestDesc(suite: "AnnotationExportHTMLTXT", name: "txtLineFormatPins") {
                let rows = [
                    row(id: 1, page: 2, type: "highlight", text: "多行\n摘句", note: "有笔记"),
                    row(id: 2, page: 5, type: "page_note", text: "", note: "页级批注"),
                    row(id: 3, page: 7, type: "underline", text: "无笔记摘句", note: ""),
                ]
                let txt = AnnotationExportAssembler.annotationsTXT(rows: rows)
                let lines = txt.split(separator: "\n").map(String.init)
                try expectEqual(lines.count, 3, "一行一批注")
                try expectEqual(lines[0], "测试书 [第 2 页] highlight/yellow 多行 摘句 —— 有笔记",
                                "换行压空格；笔记空缺段格式断言")
                try expectEqual(lines[1], "测试书 [第 5 页] page_note/yellow —— 页级批注",
                                "摘句空（页级批注）省摘句段")
                try expectEqual(lines[2], "测试书 [第 7 页] underline/yellow 无笔记摘句",
                                "笔记空省尾段（不留悬垂分隔符）")
            },
            TestDesc(suite: "AnnotationExportHTMLTXT", name: "selectionDefaultsStayBackwardCompatible") {
                // 默认两新格式 false——既有调用（不传新参）导出面零变化。
                let legacy = AnnotationExportSelection(annotationsMarkdown: true,
                                                       annotationsCSV: true,
                                                       citationsMarkdown: true,
                                                       citationsCSV: true)
                try expectEqual(legacy.annotationsHTML, false)
                try expectEqual(legacy.annotationsTXT, false)
                try expectTrue(legacy != AnnotationExportSelection(annotationsMarkdown: false,
                                                                   annotationsCSV: false,
                                                                   citationsMarkdown: false,
                                                                   citationsCSV: false,
                                                                   annotationsHTML: false,
                                                                   annotationsTXT: false),
                               "全 false 与默认值可判别（视图 hasAnySelection 语义）")
            },
        ]
    }
}
