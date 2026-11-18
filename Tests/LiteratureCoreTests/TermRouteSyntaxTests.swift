import Foundation
@testable import LiteratureCore

// MARK: - 拆分routeTerm 随迁测试

enum TermRouteSyntaxSuite {
    static var tests: [TestDesc] {
        [
            TestDesc(suite: "TermRouteSyntax", name: "syntaxRouteThreeBranches") {
                // 1) 含非 ASCII → .cjkPath（现行 bigram 全链，字节不动）
                try expectEqual(QuerySyntax.syntaxRoute(term: "法律", wftsReady: true), .cjkPath)
                try expectEqual(QuerySyntax.syntaxRoute(term: "state权", wftsReady: true), .cjkPath)
                // 2) 非纯 [a-zA-Z0-9]（含点/撇号）→ .latinSubstringPath
                try expectEqual(QuerySyntax.syntaxRoute(term: "h.l.a.", wftsReady: true), .latinSubstringPath)
                try expectEqual(QuerySyntax.syntaxRoute(term: "o'connor", wftsReady: false), .latinSubstringPath)
                // 3) 纯字母且 PinyinSyllables.isParseable → .latinSubstringPath
                //    （falv=fa+lv 可解析；不可用 isPinyinQuery——"rights" 也中）
                try expectEqual(QuerySyntax.syntaxRoute(term: "falv", wftsReady: true), .latinSubstringPath)
                try expectEqual(QuerySyntax.syntaxRoute(term: "falv", wftsReady: false), .latinSubstringPath)
                // 4) 纯字母数字非拼音＋wftsReady → .latinWordPath
                try expectEqual(QuerySyntax.syntaxRoute(term: "rights", wftsReady: true), .latinWordPath)
                try expectEqual(QuerySyntax.syntaxRoute(term: "b200", wftsReady: true), .latinWordPath)
                // 路由名随迁（原 SearchService.routeName switch 体逐字；routedTerms 值域）
                try expectEqual(TermRoute.cjkPath.routeName(), "cjkPath")
                try expectEqual(TermRoute.latinWordPath.routeName(), "latinWordPath")
                try expectEqual(TermRoute.latinSubstringPath.routeName(), "latinSubstringPath")
            },

            TestDesc(suite: "TermRouteSyntax", name: "syntaxRouteWftsReadyTwoStates") {
                // 同一词项两态：ready=词路；未 ready（回填期/降级窗）=子串路。
                try expectEqual(QuerySyntax.syntaxRoute(term: "rights", wftsReady: true), .latinWordPath)
                try expectEqual(QuerySyntax.syntaxRoute(term: "rights", wftsReady: false), .latinSubstringPath)
                try expectEqual(QuerySyntax.syntaxRoute(term: "b200", wftsReady: true), .latinWordPath)
                try expectEqual(QuerySyntax.syntaxRoute(term: "b200", wftsReady: false), .latinSubstringPath)
                // 拼音分支先于 wfts 门短路：可解析拼音两态同落子串路
                // （rule=ru+le、human=hu+man； 示例短语「rule of law」
                // 「human rights」零变化的路由根基，WordLevelIndex 既有断言同源）。
                try expectEqual(QuerySyntax.syntaxRoute(term: "rule", wftsReady: true), .latinSubstringPath)
                try expectEqual(QuerySyntax.syntaxRoute(term: "rule", wftsReady: false), .latinSubstringPath)
                try expectEqual(QuerySyntax.syntaxRoute(term: "human", wftsReady: true), .latinSubstringPath)
                try expectEqual(QuerySyntax.syntaxRoute(term: "human", wftsReady: false), .latinSubstringPath)
            },
        ]
    }
}
