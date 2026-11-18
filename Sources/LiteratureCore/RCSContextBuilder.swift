import Foundation

// MARK: - RCS 逐块评分摘要（Ranking and Contextual Summarization）

// MARK: 宽松 JSON 提取（parseResponse 手法自写版；共用）

public enum AIJSONLenient {
    /// 定位文本中首个完整 JSON 对象（括号配对，跳过字符串字面量）；
    /// 严格形状由调用方负责。
    public static func firstJSONObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        let candidate = String(text[start...])
        if let data = candidate.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        guard let trimmed = trimmedJSONObject(in: candidate),
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    /// 截到首个与首括号配对的闭括号（字符串内引号/转义感知）。
    private static func trimmedJSONObject(in text: String) -> String? {
        var depth = 0
        var inString = false
        var escape = false
        for (i, ch) in text.enumerated() {
            if escape { escape = false; continue }
            if ch == "\\" && inString { escape = true; continue }
            if ch == "\"" { inString.toggle(); continue }
            if inString { continue }
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    let idx = text.index(text.startIndex, offsetBy: i)
                    return String(text[text.startIndex...idx])
                }
            }
        }
        return nil
    }
}

// MARK: 计划与块

/// 单块计划：原始出处（payload 原样保留 provenance）＋评分请求素材。
public struct RCSBlockPlan: Equatable, Sendable {
    /// 块序号（1 起，最终证据锚头沿用）。
    public let index: Int
    public let bookId: String
    /// 物理页（恒知）。
    public let page: Int
    /// 页码标签（pageLabel/printedPage 已知值；nil＝未知，绝不猜——
    /// PageNumberService 声明制语义）。评分卡与块 prompt 均用。
    public let pageLabelText: String?
    /// 截断后的块文本（rcsBlockCharLimit 适配端上 4096 窗）。
    public let snippet: String
    /// 原始选区载荷（最终组装与 provenance 展示用）。
    public let payload: AIRequestPayload.SelectionPayload

    /// 页码锚头显示（未知显式「页码未知」，绝不猜）。
    public var anchorText: String { pageLabelText ?? "页码未知" }
}

/// RCS 流程计划。previewID 与计划预览（makeRCSPlanPreview）的 AIPreview.id
/// 同值：单次确认绑定整条流程。
public struct RCSPlan: Equatable, Sendable {
    public let previewID: UUID
    public let question: String
    public let blocks: [RCSBlockPlan]

    public init(previewID: UUID, question: String, blocks: [RCSBlockPlan]) {
        self.previewID = previewID
        self.question = question
        self.blocks = blocks
    }
}

public enum RCSContextBuilder {
    /// 单块字符上限（端上 4096 窗适配；常数集中一处）。
    public static let rcsBlockCharLimit = 1200
    /// 相关性阈值（0-10 刻度；默认 7，常数集中一处，不做设置项 UI）。
    public static let rcsMinRelevanceScore = 7

    /// 计划构造（纯）。块数上限复用 synthesisPassageLimit=16：超限拒绝
    /// （预览层 makeRCSPlanPreview 已先截到 16，此处拒绝是双保险）。
    /// pageLabel 闭包注入（生产=PageNumberService+书目名换算；测试=桩），
    /// nil＝未知，绝不猜。
    public static func makePlan(question: String,
                                selections: [AIPreview.Selection],
                                pageLabel: @escaping @Sendable (String, Int) -> String? = { _, _ in nil }) throws -> RCSPlan {
        guard !selections.isEmpty else {
            throw AIAssistantError.invalidConfiguration("RCS 需要至少一个块")
        }
        guard selections.count <= AIAssistantService.synthesisPassageLimit else {
            throw AIAssistantError.invalidConfiguration(
                "RCS 块数上限 \(AIAssistantService.synthesisPassageLimit)（当前 \(selections.count)）")
        }
        let blocks = selections.enumerated().map { offset, selection -> RCSBlockPlan in
            let truncated = String(selection.snippet.prefix(rcsBlockCharLimit))
            return RCSBlockPlan(
                index: offset + 1,
                bookId: selection.bookID,
                page: selection.physicalPage,
                pageLabelText: pageLabel(selection.bookID, selection.physicalPage),
                snippet: truncated,
                payload: AIRequestPayload.SelectionPayload(selection))
        }
        return RCSPlan(previewID: UUID(), question: question, blocks: blocks)
    }

