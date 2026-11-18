import Foundation
@testable import LiteratureCore

// MARK: - Version-group dedup suite
//
// Pins the 版本去重聚合 layer (VersionGroup.swift):
//   1. key normalizer: 异版 hashes, pirated parentheticals, trailing
//      year/edition suffixes all collapse to one key; punctuation/whitespace/
//      case never create separate groups
//   2. genuinely different books never group
//   3. primary pick: max nativeTextPages, tie → shorter fileName, tie →
//      bookID — identical regardless of input order
//   4. group matchingPages = primary's count; the summed-total helper counts
//      each work once (vs a naive all-summaries sum showing double counting)

enum VersionGroupSuite {
    private static func summary(_ fileName: String, bookID: String,
                                matchingPages: Int = 1, pageCount: Int = 100,
                                nativeTextPages: Int = 0) -> SearchService.BookHitSummary {
        SearchService.BookHitSummary(bookID: bookID, fileName: fileName, title: nil,
                                     author: nil, version: nil, language: nil,
                                     pageCount: pageCount, matchingPages: matchingPages,
                                     nativeTextPages: nativeTextPages)
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "VersionGroup", name: "normalizerStripsYiBanHashAndPiratedParentheticals") {
                let a = versionGroupKey(fileName: "样学科_异版a1b2c3d4.pdf")
                let b = versionGroupKey(fileName: "样学科.pdf")
                try expectEqual(a, b, "异版 hash suffix groups with the base name")
            },

            TestDesc(suite: "VersionGroup", name: "normalizerStripsYearAndEditionSuffixes") {
                let a = versionGroupKey(fileName: "示例学科 2001.pdf")
                let b = versionGroupKey(fileName: "示例学科 2002.pdf")
                let c = versionGroupKey(fileName: "示例学科.pdf")
                try expectEqual(a, b, "trailing year never splits a work into groups")
                try expectEqual(a, c)
                let d = versionGroupKey(fileName: "示例学科（第3版）.pdf")
                try expectEqual(d, c, "parenthesized edition suffix stripped")
                let e = versionGroupKey(fileName: "示例学科 修订本.pdf")
                try expectEqual(e, c, "修订本 suffix stripped")
                let f = versionGroupKey(fileName: "示例学科 2001 第3版.pdf")
                try expectEqual(f, c, "year + edition both stripped in sequence")
            },

            TestDesc(suite: "VersionGroup", name: "normalizerDropsPunctuationCaseWhitespace") {
                let a = versionGroupKey(fileName: "The Fictional Order.pdf")
                let b = versionGroupKey(fileName: "the fictional order.PDF")
                try expectEqual(a, b, "case + extension never split groups")
                let c = versionGroupKey(fileName: "Quill - A Sample Treatise.pdf")
                let d = versionGroupKey(fileName: "Quill - A Sample Treatise.pdf")
                try expectEqual(c, d, "punctuation/whitespace never split groups")
            },

            TestDesc(suite: "VersionGroup", name: "differentBooksNeverGroup") {
                let a = versionGroupKey(fileName: "样学科.pdf")
                let b = versionGroupKey(fileName: "样书五.pdf")
                try expectNotEqual(a, b)
                let c = versionGroupKey(fileName: "示例学科原理.pdf")
                try expectNotEqual(a, c, "shared prefix is not identity")
            },

            TestDesc(suite: "VersionGroup", name: "yiBanVariantsAggregateIntoOneGroup") {
                let summaries = [
                    summary("样学科_异版a1b2c3d4.pdf", bookID: "b1", matchingPages: 5),
                    summary("样学科.pdf", bookID: "b2", matchingPages: 9),
                    summary("样学科 2002.pdf", bookID: "b3", matchingPages: 2),
                ]
                let groups = aggregateVersionGroups(summaries)
                try expectEqual(groups.count, 1, "all variants land in ONE group")
                try expectEqual(groups[0].others.count, 2)
                // others sorted by fileName for determinism
                let otherNames = groups[0].others.map(\.fileName)
                try expectEqual(otherNames, otherNames.sorted(), "others sorted by fileName")
            },

