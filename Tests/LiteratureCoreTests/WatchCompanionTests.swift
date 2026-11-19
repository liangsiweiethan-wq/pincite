import Foundation
@testable import LiteratureCore

// MARK: - Watch companion suite (all synthetic, zero network)
//
// Covers the companion slice:
//   1. codec roundtrip (full / quote-only / progress-only)
//   2. fail-closed decode (empty data, unknown schema) and encode cap
//   3. empty-payload rejection (init and makeContext)
//   4. contract caps (title/sentence truncation)
//   5. staleness TTL boundary (exactly at TTL not expired; +1s expired)
//   6. applicationContext single-slot merge contract (makeContext —
//      推伴侣不丢摘要、推摘要不丢伴侣，双 nil 拒绝)
//   7. daily-quote cache gates (needsRepick) and push throttle (shouldPush)
//   8. key/date-string pinning (contextKey, dailyQuoteCacheKey)

enum WatchCompanionSuite {
    static let quote = WatchDailyQuote(
        sentence: "凡 OL3-不可外移的规范皆为效力秩序之内核 synthetic。",
        bookTitle: "示例学科纲甲", bookFileName: "book-a.pdf",
        physicalPage: 12, date: "2026-09-29")

    static let progress = WatchReadingProgress(
        bookTitle: "示例学科纲乙", bookFileName: "book-b.pdf",
        page: 7, pageCount: 300,
        updatedAt: Date(timeIntervalSince1970: 1_000_000))

    static func fullPayload(pushedAt: Date = Date(timeIntervalSince1970: 1_000_000)) throws -> WatchCompanionPayload {
        try WatchCompanionPayload(pushedAt: pushedAt, dailyQuote: quote,
                                  progress: progress, truncated: false)
    }

