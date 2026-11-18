import Foundation
@testable import LiteratureCore

// MARK: - RCS 逐块评分摘要合成套件

enum RCSContextBuilderSuite {
    /// 可编程评分 stub：按问题里的块序号回复对应 verdict JSON。
    final class ScriptedTransport: AITransport, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(URL, AIRequestPayload)] = []
        /// 每次调用的回复（循环取用）；特殊标记 `@@CANCEL` 在第 N 次调用前取消。
        let replies: [String]
        /// 非 nil 时：第 cancelAtCall 次调用入口处先取消令牌再检查。
        let cancelAtCall: Int?
        let token: AICancellationToken?

        init(replies: [String], cancelAtCall: Int? = nil,
             token: AICancellationToken? = nil) {
            self.replies = replies
            self.cancelAtCall = cancelAtCall
            self.token = token
        }

        var callCount: Int {
            lock.lock(); defer { lock.unlock() }
            return calls.count
        }

        var payloads: [AIRequestPayload] {
            lock.lock(); defer { lock.unlock() }
            return calls.map(\.1)
        }

        func send(_ endpoint: URL, payload: AIRequestPayload, apiKey: String?,
                  cancellation: AICancellationToken?) async throws -> String {
            let index: Int = {
                lock.lock(); defer { lock.unlock() }
                calls.append((endpoint, payload))
                return calls.count
            }()
            try cancellation?.check()
            if let cancelAtCall, let token, index == cancelAtCall {
                token.cancel()
                try cancellation?.check()
            }
            return replies[(index - 1) % replies.count]
        }
    }

    static func selection(_ id: String, page: Int, snippet: String = "证据内容") -> AIPreview.Selection {
        AIPreview.Selection(bookID: id, fingerprint: "fp-\(id)", physicalPage: page, snippet: snippet)
    }

    static func verdictJSON(summary: String, score: Int) -> String {
        "{\"summary\": \"\(summary)\", \"relevance_score\": \(score)}"
    }

    static let highVerdict = verdictJSON(summary: "高相关摘要", score: 9)
    static let lowVerdict = verdictJSON(summary: "低相关摘要", score: 3)
    /// 综合 leg 的回复（parseResponse 严格形状）。
    static let answerReply = #"{"answer": "综合回答文本", "references": [{"bookId": "b1", "page": 1}]}"#

    static var tests: [TestDesc] {
        [

            TestDesc(suite: "RCSContext", name: "plannerRejectsSeventeenAcceptsSixteen") {
                let seventeen = (1...17).map { selection("b\($0)", page: $0) }
                try expectThrows(try RCSContextBuilder.makePlan(question: "q", selections: seventeen),
                                 "17 块必须拒绝（上限=synthesisPassageLimit）")
                let sixteen = (1...16).map { selection("b\($0)", page: $0) }
                let plan = try RCSContextBuilder.makePlan(question: "q", selections: sixteen)
                try expectEqual(plan.blocks.count, 16, "16 块应收下")
            },

            TestDesc(suite: "RCSContext", name: "plannerTruncatesSnippetAtCharLimit") {
                let long = String(repeating: "字", count: RCSContextBuilder.rcsBlockCharLimit + 100)
                let plan = try RCSContextBuilder.makePlan(question: "q",
                                                          selections: [selection("b1", page: 1, snippet: long)])
                try expectEqual(plan.blocks.first?.snippet.count, RCSContextBuilder.rcsBlockCharLimit)
                try expectEqual(RCSContextBuilder.rcsBlockCharLimit, 1200)
            },

            TestDesc(suite: "RCSContext", name: "plannerRejectsEmptySelections") {
                try expectThrows(try RCSContextBuilder.makePlan(question: "q", selections: []),
                                 "空证据必须拒绝")
            },

            TestDesc(suite: "RCSContext", name: "plannerPageLabelKnownAndUnknownTwoStates") {
                let plan = try RCSContextBuilder.makePlan(
                    question: "q",
                    selections: [selection("b1", page: 3), selection("b2", page: 7)],
                    pageLabel: { bookID, _ in bookID == "b1" ? "印刷页 12" : nil })
                try expectEqual(plan.blocks[0].pageLabelText, "印刷页 12")
                try expectEqual(plan.blocks[0].anchorText, "印刷页 12")
                try expectNil(plan.blocks[1].pageLabelText)
                try expectEqual(plan.blocks[1].anchorText, "页码未知", "未知显式「页码未知」，绝不猜")
            },


            TestDesc(suite: "RCSContext", name: "verdictParsesNormalShape") {
                let verdict = RCSContextBuilder.parseVerdict(
                    "前置说明 {\"summary\": \"相关内容摘要\", \"relevance_score\": 8} 后缀")
                try expectEqual(verdict?.summary, "相关内容摘要", "宽松定位首个 JSON")
                try expectEqual(verdict?.relevanceScore, 8)
            },

            TestDesc(suite: "RCSContext", name: "verdictEmptySummaryZeroScoreIsLegalExit") {
                // 「不相关＝空摘要＋0 分」正路出局（PaperQA2 契约语义）。
                let verdict = RCSContextBuilder.parseVerdict(
                    #"{"summary": "", "relevance_score": 0}"#)
                try expectEqual(verdict?.summary, "")
                try expectEqual(verdict?.relevanceScore, 0)
            },

            TestDesc(suite: "RCSContext", name: "verdictMalformedJSONReturnsNil") {
                try expectNil(RCSContextBuilder.parseVerdict("完全不是 JSON"))
                try expectNil(RCSContextBuilder.parseVerdict(#"{"summary": "缺分数"}"#))
                try expectNil(RCSContextBuilder.parseVerdict(#"{"relevance_score": 5}"#))
                try expectNil(RCSContextBuilder.parseVerdict(
                    #"{"summary": 123, "relevance_score": 5}"#), "summary 必须是字符串")
            },

            TestDesc(suite: "RCSContext", name: "verdictClampsOutOfRangeScores") {
                try expectEqual(RCSContextBuilder.parseVerdict(
                    #"{"summary": "s", "relevance_score": 12}"#)?.relevanceScore, 10)
                try expectEqual(RCSContextBuilder.parseVerdict(
                    #"{"summary": "s", "relevance_score": -3}"#)?.relevanceScore, 0)
                try expectEqual(RCSContextBuilder.parseVerdict(
                    #"{"summary": "s", "relevance_score": "7"}"#)?.relevanceScore, 7,
                    "字符串数字宽容解析")
            },


            TestDesc(suite: "RCSContext", name: "thresholdBoundarySevenInSixOut") {
                try expectEqual(RCSContextBuilder.rcsMinRelevanceScore, 7, "阈值常数集中一处")
                let selections = [selection("b1", page: 1), selection("b2", page: 2)]
                let transport = ScriptedTransport(replies: [verdictJSON(summary: "入", score: 7),
                                                            verdictJSON(summary: "出", score: 6),
                                                            answerReply])
                let ledger = AICallLedger()
                let plan = RCSPlan(previewID: UUID(), question: "q", blocks: try RCSContextBuilder.makePlan(
                    question: "q", selections: selections).blocks)
                let outcome = try await RCSPipeline.run(plan: plan,
                                                        configuration: AIConfiguration(
                                                            serviceURL: URL(string: "https://api.example.com/v1")!,
                                                            model: "m"),
                                                        confirmation: AIConfirmation(explicit: true,
                                                                                     previewID: plan.previewID),
                                                        transport: transport, cancellation: nil, ledger: ledger)
                try expectEqual(outcome.results[0].survived, true, "评分 7 必须入围")
                try expectEqual(outcome.results[1].survived, false, "评分 6 必须出局")
                try expectEqual(transport.callCount, 3, "2 块评分＋1 次综合")
                let answer = try expectNotNil(outcome.answer)
                try expectTrue(!answer.answerText.isEmpty)
            },


            TestDesc(suite: "RCSContext", name: "finalPayloadKeepsProvenanceAndAnchorHead") {
                let plan = try RCSContextBuilder.makePlan(
                    question: "原问题？",
                    selections: [selection("b1", page: 5, snippet: "片段")],
                    pageLabel: { _, _ in nil })
                let block = plan.blocks[0]
                try expectEqual(block.anchorText, "页码未知")
                let results = [RCSContextBuilder.BlockResult.survived(
                    block, RCSContextBuilder.RCSVerdict(summary: "压缩摘要", relevanceScore: 9))]
                let payload = try expectNotNil(RCSContextBuilder.assembleFinalPayload(
                    plan: plan, results: results, model: "m"))
                let surviving = try expectNotNil(payload.selections)
                try expectEqual(surviving.count, 1)
                try expectTrue(surviving[0].snippet.contains("页码: 页码未知"),
                               "锚头缺失显式「页码未知」")
                try expectTrue(surviving[0].snippet.contains("压缩摘要"))
                try expectEqual(surviving[0].bookId, "b1", "出处 provenance 原样保留")
                try expectEqual(surviving[0].page, 5)
                try expectEqual(payload.citationNote, AIAssistantService.synthesisCitationNote,
                                "引用契约沿用既有")
                try expectEqual(payload.question, "原问题？", "最终问题=用户原问题")
            },

            TestDesc(suite: "RCSContext", name: "allFilteredOutSkipsFinalRequest") {
                let plan = RCSPlan(previewID: UUID(), question: "q", blocks: try RCSContextBuilder.makePlan(
                    question: "q", selections: [selection("b1", page: 1)]).blocks)
                let transport = ScriptedTransport(replies: [lowVerdict])
                let outcome = try await RCSPipeline.run(
                    plan: plan,
                    configuration: AIConfiguration(serviceURL: URL(string: "https://api.example.com/v1")!, model: "m"),
                    confirmation: AIConfirmation(explicit: true, previewID: plan.previewID),
                    transport: transport, cancellation: nil, ledger: AICallLedger())
                try expectNil(outcome.answer, "全部出局不得发送空证据综合请求")
                try expectEqual(transport.callCount, 1, "只有评分 leg，无综合 leg")
            },


            TestDesc(suite: "RCSContext", name: "runnerGateNilConfirmationZeroCalls") {
                let plan = RCSPlan(previewID: UUID(), question: "q", blocks: try RCSContextBuilder.makePlan(
                    question: "q", selections: [selection("b1", page: 1)]).blocks)
                let transport = ScriptedTransport(replies: [highVerdict])
                try await expectThrowsAsync({
                    try await RCSPipeline.run(plan: plan,
                                              configuration: AIConfiguration(
                                                  serviceURL: URL(string: "https://api.example.com/v1")!, model: "m"),
                                              confirmation: nil, transport: transport,
                                              cancellation: nil, ledger: AICallLedger())
                })
                try expectEqual(transport.callCount, 0, "零确认＝零 transport 调用")
            },

            TestDesc(suite: "RCSContext", name: "runnerGateExplicitFalseZeroCalls") {
                let plan = RCSPlan(previewID: UUID(), question: "q", blocks: try RCSContextBuilder.makePlan(
                    question: "q", selections: [selection("b1", page: 1)]).blocks)
                let transport = ScriptedTransport(replies: [highVerdict])
                // AIConfirmation(explicit: false) 构造即 nil（failable init）。
                let confirmation = AIConfirmation(explicit: false, previewID: plan.previewID)
                try expectNil(confirmation, "explicit=false 不可构造")
                try await expectThrowsAsync({
                    try await RCSPipeline.run(plan: plan,
                                              configuration: AIConfiguration(
                                                  serviceURL: URL(string: "https://api.example.com/v1")!, model: "m"),
                                              confirmation: nil, transport: transport,
                                              cancellation: nil, ledger: AICallLedger())
                })
                try expectEqual(transport.callCount, 0)
            },

            TestDesc(suite: "RCSContext", name: "runnerGateMismatchedPreviewIDZeroCalls") {
                let plan = RCSPlan(previewID: UUID(), question: "q", blocks: try RCSContextBuilder.makePlan(
                    question: "q", selections: [selection("b1", page: 1)]).blocks)
                let transport = ScriptedTransport(replies: [highVerdict])
                let wrongBinding = AIConfirmation(explicit: true, previewID: UUID())
                try await expectThrowsAsync({
                    try await RCSPipeline.run(plan: plan,
                                              configuration: AIConfiguration(
                                                  serviceURL: URL(string: "https://api.example.com/v1")!, model: "m"),
                                              confirmation: wrongBinding, transport: transport,
                                              cancellation: nil, ledger: AICallLedger())
                }, "绑错预览必须 confirmationMismatch")
                try expectEqual(transport.callCount, 0, "绑错＝零 transport 调用")
            },


            TestDesc(suite: "RCSContext", name: "cancellationMidRunStopsSubsequentBlocks") {
                let selections = (1...3).map { selection("b\($0)", page: $0) }
                let plan = RCSPlan(previewID: UUID(), question: "q",
                                   blocks: try RCSContextBuilder.makePlan(question: "q", selections: selections).blocks)
                let token = AICancellationToken()
                // 第 2 次调用（块 2）入口处取消：块 3 不得再发。
                let transport = ScriptedTransport(
                    replies: [highVerdict, highVerdict, highVerdict],
                    cancelAtCall: 2, token: token)
                let ledger = AICallLedger()
                try await expectThrowsAsync({
                    try await RCSPipeline.run(plan: plan,
                                              configuration: AIConfiguration(
                                                  serviceURL: URL(string: "https://api.example.com/v1")!, model: "m"),
                                              confirmation: AIConfirmation(explicit: true, previewID: plan.previewID),
                                              transport: transport, cancellation: token, ledger: ledger)
                })
                try expectEqual(transport.callCount, 2, "取消后后续块零调用")
                let failed = ledger.entries.filter { !$0.ok }
                try expectEqual(failed.count, 1, "取消 leg 如实记账")
            },


            TestDesc(suite: "RCSContext", name: "ledgerCountsEveryLegAndSummarizes") {
                let ledger = AICallLedger()
                ledger.record(name: "评分 块1", requestBytes: 100, ok: true)
                ledger.record(name: "评分 块2", requestBytes: 200, ok: true)
                ledger.record(name: "综合", requestBytes: 300, ok: true)
                try expectEqual(ledger.totalCount, 3)
                try expectEqual(ledger.okCount, 3)
                try expectEqual(ledger.failedCount, 0)
                try expectEqual(ledger.totalRequestBytes, 600)
                try expectTrue(ledger.summaryText.contains("3 次请求"))
                try expectTrue(ledger.summaryText.contains("600 字节"))
                ledger.record(name: "评分 块3", requestBytes: 50, ok: false)
                try expectEqual(ledger.failedCount, 1)
                try expectTrue(ledger.summaryText.contains("失败 1"))
            },


            TestDesc(suite: "RCSContext", name: "finalPayloadEncodesThroughExistingAdapterShape") {
                let plan = try RCSContextBuilder.makePlan(
                    question: "q", selections: [selection("b1", page: 2, snippet: "片段一")])
                let results = [RCSContextBuilder.BlockResult.survived(
                    plan.blocks[0], RCSContextBuilder.RCSVerdict(summary: "摘要甲", relevanceScore: 8))]
                let payload = try expectNotNil(RCSContextBuilder.assembleFinalPayload(
                    plan: plan, results: results, model: "m1"))
                // 复用既有 encode 零改动：可编码＝形状兼容；证据行含锚头+摘要。
                let data = try OpenAIChatCompletionsAdapter.encode(payload)
                let text = String(data: data, encoding: .utf8) ?? ""
                try expectTrue(text.contains("bookId=b1"), "encode 证据行保留 bookId")
                try expectTrue(text.contains("page=2"), "encode 证据行保留 page")
                try expectTrue(text.contains("摘要甲"), "encode 载入存活块摘要")
                // 回读：answerJSON 走同一形状。
                let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                try expectEqual(body?["model"] as? String, "m1")
            },


            TestDesc(suite: "RCSContext", name: "parseFailureBlockExitsWithCount") {
                let plan = RCSPlan(previewID: UUID(), question: "q", blocks: try RCSContextBuilder.makePlan(
                    question: "q",
                    selections: [selection("b1", page: 1), selection("b2", page: 2)]).blocks)
                let transport = ScriptedTransport(replies: ["瞎写的", highVerdict, answerReply])
                let outcome = try await RCSPipeline.run(
                    plan: plan,
                    configuration: AIConfiguration(serviceURL: URL(string: "https://api.example.com/v1")!, model: "m"),
                    confirmation: AIConfirmation(explicit: true, previewID: plan.previewID),
                    transport: transport, cancellation: nil, ledger: AICallLedger())
                try expectEqual(outcome.parseFailureCount, 1, "畸形响应按 0 分出局＋计数")
                try expectEqual(outcome.results[0].survived, false)
                try expectTrue(outcome.results[0].failureReason?.contains("解析失败") == true)
                try expectEqual(outcome.results[1].survived, true)
            },
        ]
    }
}
