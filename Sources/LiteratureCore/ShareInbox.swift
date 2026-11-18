import Foundation

// MARK: - Share 回传 inbox（iPhone/iPad「存到 Mac」经 WebDAV
// inbox 目录回 Mac，Mac 侧 CLI webdav-inbox-pull 拉取）
//
// 远端前缀 `LiteratureSearch/sync/inbox/`（毗邻 WebDAVIndexPaths.uploadPrefix-
// Segments 的形制；既有 index 前缀与白名单正则零触碰—— 设计确认
// 只读复用）。inbox 有自己的文件名正则：程序生成文件名（时间戳+随机段），
// 拒用户输入远端路径（同款纪律；穿越串在正则处天然拒绝）。
// 内容 = UTF-8 纯文本 ≤ 64KiB（选段原文或 URL，可带书/页来源元数据行）。
// 无删除语义：Mac 拉取只下载、远端不删；同名即跳过（幂等）。
// 上传通道 = 既有 WebDAVClient.upload/MKCOL（受管前缀注册表扩展，
// 见 WebDAVClient.swift 注记；index 语义逐字节不变）。

public enum ShareInbox {
    // MARK: 远端布局

    /// inbox 前缀段（与 index 前缀共享 LiteratureSearch/sync 两段）。
    public static let prefixSegments = ["LiteratureSearch", "sync", "inbox"]
    /// 前缀目录（相对 serverBase；PROPFIND/MKCOL 用）。
    public static let prefixDirectory = prefixSegments.joined(separator: "/")

    /// 文件名白名单（逐条设计）：`share-<8hex>-<10位时间戳>-<6位小写随机>.txt`。
    /// （字符串初始化而非裸斜杠字面量：包未开 bare-slash-regex 旗标，
    /// 语义一致——照 WebDAVIndexManifest.swift:29 先例。）
    public static let fileNameRegex = try! Regex(
        "^share-[0-9a-f]{8}-[0-9]{10}-[a-z0-9]{6}\\.txt$")

    public static func isAllowedFileName(_ name: String) -> Bool {
        name.wholeMatch(of: fileNameRegex) != nil
    }

    /// 程序生成文件名（用户输入永不参与；随机段重试避让重名由调用方做）。
    /// now: epoch 秒（10 位）；random: 小写字母数字 6 位（缺省取 UUID）。
    public static func makeFileName(now: Date = Date(), random: String? = nil) -> String {
        let stamp = String(Int(now.timeIntervalSince1970))
        var suffix = random ?? UUID().uuidString.lowercased()
        // 归一到 [a-z0-9]{6}（UUID 去连字符后截断即可满足字符集）。
        suffix = String(suffix.filter { $0.isLetter || $0.isNumber }.lowercased().prefix(6))
        if suffix.count < 6 { suffix = (suffix + "000000").prefix(6).description }
        let hex8 = String(UUID().uuidString.prefix(8)).lowercased()
        return "share-\(hex8)-\(stamp)-\(suffix).txt"
    }

    // MARK: 载荷

    /// 内容上限 64KiB（UTF-8 字节）。
    public static let maxPayloadBytes = 65_536

    public enum ShareInboxError: Error, CustomStringConvertible {
        case payloadTooLarge(Int)
        case notUTF8
        case emptyPayload

        public var description: String {
            switch self {
            case .payloadTooLarge(let n): return "分享载荷超上限（≤\(maxPayloadBytes)B，实际 \(n)B）"
            case .notUTF8: return "分享载荷不是合法 UTF-8 文本"
            case .emptyPayload: return "分享载荷为空"
            }
        }
    }

    /// 组装载荷：可选元数据头（# 注释行）+ 正文。全部走 validate。
    public static func makePayload(text: String, sourceLines: [String] = []) throws -> Data {
        var body = ""
        for line in sourceLines where !line.isEmpty {
            body += "# \(line)\n"
        }
        body += text
        let data = Data(body.utf8)
        try validatePayload(data)
        return data
    }

    /// 校验（fail-closed）：非空、合法 UTF-8、≤64KiB。
    public static func validatePayload(_ data: Data) throws {
        guard !data.isEmpty else { throw ShareInboxError.emptyPayload }
        guard data.count <= maxPayloadBytes else {
            throw ShareInboxError.payloadTooLarge(data.count)
        }
        guard let decoded = String(data: data, encoding: .utf8), !decoded.isEmpty else {
            throw ShareInboxError.notUTF8
        }
        // 二次确认字节级往返一致（带 BOM/损坏序列拒绝——UTF-16 混入检测）。
        guard Data(decoded.utf8) == data else { throw ShareInboxError.notUTF8 }
    }

    // MARK: 拉取侧上限（Mac CLI webdav-inbox-pull；DoS 防护——同构）

    /// 单文件上限 1 MiB（PROPFIND getcontentlength 声明值预检 + 下载双保险）。
    public static let maxFileBytes: Int64 = 1 << 20
    /// 单批总量上限 64 MiB。
    public static let maxTotalBytes: Int64 = 64 << 20

