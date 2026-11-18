import Foundation

// MARK: - 综述自检反馈循环（逐断言查支撑、缺证回检索或删句）

public enum ReviewSelfCheck {
    /// 自检轮数上限（默认值，常数集中一处）。
    public static let reviewSelfCheckMaxRounds = 2
    /// 防坍缩阈值（常数集中一处）。
    public static let collapseThreshold = 0.9

    /// 防坍缩门（纯函数）：改写稿字符长度 ≥ 原稿×threshold 才接受
    public static func collapseGate(original: String, revised: String,
                                    threshold: Double = collapseThreshold) -> Bool {
        let originalLength = original.count
        guard originalLength > 0 else { return !revised.isEmpty }
        return Double(revised.count) >= Double(originalLength) * threshold
    }

    /// 逐断言检查 prompt（自写；claim_full 语义：逐条判 supported＋支撑
    public static func checkPrompt(draft: String, evidence: [String]) -> String {
        return """
        你是学术综述的事实核查员。下面是一篇综述草稿和带页码的证据清单。请逐条检查草稿中的断言是否被证据支撑，只输出一个 JSON 数组，不要输出其它文字：
        [{"id": "断言编号 a1/a2/…", "supported": true或false, "citations": [支撑该断言的证据编号（整数）], "text": "该断言在草稿中的原文（逐字摘录整句，供后续编辑定位，不要改写）", "search_query": "当 supported 为 false 且本地证据可能不足时，给出一条用于在文献库中检索补充证据的中文检索问句；否则省略该字段"}]

        \(Self.contractPriorityLine)

        规则：
        - 只依据证据清单判断，不凭常识补证。
        - citations 只能引用证据清单中的编号。
        - text 必须从草稿逐字复制，不得缩写或改写。
        - 宁可漏删不可误删：拿不准时 supported 填 true。

        证据清单：
        \(evidence.enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: "\n"))

        综述草稿：
        \(draft)
        """
    }

    public struct ClaimVerdict: Equatable, Sendable {
        public let id: String
        public let supported: Bool
        public let citations: [Int]
        public let text: String?
        public let searchQuery: String?
    }

    public static func parseVerdicts(_ raw: String) -> [ClaimVerdict]? {
        guard let start = raw.firstIndex(of: "["),
              let data = String(raw[start...]).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !array.isEmpty else { return nil }
        var verdicts: [ClaimVerdict] = []
        for item in array {
            guard let id = item["id"] as? String,
                  let supported = item["supported"] as? Bool else { continue }
            let citations = (item["citations"] as? [Double])?.map { Int($0) }
                ?? (item["citations"] as? [Int]) ?? []
            let query = item["search_query"] as? String
            verdicts.append(ClaimVerdict(id: id, supported: supported,
                                         citations: citations,
                                         text: item["text"] as? String,
                                         searchQuery: query))
        }
        return verdicts.isEmpty ? nil : verdicts
    }

    /// 通道契约优先级声明（子请求经既有 encode 会携带
    /// answer/references 的系统应答契约，与各 leg 自有 JSON 契约冲突——
    /// 显式声明优先级，模型收到一致指令）。
    static let contractPriorityLine = "注意：若系统指令要求以 {\"answer\":…, \"references\":[…]} 形状应答，该要求不适用于本请求；本请求的唯一合法输出是下方用户指令规定的形状，除此之外不要输出任何文字。"

    /// 三类子请求经 encode 时以非 nil citationNote
    /// 占据 user 消息末尾（encode 对 citationNote 非 nil 不再追加默认
    /// answer/references 指令）——契约在消息末尾与 prompt 优先级行一致，
    /// 无「末尾矛盾指令」。
    static let checkLegContractNote = "本请求的唯一合法输出（覆盖任何系统应答格式要求）：一个 JSON 数组，元素形状 {\"id\": …, \"supported\": …, \"citations\": […], \"text\": …, \"search_query\": …}，与上方用户指令一致；不要输出 answer/references 形状。"
    static let reviseLegContractNote = "本请求的唯一合法输出（覆盖任何系统应答格式要求）：修改后的综述全文纯文本；不要输出 answer/references 形状，不要 JSON 包裹。"

