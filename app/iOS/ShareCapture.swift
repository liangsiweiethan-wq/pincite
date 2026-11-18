import Foundation

// MARK: - Share 回传 iOS 侧
//
// 本地待发队列 = annotations.db 外的轻量 JSON 队列（AppSupport/
// share-outbox.json）；WebDAV 配置在位时手动「立即发送」。文件名程序生成
// （ShareInbox.makeFileName），重名避让（随机段重试 ≤3，绝不覆盖既有
// 文件）；内容 = UTF-8 纯文本 ≤64KiB。禁轮询：只在显式动作触发。
// 远端路径 = ShareInbox.prefixDirectory + 白名单名（安全约束）。

struct ShareCapture: Codable, Equatable, ShareOutboxItem {
    var id: String
    var text: String
    var sourceLines: [String]
    var createdAt: Double

    /// Core 结算契约：队列身份 + 载荷。
    var outboxID: String { id }
    func outboxPayload() throws -> Data { try payload() }

    /// 组装入队（载荷立即校验——超限在入队时 fail-closed）。
    init(text: String, sourceLines: [String] = []) {
        id = UUID().uuidString
        self.text = text
        self.sourceLines = sourceLines
        createdAt = Date().timeIntervalSince1970
        // 构造不抛：超限在 enqueue 时校验（Codable 结构先建好再验）。
    }

    /// 载荷字节（ShareInbox.validatePayload 同一条校验）。
    func payload() throws -> Data {
        try ShareInbox.makePayload(text: text, sourceLines: sourceLines)
    }

    // MARK: 队列存取

    static var queueURL: URL {
        AppSupportPaths.appDirectory("share-outbox.json")
    }

    static func load() -> [ShareCapture] {
        guard let data = try? Data(contentsOf: queueURL),
              let items = try? JSONDecoder().decode([ShareCapture].self, from: data) else { return [] }
        return items
    }

    static func save(_ items: [ShareCapture]) throws {
        try FileManager.default.createDirectory(at: queueURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(items).write(to: queueURL, options: .atomic)
    }

    static func enqueue(_ capture: ShareCapture) throws {
        _ = try capture.payload()   // fail-closed：坏载荷不入队
        var items = load()
        items.append(capture)
        try save(items)
    }

    /// 发送全部待发件；返回已发送的 id（空数组 = 无待发或全部失败）。
    /// MKCOL 前缀（既有先例）→ 逐件 PUT，重名避让 ≤3。
    /// 结算算法移交 Core ShareOutbox.flush（可测核心）——
    /// 每件在循环内至多入队一次（问题：失败分支 append 后 throw 被
    /// 外层 catch 再 append = 双份入队）；队列一次性结算后才抛首个错误。
    static func flush(client: WebDAVClient) async throws -> [String] {
        try await client.makeCollection(path: ShareInbox.prefixDirectory)
        let items = load()
        guard !items.isEmpty else { return [] }
        let outcome = await ShareOutbox.flush(items) { payload, item in
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("share-\(item.id).txt")
            try payload.write(to: tmp, options: .atomic)
            defer { try? FileManager.default.removeItem(at: tmp) }
            // 重名避让：换名重试 ≤3（程序生成名，从不覆盖既有文件）；
            // 穷尽重试抛最后错误 = 本件失败（Core 侧恰一次入队）。
            var lastError: Error?
            for _ in 0..<3 {
                let name = ShareInbox.makeFileName()
                do {
                    _ = try await client.upload(fileURL: tmp,
                                                to: ShareInbox.prefixDirectory + "/" + name)
                    return
                } catch {
                    lastError = error
                }
            }
            throw lastError ?? ShareOutboxFailure.exhaustedRetries
        }
        try save(outcome.remaining)   // 队列恰一次结算（含失败件恰一份）
        if let error = outcome.error { throw error }
        return outcome.sent
    }
}

/// 上传重试穷尽的降级处理错误（闭包内 lastError 缺失时的 fail-closed 占位）。
enum ShareOutboxFailure: Error {
    case exhaustedRetries
}
