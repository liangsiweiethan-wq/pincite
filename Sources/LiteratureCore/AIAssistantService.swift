import Foundation

// MARK: - AI assistant (strictly confirmation-gated)
//
// Policy implemented here and enforced by tests:
// - Default configuration is nil: the service is unconfigured until the user
//   explicitly provides service URL + model. No defaults, no hardcoded model
//   identity, no conclusions about which model is "behind" a service.
// - Nothing leaves the machine without an explicit `AIConfirmation` bound to
//   the exact preview the user saw. No confirmation -> zero transport calls.
// - The API key lives in memory only (session-scoped); this service never
//   persists or resolves credentials. A user-triggered app action may provide
//   an explicitly named keychain item to the service.
// - Transport is injected; tests use a counting mock. The production transport
//   is plain URLSession against the user-configured service URL.
// - OCR provenance is part of the preview: a selection coming from paired OCR
//   text carries source="ocr" + ocrPage so the user sees exactly which file the
//   excerpt came from BEFORE anything is sent. Confirmation gating is unchanged.

public struct AIConfiguration: Equatable {
    /// Full endpoint URL of the user-configured service.
    public var serviceURL: URL
    /// Model identifier, chosen explicitly by the user. Never inferred.
    public var model: String
    /// In-memory only; never persisted, never read from the environment/keychain.
    public var apiKey: String?
    /// 预览「服务」行的人读名（端上档显示「设备端（Apple Foundation
    /// Models）」）。nil（云端档案既有路径）时 makePreview/makeSynthesisPreview
    public var displayName: String?

    public init(serviceURL: URL, model: String, apiKey: String? = nil,
                displayName: String? = nil) {
        self.serviceURL = serviceURL
        self.model = model
        self.apiKey = apiKey
        self.displayName = displayName
    }
}

/// The exact content that would be sent, shown to the user before any request.
public struct AIPreview: Equatable, Identifiable {
    /// The text selection sent to the AI (verbatim snippet + provenance).
    public struct Selection: Equatable {
        public var bookID: String
        public var fingerprint: String
        public var physicalPage: Int
        public var snippet: String   // verbatim excerpt the user selected
        /// "native" | "ocr"; nil = legacy selection (treated as native).
        /// For "ocr", physicalPage is the ORIGINAL pdf's page and ocrPage is the
        /// page inside the OCR pdf — both are shown in the preview.
        public var source: String?
        /// Physical page inside the OCR pdf when source == "ocr".
        public var ocrPage: Int?
        ///段级落点（页内 0 起段序；nil＝页级选区——既有路径
        /// 全部 nil，零回归。仅混合检索路径携带）。
        public var para: Int?

        public init(bookID: String, fingerprint: String, physicalPage: Int, snippet: String,
                    source: String? = nil, ocrPage: Int? = nil, para: Int? = nil) {
            self.bookID = bookID
            self.fingerprint = fingerprint
            self.physicalPage = physicalPage
            self.snippet = snippet
            self.source = source
            self.ocrPage = ocrPage
            self.para = para
        }
    }
    public var id: UUID
    public var question: String
    public var selection: Selection
    /// Multi-evidence synthesis (PaperQA2-style): when non-empty, the payload
    /// carries ALL passages and the model must cite only from these.
    public var selections: [Selection] = []
    public var serviceHost: String   // display only
    public var model: String         // display only
    public var planSummary: String? = nil
    /// 低1：端上档结构化标记（默认 false）。UI 按
    /// `preview.onDevice` 判别，不再做 serviceHost 字符串比对。
    public var onDevice: Bool = false
}

/// Explicit user confirmation bound to a preview. `explicit` must be true —
/// this type cannot be constructed implicitly by accident.
public struct AIConfirmation: Equatable {
    public let explicit: Bool
    public let previewID: UUID

    public init?(explicit: Bool, previewID: UUID) {
        guard explicit else { return nil }
        self.explicit = true
        self.previewID = previewID
    }
}