    /// 拉取白名单过滤：PROPFIND 列表 → 合法 inbox 文件名 + 非 .txt 例外全拒。
    /// （目录/怪名一律滤除——怪名根本不该出现在 inbox，出现即视为此前
    /// 写路径失效的证据，绝不尝试下载。）
    public static func filterListing(_ resources: [WebDAVResource]) -> [WebDAVResource] {
        resources.filter { !$0.isDirectory && isAllowedFileName($0.fileName) }
    }
}

// MARK: - Mac 侧拉取引擎（CLI webdav-inbox-pull 的可测核心，
// CLI 子命令是薄壳——literaturesearch-cli 是独立 target 进不了合成测试，
// 编排逻辑全部收在这里离线覆盖。）

/// 注入点：list + download（生产 = WebDAVClient；测试 = 桩）。
public protocol ShareInboxLoading {
    func list(directory: String) async throws -> [WebDAVResource]
    func download(remotePath: String, to local: URL, expectedBytes: Int64?) async throws
}

public final class ShareInboxPuller {
    public struct PullOutcome: Equatable {
        public var downloaded: [String] = []
        public var skippedExisting: [String] = []
        /// 声明 size 超 maxFileBytes（DoS 预检拒下）。
        public var skippedOversize: [String] = []
        /// 白名单外怪名（不下载——写路径失效的证据，只报告）。
        public var foreignSkipped = 0
        public var bytes: Int64 = 0
        /// 总量预算（maxTotalBytes）耗尽提前停。
        public var stoppedForBudget = false

        public init() {}
        public static func == (a: PullOutcome, b: PullOutcome) -> Bool {
            a.downloaded == b.downloaded && a.skippedExisting == b.skippedExisting
                && a.skippedOversize == b.skippedOversize && a.foreignSkipped == b.foreignSkipped
                && a.bytes == b.bytes && a.stoppedForBudget == b.stoppedForBudget
        }
    }

    public let loader: ShareInboxLoading
    /// 本地落点（生产 = AppSupport/LiteratureSearch/inbox/）。
    public let into: URL

    public init(loader: ShareInboxLoading, into: URL) {
        self.loader = loader
        self.into = into
    }

    /// 凭据守卫（CLI 与测试共用一条；webdav-sync 先例同形）：
    /// 用户名/密码任一缺失 → credentialMissing 明确报错，绝不静默空跑。
    public static func validateCredentials(username: String, password: String) throws {
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty,
              !password.isEmpty else {
            throw WebDAVError.credentialMissing
        }
    }

    /// 拉取编排：PROPFIND inbox 前缀 → 白名单过滤 → 预检（本地同名跳过/
    /// 超限跳过/预算停）→ 逐文件下载（expectedBytes= 声明值，双保险）。
    /// 远端不删（无删除语义）；本地已存在同名即跳过（幂等）。
    public func pull() async throws -> PullOutcome {
        try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
        var outcome = PullOutcome()
        let listing = try await loader.list(directory: ShareInbox.prefixDirectory)
        let candidates = ShareInbox.filterListing(listing)
        outcome.foreignSkipped = listing.filter { !$0.isDirectory }.count - candidates.count
        var budget = Int64(0)
        for resource in candidates.sorted(by: { $0.path < $1.path }) {
            let name = resource.fileName
            let local = into.appendingPathComponent(name, isDirectory: false)
            // 同名幂等跳过（已存在 = 上批已拉，远端不覆盖本地）。
            if FileManager.default.fileExists(atPath: local.path) {
                outcome.skippedExisting.append(name)
                continue
            }
            // 单文件上限（声明值预检——getcontentlength 缺失时无法预检，
            // 交给下载侧 expectedBytes 双保险）。
            if resource.sizeDeclared, resource.size > ShareInbox.maxFileBytes {
                outcome.skippedOversize.append(name)
                continue
            }
            if budget + max(resource.size, 0) > ShareInbox.maxTotalBytes {
                outcome.stoppedForBudget = true
                break
            }
            try await loader.download(remotePath: ShareInbox.prefixDirectory + "/" + name,
                                      to: local, expectedBytes: resource.sizeDeclared ? resource.size : nil)
            outcome.downloaded.append(name)
            outcome.bytes += resource.size
            budget += resource.size
        }
        return outcome
    }
}

/// 生产实现：包既有 WebDAVClient（list/download 同走 transferSession 与
/// RedirectGuard；凭据只经 Basic 头发往 validatedBase 同一 host）。
public final class WebDAVShareInboxLoader: ShareInboxLoading {
    private let client: WebDAVClient

    public init(client: WebDAVClient) {
        self.client = client
    }

    public func list(directory: String) async throws -> [WebDAVResource] {
        try await client.list(directory: directory)
    }

    public func download(remotePath: String, to local: URL, expectedBytes: Int64?) async throws {
        try await client.download(remotePath: remotePath, to: local, expectedBytes: expectedBytes)
    }
}