    /// 逐块评分 prompt（自写模板；契约语义对齐 PaperQA2 prompts.py——
    /// 「打分＋压缩一体、不相关＝空摘要＋0 分、摘要面向下游模型」，文案
    public static func blockPrompt(for block: RCSBlockPlan, question: String) -> String {
        return """
        你是文献检索的相关性分析器。针对下面的问题阅读给定块，只输出一个 JSON 对象，不要输出其它文字：
        {"summary": "对该块中与回答问题相关内容的简洁摘要", "relevance_score": 0到10的整数}

        注意：若系统指令要求以 {"answer":…, "references":[…]} 形状应答，该要求不适用于本请求；本请求的唯一合法输出是上方 JSON 形状。

        规则：
        - relevance_score 只表示该块与问题的相关程度，不要解释分数。
        - 如果块内容与问题无关，summary 留空字符串、relevance_score 填 0。
        - 你的摘要将与其它块的摘要合并交给下游模型作答，只依据块内容，不要编造。

        问题：\(question)

        块 [\(block.index)] bookId=\(block.bookId) 页码: \(block.anchorText)
        \(block.snippet)
        """
    }

    // MARK: verdict 解析（宽松定位首个 JSON、严格形状）

    /// 逐块分析结果。relevanceScore 已限制在 0-10。
    public struct RCSVerdict: Equatable, Sendable {
        public let summary: String
        public let relevanceScore: Int
    }

    /// 解析失败返回 nil（调用方：该块按 0 分出局＋失败计数；不崩、不重试，
    /// 计数进 ledger 如实显示）。空 summary＋0 分是合法 verdict（正路出局）。
    public static func parseVerdict(_ raw: String) -> RCSVerdict? {
        guard let obj = AIJSONLenient.firstJSONObject(in: raw) else { return nil }
        guard let summary = obj["summary"] as? String else { return nil }
        let score: Int?
        if let intValue = obj["relevance_score"] as? Int {
            score = intValue
        } else if let doubleValue = obj["relevance_score"] as? Double,
                  doubleValue == doubleValue.rounded() {
            score = Int(doubleValue)
        } else if let stringValue = obj["relevance_score"] as? String {
            score = Int(stringValue.trimmingCharacters(in: .whitespaces))
        } else {
            score = nil
        }
        guard let rawScore = score else { return nil }
        return RCSVerdict(summary: summary, relevanceScore: min(10, max(0, rawScore)))
    }

    // MARK: 最终上下文组装（纯）

    /// 单块处置结果（评分卡逐行）。
    public struct BlockResult: Equatable, Sendable {
        public let block: RCSBlockPlan
        /// nil＝解析失败出局。
        public let verdict: RCSVerdict?
        public let survived: Bool
        /// 落选原因（评分低于阈值／解析失败；存活块为 nil）。
        public let failureReason: String?

        public static func survived(_ block: RCSBlockPlan, _ verdict: RCSVerdict) -> BlockResult {
            BlockResult(block: block, verdict: verdict, survived: true, failureReason: nil)
        }

        public static func filteredByScore(_ block: RCSBlockPlan, _ verdict: RCSVerdict) -> BlockResult {
            BlockResult(block: block, verdict: verdict, survived: false,
                        failureReason: "相关性评分 \(verdict.relevanceScore) 低于阈值 \(rcsMinRelevanceScore)")
        }

        public static func parseFailed(_ block: RCSBlockPlan) -> BlockResult {
            BlockResult(block: block, verdict: nil, survived: false,
                        failureReason: "评分响应解析失败，按 0 分出局")
        }
    }

    /// 最终综合载荷：存活块摘要带页码锚头拼成 selections 语义；question=
    /// 用户原问题；citationNote 沿用既有综合引用契约。经
    public static func assembleFinalPayload(plan: RCSPlan,
                                            results: [BlockResult],
                                            model: String) -> AIRequestPayload? {
        let survivors = results.filter(\.survived)
        guard !survivors.isEmpty else { return nil }
        let selections = survivors.map { result -> AIRequestPayload.SelectionPayload in
            var payload = result.block.payload
            // 摘要带页码锚头（锚头缺失=页码未知，绝不猜）。
            payload.snippet = "[\(result.block.index)] 页码: \(result.block.anchorText) 摘要: \(result.verdict?.summary ?? "")"
            return payload
        }
        // selections 非空由上面的 guard 保证（下标 0 安全）。
        return AIRequestPayload(
            model: model,
            question: plan.question,
            selection: selections[0],
            selections: selections,
            citationNote: AIAssistantService.synthesisCitationNote)
    }
}

