import Foundation

// MARK: - 端上模型档（Apple Foundation Models transport ＋ 类型化体检

// MARK: 防护外：档案分型常量与占位端点（Foundation-only，iOS 门可编译、可测）

/// 档案分型（AIProfile.kind 字段的合法值）。nil/"cloud"＝云端 OpenAI 形状；
/// "onDevice"＝端上档。
public enum OnDeviceProfileKind {
    public static let cloud = "cloud"
    public static let onDevice = "onDevice"

    public static func isOnDevice(_ kind: String?) -> Bool { kind == onDevice }
}

/// 端上档占位端点。`.invalid` 顶级域由 RFC 2606 保留、永不解析（见文件头
/// 论证 1）；端上 transport 不使用它，误经既有网络通道必然 DNS 失败＝显式错误。
public enum OnDeviceEndpoint {
    public static let placeholderURLString = "https://foundationmodels.on-device.invalid"
    public static let modelIdentifier = "apple-on-device"
}

// MARK: 防护外：类型化体检值类型（FoundationModelsKit 思想：不可用＝原因＋恢复指引）

public enum OnDeviceBlockKind: String, Codable, CaseIterable, Sendable {
    case appleIntelligenceDisabled
    case deviceMismatch
    case osTooOld
    case regionUnsupported
    case modelLoading
    case unknown
}

/// 单项不可用原因＋自写恢复指引。指引文案集中一处，按 kind 派发。
public struct OnDeviceBlock: Equatable, Sendable {
    public let kind: OnDeviceBlockKind
    /// 自写恢复指引（用户可执行的下一步）。
    public let guidance: String

    public init(kind: OnDeviceBlockKind, guidance: String? = nil) {
        self.kind = kind
        self.guidance = guidance ?? Self.defaultGuidance(for: kind)
    }

    /// 自写文案（对应六类：Apple Intelligence 开关／机型／系统版本／地区／
    /// 模型准备中／未知）。
    public static func defaultGuidance(for kind: OnDeviceBlockKind) -> String {
        switch kind {
        case .appleIntelligenceDisabled:
            return "Apple Intelligence 未开启：请到 系统设置 → Apple Intelligence 与 Siri 打开后重试。"
        case .deviceMismatch:
            return "本机型不在 Apple Intelligence 支持列表：此设备无法使用端上模型，请改绑云端档案。"
        case .osTooOld:
            return "系统版本过低：端上模型要求 macOS 26 或更高版本，请升级系统后重试。"
        case .regionUnsupported:
            return "当前地区暂不支持 Apple Intelligence：请继续使用云端档案。"
        case .modelLoading:
            return "端上模型正在下载或准备中：请稍后重试，或先使用云端档案。"
        case .unknown:
            return "端上模型暂不可用（原因未知）：请检查系统设置中的 Apple Intelligence 状态，或继续使用云端档案。"
        }
    }

    /// 人读名（体检卡/错误描述用；与 L10n 解耦——Core 层判别串，先例
    /// SearchService 零命中解释文案）。
    public var label: String {
        switch kind {
        case .appleIntelligenceDisabled: return "Apple Intelligence 未开启"
        case .deviceMismatch: return "机型不支持"
        case .osTooOld: return "系统版本过低"
        case .regionUnsupported: return "地区不支持"
        case .modelLoading: return "模型准备中"
        case .unknown: return "原因未知"
        }
    }
}

/// 端上模型体检结果。available 携带运行时读到的上下文窗 token 数
public struct OnDeviceModelStatus: Equatable, Sendable {
    public enum Availability: Equatable, Sendable {
        case available(contextTokens: Int)
        case unavailable([OnDeviceBlock])
    }

    public let availability: Availability

    public init(availability: Availability) { self.availability = availability }

    public static func available(contextTokens: Int) -> OnDeviceModelStatus {
        OnDeviceModelStatus(availability: .available(contextTokens: contextTokens))
    }

    public static func unavailable(_ blocks: [OnDeviceBlock]) -> OnDeviceModelStatus {
        OnDeviceModelStatus(availability: .unavailable(blocks))
    }

    public var isAvailable: Bool {
        if case .available = availability { return true }
        return false
    }

    /// 逐项「人读名：指引」拼装（错误描述/体检卡共用）。
    public var diagnosticText: String {
        switch availability {
        case .available(let tokens):
            return "端上模型可用（上下文窗 \(tokens) tokens）"
        case .unavailable(let blocks):
            return blocks.map { "\($0.label)：\($0.guidance)" }.joined(separator: "；")
        }
    }
}

/// 可用性探针协议（测试注入假探针，绝不触真模型；生产实现走系统框架）。
public protocol OnDeviceModelProbe: Sendable {
    func status() -> OnDeviceModelStatus
}

// MARK: 防护外：分型路由（界限写死：体检失败＝可降级项；解析失败＝不可降级项）