    /// 改写 prompt（自写编辑纪律）：只改需改处、其余逐字保留。删除仅适用于「无检索问句且原文可定位」的
    /// 无支撑断言——有检索问句的断言经补块改写后原句保留（补块证据只供
    /// 新增/修订引用），此为现状且如实呈现，不虚称全量删句；新增内容只准
    /// 引用既有＋新增证据。
    public static func revisePrompt(draft: String,
                                    deletions: [(id: String, text: String)],
                                    extraEvidence: [String]) -> String {
        var lines: [String] = [
            "你是学术综述的编辑。请对下面的综述草稿作最小修改，只输出修改后的全文，不要输出其它文字。",
            Self.contractPriorityLine,
            "编辑纪律：",
            "- 只改需要修改的句子，其余句子逐字保留，不改写、不润色、不缩写。",
            "- 新增或修改的讨论只准引用既有证据和下面给出（若有）的新增证据。",
            "- 保持原稿的全部既有引用编号与页码锚点不变。",
        ]
        if !deletions.isEmpty {
            let listing = deletions.map { deletion -> String in
                "[\(deletion.id)] 原文：\(deletion.text)"
            }.joined(separator: "\n")
            lines.append("- 以下断言经核查无证据支撑且无法补充证据，请将其整句删除（编号＋原文）：\n\(listing)")
        }
        if !extraEvidence.isEmpty {
            lines.append("新增证据（编号延续原清单）：\n" + extraEvidence.enumerated().map { "[新\($0.offset + 1)] \($0.element)" }.joined(separator: "\n"))
        }
        lines.append("综述草稿：\n\(draft)")
        return lines.joined(separator: "\n")
    }
}

// MARK: runner（轮数上限固定；单确认绑整计划；逐 leg 记账）

public struct ReviewRoundRecord: Equatable, Sendable {
    public let round: Int
    /// nil＝该轮解析失败（保守保留）。
    public let verdicts: [ReviewSelfCheck.ClaimVerdict]?
    public let parseFailed: Bool
    public let retrievedQueries: [String]
    public let supplementedBlocks: Int
    public let revised: Bool
    public let revisionAccepted: Bool
    public let note: String?
}

public struct ReviewSelfCheckOutcome: Equatable, Sendable {
    public let finalDraft: String
    public let rounds: [ReviewRoundRecord]
    public let initialDraft: String
}

