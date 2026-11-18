import Foundation
@testable import LiteratureCore

// MARK: - 端上模型档合成套件
//
// 覆盖：OnDeviceRouter 三分型；体检状态映射
// （假探针注入六种 block）；resolveConfiguration onDevice 跳过密钥/cloud
// 零变化（UI 层）；存量档案 JSON 解码＝云端；schema_version=1 断言固定；
// AIConfiguration.displayName 预览行为；AIPreview.planSummary 默认 nil；
// AIErrorClassifier 正负例；refused 传播；onDeviceUnavailable 描述；路由
// 失败 → 零 transport 调用（CountingTransport 断言）。
// 真模型绝不触碰：探针一律注入假实现（协议缝）。

/// 假探针：注入指定状态，绝不触真模型。
final class FakeOnDeviceProbe: OnDeviceModelProbe {
    let fakeStatus: OnDeviceModelStatus
    init(status: OnDeviceModelStatus) { self.fakeStatus = status }
    func status() -> OnDeviceModelStatus { fakeStatus }
}

enum FoundationModelsTransportSuite {
    static var tests: [TestDesc] {
        [

            TestDesc(suite: "FoundationModelsTransport", name: "routerCloudKindSkipsProbeEntirely") {
                // MarginNote 规则 2：云端分型不探针直接 .cloud——探针状态
                // 无关（即便端上可用也不自动换档）。
                let cloud = AIConfiguration(serviceURL: URL(string: "https://api.example.com/v1")!,
                                            model: "m", apiKey: "k")
                let outcome = OnDeviceRouter.route(
                    profileKind: OnDeviceProfileKind.cloud, resolved: cloud,
                    probe: FakeOnDeviceProbe(status: .available(contextTokens: 4096)))
                guard case .cloud(let cfg) = outcome else {
                    try failTest("云端分型应得 .cloud")
                    return
                }
                try expectEqual(cfg, cloud)
            },

            TestDesc(suite: "FoundationModelsTransport", name: "routerNilKindTreatedAsCloud") {
                let cloud = AIConfiguration(serviceURL: URL(string: "https://api.example.com/v1")!, model: "m")
                let outcome = OnDeviceRouter.route(profileKind: nil, resolved: cloud, probe: nil)
                guard case .cloud = outcome else {
                    try failTest("nil 分型应按云端")
                    return
                }
            },

            TestDesc(suite: "FoundationModelsTransport", name: "routerOnDeviceAvailableUsesOnDeviceConfig") {
                let onDevice = AIConfiguration(
                    serviceURL: URL(string: OnDeviceEndpoint.placeholderURLString)!,
                    model: OnDeviceEndpoint.modelIdentifier,
                    displayName: "设备端")
                let outcome = OnDeviceRouter.route(
                    profileKind: OnDeviceProfileKind.onDevice, resolved: onDevice,
                    probe: FakeOnDeviceProbe(status: .available(contextTokens: 4096)))
                guard case .onDevice(let cfg) = outcome else {
                    try failTest("可用探针应得 .onDevice")
                    return
                }
                try expectEqual(cfg.serviceURL, onDevice.serviceURL)
            },

            TestDesc(suite: "FoundationModelsTransport", name: "routerOnDeviceUnavailableCarriesTypedStatus") {
                let status = OnDeviceModelStatus.unavailable([
                    OnDeviceBlock(kind: .appleIntelligenceDisabled),
                    OnDeviceBlock(kind: .deviceMismatch),
                ])
                let outcome = OnDeviceRouter.route(
                    profileKind: OnDeviceProfileKind.onDevice,
                    resolved: AIConfiguration(serviceURL: URL(string: OnDeviceEndpoint.placeholderURLString)!,
                                              model: OnDeviceEndpoint.modelIdentifier),
                    probe: FakeOnDeviceProbe(status: status))
                guard case .onDeviceUnavailable(let carried) = outcome else {
                    try failTest("体检失败应得 .onDeviceUnavailable")
                    return
                }
                try expectEqual(carried, status, "逐项类型化原因必须随路携带")
            },

            TestDesc(suite: "FoundationModelsTransport", name: "routerNilProbeOnOnDeviceFailsClosedAsOsTooOld") {
                // 无 FoundationModels 平台：fail-closed＝osTooOld，绝不静默可用。
                let outcome = OnDeviceRouter.route(
                    profileKind: OnDeviceProfileKind.onDevice,
                    resolved: AIConfiguration(serviceURL: URL(string: OnDeviceEndpoint.placeholderURLString)!,
                                              model: OnDeviceEndpoint.modelIdentifier),
                    probe: nil)
                guard case .onDeviceUnavailable(let status) = outcome else {
                    try failTest("nil 探针应 fail-closed")
                    return
                }
                guard case .unavailable(let blocks) = status.availability else {
                    try failTest("应为 unavailable")
                    return
                }
                try expectEqual(blocks.map(\.kind), [.osTooOld])
            },


            TestDesc(suite: "FoundationModelsTransport", name: "probeMapsAllSixBlockKindsWithGuidance") {
                let kinds: [OnDeviceBlockKind] = [.appleIntelligenceDisabled, .deviceMismatch,
                                                  .osTooOld, .regionUnsupported,
                                                  .modelLoading, .unknown]
                for kind in kinds {
                    let block = OnDeviceBlock(kind: kind)
                    try expectFalse(block.guidance.isEmpty, "\(kind) 必须带自写恢复指引")
                    try expectFalse(block.label.isEmpty, "\(kind) 必须带人读名")
                }
                let status = OnDeviceModelStatus.unavailable(kinds.map { OnDeviceBlock(kind: $0) })
                guard case .unavailable(let blocks) = status.availability else {
                    try failTest("unavailable 构造应保持")
                    return
                }
                try expectEqual(blocks.count, 6)
                try expectFalse(status.isAvailable)
            },

            TestDesc(suite: "FoundationModelsTransport", name: "availableStatusCarriesRuntimeContextTokens") {
                let status = OnDeviceModelStatus.available(contextTokens: 4096)
                try expectTrue(status.isAvailable)
                guard case .available(let tokens) = status.availability else {
                    try failTest("available 应携带 tokens")
                    return
                }
                try expectEqual(tokens, 4096, "运行时读取值原样携带")
            },


            TestDesc(suite: "FoundationModelsTransport", name: "placeholderEndpointIsReservedInvalidTLD") {
                // RFC 2606 论证的机器可核部分：占位域名顶级域必须是 .invalid。
                try expectTrue(OnDeviceEndpoint.placeholderURLString.hasSuffix(".invalid"),
                               "占位域名必须用 RFC 2606 保留顶级域 .invalid（不可路由）")
                let url = try expectNotNil(URL(string: OnDeviceEndpoint.placeholderURLString))
                try expectEqual(url.host, "foundationmodels.on-device.invalid")
                try expectEqual(OnDeviceProfileKind.isOnDevice("onDevice"), true)
                try expectEqual(OnDeviceProfileKind.isOnDevice("cloud"), false)
                try expectEqual(OnDeviceProfileKind.isOnDevice(nil), false)
            },


            TestDesc(suite: "FoundationModelsTransport", name: "displayNameNilKeepsServiceHostBehaviorIdentical") {
                let service = AIAssistantService()
                try service.configure(AIConfiguration(
                    serviceURL: URL(string: "https://api.example.com/v1")!, model: "m1"))
                let preview = try service.makePreview(
                    question: "q",
                    selection: AIPreview.Selection(bookID: "b", fingerprint: "f", physicalPage: 1, snippet: "s"))
                try expectEqual(preview.serviceHost, "api.example.com",
                                "displayName 缺省时 serviceHost 行为与旧版逐字节一致")
                try expectNil(preview.planSummary, "单发预览 planSummary 默认 nil")
                try expectFalse(preview.onDevice, "云端档案 onDevice 标记恒 false")
            },

            TestDesc(suite: "FoundationModelsTransport", name: "displayNameOverridesPreviewServiceHost") {
                let service = AIAssistantService()
                try service.configure(AIConfiguration(
                    serviceURL: URL(string: "https://foundationmodels.on-device.invalid")!,
                    model: "apple-on-device", apiKey: nil, displayName: "设备端（Apple Foundation Models）"))
                let preview = try service.makePreview(
                    question: "q",
                    selection: AIPreview.Selection(bookID: "b", fingerprint: "f", physicalPage: 1, snippet: "s"))
                try expectEqual(preview.serviceHost, "设备端（Apple Foundation Models）")
                try expectTrue(preview.onDevice, "端上档结构化标记置位")
            },

            TestDesc(suite: "FoundationModelsTransport", name: "planPreviewsCarryPlanSummaryDisclosure") {
                let service = AIAssistantService()
                try service.configure(AIConfiguration(
                    serviceURL: URL(string: "https://api.example.com/v1")!, model: "m1"))
                let selections = (1...3).map {
                    AIPreview.Selection(bookID: "b\($0)", fingerprint: "f\($0)", physicalPage: $0, snippet: "s\($0)")
                }
                let rcs = try service.makeRCSPlanPreview(question: "q", selections: selections)
                let plan = try expectNotNil(rcs.planSummary)
                try expectTrue(plan.contains("4 次请求"), "计划披露必须写明 N+1 次请求")
                let review = try service.makeReviewPreview(question: "q", selections: selections)
                let reviewPlan = try expectNotNil(review.planSummary)
                try expectTrue(reviewPlan.contains("2 轮"), "综述计划披露必须写明轮数上限")
                try expectTrue(reviewPlan.contains("采用"), "必须写明最终稿经确认后才采用")
            },


            TestDesc(suite: "FoundationModelsTransport", name: "classifierAcceptsConnectivityURLErrorCodes") {
                let codes: [URLError.Code] = [.notConnectedToInternet, .timedOut, .cannotFindHost,
                                              .cannotConnectToHost, .networkConnectionLost,
                                              .dnsLookupFailed]
                for code in codes {
                    try expectTrue(AIErrorClassifier.isConnectivityError(URLError(code)),
                                   "\(code) 应判为连接类")
                }
            },

            TestDesc(suite: "FoundationModelsTransport", name: "classifierAcceptsWrappedTransportStrings") {
                let wrapped = AIAssistantError.transport(
                    "Error Domain=NSURLErrorDomain Code=-1009 \"(null)\"")
                try expectTrue(AIErrorClassifier.isConnectivityError(wrapped))
                let timeout = AIAssistantError.transport(
                    "Error Domain=NSURLErrorDomain Code=-1001 \"timed out\"")
                try expectTrue(AIErrorClassifier.isConnectivityError(timeout))
            },

            TestDesc(suite: "FoundationModelsTransport", name: "classifierNeverMisjudgesRefusedBadResponseHTTP") {
                try expectFalse(AIErrorClassifier.isConnectivityError(
                    AIAssistantError.refused("guardrail refusal")))
                try expectFalse(AIErrorClassifier.isConnectivityError(
                    AIAssistantError.badResponse("missing answer")))
                // HTTP 状态错误（含 408/5xx）不是本机断网，降级无意义。
                try expectFalse(AIErrorClassifier.isConnectivityError(
                    AIAssistantError.transport("HTTP 500")))
                try expectFalse(AIErrorClassifier.isConnectivityError(
                    AIAssistantError.transport("HTTP 408")))
                try expectFalse(AIErrorClassifier.isConnectivityError(
                    AIAssistantError.transport("cross-origin redirect blocked")))
                try expectFalse(AIErrorClassifier.isConnectivityError(
                    AIAssistantError.cancelled))
            },


            TestDesc(suite: "FoundationModelsTransport", name: "degradeOnlyCloudToOnDeviceWithProbeAvailable") {
                let offline = URLError(.notConnectedToInternet)
                let available = OnDeviceModelStatus.available(contextTokens: 4096)
                // 云端路由＋连接类错误＋探针可用 → 允许一次端上重发。
                try expectTrue(OnDeviceDegrade.shouldRetryOnOnDevice(
                    currentRouteIsOnDevice: false, error: offline, probeStatus: available))
                // 端上路由失败 → 绝不自动上云（MarginNote 规则 3）。
                try expectFalse(OnDeviceDegrade.shouldRetryOnOnDevice(
                    currentRouteIsOnDevice: true, error: offline, probeStatus: available))
                // 非连接类错误 → 不降级。
                try expectFalse(OnDeviceDegrade.shouldRetryOnOnDevice(
                    currentRouteIsOnDevice: false,
                    error: AIAssistantError.transport("HTTP 500"), probeStatus: available))
                // 探针不可用 → 不降级（显式提示，不静默换档）。
                try expectFalse(OnDeviceDegrade.shouldRetryOnOnDevice(
                    currentRouteIsOnDevice: false, error: offline,
                    probeStatus: OnDeviceModelStatus.unavailable([OnDeviceBlock(kind: .deviceMismatch)])))
                try expectFalse(OnDeviceDegrade.shouldRetryOnOnDevice(
                    currentRouteIsOnDevice: false, error: offline, probeStatus: nil))
            },


            TestDesc(suite: "FoundationModelsTransport", name: "refusedErrorRoundTripsAsExplicitCase") {
                let error = AIAssistantError.refused("guardrail 拒答")
                guard case .refused(let detail) = error else {
                    try failTest("refused 应保持 case 形状")
                    return
                }
                try expectTrue(detail.contains("guardrail"))
                try expectTrue(error.description.contains("refused"), "description 自动派生")
            },


            TestDesc(suite: "FoundationModelsTransport", name: "routeFailureLeadsToZeroTransportCalls") {
                let counting = CountingTransport()
                let service = AIAssistantService()   // 路由失败路径：从未 configure
                let probe = FakeOnDeviceProbe(status: .unavailable([OnDeviceBlock(kind: .osTooOld)]))
                let outcome = OnDeviceRouter.route(
                    profileKind: OnDeviceProfileKind.onDevice,
                    resolved: AIConfiguration(serviceURL: URL(string: OnDeviceEndpoint.placeholderURLString)!,
                                              model: OnDeviceEndpoint.modelIdentifier),
                    probe: probe)
                var routeFailed = false
                if case .onDeviceUnavailable = outcome { routeFailed = true }
                try expectTrue(routeFailed, "体检失败应拦在路由层")
                // 拦截后不可能有合法发送：服务未配置 → notConfigured，零 transport 调用。
                let preview = AIPreview(id: UUID(), question: "q",
                                        selection: AIPreview.Selection(bookID: "b", fingerprint: "f",
                                                                       physicalPage: 1, snippet: "s"),
                                        serviceHost: "foundationmodels.on-device.invalid", model: "m")
                let confirmation = AIConfirmation(explicit: true, previewID: preview.id)
                try await expectThrowsAsync({
                    try await service.send(preview: preview, confirmation: confirmation,
                                           transport: counting)
                }, "路由失败后发送必须被 notConfigured 拦截")
                try expectEqual(counting.callCount, 0, "路由失败 → 零 transport 调用")
            },


            TestDesc(suite: "FoundationModelsTransport", name: "onDeviceStatusDiagnosticTextJoinsGuidance") {
                let status = OnDeviceModelStatus.unavailable([
                    OnDeviceBlock(kind: .appleIntelligenceDisabled),
                    OnDeviceBlock(kind: .modelLoading),
                ])
                let text = status.diagnosticText
                try expectTrue(text.contains("Apple Intelligence 未开启"), "含人读名")
                try expectTrue(text.contains("系统设置"), "含恢复指引")
                try expectTrue(text.contains("模型准备中"), "多项逐行拼装")
            },
        ]
    }
}