public struct AIRequestPayload: Codable, Equatable {
    public struct SelectionPayload: Codable, Equatable {
        public var bookId: String
        public var fingerprint: String
        public var page: Int
        public var snippet: String
        /// OCR provenance (absent in older payloads — decodes as nil).
        public var source: String?
        public var ocrPage: Int?
        ///段级落点（可选；JSONEncoder 对 nil Optional 省键——
        /// 旧载荷 decode 零回归，新载荷仅混合检索路径携带）。
        public var para: Int?

        public init(bookId: String, fingerprint: String, page: Int, snippet: String,
                    source: String? = nil, ocrPage: Int? = nil, para: Int? = nil) {
            self.bookId = bookId
            self.fingerprint = fingerprint
            self.page = page
            self.snippet = snippet
            self.source = source
            self.ocrPage = ocrPage
            self.para = para
        }

        /// From the preview-facing Selection (same fields, different naming).
        public init(_ selection: AIPreview.Selection) {
            self.init(bookId: selection.bookID, fingerprint: selection.fingerprint,
                      page: selection.physicalPage, snippet: selection.snippet,
                      source: selection.source, ocrPage: selection.ocrPage,
                      para: selection.para)
        }
    }
    public var model: String
    public var question: String
    public var selection: SelectionPayload
    /// Multi-evidence form: all passages when this is a synthesis request.
    public var selections: [SelectionPayload]?
    /// Instruction bound into the payload for synthesis requests: the model
    /// must cite only from the provided passages (bookId + page pairs).
    public var citationNote: String?
}

public struct AIParsedResponse: Equatable {
    public var answerText: String
    public var references: [AIReference]
}

/// Structured reference produced from an AI response.
public struct AIReference: Codable, Equatable {
    public var bookId: String
    public var page: Int
    /// Optional fingerprint echoed by the model; presence is validated, absence allowed.
    public var fingerprint: String?
    ///段级落点（可选；旧响应无此键 decode 为 nil，零回归）。
    /// para 非 nil 时由 ReferenceResolver.resolveWithParagraphs 生成后降级处理校验。
    public var para: Int?

    public init(bookId: String, page: Int, fingerprint: String? = nil, para: Int? = nil) {
        self.bookId = bookId
        self.page = page
        self.fingerprint = fingerprint
        self.para = para
    }
}

public enum AIAssistantError: Error, Equatable, CustomStringConvertible {
    case notConfigured
    case invalidConfiguration(String)
    case previewRequired
    case confirmationRequired
    case confirmationMismatch
    case transport(String)
    case badResponse(String)
    /// 用户主动停止（AICancellationToken.cancel）。与 transport
    /// 错误区分开，UI 据此给出"已停止，可重新发送"而非失败文案。
    case cancelled
    /// 端上模型 guardrail/安全策略拒答（FoundationModels
    /// LanguageModelError.refusal / guardrailViolation 的显式归档）。显式报错，
    case refused(String)

    public var description: String {
        switch self {
        case .notConfigured: return "notConfigured"
        case .invalidConfiguration(let detail): return "invalidConfiguration(\(detail))"
        case .previewRequired: return "previewRequired"
        case .confirmationRequired: return "confirmationRequired"
        case .confirmationMismatch: return "confirmationMismatch"
        case .transport(let detail): return "transport(\(detail))"
        case .badResponse(let detail): return "badResponse(\(detail))"
        case .cancelled: return "cancelled"
        case .refused(let detail): return "refused(\(detail))"
        }
    }
}

/// AI 请求取消令牌。线程安全；cancel 幂等，且会触发已注册的
/// 一次性回调（URLSessionAITransport 用回调取消底层 URLSessionTask，实现
/// 真正的网络中断而非事后丢弃结果）。
public final class AICancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [() -> Void] = []

    public init() {}

    public func cancel() {
        lock.lock()
        let first = !cancelled
        cancelled = true
        let pending = first ? handlers : []
        handlers = []
        lock.unlock()
        if first {
            for handler in pending { handler() }
        }
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// 已取消则抛 AIAssistantError.cancelled（挂起点/发送前检查）。
    public func check() throws {
        if isCancelled { throw AIAssistantError.cancelled }
    }

    /// 注册一次性回调；若已取消则立即同步执行。
    func onCancel(_ handler: @escaping () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
            return
        }
        handlers.append(handler)
        lock.unlock()
    }
}