public enum ReviewSelfCheckRunner {
    /// 执行自检循环：草稿 →（逐断言检查 → 补块/删句 → 改写 → 防坍缩门）×
    /// reviewSelfCheckMaxRounds。
    public static func run(draft: String,
                           planPreviewID: UUID,
                           configuration: AIConfiguration,
                           confirmation: AIConfirmation?,
                           transport: AITransport,
                           cancellation: AICancellationToken?,
                           ledger: AICallLedger,
                           evidence: [AIRequestPayload.SelectionPayload],
                           retrieve: @escaping @Sendable (String) async -> [SearchHit],
                           verify: @escaping @Sendable (SearchHit) async -> Bool) async throws -> ReviewSelfCheckOutcome {
        // 确认门（与 AIAssistantService.send 既有门同构；单确认绑整计划）。
        guard let confirmation else { throw AIAssistantError.confirmationRequired }
        guard confirmation.explicit else { throw AIAssistantError.confirmationRequired }
        guard confirmation.previewID == planPreviewID else {
            throw AIAssistantError.confirmationMismatch
        }

        let boundedEvidence = evidence.map { payload -> AIRequestPayload.SelectionPayload in
            var bounded = payload
            bounded.snippet = String(payload.snippet.prefix(RCSContextBuilder.rcsBlockCharLimit))
            return bounded
        }
        let evidenceLines = boundedEvidence.map { payload in
            "bookId=\(payload.bookId), page=\(payload.page)：\(payload.snippet)"
        }
        var currentDraft = draft
        var rounds: [ReviewRoundRecord] = []

        for roundNumber in 1...ReviewSelfCheck.reviewSelfCheckMaxRounds {
            try cancellation?.check()   // 每 leg 前取消检查

            let checkPayload = AIRequestPayload(
                model: configuration.model,
                question: ReviewSelfCheck.checkPrompt(draft: currentDraft, evidence: evidenceLines),
                selection: boundedEvidence.first ?? AIRequestPayload.SelectionPayload(
                    bookId: "review-self-check", fingerprint: "-", page: 1,
                    snippet: String(currentDraft.prefix(RCSContextBuilder.rcsBlockCharLimit))),
                citationNote: ReviewSelfCheck.checkLegContractNote)
            let checkBytes = AIRequestMetrics.requestBytes(of: checkPayload)
            let checkRaw: String
            do {
                checkRaw = try await transport.send(configuration.serviceURL,
                                                    payload: checkPayload,
                                                    apiKey: configuration.apiKey,
                                                    cancellation: cancellation)
            } catch {
                ledger.record(name: "自检 r\(roundNumber) 逐断言", requestBytes: checkBytes, ok: false)
                throw error
            }
            ledger.record(name: "自检 r\(roundNumber) 逐断言", requestBytes: checkBytes, ok: true)

            guard let verdicts = ReviewSelfCheck.parseVerdicts(checkRaw) else {
                // 解析失败＝保守保留（宁可漏删不可误删），如实计数后收束。
                rounds.append(ReviewRoundRecord(round: roundNumber, verdicts: nil, parseFailed: true,
                                                retrievedQueries: [], supplementedBlocks: 0,
                                                revised: false, revisionAccepted: false,
                                                note: "断言检查响应解析失败，本轮保守保留全部内容"))
                break
            }

            let unsupported = verdicts.filter { !$0.supported }
            guard !unsupported.isEmpty else {
                rounds.append(ReviewRoundRecord(round: roundNumber, verdicts: verdicts, parseFailed: false,
                                                retrievedQueries: [], supplementedBlocks: 0,
                                                revised: false, revisionAccepted: false,
                                                note: "全部断言有支撑，无需改写"))
                break
            }

            var extraEvidence: [String] = []
            var retrievedQueries: [String] = []
            var supplemented = 0
            for (queryIndex, claim) in unsupported.enumerated() {
                guard let query = claim.searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !query.isEmpty else { continue }
                try cancellation?.check()
                retrievedQueries.append(query)
                let hits = await retrieve(query)
                var verifiedHits: [SearchHit] = []
                for hit in hits {
                    if await verify(hit) { verifiedHits.append(hit) }
                }
                let supplement = try await supplementBlocks(hits: verifiedHits, query: query,
                                                        queryIndex: queryIndex,
                                                        roundNumber: roundNumber,
                                                        configuration: configuration,
                                                        transport: transport,
                                                        cancellation: cancellation, ledger: ledger)
                extraEvidence.append(contentsOf: supplement)
                supplemented += supplement.count
            }

            var unlocatableCount = 0
            let deletions: [(id: String, text: String)] = unsupported.filter { claim in
                claim.searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            }.compactMap { claim -> (id: String, text: String)? in
                guard let text = claim.text,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      currentDraft.contains(text) else {
                    unlocatableCount += 1
                    return nil
                }
                return (id: claim.id, text: text)
            }

            if deletions.isEmpty && extraEvidence.isEmpty {
                rounds.append(ReviewRoundRecord(round: roundNumber, verdicts: verdicts, parseFailed: false,
                                                retrievedQueries: retrievedQueries,
                                                supplementedBlocks: supplemented,
                                                revised: false, revisionAccepted: false,
                                                note: "无可执行处置（无可删句、无新增证据），跳过改写"))
                break
            }

            let revisedRaw: String
            let revisePayload = AIRequestPayload(
                model: configuration.model,
                question: ReviewSelfCheck.revisePrompt(draft: currentDraft,
                                                       deletions: deletions,
                                                       extraEvidence: extraEvidence),
                selection: boundedEvidence.first ?? AIRequestPayload.SelectionPayload(
                    bookId: "review-self-check", fingerprint: "-", page: 1,
                    snippet: String(currentDraft.prefix(RCSContextBuilder.rcsBlockCharLimit))),
                citationNote: ReviewSelfCheck.reviseLegContractNote)
            let reviseBytes = AIRequestMetrics.requestBytes(of: revisePayload)
            do {
                try cancellation?.check()
                revisedRaw = try await transport.send(configuration.serviceURL,
                                                      payload: revisePayload,
                                                      apiKey: configuration.apiKey,
                                                      cancellation: cancellation)
            } catch {
                ledger.record(name: "改写 r\(roundNumber)", requestBytes: reviseBytes, ok: false)
                throw error
            }
            ledger.record(name: "改写 r\(roundNumber)", requestBytes: reviseBytes, ok: true)
            let revised = revisedRaw.trimmingCharacters(in: .whitespacesAndNewlines)

            let unlocatableClause = "\(unlocatableCount) 条无支撑断言因原文不可定位而保守保留（未删）"
            if ReviewSelfCheck.collapseGate(original: currentDraft, revised: revised), !revised.isEmpty {
                currentDraft = revised
                rounds.append(ReviewRoundRecord(round: roundNumber, verdicts: verdicts, parseFailed: false,
                                                retrievedQueries: retrievedQueries,
                                                supplementedBlocks: supplemented,
                                                revised: true, revisionAccepted: true,
                                                note: unlocatableCount > 0 ? unlocatableClause : nil))
            } else {
                rounds.append(ReviewRoundRecord(round: roundNumber, verdicts: verdicts, parseFailed: false,
                                                retrievedQueries: retrievedQueries,
                                                supplementedBlocks: supplemented,
                                                revised: true, revisionAccepted: false,
                                                note: "改写稿较上轮缩水超过 \(Int((1 - ReviewSelfCheck.collapseThreshold) * 100))%，已拒收并保留上轮稿"
                                                    + (unlocatableCount > 0 ? "；另 " + unlocatableClause : "")))
            }
        }

        return ReviewSelfCheckOutcome(finalDraft: currentDraft, rounds: rounds, initialDraft: draft)
    }

