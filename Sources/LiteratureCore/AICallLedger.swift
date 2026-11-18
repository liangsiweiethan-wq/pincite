import Foundation

// MARK: - AI 调用账本（多段流程逐 leg 记账）
//
// 线程安全计数值类型；leg 列表＋汇总；
// 预览与结果卡共用同一实例。显示基准＝请求次数＋请求字节，绝不虚构
// token 数（端上档 Usage 仅 macOS 27+ 可得，如实不展示）。

public final class AICallLedger: @unchecked Sendable {
    /// 单次 transport 调用的记账行。
    public struct Leg: Equatable, Sendable {
        public let name: String
        public let requestBytes: Int
        public let ok: Bool

        public init(name: String, requestBytes: Int, ok: Bool) {
            self.name = name
            self.requestBytes = requestBytes
            self.ok = ok
        }
    }

    private let lock = NSLock()
    private var legs: [Leg] = []

    public init() {}

    /// 逐 leg 记账（每 leg 前 runner 已做取消检查；成败均记账如实显示）。
    public func record(name: String, requestBytes: Int, ok: Bool) {
        lock.lock()
        legs.append(Leg(name: name, requestBytes: requestBytes, ok: ok))
        lock.unlock()
    }

    public var entries: [Leg] {
        lock.lock(); defer { lock.unlock() }
        return legs
    }

    public var totalCount: Int { entries.count }
    public var okCount: Int { entries.filter(\.ok).count }
    public var failedCount: Int { totalCount - okCount }
    public var totalRequestBytes: Int { entries.reduce(0) { $0 + $1.requestBytes } }

    /// 汇总一行（结果卡/披露文案共用基准）：「N 次请求（成功 x／失败 y），共 z 字节」。
    public var summaryText: String {
        "共 \(totalCount) 次请求（成功 \(okCount)／失败 \(failedCount)），累计发送 \(totalRequestBytes) 字节"
    }

    public func reset() {
        lock.lock()
        legs.removeAll()
        lock.unlock()
    }
}

/// 便捷：payload 编码字节数（OpenAI 通道基准；端上通道 payload 形状同源）。
public enum AIRequestMetrics {
    public static func requestBytes(of payload: AIRequestPayload) -> Int {
        (try? OpenAIChatCompletionsAdapter.encode(payload).count) ?? 0
    }

    /// 综合形状载荷的字节数（低3：草稿 leg 记账用；App 层
    /// 不直构 AIRequestPayload——其 memberwise init 为 internal，载荷构造
    /// 统一收在 Core 同模块内）。
    public static func synthesisPayloadBytes(model: String, question: String,
                                             evidence: [AIRequestPayload.SelectionPayload],
                                             citationNote: String?) -> Int {
        guard let first = evidence.first else { return 0 }
        let payload = AIRequestPayload(model: model, question: question,
                                       selection: first, selections: evidence,
                                       citationNote: citationNote)
        return requestBytes(of: payload)
    }
}