/// Injectable network boundary.：send 携带可选取消令牌——协议
/// requirement 是带 `cancellation` 的新签名；旧签名由协议扩展默认转发
/// （忽略取消），既有 mock/测试传输零改动保持可取消性以外的原语义。
public protocol AITransport {
    func send(_ endpoint: URL, payload: AIRequestPayload, apiKey: String?,
              cancellation: AICancellationToken?) async throws -> String
}

extension AITransport {
    /// 前契约：不可取消的传输按原样完成（token 只被忽略）。
    public func send(_ endpoint: URL, payload: AIRequestPayload, apiKey: String?) async throws -> String {
        try await send(endpoint, payload: payload, apiKey: apiKey, cancellation: nil)
    }
}

/// True when a redirect leaves the original origin (scheme/host/effective port).
/// Exported for unit testing — the transport uses this to refuse forwarding the
/// Authorization header across origins.
public func isCrossOriginRedirect(from original: URL, to redirected: URL) -> Bool {
    func normalized(_ url: URL) -> (String, String, Int) {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        var port = url.port ?? 0
        if port == 0 {
            switch scheme {
            case "https": port = 443
            case "http": port = 80
            default: break
            }
        }
        return (scheme, host, port)
    }
    return normalized(original) != normalized(redirected)
}

/// Blocks redirects that would carry the request (with its Authorization
/// header) to a different origin than the configured service.
final class RedirectGuardDelegate: NSObject, URLSessionDataDelegate {
    let baseURL: URL
    fileprivate var blockedRedirect = false

    init(baseURL: URL) { self.baseURL = baseURL }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        if let target = request.url, isCrossOriginRedirect(from: baseURL, to: target) {
            blockedRedirect = true
            completionHandler(nil) // refuse: do not follow
        } else {
            completionHandler(request)
        }
    }
}

/// OpenAI-compatible HTTPS transport, redirect-guarded. Evidence leaves only
/// after the preview-bound confirmation succeeds in AIAssistantService.send.
public enum OpenAIChatCompletionsAdapter {
    private struct Message: Encodable {
        var role: String
        var content: String
    }
    private struct RequestBody: Encodable {
        var model: String
        var messages: [Message]
        var max_tokens: Int
        var stream: Bool
    }

    public static func encode(_ payload: AIRequestPayload) throws -> Data {
        let selections = payload.selections ?? [payload.selection]
        let evidence = selections.enumerated().map { index, selection in
            //段级落点仅在有段号时追加 `para=`（nil＝既有格式
            // 逐字节不变——AITests 对 evidence 头的断言保持原样）。
            let paraPart = selection.para.map { ", para=\($0)" } ?? ""
            return "[\(index + 1)] bookId=\(selection.bookId), page=\(selection.page)\(paraPart), fingerprint=\(selection.fingerprint), source=\(selection.source ?? "native"), ocrPage=\(selection.ocrPage.map(String.init) ?? "unknown")\n\(selection.snippet)"
        }.joined(separator: "\n\n")
        let instruction = "Answer from only the supplied excerpts. Reply as one JSON object with string field answer and array field references; each reference has bookId and page from the supplied excerpts. If evidence is insufficient, say so."
        let content = "Question: \(payload.question)\n\nEvidence:\n\(evidence)\n\n\(payload.citationNote ?? instruction)"
        return try JSONEncoder().encode(RequestBody(
            model: payload.model,
            messages: [Message(role: "system", content: instruction), Message(role: "user", content: content)],
            max_tokens: 2048,
            stream: false
        ))
    }