    static var tests: [TestDesc] {
        [
            // 1. codec roundtrip：quote+progress 双有。
            TestDesc(suite: "WatchCompanion", name: "codecRoundtripFullPayload") {
                let original = try fullPayload()
                let decoded = try WatchCompanionCodec.decode(try WatchCompanionCodec.encode(original))
                try expectEqual(decoded, original)
                try expectEqual(decoded.dailyQuote, quote)
                try expectEqual(decoded.progress, progress)
            },

            // 2. 单边载荷各自 roundtrip。
            TestDesc(suite: "WatchCompanion", name: "codecRoundtripSingleSidedPayloads") {
                let quoteOnly = try WatchCompanionPayload(pushedAt: Date(timeIntervalSince1970: 5),
                                                          dailyQuote: quote, progress: nil,
                                                          truncated: false)
                let decodedQuote = try WatchCompanionCodec.decode(try WatchCompanionCodec.encode(quoteOnly))
                try expectEqual(decodedQuote, quoteOnly)
                try expectNil(decodedQuote.progress)

                let progressOnly = try WatchCompanionPayload(pushedAt: Date(timeIntervalSince1970: 6),
                                                             dailyQuote: nil, progress: progress,
                                                             truncated: false)
                let decodedProgress = try WatchCompanionCodec.decode(try WatchCompanionCodec.encode(progressOnly))
                try expectEqual(decodedProgress, progressOnly)
                try expectNil(decodedProgress.dailyQuote)
            },

            // 3. decode 拒 schemaVersion=2。
            TestDesc(suite: "WatchCompanion", name: "decodeRejectsUnknownSchemaVersion") {
                var raw = try JSONSerialization.jsonObject(
                    with: WatchCompanionCodec.encode(try fullPayload())) as! [String: Any]
                raw["schemaVersion"] = 2
                let mutated = try JSONSerialization.data(withJSONObject: raw)
                do {
                    _ = try WatchCompanionCodec.decode(mutated)
                    try failTest("schema v2 必须被拒")
                } catch let error as WatchCompanionError {
                    guard case .unsupportedSchemaVersion(2) = error else {
                        try failTest("应抛 unsupportedSchemaVersion(2)，实际 \(error)")
                    }
                }
            },

            // 4. decode 拒空 Data。
            TestDesc(suite: "WatchCompanion", name: "decodeRejectsEmptyData") {
                do {
                    _ = try WatchCompanionCodec.decode(Data())
                    try failTest("空数据必须被拒")
                } catch let error as WatchCompanionError {
                    guard case .emptyPayload = error else {
                        try failTest("应抛 emptyPayload，实际 \(error)")
                    }
                }
            },

            // 5. encode 超 8KiB 抛 payloadTooLarge（超长句子逼近）。
            TestDesc(suite: "WatchCompanion", name: "encodeRejectsOverCapPayload") {
                let giant = try WatchCompanionPayload(
                    pushedAt: Date(timeIntervalSince1970: 7),
                    dailyQuote: WatchDailyQuote(sentence: String(repeating: "句", count: 9000),
                                                bookTitle: "题", bookFileName: "b.pdf",
                                                physicalPage: 1, date: "2026-09-29"),
                    progress: nil, truncated: false)
                do {
                    _ = try WatchCompanionCodec.encode(giant)
                    try failTest("超 8KiB 载荷必须被拒")
                } catch let error as WatchCompanionError {
                    guard case .payloadTooLarge = error else {
                        try failTest("应抛 payloadTooLarge，实际 \(error)")
                    }
                }
                // 常规小载荷照常编码（上限只拒超限者）。
                _ = try WatchCompanionCodec.encode(try fullPayload())
            },

            // 6. 双 nil（quote、progress 全空）构造被拒。
            TestDesc(suite: "WatchCompanion", name: "initRejectsBothNilPayload") {
                try expectThrows(try WatchCompanionPayload(pushedAt: Date(), dailyQuote: nil,
                                                           progress: nil, truncated: false),
                                 "双 nil 载荷必须拒绝（空推送不覆盖好缓存）")
            },

            // 7. 题目超 80 字符 → truncated=true 且截短后 ≤80（句子/进度题同断）。
            TestDesc(suite: "WatchCompanion", name: "buildTruncatesLongTitles") {
                let longTitle = String(repeating: "题", count: 100)
                let longQuote = WatchDailyQuote(sentence: String(repeating: "句", count: 300),
                                                bookTitle: longTitle, bookFileName: "b.pdf",
                                                physicalPage: 2, date: "2026-09-29")
                let longProgress = WatchReadingProgress(bookTitle: longTitle, bookFileName: "c.pdf",
                                                        page: 3, pageCount: 9,
                                                        updatedAt: Date(timeIntervalSince1970: 8))
                let payload = try WatchCompanion.build(pushedAt: Date(timeIntervalSince1970: 9),
                                                       dailyQuote: longQuote, progress: longProgress)
                try expectTrue(payload.truncated, "超限字段必须置 truncated")
                try expectEqual(payload.dailyQuote?.bookTitle.count, WatchCompanionLimits.maxTitleLength)
                try expectTrue((payload.dailyQuote?.bookTitle.count ?? 0) <= WatchCompanionLimits.maxTitleLength)
                try expectTrue((payload.progress?.bookTitle.count ?? 0) <= WatchCompanionLimits.maxTitleLength)
                try expectEqual(payload.dailyQuote?.sentence.count, WatchCompanionLimits.maxSentenceLength)
            },

            // 8. isExpired 边界：恰等 TTL 未过期（严格 >），超 1 秒过期。
            TestDesc(suite: "WatchCompanion", name: "isExpiredBoundaryAtTTL") {
                let pushedAt = Date(timeIntervalSince1970: 1_000_000)
                let payload = try WatchCompanionPayload(pushedAt: pushedAt, dailyQuote: quote,
                                                        progress: nil, truncated: false)
                let ttl = WatchCompanionLimits.defaultMaxAge
                try expectFalse(payload.isExpired(now: pushedAt.addingTimeInterval(ttl)),
                                "恰等 TTL 未过期")
                try expectTrue(payload.isExpired(now: pushedAt.addingTimeInterval(ttl + 1)),
                               "超 1 秒即过期")
            },

            // 9. makeContext 双键：两键在、值与入参字节恒等。
            TestDesc(suite: "WatchCompanion", name: "makeContextCarriesBothKeys") {
                let summaryBytes = Data("summary-bytes".utf8)
                let companionBytes = Data("companion-bytes".utf8)
                let context = try WatchCompanion.makeContext(
                    summaryKey: "watch-summary-v1", summary: summaryBytes,
                    companionKey: WatchCompanion.contextKey, companion: companionBytes)
                try expectEqual(context.count, 2)
                try expectEqual(context["watch-summary-v1"], summaryBytes)
                try expectEqual(context[WatchCompanion.contextKey], companionBytes)
            },

            // 10. makeContext summary 为 nil：伴侣键保留且无摘要键。
            TestDesc(suite: "WatchCompanion", name: "makeContextKeepsCompanionWhenSummaryNil") {
                let companionBytes = Data("companion-only".utf8)
                let context = try WatchCompanion.makeContext(
                    summaryKey: "watch-summary-v1", summary: nil,
                    companionKey: WatchCompanion.contextKey, companion: companionBytes)
                try expectEqual(context.count, 1)
                try expectNil(context["watch-summary-v1"])
                try expectEqual(context[WatchCompanion.contextKey], companionBytes)
            },

            // 11. makeContext 双 nil：抛错（绝不发空槽覆盖）。
            TestDesc(suite: "WatchCompanion", name: "makeContextRejectsBothNil") {
                try expectThrows(try WatchCompanion.makeContext(
                    summaryKey: "watch-summary-v1", summary: nil,
                    companionKey: WatchCompanion.contextKey, companion: nil),
                    "双 nil 合并必须拒绝")
            },

            // 12. needsRepick：缓存 nil → true；同日期 → false；跨日期 → true。
            TestDesc(suite: "WatchCompanion", name: "needsRepickThreeCases") {
                try expectTrue(WatchCompanion.needsRepick(cachedDate: nil, today: "2026-09-29"))
                try expectFalse(WatchCompanion.needsRepick(cachedDate: "2026-09-29", today: "2026-09-29"))
                try expectTrue(WatchCompanion.needsRepick(cachedDate: "2026-09-28", today: "2026-09-29"))
            },

            TestDesc(suite: "WatchCompanion", name: "shouldPushThrottleBoundary") {
                let now = Date(timeIntervalSince1970: 2_000_000)
                try expectTrue(WatchCompanion.shouldPush(lastPush: nil, now: now))
                try expectFalse(WatchCompanion.shouldPush(
                    lastPush: now.addingTimeInterval(-59), now: now), "59s 内节流")
                try expectTrue(WatchCompanion.shouldPush(
                    lastPush: now.addingTimeInterval(-60), now: now), "满 60s 放行")
            },

            // 14. 键名断言值（防手滑改键导致双端失联）。
            TestDesc(suite: "WatchCompanion", name: "contextKeyPinnedValue") {
                try expectEqual(WatchCompanion.contextKey, "watch-companion-v1")
            },

            // 15. 日期键生成（当日缓存纯函数）：yyyy-MM-dd 格式 + 缓存键前缀。
            TestDesc(suite: "WatchCompanion", name: "dateStringAndDailyQuoteCacheKey") {
                let day = WatchCompanion.dateString(Date(timeIntervalSince1970: 1_789_000_000))
                let parts = day.split(separator: "-")
                try expectEqual(parts.count, 3)
                try expectEqual(parts[0].count, 4)
                try expectEqual(parts[1].count, 2)
                try expectEqual(parts[2].count, 2)
                for part in parts {
                    try expectTrue(part.allSatisfy(\.isNumber), "日期段必须全数字：\(day)")
                }
                try expectEqual(WatchCompanion.dailyQuoteCacheKey(Date(timeIntervalSince1970: 1_789_000_000)),
                                "watch.dailyQuote.\(day)")
            },

            // splitContext：两键独立读取——
            // 伴侣单键 context 绝不因摘要键缺失被整包丢弃（反之亦然）。
            TestDesc(suite: "WatchCompanion", name: "splitContextReadsBothKeysIndependently") {
                let summaryBytes = Data("summary-split".utf8)
                let companionBytes = Data("companion-split".utf8)
                let both = WatchCompanion.splitContext(
                    [WatchCompanion.contextKey: companionBytes,
                     "watch-summary-v1": summaryBytes],
                    summaryKey: "watch-summary-v1",
                    companionKey: WatchCompanion.contextKey)
                try expectEqual(both.summary, summaryBytes)
                try expectEqual(both.companion, companionBytes)
            },

            TestDesc(suite: "WatchCompanion", name: "splitContextKeepsCompanionOnlyContext") {
                // 只带伴侣键的 context 必须独立处理
                // 必须解出伴侣字节、摘要为 nil——接收侧据此独立处理两键。
                let companionBytes = Data("companion-only-split".utf8)
                let split = WatchCompanion.splitContext(
                    [WatchCompanion.contextKey: companionBytes],
                    summaryKey: "watch-summary-v1",
                    companionKey: WatchCompanion.contextKey)
                try expectNil(split.summary)
                try expectEqual(split.companion, companionBytes)
            },

            TestDesc(suite: "WatchCompanion", name: "splitContextKeepsSummaryOnlyAndEmptyContext") {
                let summaryBytes = Data("summary-only-split".utf8)
                let split = WatchCompanion.splitContext(
                    ["watch-summary-v1": summaryBytes],
                    summaryKey: "watch-summary-v1",
                    companionKey: WatchCompanion.contextKey)
                try expectEqual(split.summary, summaryBytes)
                try expectNil(split.companion)
                let empty = WatchCompanion.splitContext(
                    [:], summaryKey: "watch-summary-v1",
                    companionKey: WatchCompanion.contextKey)
                try expectNil(empty.summary)
                try expectNil(empty.companion)
            },
        ]
    }
}