            TestDesc(suite: "VersionGroup", name: "primaryPrefersMostNativeTextPages") {
                let low = summary("同书_异版aaaaaa.pdf", bookID: "scan", nativeTextPages: 10)
                let high = summary("同书_异版bbbbbb.pdf", bookID: "text", nativeTextPages: 300)
                let g1 = aggregateVersionGroups([low, high])
                let g2 = aggregateVersionGroups([high, low])
                try expectEqual(g1[0].primary.bookID, "text")
                try expectEqual(g2[0].primary.bookID, "text", "primary pick is input-order independent")
            },

            TestDesc(suite: "VersionGroup", name: "primaryTieBreaksByShorterFileNameThenBookID") {
                // Tie on nativeTextPages: the variant with the shorter fileName wins…
                let long = summary("样书四_异版abcdef12.pdf", bookID: "z1", nativeTextPages: 50)
                let short = summary("样书四.pdf", bookID: "a9", nativeTextPages: 50)
                let g = aggregateVersionGroups([long, short])
                try expectEqual(g[0].primary.bookID, "a9")
                // …and when fileName length ties too, bookID decides (stable order).
                let x = summary("同书_异版aaaaaa.pdf", bookID: "b2", nativeTextPages: 50)
                let y = summary("同书_异版bbbbbb.pdf", bookID: "b1", nativeTextPages: 50)
                try expectEqual(versionGroupKey(fileName: x.fileName),
                                versionGroupKey(fileName: y.fileName),
                                "equal-length 异版 hashes share one key")
                let g2 = aggregateVersionGroups([x, y])
                try expectEqual(g2[0].primary.bookID, "b1")
                let g3 = aggregateVersionGroups([y, x])
                try expectEqual(g3[0].primary.bookID, "b1", "bookID tiebreak is input-order independent")
            },

            TestDesc(suite: "VersionGroup", name: "groupCountsOnlyPrimaryPages") {
                let summaries = [
                    summary("样学科.pdf", bookID: "b1", matchingPages: 9, nativeTextPages: 100),
                    summary("样学科_异版a1b2c3d4.pdf", bookID: "b2", matchingPages: 5, nativeTextPages: 20),
                    summary("样书五.pdf", bookID: "b3", matchingPages: 7, nativeTextPages: 80),
                ]
                let groups = aggregateVersionGroups(summaries)
                try expectEqual(groups.count, 2)
                let civil = groups.first { $0.groupKey == versionGroupKey(fileName: "样学科.pdf") }
                let criminal = groups.first { $0.groupKey == versionGroupKey(fileName: "样书五.pdf") }
                let civilGroup = try expectNotNil(civil)
                try expectEqual(civilGroup.matchingPages, 9, "group total = PRIMARY's count only")
                // Grouped total counts each work once; the naive sum double counts
                // the duplicated work (9+5) — the gap IS the dedup.
                let groupedTotal = totalMatchingPagesAcrossGroups(groups)
                try expectEqual(groupedTotal, 9 + 7)
                let naiveTotal = summaries.reduce(0) { $0 + $1.matchingPages }
                try expectEqual(naiveTotal, 9 + 5 + 7)
                try expectTrue(naiveTotal > groupedTotal, "naive sum double-counts the duplicated work")
                try expectEqual(criminal?.matchingPages, 7)
            },

            TestDesc(suite: "VersionGroup", name: "groupOrderFollowsFirstAppearance") {
                let summaries = [
                    summary("甲书.pdf", bookID: "b1"),
                    summary("乙书.pdf", bookID: "b2"),
                    summary("甲书 2019.pdf", bookID: "b3"),
                ]
                let groups = aggregateVersionGroups(summaries)
                try expectEqual(groups.map(\.groupKey), [
                    versionGroupKey(fileName: "甲书.pdf"),
                    versionGroupKey(fileName: "乙书.pdf"),
                ], "groups keep first-appearance order")
            },
        ]
    }
}