    public static func answerJSON(from data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIAssistantError.badResponse("OpenAI response missing choices[0].message.content")
        }
        return content
    }
}

/// Production transport (plain HTTPS POST with JSON body, redirect-guarded).
/// 默认 120s 超时（可配），send 可经 AICancellationToken 真正
/// 取消（回调取消底层 URLSessionTask，而非事后丢弃结果）。
public struct URLSessionAITransport: AITransport {
    /// 请求超时秒数（resource 与 request 双限）。默认 120s；AI 问答长尾
    /// 明显长于普通 API，故不用 URLSession 默认 60s。
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 120) {
        self.timeout = timeout
    }

    public func send(_ endpoint: URL, payload: AIRequestPayload, apiKey: String?,
                     cancellation: AICancellationToken?) async throws -> String {
        // 发送前已取消 → 零请求直接返回取消错误。
        try cancellation?.check()
        let delegate = RedirectGuardDelegate(baseURL: endpoint)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = timeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try OpenAIChatCompletionsAdapter.encode(payload)

        let work = Task { try await session.data(for: request) }
        if let cancellation {
            // token 取消 → 取消底层任务（data(for:) 随即抛取消类错误）。
            cancellation.onCancel { work.cancel() }
            // 注册与取消并发的降级处理：回调可能尚未挂上 token 就已取消。
            if cancellation.isCancelled { work.cancel() }
        }
        let outcome: Result<(Data, URLResponse), Error>
        do {
            outcome = .success(try await work.value)
        } catch {
            outcome = .failure(error)
        }
        try cancellation?.check()
        let (data, response): (Data, URLResponse)
        switch outcome {
        case .success(let pair):
            (data, response) = pair
        case .failure(let error):
            if cancellation?.isCancelled == true { throw AIAssistantError.cancelled }
            throw AIAssistantError.transport(String(describing: error))
        }
        if delegate.blockedRedirect {
            throw AIAssistantError.transport("cross-origin redirect blocked (API key must not leave the configured origin)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw AIAssistantError.transport("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AIAssistantError.transport("HTTP \(http.statusCode)")
        }
        return try OpenAIChatCompletionsAdapter.answerJSON(from: data)
    }
}

public final class AIAssistantService {
    /// nil until the user configures a service; default is unconfigured.
    public private(set) var configuration: AIConfiguration?

    public init() {}