public enum OnDeviceRouteOutcome: Equatable {
    case cloud(AIConfiguration)
    case onDevice(AIConfiguration)
    case onDeviceUnavailable(OnDeviceModelStatus)
}

public enum OnDeviceRouter {
    /// 分型路由。`resolved` 是 AIProfilesStore.resolveConfiguration 的产物
    /// （云端＝HTTPS 配置；端上＝占位配置）。体检失败返回 .onDeviceUnavailable
    /// （可降级项：路由层显式提示原因，调用方把它变类型化错误，不静默回退）；
    /// 配置解析失败不经此路由（既有 fail-closed 语义零变化＝不可降级项）。
    /// 云端分型不探针直接 .cloud（MarginNote 规则 2：不支持机型保留云端通路）。
    public static func route(profileKind: String?,
                             resolved: AIConfiguration,
                             probe: OnDeviceModelProbe?) -> OnDeviceRouteOutcome {
        guard OnDeviceProfileKind.isOnDevice(profileKind) else { return .cloud(resolved) }
        guard let probe else {
            // 平台无 FoundationModels（编译门未过）＝按 osTooOld fail-closed。
            return .onDeviceUnavailable(.unavailable([OnDeviceBlock(kind: .osTooOld)]))
        }
        let status = probe.status()
        switch status.availability {
        case .available:
            return .onDevice(resolved)
        case .unavailable:
            return .onDeviceUnavailable(status)
        }
    }
}

// MARK: 防护外：连接错误分类器（断网降级判定的正负例边界）

public enum AIErrorClassifier {
    /// 网络层连接类错误码（URLError rawValue）：断网／超时／找不到主机／
    /// 无法连主机／连接丢失／DNS 失败。HTTP 4xx/5xx、refused、badResponse
    /// 绝不在此列。
    static let connectivityCodes: Set<Int> = [
        URLError.notConnectedToInternet.rawValue,
        URLError.timedOut.rawValue,
        URLError.cannotFindHost.rawValue,
        URLError.cannotConnectToHost.rawValue,
        URLError.networkConnectionLost.rawValue,
        URLError.dnsLookupFailed.rawValue,
    ]

    /// 是否连接类错误。两种来路都认：URLError 实例（直接判 code）与
    /// transport 包裹串（"Error Domain=NSURLErrorDomain Code=-1009 …" 形态，
    /// 用 `Code=<n>` 精确抽取，不做全文模糊匹配）。
    public static func isConnectivityError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return connectivityCodes.contains(urlError.errorCode)
        }
        if let assistantError = error as? AIAssistantError {
            switch assistantError {
            case .transport(let message):
                return matchesWrapped(message)
            default:
                // refused / badResponse / HTTP 状态串等永不判为连接类
                //（HTTP 408/5xx 属服务端状态，不是本机断网，降级无意义）。
                return false
            }
        }
        return matchesWrapped(String(describing: error))
    }

    /// 包裹串匹配：抽取 `Code=<整数>` 与连接类码集比对。
    static func matchesWrapped(_ message: String) -> Bool {
        guard let range = message.range(of: "Code=(-?\\d+)", options: .regularExpression) else {
            return false
        }
        let digits = message[range].replacingOccurrences(of: "Code=", with: "")
        guard let code = Int(digits) else { return false }
        return connectivityCodes.contains(code)
    }
}

// MARK: 防护外：断网降级判定（方向性写死的纯函数）

public enum OnDeviceDegrade {
    /// 断网降级判定：仅「云端→端上」自动（数据出设备面只减不增）且须披露；
    /// 「端上→云端」自动重试路径在本设计内不存在（恒 false）——端上失败
    /// 显式报错，上云必须用户显式改绑云端档案并重新过预览确认。
    public static func shouldRetryOnOnDevice(currentRouteIsOnDevice: Bool,
                                             error: Error,
                                             probeStatus: OnDeviceModelStatus?) -> Bool {
        // 端上路由失败：绝不自动上云（MarginNote 规则 3）。
        guard !currentRouteIsOnDevice else { return false }
        // 只有连接类错误才降级；refused/HTTP 状态错误降级无意义。
        guard AIErrorClassifier.isConnectivityError(error) else { return false }
        // 探针可用才降级；体检失败保留原错误（显式提示，不静默换档）。
        guard let probeStatus, probeStatus.isAvailable else { return false }
        return true
    }
}

// MARK: 防护内／外：生产探针与 transport 工厂

#if canImport(FoundationModels) && os(macOS)
// FoundationModels 专属代码唯一宿主（全 Sources/ 仅本文件可 import）。
// 编译门 canImport＋os(macOS)；运行时门 #available(macOS 26.0, *)（部署线仍 13）。
import FoundationModels

