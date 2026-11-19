import Foundation
@testable import LiteratureCore

// MARK: - 综述自检反馈循环合成套件

enum ReviewSelfCheckSuite {
    /// 可编程回复 stub（按调用序回复；支持第 N 次调用入口取消）。
    final class ScriptedTransport: AITransport, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [AIRequestPayload] = []
        let replies: [String]
        let cancelAtCall: Int?
        let token: AICancellationToken?

        init(replies: [String], cancelAtCall: Int? = nil, token: AICancellationToken? = nil) {
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
            return calls
        }

        func send(_ endpoint: URL, payload: AIRequestPayload, apiKey: String?,
                  cancellation: AICancellationToken?) async throws -> String {
            let index: Int = {
                lock.lock(); defer { lock.unlock() }
                calls.append(payload)
                return calls.count
            }()
            try cancellation?.check()
            if let cancelAtCall, let token, index == cancelAtCall {
                token.cancel()
                try cancellation?.check()
            }
            return replies[min(index - 1, replies.count - 1)]
        }
    }

    static func hit(_ bookID: String, page: Int, snippet: String) -> SearchHit {
        SearchHit(bookID: bookID, filePath: "/tmp/\(bookID).pdf", fileName: "\(bookID).pdf",
                  fingerprint: "fp-\(bookID)", physicalPage: page, pageLabel: nil,
                  printedPage: nil, pageCount: 30, title: nil, author: nil, version: nil,
                  language: nil, matches: [], snippet: snippet)
    }

    static let configuration = AIConfiguration(serviceURL: URL(string: "https://api.example.com/v1")!,
                                               model: "m")
    static let draft = String(repeating: "论", count: 200)
    static let evidence = [AIRequestPayload.SelectionPayload(
        bookId: "b1", fingerprint: "fp-b1", page: 3, snippet: "证据片段")]

    static func run(_ transport: AITransport,
                    confirmation: AIConfirmation?,
                    retrieve: @escaping @Sendable (String) async -> [SearchHit] = { _ in [] },
                    verify: @escaping @Sendable (SearchHit) -> Bool = { _ in true },
                    cancellation: AICancellationToken? = nil,
                    ledger: AICallLedger = AICallLedger(),
                    draftText: String = draft) async throws -> ReviewSelfCheckOutcome {
        try await ReviewSelfCheckRunner.run(
            draft: draftText, planPreviewID: PreviewIDs.review,
            configuration: configuration, confirmation: confirmation,
            transport: transport, cancellation: cancellation, ledger: ledger,
            evidence: evidence, retrieve: retrieve, verify: verify)
    }

    /// 固定预览 ID（确认门绑定目标）。
    enum PreviewIDs {
        static let review = UUID()
    }

    static var tests: [TestDesc] {
        [

            TestDesc(suite: "ReviewSelfCheck", name: "checkPromptCarriesDraftEvidenceAndCitationContract") {
                let prompt = ReviewSelfCheck.checkPrompt(draft: "草稿正文", evidence: ["bookId=b1, page=3：证据一"])
                try expectTrue(prompt.contains("草稿正文"), "含草稿")
                try expectTrue(prompt.contains("bookId=b1, page=3"), "含证据清单")
                try expectTrue(prompt.contains("citations"), "引用号契约")
                try expectTrue(prompt.contains("supported"), "逐断言判定字段")
                try expectTrue(prompt.contains("search_query"), "检索问句契约（缺证回检索）")
            },

            TestDesc(suite: "ReviewSelfCheck", name: "verdictsParseNormalShape") {
                let raw = #"[{"id": "a1", "supported": true, "citations": [1, 2]}, {"id": "a2", "supported": false, "citations": [], "search_query": "方法 缺点"}]"#
                let verdicts = try expectNotNil(ReviewSelfCheck.parseVerdicts(raw))
                try expectEqual(verdicts.count, 2)
                try expectEqual(verdicts[0].citations, [1, 2])
                try expectEqual(verdicts[1].searchQuery, "方法 缺点")
                try expectNil(verdicts[0].searchQuery)
            },

            TestDesc(suite: "ReviewSelfCheck", name: "verdictsMalformedReturnsNilConservativeKeep") {
                try expectNil(ReviewSelfCheck.parseVerdicts("不是 JSON"))
                try expectNil(ReviewSelfCheck.parseVerdicts(#"{"id": "a1"}"#), "必须为数组")
                try expectNil(ReviewSelfCheck.parseVerdicts("[]"), "空数组按解析失败保守保留")
            },


            TestDesc(suite: "ReviewSelfCheck", name: "collapseGateBoundary") {
                try expectEqual(ReviewSelfCheck.collapseThreshold, 0.9, "常数集中一处")
                let original = String(repeating: "字", count: 100)
                let exact90 = String(repeating: "字", count: 90)
                let below89 = String(repeating: "字", count: 89)
                let equal = original
                let grown = original + "增"
                try expectTrue(ReviewSelfCheck.collapseGate(original: original, revised: exact90),
                               "=90% 收")
                try expectFalse(ReviewSelfCheck.collapseGate(original: original, revised: below89),
                                "<90% 拒")
                try expectTrue(ReviewSelfCheck.collapseGate(original: original, revised: equal),
                               "等长收")
                try expectTrue(ReviewSelfCheck.collapseGate(original: original, revised: grown),
                               "增长收")
            },


            TestDesc(suite: "ReviewSelfCheck", name: "allSupportedSkipsRevisionLeg") {
                let check = #"[{"id": "a1", "supported": true, "citations": [1]}]"#
                let transport = ScriptedTransport(replies: [check])
                let outcome = try await run(transport, confirmation: AIConfirmation(
                    explicit: true, previewID: PreviewIDs.review))
                try expectEqual(transport.callCount, 1, "全有支撑＝只有检查 leg")
                try expectEqual(outcome.finalDraft, draft, "草稿原样保留")
                try expectEqual(outcome.rounds.count, 1)
                try expectFalse(outcome.rounds[0].revised)
                try expectTrue(outcome.rounds[0].note?.contains("有支撑") == true)
            },


            TestDesc(suite: "ReviewSelfCheck", name: "UnsupportedWithoutQueryTriggersDeleteInstruction") {
                // 删除指令只收可定位断言——verdict 携带原文
                // （draft=「论」×200，原文取其子串保证可定位）。
                let check = #"[{"id": "a3", "supported": false, "citations": [], "text": "论论论论论"}]"#
                let revised = String(repeating: "改", count: 200)
                let transport = ScriptedTransport(replies: [check, revised])
                let outcome = try await run(transport, confirmation: AIConfirmation(
                    explicit: true, previewID: PreviewIDs.review))
                try expectEqual(transport.callCount, 3, "检查＋改写（r1，无补块 leg）＋r2 检查腿（改写稿非数组→保守收束）")
                let revisePayload = transport.payloads[1].question
                try expectTrue(revisePayload.contains("a3"), "改写指令点名删除的断言")
                try expectTrue(revisePayload.contains("[a3] 原文：论论论论论"), "带原文可定位")
                try expectTrue(revisePayload.contains("删除"), "删句纪律")
                try expectTrue(revisePayload.contains("本请求的唯一合法输出"), "leg 契约优先级声明")
                try expectEqual(outcome.finalDraft, revised)
                try expectTrue(outcome.rounds[0].revised && outcome.rounds[0].revisionAccepted)
                try expectEqual(outcome.rounds[0].retrievedQueries.count, 0)
            },


            TestDesc(suite: "ReviewSelfCheck", name: "unsupportedWithQueryRetrievesAndScoresViaRCS") {
                let check = #"[{"id": "a2", "supported": false, "citations": [], "search_query": "概念地图 方法"}]"#
                let revised = String(repeating: "补", count: 210)
                //补块评分走 契约（blockPrompt＋parseVerdict＋阈值）。
                let transport = ScriptedTransport(replies: [
                    check,
                    #"{"summary": "补充摘要内容", "relevance_score": 8}"#,   // 补引评分
                    revised,
                ])
                final class QueryBox: @unchecked Sendable {
                    private let lock = NSLock()
                    private var value: String?
                    func set(_ v: String) { lock.withLock { value = v } }
                    func get() -> String? { lock.withLock { value } }
                }
                let retrievedQuery = QueryBox()
                let outcome = try await run(transport, confirmation: AIConfirmation(
                    explicit: true, previewID: PreviewIDs.review),
                    retrieve: { query in
                        retrievedQuery.set(query)
                        return [hit("b9", page: 4, snippet: "补充证据片段")]
                    })
                try expectEqual(retrievedQuery.get(), "概念地图 方法", "检索问句来自模型 verdict")
                try expectEqual(transport.callCount, 4, "r1 检查＋补块评分＋改写，＋r2 检查腿")
                try expectTrue(transport.payloads[1].question.contains("概念地图 方法"),
                               "补块评分问句=模型检索问句（非常量串）")
                try expectTrue(transport.payloads[2].question.contains("补充摘要内容"),
                               "存活块摘要进改写 prompt")
                try expectTrue(transport.payloads[2].question.contains("b9"),
                               "补块带出处")
                try expectEqual(outcome.rounds[0].supplementedBlocks, 1)
                try expectEqual(outcome.rounds[0].retrievedQueries.count, 1)
            },

            TestDesc(suite: "ReviewSelfCheck", name: "supplementBlockBelowThresholdNotInjected") {
                // (c) 夹具适配：补一枚可定位无问句断言撑起改写 leg
                // （否则空处置集短路，本断言面无从观察）。
                let check = #"[{"id": "a2", "supported": false, "citations": [], "search_query": "某 检索"}, {"id": "a3", "supported": false, "citations": [], "text": "论论论论论"}]"#
                let revised = String(repeating: "改", count: 200)
                let transport = ScriptedTransport(replies: [
                    check,
                    #"{"summary": "低分补充", "relevance_score": 5}"#,   // 低于阈值 7 → 出局
                    revised,
                ])
                let outcome = try await run(transport, confirmation: AIConfirmation(
                    explicit: true, previewID: PreviewIDs.review),
                    retrieve: { _ in [hit("b9", page: 4, snippet: "补充")] })
                try expectTrue(transport.payloads[2].question.contains("b9") == false,
                               "低分补块不进改写证据")
                try expectEqual(outcome.rounds[0].supplementedBlocks, 0)
            },


            TestDesc(suite: "ReviewSelfCheck", name: "parseFailureKeepsAllConservativelyAndStops") {
                let transport = ScriptedTransport(replies: ["模型胡言乱语"])
                let outcome = try await run(transport, confirmation: AIConfirmation(
                    explicit: true, previewID: PreviewIDs.review))
                try expectEqual(transport.callCount, 1, "解析失败不进入改写（宁可漏删不可误删）")
                try expectEqual(outcome.finalDraft, draft)
                try expectTrue(outcome.rounds[0].parseFailed)
                try expectNil(outcome.rounds[0].verdicts)
                try expectTrue(outcome.rounds[0].note?.contains("保守保留") == true)
            },


            TestDesc(suite: "ReviewSelfCheck", name: "collapseGateRejectsShrunkenRevisionKeepsPreviousDraft") {
                let check = #"[{"id": "a1", "supported": false, "citations": [], "text": "论论论论论"}]"#
                let shrunk = String(repeating: "缩", count: 100)   // 200 字的 50% → 拒收
                let transport = ScriptedTransport(replies: [check, shrunk])
                let outcome = try await run(transport, confirmation: AIConfirmation(
                    explicit: true, previewID: PreviewIDs.review))
                try expectEqual(outcome.finalDraft, draft, "拒收后保留上轮稿")
                try expectFalse(outcome.rounds[0].revisionAccepted)
                try expectTrue(outcome.rounds[0].note?.contains("拒收") == true)
            },


            TestDesc(suite: "ReviewSelfCheck", name: "emptyDispositionsSkipRewriteLeg") {
                // 无支撑断言仅不可定位（无删句、无检索问句→无补块）＝空处置集：
                // 不再发「无修改改写」leg（原状多发一次纯空转请求）；记轮收束。
                let check = #"[{"id": "a1", "supported": false, "citations": [], "text": "这句并不在草稿里"}]"#
                let transport = ScriptedTransport(replies: [check])
                let outcome = try await run(transport, confirmation: AIConfirmation(
                    explicit: true, previewID: PreviewIDs.review))
                try expectEqual(transport.callCount, 1, "空处置集＝只有检查 leg，零改写调用")
                try expectEqual(outcome.finalDraft, draft, "草稿原样保留")
                try expectEqual(outcome.rounds.count, 1, "草稿未动后续轮无可为，记轮收束")
                try expectFalse(outcome.rounds[0].revised)
                try expectFalse(outcome.rounds[0].revisionAccepted)
                try expectTrue(outcome.rounds[0].note?.contains("跳过改写") == true)
            },


            TestDesc(suite: "ReviewSelfCheck", name: "rejectionWithUnlocatableKeepsUnifiedClause") {
                // 拒收路径（原无测试）：可定位断言撑起改写＋缩水拒收，note 的
                // 不可定位子句与接受分支同文案（原拒收分支缺「而…（未删）」尾）。
                let check = #"[{"id": "a1", "supported": false, "citations": [], "text": "论论论论论"}, {"id": "a2", "supported": false, "citations": [], "text": "这句并不在草稿里"}]"#
                let shrunk = String(repeating: "缩", count: 100)   // 200 字的 50% → 拒收
                let transport = ScriptedTransport(replies: [check, shrunk])
                let outcome = try await run(transport, confirmation: AIConfirmation(
                    explicit: true, previewID: PreviewIDs.review))
                try expectFalse(outcome.rounds[0].revisionAccepted)
                let note = try expectNotNil(outcome.rounds[0].note)
                try expectTrue(note.contains("拒收"), "拒收语义在案")
                try expectTrue(note.contains("另 1 条无支撑断言因原文不可定位而保守保留（未删）"),
                               "拒收分支携带与接受分支统一的不可定位子句")
            },

            TestDesc(suite: "ReviewSelfCheck", name: "antiCollapseNoteClauseIdenticalAcrossBranches") {
                let clause = "1 条无支撑断言因原文不可定位而保守保留（未删）"
                func fixtureNote(revised: String) async throws -> String {
                    let check = #"[{"id": "a1", "supported": false, "citations": [], "text": "论论论论论"}, {"id": "a2", "supported": false, "citations": [], "text": "这句并不在草稿里"}]"#
                    let transport = ScriptedTransport(replies: [check, revised])
                    let outcome = try await run(transport, confirmation: AIConfirmation(
                        explicit: true, previewID: PreviewIDs.review))
                    return try expectNotNil(outcome.rounds[0].note)
                }
                let acceptedNote = try await fixtureNote(revised: String(repeating: "改", count: 200))
                let rejectedNote = try await fixtureNote(revised: String(repeating: "缩", count: 100))
                try expectTrue(acceptedNote.contains(clause), "接受分支子句")
                try expectTrue(rejectedNote.contains(clause), "拒收分支子句同文案")
            },


            TestDesc(suite: "ReviewSelfCheck", name: "roundsCappedAtConstant") {
                try expectEqual(ReviewSelfCheck.reviewSelfCheckMaxRounds, 2, "轮数上限常数集中一处")
                // 每轮都有可执行处置：r1 检查+补块+改写；r2 检查+补块（评分复读
                // 败出局）+改写（删句腿撑起—— (c) 空处置集已短路）。
                let check = #"[{"id": "a1", "supported": false, "citations": [], "search_query": "q1"}, {"id": "a3", "supported": false, "citations": [], "text": "论论论论论"}]"#
                // 改写稿保留 a3 原文（r2 可继续定位删除；长度 200 过防坍缩门）。
                let revised1 = String(repeating: "一", count: 196) + "论论论论论"
                let revised2 = String(repeating: "二", count: 200)
                let transport = ScriptedTransport(replies: [
                    check,
                    #"{"summary": "补充", "relevance_score": 9}"#,
                    revised1,
                    check,
                    revised2,
                ])
                let outcome = try await run(transport, confirmation: AIConfirmation(
                    explicit: true, previewID: PreviewIDs.review),
                    retrieve: { _ in [hit("b8", page: 2, snippet: "块")] })
                try expectEqual(outcome.rounds.count, ReviewSelfCheck.reviewSelfCheckMaxRounds,
                                "轮数上限截断")
                try expectEqual(outcome.finalDraft, revised2)
                try expectEqual(transport.callCount, 6, "r1 检查+补块+改写；r2 检查+补块+改写")
            },


            TestDesc(suite: "ReviewSelfCheck", name: "runnerGateNilAndMismatchZeroCalls") {
                let check = #"[{"id": "a1", "supported": true, "citations": [1]}]"#
                let transport = ScriptedTransport(replies: [check])
                try await expectThrowsAsync({
                    try await run(transport, confirmation: nil)
                })
                try expectEqual(transport.callCount, 0, "零确认＝零 transport 调用")
                let wrong = AIConfirmation(explicit: true, previewID: UUID())
                try await expectThrowsAsync({
                    try await run(transport, confirmation: wrong)
                }, "绑错预览必须 confirmationMismatch")
                try expectEqual(transport.callCount, 0, "绑错＝零 transport 调用")
            },


            TestDesc(suite: "ReviewSelfCheck", name: "cancellationMidLoopPropagates") {
                let check = #"[{"id": "a1", "supported": false, "citations": [], "search_query": "qq"}]"#
                let token = AICancellationToken()
                // 第 2 次调用（补块评分）入口取消。
                let transport = ScriptedTransport(replies: [check, check, check],
                                                  cancelAtCall: 2, token: token)
                let ledger = AICallLedger()
                try await expectThrowsAsync({
                    try await run(transport,
                                  confirmation: AIConfirmation(explicit: true, previewID: PreviewIDs.review),
                                  retrieve: { _ in [hit("b7", page: 1, snippet: "块")] },
                                  cancellation: token, ledger: ledger)
                })
                try expectEqual(transport.callCount, 2, "取消后零后续调用")
                try expectTrue(ledger.entries.contains { !$0.ok }, "取消 leg 如实记账")
            },


            TestDesc(suite: "ReviewSelfCheck", name: "revisePromptCarriesDeletionClaimTextForLocation") {
                // 删除指令只收可定位断言（编号＋原文）；
                // 不可定位者由 runner 保守保留（见下例），不进 revise prompt。
                let prompt = ReviewSelfCheck.revisePrompt(
                    draft: "草稿",
                    deletions: [(id: "a3", text: "被驳斥的断言原文整句。")],
                    extraEvidence: [])
                try expectTrue(prompt.contains("[a3] 原文：被驳斥的断言原文整句。"), "带原文可定位")
                try expectFalse(prompt.contains("原文未摘录"), "不可定位者不再以编号定位降级（改由 runner 保守保留）")
                try expectTrue(prompt.contains("整句删除"), "删句纪律")
            },

            TestDesc(suite: "ReviewSelfCheck", name: "unlocatableDeletionKeptConservativelyWithCount") {
                let check = #"[{"id": "a1", "supported": false, "citations": [], "text": "这句并不在草稿里"}, {"id": "a3", "supported": false, "citations": [], "text": "论论论论论"}]"#
                let revised = String(repeating: "改", count: 200)
                let transport = ScriptedTransport(replies: [check, revised])
                let outcome = try await run(transport, confirmation: AIConfirmation(
                    explicit: true, previewID: PreviewIDs.review))
                let reviseQ = transport.payloads[1].question
                try expectTrue(reviseQ.contains("a1") == false, "原文不在稿中者不进删除指令")
                try expectTrue(reviseQ.contains("[a3] 原文：论论论论论"), "可定位者进删除指令")
                let note = try expectNotNil(outcome.rounds[0].note)
                try expectTrue(note.contains("1 条无支撑断言因原文不可定位而保守保留"), "保守保留如实计数")
                try expectEqual(outcome.finalDraft, revised, "改写腿仍执行（有可执行处置：可删句在案）")
            },

            TestDesc(suite: "ReviewSelfCheck", name: "checkPromptContractCarriesVerbatimTextAndPriorityLine") {
                let prompt = ReviewSelfCheck.checkPrompt(draft: "草稿", evidence: ["证据"])
                try expectTrue(prompt.contains("\"text\""), "输出契约含 text 字段")
                try expectTrue(prompt.contains("逐字复制"), "text 逐字约束")
                try expectTrue(prompt.contains("本请求的唯一合法输出"), "通道契约优先级声明（answer/references 不适用）")
            },

            TestDesc(suite: "ReviewSelfCheck", name: "subrequestCitationNoteOccupiesUserTailNoConflict") {
                // 子请求 citationNote 非 nil——encode 的 user
                // 消息末尾不再追加默认 answer/references 指令（末尾无矛盾契约）。
                let check = #"[{"id": "a1", "supported": true, "citations": [1]}]"#
                let transport = ScriptedTransport(replies: [check])
                _ = try await run(transport, confirmation: AIConfirmation(
                    explicit: true, previewID: PreviewIDs.review))
                let payload = transport.payloads[0]
                let note = try expectNotNil(payload.citationNote, "check leg 必须携带非 nil citationNote")
                try expectTrue(note.contains("唯一合法输出"), "末尾契约=本 leg 形状")
                let data = try OpenAIChatCompletionsAdapter.encode(payload)
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let messages = try expectNotNil(obj?["messages"] as? [[String: Any]])
                let userContent = try expectNotNil(messages.last?["content"] as? String)
                try expectTrue(userContent.hasSuffix(ReviewSelfCheck.checkLegContractNote),
                               "user 末尾=本 leg 契约（hasSuffix）")
                try expectFalse(userContent.contains("string field answer"),
                                "user 消息不含默认 answer/references 指令特征串")
            },

            TestDesc(suite: "ReviewSelfCheck", name: "supplementSkipsUnverifiedHitsAndAnchorsPageHonestly") {
                let check = #"[{"id": "a2", "supported": false, "citations": [], "text": "可疑断言原句", "search_query": "某 检索"}]"#
                let revised = String(repeating: "改", count: 200)
                let transport = ScriptedTransport(replies: [
                    check,
                    #"{"summary": "补充摘要", "relevance_score": 9}"#,
                    revised,
                ])
                final class HitsBox: @unchecked Sendable {
                    private let lock = NSLock()
                    private var items: [SearchHit] = []
                    func append(_ hit: SearchHit) { lock.withLock { items.append(hit) } }
                    func count() -> Int { lock.withLock { items.count } }
                }
                let verifiedHits = HitsBox()
                let outcome = try await run(transport, confirmation: AIConfirmation(
                    explicit: true, previewID: PreviewIDs.review),
                    retrieve: { _ in
                        [hit("good", page: 4, snippet: "好块"), hit("stale", page: 9, snippet: "漂移块")]
                    },
                    verify: { hit in
                        verifiedHits.append(hit)
                        return hit.bookID == "good"   // 指纹漂移块拒绝
                    })
                try expectEqual(verifiedHits.count(), 2, "两个 hit 都过校验闭包")
                try expectEqual(transport.callCount, 4, "被拒块零评分调用（r1 检查＋1 评分＋改写＋r2 检查腿保守收束）")
                try expectEqual(outcome.rounds[0].supplementedBlocks, 1)
                try expectTrue(transport.payloads[1].question.contains("好块"))
                try expectTrue(transport.payloads[1].question.contains("漂移块") == false, "被拒块不进评分")
                try expectTrue(transport.payloads[2].question.contains("物理页 4（印刷页码未知）"),
                               "页码两基准分述（物理页恒知/印刷页码未知，不自相矛盾）")
            },

            TestDesc(suite: "ReviewSelfCheck", name: "evidenceTruncatedAtRunnerBoundary") {
                let longSnippet = String(repeating: "长", count: RCSContextBuilder.rcsBlockCharLimit + 500)
                let longEvidence = [AIRequestPayload.SelectionPayload(
                    bookId: "b1", fingerprint: "fp", page: 1, snippet: longSnippet)]
                let check = #"[{"id": "a1", "supported": true, "citations": [1]}]"#
                let transport = ScriptedTransport(replies: [check])
                _ = try await ReviewSelfCheckRunner.run(
                    draft: draft, planPreviewID: PreviewIDs.review,
                    configuration: configuration,
                    confirmation: AIConfirmation(explicit: true, previewID: PreviewIDs.review),
                    transport: transport, cancellation: nil, ledger: AICallLedger(),
                    evidence: longEvidence, retrieve: { _ in [] },
                    verify: { _ in true })
                let payload = transport.payloads[0]
                try expectEqual(payload.selection.snippet.count, RCSContextBuilder.rcsBlockCharLimit,
                                "缆层 snippet 截断至 1200")
                try expectNil(payload.question.range(of: "长{1210}", options: .regularExpression),
                              "prompt 清单同界（无超限长串）")
            },


            TestDesc(suite: "ReviewSelfCheck", name: "ledgerSummarizesAllLegs") {
                let check = #"[{"id": "a1", "supported": true, "citations": [1]}]"#
                let transport = ScriptedTransport(replies: [check])
                let ledger = AICallLedger()
                _ = try await run(transport,
                                  confirmation: AIConfirmation(explicit: true, previewID: PreviewIDs.review),
                                  ledger: ledger)
                try expectEqual(ledger.totalCount, 1)
                try expectTrue(ledger.entries[0].name.contains("逐断言"))
                try expectTrue(ledger.summaryText.contains("1 次请求"))
            },
        ]
    }
}
