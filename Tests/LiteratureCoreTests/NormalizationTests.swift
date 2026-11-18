import Foundation
@testable import LiteratureCore

enum NormalizationSuite {
    static var tests: [TestDesc] {
        [
            TestDesc(suite: "Normalization", name: "englishCaseFolding") {
                let n = normalizeForSearch("Graph Theory ROCKS")
                try expectEqual(n.text, "graph theory rocks")
            },
            TestDesc(suite: "Normalization", name: "fullWidthToHalfWidth") {
                let n = normalizeForSearch("ＡＢＣ１２３")
                try expectEqual(n.text, "abc123")
            },
            TestDesc(suite: "Normalization", name: "softHyphenAndZeroWidthRemoved") {
                let n = normalizeForSearch("prob\u{00AD}lem\u{200B}set")
                try expectEqual(n.text, "problemset")
            },
            TestDesc(suite: "Normalization", name: "whitespaceCollapsed") {
                let n = normalizeForSearch("a \t\n b")
                try expectEqual(n.text, "a b")
            },
            TestDesc(suite: "Normalization", name: "offsetMapRoundTrip") {
                let original = "中文 mix 英文"
                let n = normalizeForSearch(original)
                try expectEqual(n.text, "中文 mix 英文")
                for s in n.starts {
                    _ = original.utf16.index(original.utf16.startIndex, offsetBy: Int(s))
                }
            },
            TestDesc(suite: "Normalization", name: "mapWithCompatibilityExpansion") {
                // "ﬁ" expands to "fi" in NFKC; both output chars map to the same source char.
                let n = normalizeForSearch("ﬁre")
                try expectEqual(n.text, "fire")
                try expectEqual(n.starts, [0, 0, 1, 2])
                try expectEqual(n.ends, [1, 1, 2, 3])
            },
            TestDesc(suite: "Normalization", name: "splitQueryTerms") {
                try expectEqual(splitQueryTerms(normalizeQuery("  中文  GRAPH  ")), ["中文", "graph"])
            },
            TestDesc(suite: "Normalization", name: "likeEscaping") {
                try expectEqual(escapeForLike("100%_a\\b"), "100\\%\\_a\\\\b")
            },
            TestDesc(suite: "Normalization", name: "ftsQuotingIsLiteral") {
                try expectEqual(quoteForFTS("a\"b"), "\"a\"\"b\"")
            },
        ]
    }
}