/// 生产探针：运行时读 SystemLanguageModel.default 的 availability 与
/// contextSize（不硬编码 4096），映射到本库类型化状态。regionUnsupported
/// 在当前 SDK 的 UnavailableReason 中无独立 case（仅 deviceNotEligible /
/// appleIntelligenceNotEnabled / modelNotReady 三项）——保留该 block 种类作
/// 类型完备，真实设备上如遇地区限制将落入 unknown，如实呈现不虚构归因。
struct SystemLanguageModelProbe: OnDeviceModelProbe {
    func status() -> OnDeviceModelStatus {
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return .available(contextTokens: model.contextSize)
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled:
                    return .unavailable([OnDeviceBlock(kind: .appleIntelligenceDisabled)])
                case .deviceNotEligible:
                    return .unavailable([OnDeviceBlock(kind: .deviceMismatch)])
                case .modelNotReady:
                    return .unavailable([OnDeviceBlock(kind: .modelLoading)])
                @unknown default:
                    return .unavailable([OnDeviceBlock(kind: .unknown)])
                }
            }
        } else {
            return .unavailable([OnDeviceBlock(kind: .osTooOld)])
        }
    }
}

/// 端上 transport：进程内系统框架生成。endpoint/apiKey 忽略（占位 URL 永不
/// 出网，mock 惯例同款）；guardrail 拒答显式 refused；模型生成中不可中断
struct FoundationModelsAITransport: AITransport {
    /// 生成参数：GenerationOptions 可表达子集（maximumResponseTokens 对齐
    /// OpenAI 通道 encode 的 max_tokens=2048）；payload 未携带温度/采样等，
    /// 无从映射即显式不设（超集忽略，预览 planSummary 注明）。
    private static let maximumResponseTokens = 2048

    static var systemInstructions: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return "你是文献检索工具的端上助手。今天的日期是 \(formatter.string(from: Date()))。"
            + "只依据用户提供的材料回答；材料不含答案时如实说明，不编造。"
    }

    func send(_ endpoint: URL, payload: AIRequestPayload, apiKey: String?,
              cancellation: AICancellationToken?) async throws -> String {
        // 端上档零出网：endpoint/apiKey 形参按 mock 惯例忽略。
        try cancellation?.check()   // send 前检查
        guard #available(macOS 26.0, *) else {
            throw AIAssistantError.invalidConfiguration("端上模型要求 macOS 26 或更高版本")
        }
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw AIAssistantError.invalidConfiguration("端上模型不可用：\(reason)")
        }

        let question = Self.promptText(for: payload)
        let options = GenerationOptions(maximumResponseTokens: Self.maximumResponseTokens)
        let session = LanguageModelSession(model: model, instructions: Self.systemInstructions)
        let answer: String
        do {
            let response = try await session.respond(to: question, options: options)
            answer = response.content
        } catch {
            if error is CancellationError { throw AIAssistantError.cancelled }
            #if compiler(>=6.4)
            if #available(macOS 27.0, *), let lmError = error as? LanguageModelError {
                // macOS 27+：LanguageModelError 为现行错误类型。
                switch lmError {
                case .refusal, .guardrailViolation:
                    throw AIAssistantError.refused(String(describing: lmError))
                default:
                    throw AIAssistantError.transport(String(describing: lmError))
                }
            }
            #endif
            if let generationError = error as? LanguageModelSession.GenerationError {
                switch generationError {
                case .refusal, .guardrailViolation:
                    throw AIAssistantError.refused(String(describing: generationError))
                default:
                    throw AIAssistantError.transport(String(describing: generationError))
                }
            }
            throw AIAssistantError.transport(String(describing: error))
        }
        try cancellation?.check()
        return answer
    }

    /// 请求载荷 → 单条 prompt（证据块沿 encode 的锚头语义拼装，页码锚点
    /// 原样保留，模型可引用）。
    static func promptText(for payload: AIRequestPayload) -> String {
        let selections = payload.selections ?? [payload.selection]
        let evidence = selections.enumerated().map { index, selection in
            "[\(index + 1)] bookId=\(selection.bookId), page=\(selection.page), fingerprint=\(selection.fingerprint), source=\(selection.source ?? "native"), ocrPage=\(selection.ocrPage.map(String.init) ?? "unknown")\n\(selection.snippet)"
        }.joined(separator: "\n\n")
        return "Question: \(payload.question)\n\nEvidence:\n\(evidence)\n\n\(payload.citationNote ?? "Answer from only the supplied excerpts.")"
    }
}

/// 生产工厂：App 层经此取探针/transport，FoundationModels 类型不出本文件。
public func makeOnDeviceModelProbe() -> OnDeviceModelProbe? {
    SystemLanguageModelProbe()
}

public func makeOnDeviceAITransport() -> AITransport? {
    FoundationModelsAITransport()
}

#else

/// 无 FoundationModels 平台（iOS 门直编等）：fail-closed 返回 nil，
/// 路由层按「系统版本过低」类型化呈现，绝不静默假装可用。
public func makeOnDeviceModelProbe() -> OnDeviceModelProbe? { nil }
public func makeOnDeviceAITransport() -> AITransport? { nil }

#endif
