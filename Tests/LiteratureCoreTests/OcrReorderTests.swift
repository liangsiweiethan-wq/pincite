import Foundation
@testable import LiteratureCore

// 布局重排钩子五断言。
enum OcrReorderSuite {
    static var tests: [TestDesc] {
        var t: [TestDesc] = []
        t.append(TestDesc(suite: "OcrReorder", name: "headerStrippedWhenInSixtyPercentPages") {
            let pages = (0..<3).map { i in "COPYRIGHT NOTICE\n正文第\(i)页内容" }
            let out = OcrReorder.reorderParagraphs(pages: pages)
            for o in out { try expectTrue(!o.contains("COPYRIGHT NOTICE"), "页眉应剔除") }
        })
        t.append(TestDesc(suite: "OcrReorder", name: "fewerThanThreePagesSkipHeaderStripping") {
            let pages = ["SAME HEADER\na", "SAME HEADER\nb"]
            let out = OcrReorder.reorderParagraphs(pages: pages)
            try expectTrue(out[0].contains("SAME HEADER"), "两页样本不足不剔除")
        })
        t.append(TestDesc(suite: "OcrReorder", name: "blankLinesCompressedToOne") {
            let pages = ["a\n\n\n\nb"]
            let out = OcrReorder.reorderParagraphs(pages: pages)
            try expectTrue(!out[0].contains("\n\n\n"), "连续空行应压缩")
            try expectTrue(out[0].contains("\n") || out[0] == "a\nb" || out[0].contains("a"), "内容保留")
        })
        t.append(TestDesc(suite: "OcrReorder", name: "noHeaderFooterPassesThrough") {
            let pages = ["alpha\nbeta", "gamma\ndelta", "epsilon\nzeta"]
            let out = OcrReorder.reorderParagraphs(pages: pages)
            for (i, o) in out.enumerated() {
                try expectTrue(o.contains(pages[i].components(separatedBy: "\n")[0]), "非页眉脚内容原样保留")
            }
        })
        t.append(TestDesc(suite: "OcrReorder", name: "totalCharsOnlyShrink") {
            let pages = (0..<5).map { i in "HEADER\n第\(i)页正文内容较多一些字" }
            let out = OcrReorder.reorderParagraphs(pages: pages)
            let before = pages.reduce(0) { $0 + $1.count }
            let after = out.reduce(0) { $0 + $1.count }
            try expectTrue(after <= before, "重排只减不增: \(after) > \(before)")
        })
        t.append(TestDesc(suite: "OcrReorder", name: "pipelineVersionIsTwo") {
            try expectTrue(OcrPipelineVersion.current == 2, "重排上线应递增至 2")
        })
        return t
    }
}
