import Foundation

// MARK: - Share 回传待发队列结算算法

/// 待发件最小契约（iOS ShareCapture 遵守；测试桩就地实现）。
public protocol ShareOutboxItem {
    /// 队列身份（发送成功回执按此上报）。
    var outboxID: String { get }
    /// 上传载荷（fail-closed：抛错 = 本件失败，进 remaining）。
    func outboxPayload() throws -> Data
}

public struct ShareOutboxOutcome<Item> {
    public var sent: [String] = []
    /// 留队件（含载荷校验失败与上传失败件）——恰一份，顺序保持。
    public var remaining: [Item] = []
    /// 首个错误（全部件处理完才回传；nil = 全部成功）。
    public var error: Error?
}

public enum ShareOutbox {

    /// 逐件上传结算。`upload` 收（载荷, 件）并完成实际上传（重名避让与
    /// ≤3 次换名重试语义由闭包内自治——闭包穷尽重试后抛错即本件失败，
    public static func flush<Item: ShareOutboxItem>(
        _ items: [Item],
        upload: (_ payload: Data, _ item: Item) async throws -> Void
    ) async -> ShareOutboxOutcome<Item> {
        var outcome = ShareOutboxOutcome<Item>()
        for item in items {
            do {
                let payload = try item.outboxPayload()   // 载荷校验失败 = 本件失败（不抛出循环）
                try await upload(payload, item)
                outcome.sent.append(item.outboxID)
            } catch {
                outcome.remaining.append(item)           // 恰一次入队
                if outcome.error == nil { outcome.error = error }
            }
        }
        return outcome
    }
}