    /// 补块评分：检索命中的块（已经 verify 指纹复检过滤）走 RCS 评分
    /// 契约（blockPrompt＋parseVerdict＋阈值过滤，stub 评分经 transport
    static func supplementBlocks(hits: [SearchHit],
                                 query: String,
                                 queryIndex: Int,
                                 roundNumber: Int,
                                 configuration: AIConfiguration,
                                 transport: AITransport,
                                 cancellation: AICancellationToken?,
                                 ledger: AICallLedger) async throws -> [String] {
        var extra: [String] = []
        for (blockIndex, hit) in hits.prefix(AIAssistantService.synthesisPassageLimit).enumerated() {
            try cancellation?.check()   // 取消传播：补块中途取消即上抛
            let boundedSnippet = String(hit.snippet.prefix(RCSContextBuilder.rcsBlockCharLimit))
            let block = RCSBlockPlan(
                index: blockIndex + 1,
                bookId: hit.bookID,
                page: hit.physicalPage,
                pageLabelText: nil,
                snippet: boundedSnippet,
                payload: AIRequestPayload.SelectionPayload(
                    bookId: hit.bookID, fingerprint: hit.fingerprint,
                    page: hit.physicalPage, snippet: hit.snippet,
                    source: hit.source, ocrPage: hit.ocrPage))
            var scoringSelection = block.payload
            scoringSelection.snippet = boundedSnippet
            let payload = AIRequestPayload(
                model: configuration.model,
                question: RCSContextBuilder.blockPrompt(for: block, question: query),
                selection: scoringSelection)
            let bytes = AIRequestMetrics.requestBytes(of: payload)
            let raw: String
            do {
                raw = try await transport.send(configuration.serviceURL, payload: payload,
                                               apiKey: configuration.apiKey,
                                               cancellation: cancellation)
            } catch {
                ledger.record(name: "补引评分 r\(roundNumber)q\(queryIndex + 1)b\(blockIndex + 1)",
                              requestBytes: bytes, ok: false)
                if error is CancellationError || (error as? AIAssistantError) == .cancelled {
                    throw error   // 取消必须传播，不按单块失败吞掉
                }
                continue   // 单块评分失败不拖垮整轮（如实计数，块出局）
            }
            ledger.record(name: "补引评分 r\(roundNumber)q\(queryIndex + 1)b\(blockIndex + 1)",
                          requestBytes: bytes, ok: true)
            guard let verdict = RCSContextBuilder.parseVerdict(raw),
                  verdict.relevanceScore >= RCSContextBuilder.rcsMinRelevanceScore,
                  !verdict.summary.isEmpty else { continue }
            extra.append("bookId=\(block.bookId), 物理页 \(block.page)（印刷页码未知）：\(verdict.summary)")
        }
        return extra
    }
}