    /// Explicit user action. Passing nil un-configures the service.
    /// HTTPS is mandatory: the API key travels as a Bearer header, and plain
    /// HTTP would leak it. Invalid configurations are rejected, not softened.
    public func configure(_ configuration: AIConfiguration?) throws {
        guard let configuration else { self.configuration = nil; return }
        guard let scheme = configuration.serviceURL.scheme?.lowercased(), scheme == "https" else {
            throw AIAssistantError.invalidConfiguration("service URL must be HTTPS (Bearer key must not travel over plain HTTP)")
        }
        guard configuration.serviceURL.host != nil else {
            throw AIAssistantError.invalidConfiguration("service URL has no host")
        }
        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIAssistantError.invalidConfiguration("model identifier must be provided explicitly")
        }
        self.configuration = configuration
    }

    /// Builds the preview the user must confirm before anything is sent.
    /// Does not perform I/O.
    public func makePreview(question: String, selection: AIPreview.Selection) throws -> AIPreview {
        guard let config = configuration else { throw AIAssistantError.notConfigured }
        return AIPreview(
            id: UUID(),
            question: question,
            selection: selection,
            serviceHost: Self.displayHost(of: config),
            model: config.model,
            onDevice: config.displayName != nil)
    }

    /// Multi-evidence synthesis preview (PaperQA2-style): one question over
    /// several passages; the model must cite only from these. Caps the passage
    /// count to keep payloads bounded. Still zero network until confirmed.
    public func makeSynthesisPreview(question: String, selections: [AIPreview.Selection]) throws -> AIPreview {
        guard let config = configuration else { throw AIAssistantError.notConfigured }
        guard !selections.isEmpty else { throw AIAssistantError.invalidConfiguration("synthesis needs at least one passage") }
        let capped = Array(selections.prefix(Self.synthesisPassageLimit))
        guard let first = capped.first else { throw AIAssistantError.invalidConfiguration("synthesis needs at least one passage") }
        return AIPreview(
            id: UUID(),
            question: question,
            selection: first,
            selections: capped,
            serviceHost: Self.displayHost(of: config),
            model: config.model,
            onDevice: config.displayName != nil)
    }

    /// RCS 计划预览——单发综合预览形态 ＋ planSummary 计划披露
    /// （将发 N+1 次请求）。未确认零副作用（同 makeSynthesisPreview）。
    public func makeRCSPlanPreview(question: String, selections: [AIPreview.Selection]) throws -> AIPreview {
        guard let config = configuration else { throw AIAssistantError.notConfigured }
        guard !selections.isEmpty else { throw AIAssistantError.invalidConfiguration("synthesis needs at least one passage") }
        let capped = Array(selections.prefix(Self.synthesisPassageLimit))
        guard let first = capped.first else { throw AIAssistantError.invalidConfiguration("synthesis needs at least one passage") }
        let blocks = capped.count
        return AIPreview(
            id: UUID(),
            question: question,
            selection: first,
            selections: capped,
            serviceHost: Self.displayHost(of: config),
            model: config.model,
            planSummary: "本流程将发送 \(blocks + 1) 次请求（\(blocks) 块逐块评分＋1 次综合），"
                + "载荷全部由你确认的选区派生；逐块串行发送。",
            onDevice: config.displayName != nil
        )
    }

    /// 综述计划预览——单确认绑整计划（草稿＋自检循环），planSummary
    /// 写明轮数上限、载荷来源与「最终稿经你确认后才采用」。
    public func makeReviewPreview(question: String, selections: [AIPreview.Selection]) throws -> AIPreview {
        guard let config = configuration else { throw AIAssistantError.notConfigured }
        guard !selections.isEmpty else { throw AIAssistantError.invalidConfiguration("synthesis needs at least one passage") }
        let capped = Array(selections.prefix(Self.synthesisPassageLimit))
        guard let first = capped.first else { throw AIAssistantError.invalidConfiguration("synthesis needs at least one passage") }
        return AIPreview(
            id: UUID(),
            question: question,
            selection: first,
            selections: capped,
            serviceHost: Self.displayHost(of: config),
            model: config.model,
            planSummary: "本流程将发送 1 次草稿生成请求，随后自检至多 "
                + "\(ReviewSelfCheck.reviewSelfCheckMaxRounds) 轮：每轮 1 次逐断言检查＋至多 1 次改写"
                + "＋补引时每块评分 ≤1 次；全部载荷由你确认的选区与本地检索结果派生；"
                + "最终稿经你确认后才采用。",
            onDevice: config.displayName != nil
        )
    }

    /// 预览「服务」行显示名：displayName（端上档）优先；云端档案 nil 时与
    /// 前逐字节一致（host，无 host 则绝对串）。
    private static func displayHost(of config: AIConfiguration) -> String {
        if let displayName = config.displayName, !displayName.isEmpty { return displayName }
        return config.serviceURL.host ?? config.serviceURL.absoluteString
    }

    /// Passage cap for synthesis requests (payload-size sanity).
    public static let synthesisPassageLimit = 16

    /// Instruction carried in synthesis payloads: citations must come from the
    /// provided passages only.
    public static let synthesisCitationNote =
        "Answer using ONLY the passages in `selections`. Every claim must cite the " +
        "passage it came from as {\"bookId\": ..., \"page\": ...}. If the passages do " +
        "not contain the answer, say so explicitly."

    ///段级综合引用契约——selections 携带段号（para）时使用
    /// （send 按「任一 selection 带段号」自动选档；既有页级契约文案逐字不动，
    public static let synthesisCitationNoteWithParagraphs =
        "Answer using ONLY the passages in `selections`. Every claim must cite the " +
        "passage it came from as {\"bookId\": ..., \"page\": ..., \"para\": ...} where para is " +
        "the passage's `para=` number from the evidence header (0-based paragraph index " +
        "within the page). If the passages do not contain the answer, say so explicitly."

    /// Sends ONLY after a valid, explicit confirmation bound to this preview.
    /// Any other path returns/throws before the transport is touched.
    /// `cancellation` 可选透传给传输层（用户停止 → cancelled 错误）；
    /// nil 时语义与改动前完全一致。
    public func send(preview: AIPreview,
                     confirmation: AIConfirmation?,
                     transport: AITransport,
                     cancellation: AICancellationToken? = nil) async throws -> AIParsedResponse {
        guard let config = configuration else { throw AIAssistantError.notConfigured }
        guard let confirmation else { throw AIAssistantError.confirmationRequired }
        guard confirmation.explicit else { throw AIAssistantError.confirmationRequired }
        guard confirmation.previewID == preview.id else { throw AIAssistantError.confirmationMismatch }

        let payload: AIRequestPayload
        if preview.selections.isEmpty {
            payload = AIRequestPayload(
                model: config.model,
                question: preview.question,
                selection: AIRequestPayload.SelectionPayload(preview.selection)
            )
        } else {
            // Synthesis: every passage rides in `selections`; `selection` keeps
            // the first for payload-shape backward compatibility.
            //selections 携带段号（仅混合检索路径）→ 段级引用
            // 契约；既有页级路径 citationNote 逐字节不变。
            let note = preview.selections.contains { $0.para != nil }
                ? Self.synthesisCitationNoteWithParagraphs
                : Self.synthesisCitationNote
            payload = AIRequestPayload(
                model: config.model,
                question: preview.question,
                selection: AIRequestPayload.SelectionPayload(preview.selection),
                selections: preview.selections.map { AIRequestPayload.SelectionPayload($0) },
                citationNote: note
            )
        }

        let raw: String
        do {
            try cancellation?.check()   // 确认门通过后、出网前的最后一道闸
            raw = try await transport.send(config.serviceURL, payload: payload,
                                           apiKey: config.apiKey, cancellation: cancellation)
        } catch let error as AIAssistantError {
            throw error
        } catch {
            throw AIAssistantError.transport(String(describing: error))
        }
        return try Self.parseResponse(raw)
    }

    /// Parses {"answer": "...", "references": [{"bookId": "...", "page": N}]}.
    /// Lenient location (first JSON object in the text), strict shape.
    public static func parseResponse(_ raw: String) throws -> AIParsedResponse {
        guard let start = raw.firstIndex(of: "{") else {
            throw AIAssistantError.badResponse("no JSON object found")
        }
        let candidate = String(raw[start...])
        guard let data = candidate.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Attempt to trim to the matching brace.
            if let trimmed = trimmedJSONObject(in: candidate), let data = trimmed.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return try build(from: obj)
            }
            throw AIAssistantError.badResponse("response is not valid JSON")
        }
        return try build(from: obj)
    }

    private static func build(from obj: [String: Any]) throws -> AIParsedResponse {
        guard let answer = obj["answer"] as? String else {
            throw AIAssistantError.badResponse("missing 'answer' string")
        }
        var refs: [AIReference] = []
        if let arr = obj["references"] as? [[String: Any]] {
            for item in arr {
                guard let bookId = item["bookId"] as? String,
                      let page = item["page"] as? Int else { continue }
                //段级落点可选回读（缺键/非整数＝nil → 页级语义）。
                let para: Int?
                if let p = item["para"] as? Int {
                    para = p
                } else if let d = item["para"] as? Double, d == d.rounded() {
                    para = Int(d)
                } else {
                    para = nil
                }
                refs.append(AIReference(bookId: bookId, page: page,
                                        fingerprint: item["fingerprint"] as? String, para: para))
            }
        }
        return AIParsedResponse(answerText: answer, references: refs)
    }

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
