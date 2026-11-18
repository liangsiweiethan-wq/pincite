import Foundation
@testable import LiteratureCore
@testable import LiteratureSearchUI

// MARK: - 输入候选/历史补全层测试

enum SearchCompletionSuite {
    static func entry(_ query: String, _ hitCount: Int, _ at: TimeInterval) -> HistoryEntry {
        HistoryEntry(query: query, at: Date(timeIntervalSince1970: at), hitCount: hitCount)
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "SearchCompletion", name: "sameInputSameOutputTwice") {
                let history = [
                    entry("law of nations", 12, 50),
                    entry("lawvere theories", 3, 80),
                    entry("权利的概念", 7, 60),
                ]
                let a = SearchCompletionSource.candidates(history: history, prefix: "law")
                let b = SearchCompletionSource.candidates(history: history, prefix: "law")
                try expectEqual(a, b, "pure function must be deterministic")
            },

            TestDesc(suite: "SearchCompletion", name: "frequencyThenRecencyThenQueryOrdering") {
                let history = [
                    entry("law a", 5, 10),
                    entry("law b", 9, 10),
                    entry("law c", 9, 20),
                    entry("law d", 9, 20),
                ]
                let out = SearchCompletionSource.candidates(history: history, prefix: "law")
                let historyOnly = out.filter { !$0.isPrefixExpansion }
                try expectEqual(historyOnly.map(\.query), ["law c", "law d", "law b", "law a"],
                                "hitCount desc, then at desc, then query asc")
                try expectTrue(out.count <= SearchCompletionSource.candidateLimit)
            },

            TestDesc(suite: "SearchCompletion", name: "dedupAndExactPrefixExclusion") {
                let history = [
                    entry("Law  of  Nations", 5, 10),   // 归一化 = "law of nations"
                    entry("law of nations", 2, 30),     // 同串（归一化后）→ 去重
                    entry("law", 9, 99),                // == 前缀 → 排除
                ]
                let out = SearchCompletionSource.candidates(history: history, prefix: "law")
                let matches = out.filter { $0.query.lowercased() == "law of nations" }
                try expectEqual(matches.count, 1, "normalized duplicates collapse to one")
                try expectTrue(!out.contains { $0.query == "law" },
                               "prefix-equal history is not a completion")
            },

            TestDesc(suite: "SearchCompletion", name: "prefixExpansionShapeAndGates") {
                let out = SearchCompletionSource.candidates(history: [], prefix: "law")
                try expectEqual(out.count, 1)
                try expectTrue(out[0].isPrefixExpansion)
                try expectEqual(out[0].query, "law*")
                try expectEqual(out[0].hitCount, 0)

                let noShort = SearchCompletionSource.candidates(history: [], prefix: "l")
                try expectTrue(noShort.isEmpty, "single-char prefix stays quiet")

                let alreadyStar = SearchCompletionSource.candidates(history: [], prefix: "law*")
                try expectTrue(alreadyStar.isEmpty, "no double star")

                // 历史项频次正数 ⇒ 恒排在前缀扩展项之前（* 项沉底不抢位）。
                let mixed = SearchCompletionSource.candidates(
                    history: [entry("law and morality", 1, 1)], prefix: "law")
                try expectEqual(mixed.first?.query, "law and morality")
                try expectEqual(mixed.last?.query, "law*")
            },

            TestDesc(suite: "SearchCompletion", name: "emptyPrefixYieldsNoCandidates") {
                try expectTrue(SearchCompletionSource.candidates(history: [
                    entry("anything", 3, 1),
                ], prefix: "").isEmpty)
                try expectTrue(SearchCompletionSource.candidates(history: [], prefix: "   ").isEmpty)
                let noHistory = SearchCompletionSource.candidates(history: [], prefix: "zzz")
                try expectEqual(noHistory.map(\.query), ["zzz*"],
                                "no history match leaves only the star suggestion")
            },

            TestDesc(suite: "SearchCompletion", name: "candidatesArePlainTextNoEngineState") {
                let out = SearchCompletionSource.candidates(
                    history: [entry("state", 4, 1)], prefix: "sta")
                for candidate in out {
                    try expectTrue(!candidate.query.contains("\n"), "single-line text only")
                }
                try expectTrue(out.contains { $0.query == "sta*" }, "star suggestion is plain text")
                try expectTrue(out.contains { $0.query == "state" }, "history completion is plain text")
            },
        ]
    }
}
