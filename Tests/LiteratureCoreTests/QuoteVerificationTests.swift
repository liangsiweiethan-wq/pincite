import Foundation
@testable import LiteratureCore

// MARK: - /E3/E4 测试（三级引句定位 / grounding 归一化 / 五级分层匹配）
//
// 门禁：定位/标注增强、检索排序语义零触碰——本套件只打纯函数，
// 不触 SearchService；分级/降级一律如实标注断言（宁缺勿错）。

/// UTF-16 区间取原文切片（测试断言用）。
private func sliceUTF16(_ s: String, _ r: Range<Int>) -> String {
    let units = Array(s.utf16)
    guard r.lowerBound >= 0, r.upperBound <= units.count, r.lowerBound <= r.upperBound else {
        return "<range-out-of-bounds>"
    }
    return String(decoding: units[r].map { UInt16($0) }, as: UTF16.self)
}

enum QuoteVerificationTests {
    static var tests: [TestDesc] {
        [

            TestDesc(suite: "QuoteLocate", name: "exactHitMapsNormRangeToOriginalUTF16") {
                let original = "A fictional label reads Inventarium beside the sample tray."
                let norm = normalizeForSearch(original)
                let loc = QuoteLocate.locate(quote: "inventarium", pageOriginal: original, norm: norm)
                try expectEqual(loc.level, QuoteLocate.Level.exact)
                let r = try expectNotNil(loc.originalUTF16Range)
                try expectEqual(sliceUTF16(original, r), "Inventarium")
                try expectEqual(loc.similarity, 1.0)
                try expectNil(loc.reason)
            },

            TestDesc(suite: "QuoteLocate", name: "approximateHitWithinBoundedDPFindsTypo") {
                let original = "The sample lantern glows beside the painted boxes on the shelf."
                let norm = normalizeForSearch(original)
                let loc = QuoteLocate.locate(quote: "lantern glows beside the paited boxes on the shef",
                                             pageOriginal: original, norm: norm)
                try expectEqual(loc.level, QuoteLocate.Level.approximate)
                let r = try expectNotNil(loc.originalUTF16Range)
                let sim = try expectNotNil(loc.similarity)
                try expectTrue(sim >= QuoteLocate.minSimilarity, "相似度 \(sim) 应达阈值")
                try expectTrue(sliceUTF16(original, r).hasPrefix("lantern"),
                               "区间应锚定命中段，实得: \(sliceUTF16(original, r))")
            },

            TestDesc(suite: "QuoteLocate", name: "missingNormBlobDegradesToPageLevelHonestly") {
                let loc = QuoteLocate.locate(quote: "anything", pageOriginal: "text", norm: nil)
                try expectEqual(loc.level, QuoteLocate.Level.pageOnly)
                try expectNil(loc.originalUTF16Range)
                let reason = try expectNotNil(loc.reason)
                try expectTrue(reason.contains("norm blob 缺损"), "降级原因须如实标注: \(reason)")
            },

            TestDesc(suite: "QuoteLocate", name: "absentQuoteReportsNotFoundNotPageOnly") {
                let original = "Completely unrelated sample text about archives."
                let norm = normalizeForSearch(original)
                let loc = QuoteLocate.locate(quote: "quantum chromodynamics parity violation",
                                             pageOriginal: original, norm: norm)
                try expectEqual(loc.level, QuoteLocate.Level.notFound)
                try expectNil(loc.originalUTF16Range)
                try expectNotNil(loc.reason)
            },

            TestDesc(suite: "QuoteLocate", name: "needleCapSkipsApproximateToPageLevel") {
                let original = String(repeating: "word ", count: 600)
                let norm = normalizeForSearch(original)
                // 尾部扰动防精确层接住；needle 归一化后 > 500 → 跳过近似层如实降级。
                let hugeQuote = String(repeating: "word ", count: 600) + " typo"
                let loc = QuoteLocate.locate(quote: hugeQuote, pageOriginal: original, norm: norm)
                try expectEqual(loc.level, QuoteLocate.Level.pageOnly)
                let reason = try expectNotNil(loc.reason)
                try expectTrue(reason.contains("needle 上限"), "超限原因如实: \(reason)")
            },

            TestDesc(suite: "QuoteLocate", name: "anchorCarriesSearchHitBookAndPage") {
                let hit = SearchHit(bookID: "bE2", filePath: "/tmp/x.pdf", fileName: "x.pdf",
                                    fingerprint: "fp", physicalPage: 7, pageLabel: nil,
                                    printedPage: nil, pageCount: 10, title: nil, author: nil,
                                    version: nil, language: nil, matches: [], snippet: "")
                let original = "Locate this sentence precisely here."
                let anchor = QuoteLocate.anchor(quote: "this sentence",
                                                hit: hit, pageOriginal: original,
                                                norm: normalizeForSearch(original))
                try expectEqual(anchor.bookID, "bE2")
                try expectEqual(anchor.physicalPage, 7)
                try expectEqual(anchor.location.level, QuoteLocate.Level.exact)
            },


            TestDesc(suite: "QuoteGround", name: "variantFoldingRecognizesTrueQuoteAsExact") {
                // 引句用弯引号/NBSP/em-dash 变体；原文用直引号/普通空格/普通连字符。
                let original = "A sample archive stores 'fictional' records-in a clearly ordered collection."
                let quote = "A sample archive stores \u{2018}fictional\u{2019}\u{00A0}records\u{2014}in a clearly ordered collection"
                let r = QuoteGround.verify(quote: quote, original: original)
                try expectEqual(r.verdict, QuoteGround.Verdict.exact)
                try expectEqual(r.note, "canonical-contain")
            },

            TestDesc(suite: "QuoteGround", name: "trailingFigureReferenceStrippedFromQuoteSideOnly") {
                let original = "The sample counter displays twelve painted lanterns."
                let withTail = "The sample counter displays twelve painted lanterns. (Fig. 2a)"
                let r = QuoteGround.verify(quote: withTail, original: original)
                try expectEqual(r.verdict, QuoteGround.Verdict.exact)
                // 剥尾函数直断言：引用尾巴剥；非引用括号不剥。
                try expectEqual(QuoteGround.stripTrailingReference("End of sentence. (p. 3)"), "End of sentence.")
                try expectEqual(QuoteGround.stripTrailingReference("A (B) C"), "A (B) C")
            },

            TestDesc(suite: "QuoteGround", name: "elisionSegmentsMatchedInOrderIsFuzzy") {
                let original = "Records are not random, nor are they mere entries; they follow an ordered pattern."
                let elided = "Records are not random … they follow an ordered pattern."
                let r = QuoteGround.verify(quote: elided, original: original)
                try expectEqual(r.verdict, QuoteGround.Verdict.fuzzy)
                try expectEqual(r.segments, 2)
                try expectEqual(r.matchedSegments, 2)
                try expectEqual(r.note, "elision-in-order")
            },

            TestDesc(suite: "QuoteGround", name: "dehyphenatedLineBreakVariantIsFuzzy") {
                // PDF 断词：原文 "sample records" 被抽成 "sam-\nple records"。
                let original = "the sam-\nple records in an archive"
                let quote = "the sample records"
                let r = QuoteGround.verify(quote: quote, original: original)
                try expectEqual(r.verdict, QuoteGround.Verdict.fuzzy)
                try expectEqual(r.note, "dehyphenated")
            },

            TestDesc(suite: "QuoteGround", name: "fabricatedQuoteIsRejectedNone") {
                // 编造引句：原文根本没有这段——exact/fuzzy 都不许认领（宁缺勿错核心）。
                let original = "The sample record was stored in the archive."
                let r = QuoteGround.verify(quote: "The archive awarded one billion tokens to every record",
                                           original: original)
                try expectEqual(r.verdict, QuoteGround.Verdict.none)
                try expectNotNil(r.note)
            },

            TestDesc(suite: "QuoteGround", name: "emptySidesAreHonestNone") {
                try expectEqual(QuoteGround.verify(quote: "   ", original: "text").verdict,
                                QuoteGround.Verdict.none)
                try expectEqual(QuoteGround.verify(quote: "text", original: "").verdict,
                                QuoteGround.Verdict.none)
            },


            TestDesc(suite: "QuoteMatch", name: "fullSentenceIsHighestLevel") {
                let candidate = "Earlier sample records claim that order is consistent. Other views exist."
                let r = QuoteMatch.classify(quote: "order is consistent", candidate: candidate)
                try expectEqual(r.level, QuoteMatch.Level.fullSentence)
                try expectEqual(r.score, 1.0)
                try expectTrue(r.detail.hasPrefix("整句"))
            },

            TestDesc(suite: "QuoteMatch", name: "halfSentenceWindowAtLeastHalfTokens") {
                // 引句 7 词元，候选连续含前 4 个（4×2=8 ≥ 7 达半句线）；尾部词元全不在。
                let quote = "A sample archive stores fictional records in order"
                let candidate = "A sample archive stores other records elsewhere entirely"
                let r = QuoteMatch.classify(quote: quote, candidate: candidate)
                try expectEqual(r.level, QuoteMatch.Level.halfSentence)
                try expectTrue(r.detail.hasPrefix("半句"))
            },

            TestDesc(suite: "QuoteMatch", name: "phraseWindowBelowHalfLine") {
                // 引句 8 词元，候选只连续含 2 个（≥2 且 < 半句线）→ 词组。
                let quote = "sample records remain distinct in this example archive"
                let candidate = "sample records were sorted elsewhere using different labels"
                let r = QuoteMatch.classify(quote: quote, candidate: candidate)
                try expectEqual(r.level, QuoteMatch.Level.phrase)
                try expectTrue(r.detail.hasPrefix("词组"))
            },

            TestDesc(suite: "QuoteMatch", name: "withinWordScatteredTokenHitsOnly") {
                // 各词元散点出现（无 ≥2 连续窗）→ 词内级，如实标注散点占比。
                let quote = "archive sample order records distinctly"
                let candidate = "records are filed differently; samples keep an archive in order"
                let r = QuoteMatch.classify(quote: quote, candidate: candidate)
                try expectEqual(r.level, QuoteMatch.Level.withinWord)
                try expectTrue(r.detail.hasPrefix("词内"))
            },

            TestDesc(suite: "QuoteMatch", name: "rotatedWindowStillRatesHalfSentence") {
                // 旋转窗 6/8：连续窗达半句线 → 半句级（词元全在但整句不连续，
                // 走不到整句级——分级只认证据）。
                let quote = "alpha beta gamma delta epsilon zeta eta theta"
                let candidate = "eta theta alpha beta gamma delta epsilon zeta"
                let r = QuoteMatch.classify(quote: quote, candidate: candidate)
                try expectEqual(r.level, QuoteMatch.Level.halfSentence)
            },

            TestDesc(suite: "QuoteMatch", name: "cjkQuoteUsesWholeRunContainment") {
                // 中文引句：整串词元含于候选 → 整句级（CJK 保留域，非 Latin 投影）。
                let quote = "记录样例保持清晰顺序"
                let candidate = "档案中的记录样例保持清晰顺序，方便核验。"
                let r = QuoteMatch.classify(quote: quote, candidate: candidate)
                try expectEqual(r.level, QuoteMatch.Level.fullSentence)
            },

            TestDesc(suite: "QuoteMatch", name: "cjkPartialHitDegradesHonestly") {
                let quote = "样例记录保持清晰顺序"
                let candidate = "记录的归档顺序保持清晰。"
                let r = QuoteMatch.classify(quote: quote, candidate: candidate)
                // 只有「行政机关」二字组连续命中 → 词组级如实标注。
                try expectEqual(r.level, QuoteMatch.Level.phrase)
                try expectTrue(r.detail.hasPrefix("词组"))
            },

            TestDesc(suite: "QuoteMatch", name: "noEvidenceReturnsNilLevelHonestly") {
                let r = QuoteMatch.classify(quote: "quantum entanglement paradox", candidate: "完全无关的中文文本")
                try expectNil(r.level)
                try expectNotNil(r.detail)
            },

            TestDesc(suite: "QuoteMatch", name: "levelOrderingAndLabels") {
                try expectTrue(QuoteMatch.Level.fullSentence < QuoteMatch.Level.halfSentence)
                try expectTrue(QuoteMatch.Level.fuzzy > QuoteMatch.Level.withinWord)
                try expectEqual(QuoteMatch.Level.phrase.label, "词组")
                try expectEqual(QuoteMatch.Level.allCases.count, 5)
            },
        ]
    }
}