// MARK: runner（串行；确认门同构；逐 leg 记账）

public struct RCSOutcome: Equatable, Sendable {
    public let results: [RCSContextBuilder.BlockResult]
    /// 全部块出局时为 nil（未发送综合请求，如实显示）。
    public let answer: AIParsedResponse?
    public let parseFailureCount: Int
}

public enum RCSPipeline {
    /// 执行 RCS 流程：逐块串行评分（每 leg 前取消检查＋ledger 记账）→
    /// 阈值过滤 → 存活块拼最终综合请求（plan 级确认已绑定）。
    /// - Throws: 确认门失败（confirmationRequired/confirmationMismatch）、
    ///   取消（cancelled）、transport 错误（首个失败 leg 后中止，不静默续跑）。
    public static func run(plan: RCSPlan,
                           configuration: AIConfiguration,
                           confirmation: AIConfirmation?,
                           transport: AITransport,
                           cancellation: AICancellationToken?,
                           ledger: AICallLedger) async throws -> RCSOutcome {
        // 确认门（与 AIAssistantService.send 既有门同构）：零确认或绑错
        // ＝零 transport 调用。
        guard let confirmation else { throw AIAssistantError.confirmationRequired }
        guard confirmation.explicit else { throw AIAssistantError.confirmationRequired }
        guard confirmation.previewID == plan.previewID else {
            throw AIAssistantError.confirmationMismatch
        }

        var results: [RCSContextBuilder.BlockResult] = []
        var parseFailures = 0
        for block in plan.blocks {
            try cancellation?.check()   // 每 leg 前取消检查
            var scoringSelection = block.payload
            scoringSelection.snippet = block.snippet
            let payload = AIRequestPayload(
                model: configuration.model,
                question: RCSContextBuilder.blockPrompt(for: block, question: plan.question),
                selection: scoringSelection,
                citationNote: "本请求的唯一合法输出（覆盖任何系统应答格式要求）：{\"summary\": …, \"relevance_score\": 0到10整数} JSON 对象，与上方用户指令一致；不要输出 answer/references 形状。")
            let bytes = AIRequestMetrics.requestBytes(of: payload)
            let raw: String
            do {
                raw = try await transport.send(configuration.serviceURL, payload: payload,
                                               apiKey: configuration.apiKey,
                                               cancellation: cancellation)
            } catch {
                ledger.record(name: "评分 块\(block.index)", requestBytes: bytes, ok: false)
                throw error
            }
            if let verdict = RCSContextBuilder.parseVerdict(raw) {
                ledger.record(name: "评分 块\(block.index)", requestBytes: bytes, ok: true)
                if verdict.relevanceScore >= RCSContextBuilder.rcsMinRelevanceScore {
                    results.append(.survived(block, verdict))
                } else {
                    results.append(.filteredByScore(block, verdict))
                }
            } else {
                ledger.record(name: "评分 块\(block.index)", requestBytes: bytes, ok: true)
                parseFailures += 1
                results.append(.parseFailed(block))
            }
        }

        // 全部块出局：不发送综合请求（诚实呈现，不发空证据请求）。
        guard let finalPayload = RCSContextBuilder.assembleFinalPayload(
            plan: plan, results: results, model: configuration.model) else {
            return RCSOutcome(results: results, answer: nil, parseFailureCount: parseFailures)
        }

        try cancellation?.check()
        let finalBytes = AIRequestMetrics.requestBytes(of: finalPayload)
        let finalRaw: String
        do {
            finalRaw = try await transport.send(configuration.serviceURL, payload: finalPayload,
                                                apiKey: configuration.apiKey,
                                                cancellation: cancellation)
        } catch {
            ledger.record(name: "综合", requestBytes: finalBytes, ok: false)
            throw error
        }
        ledger.record(name: "综合", requestBytes: finalBytes, ok: true)
        let answer = try AIAssistantService.parseResponse(finalRaw)
        return RCSOutcome(results: results, answer: answer, parseFailureCount: parseFailures)
    }
}
