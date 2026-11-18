import Foundation

// MARK: - Share Extension 入站收录
//
// 规格：新 Share Extension target（app/ShareExtension）接收系统分享的
// PDF/URL → 写 App Group 容器收件箱 → 主 App 启动/前台时拉取合并到书库
//（fileReception 语义：复制入书域待索引目录，由既有索引扫描自动收录）。
//
// 约束：
//   · Extension 不持凭据、不直接访问书库（App Group 隔离）——本文件是
//     Extension target 编译的**唯一** Core 件（自包含：不 import/引用
//     WebDAV*/SecretStore/ShareInbox 任何凭据面符号）；写面只有 App Group
//     容器 inbox，读面只有收件箱自身。
//   · 主 App 拉取幂等（同名跳过）——pull 对同名不覆盖、成功后消费源件；
//     失败保留源件待下轮，绝不半写。
//
// 形制沿 ShareInbox 先例（程序生成文件名/白名单正则/fail-closed 校验/
// 64KiB 文本载荷），但**类型零共享**（Extension target 不连 WebDAV 面）；
// App Group ID 沿用既有 app/Support/LiteratureSearchiOS.entitlements 的
// group.com.example.literaturesearch.shared。
//
// 合并语义（fileReception）：PDF → 复制入书域原件目录（iOS 生产 =
// LibraryModel.originalsDirectory，即 Documents/Library 待索引域，既有索引
// 扫描/副本管线照常接管）；URL/文本 → 追加进 captures JSON（AppSupport/
// share-captures.json，与 share-outbox.json 出站件对称）。目标目录由调用方
// 注入——本文件不感知平台布局（纯函数可测）。
public enum ShareReceive {
    /// 既有 App Group（LiteratureSearchiOS.entitlements 同值；Extension
    /// entitlements 同键照抄——进组即通，无需新组）。
    public static let appGroupID = "group.com.example.literaturesearch.shared"
    /// App Group 容器内收件箱子目录。
    public static let inboxDirectoryName = "share-inbox"
    /// 文本载荷上限（ShareInbox.maxPayloadBytes 同值同纪律）。
    public static let maxPayloadBytes = 65_536
    /// 单文件上限（DoS 防护；ShareInbox.maxFileBytes 同值）。
    public static let maxFileBytes = 1 << 20

    // MARK: 文件名（程序生成；用户输入永不参与）

    /// 文件名白名单：`sharein-<8hex>-<10位时间戳>-<6位小写随机>.<pdf|txt>`。
    /// （字符串初始化而非裸斜杠字面量：包未开 bare-slash-regex 旗标，
    /// 照 ShareInbox.swift:26 先例。）
    public static let fileNameRegex = try! Regex(
        "^sharein-[0-9a-f]{8}-[0-9]{10}-[a-z0-9]{6}\\.(pdf|txt)$")

    public static func isAllowedFileName(_ name: String) -> Bool {
        name.wholeMatch(of: fileNameRegex) != nil
    }

    public enum Kind: String, Equatable, Sendable {
        case pdf
        case text

        /// 落盘扩展名（文本件 = .txt，与白名单正则同值）。
        var fileExtension: String {
            switch self {
            case .pdf: return "pdf"
            case .text: return "txt"
            }
        }
    }

    /// 程序生成文件名（随机段重试避让重名由调用方做；名撞即换名）。
    public static func makeFileName(kind: Kind, now: Date = Date(), random: String? = nil) -> String {
        let stamp = String(Int(now.timeIntervalSince1970))
        var suffix = random ?? UUID().uuidString.lowercased()
        suffix = String(suffix.filter { $0.isLetter || $0.isNumber }.lowercased().prefix(6))
        if suffix.count < 6 { suffix = (suffix + "000000").prefix(6).description }
        let hex8 = String(UUID().uuidString.prefix(8)).lowercased()
        return "sharein-\(hex8)-\(stamp)-\(suffix).\(kind.fileExtension)"
    }

    public static func kind(ofFileName name: String) -> Kind? {
        if name.hasSuffix(".pdf") { return .pdf }
        if name.hasSuffix(".txt") { return .text }
        return nil
    }

    // MARK: 载荷（文本件；PDF 为原始字节不经此）

    public enum ShareReceiveError: Error, Equatable, CustomStringConvertible {
        case payloadTooLarge(Int)
        case notUTF8
        case emptyPayload
        case appGroupUnavailable

        public static func == (a: ShareReceiveError, b: ShareReceiveError) -> Bool {
            String(describing: a) == String(describing: b)
        }

        public var description: String {
            switch self {
            case .payloadTooLarge(let n): return "分享载荷超上限（≤\(maxPayloadBytes)B，实际 \(n)B）"
            case .notUTF8: return "分享载荷不是合法 UTF-8 文本"
            case .emptyPayload: return "分享载荷为空"
            case .appGroupUnavailable: return "App Group 容器不可用（\(appGroupID)）"
            }
        }
    }

    /// 文本载荷（URL 入站走这里；# 注释元数据行形制照 ShareInbox.makePayload）。
    public static func makeTextPayload(text: String, sourceLines: [String] = []) throws -> Data {
        var body = ""
        for line in sourceLines where !line.isEmpty {
            body += "# \(line)\n"
        }
        body += text
        let data = Data(body.utf8)
        try validatePayload(data)
        return data
    }

    /// fail-closed 校验（ShareInbox.validatePayload 同一条纪律）：非空、
    /// 合法 UTF-8、≤64KiB、字节级往返一致（BOM/UTF-16 混入检测）。
    public static func validatePayload(_ data: Data) throws {
        guard !data.isEmpty else { throw ShareReceiveError.emptyPayload }
        guard data.count <= maxPayloadBytes else {
            throw ShareReceiveError.payloadTooLarge(data.count)
        }
        guard let decoded = String(data: data, encoding: .utf8), !decoded.isEmpty else {
            throw ShareReceiveError.notUTF8
        }
        guard Data(decoded.utf8) == data else { throw ShareReceiveError.notUTF8 }
    }

    // MARK: App Group 容器（生产路径；测试用注入目录，不依赖本函数）

    /// App Group 容器（无签名/组未授权环境返回 nil——调用方如实上报，
    /// 绝不静默落回 AppSupport 之类越权目录）。
    public static func groupContainer() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// 收件箱目录（容器下 share-inbox/；不自动创建——创建是写侧显式动作）。
    public static func inboxDirectory(in container: URL) -> URL {
        container.appendingPathComponent(inboxDirectoryName, isDirectory: true)
    }

    // MARK: 收件箱扫描（读侧；主 App 与测试共用）

    public struct InboxItem: Equatable, Sendable {
        public var name: String
        public var kind: Kind
        public var url: URL

        public init(name: String, kind: Kind, url: URL) {
            self.name = name
            self.kind = kind
            self.url = url
        }
    }

    /// 白名单过滤扫描（怪名一律不收——写路径失效的证据，只报告不下载不删）。
    public static func scanInbox(at directory: URL) -> [InboxItem] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return items
        .filter { !$0.hasDirectoryPath }
        .compactMap { url -> InboxItem? in
            let name = url.lastPathComponent
            guard isAllowedFileName(name), let kind = kind(ofFileName: name) else { return nil }
            return InboxItem(name: name, kind: kind, url: url)
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: 拉取合并（fileReception 语义；幂等）

    public struct PullOutcome: Equatable, Sendable {
        /// 合并入书域的 PDF 名。
        public var mergedPDFs: [String] = []
        /// 合并进 captures 的文本件名。
        public var mergedCaptures: [String] = []
        /// 目的地同名已存在 → 跳过（幂等；源件保留不删——同名说明已收过）。
        public var skippedExisting: [String] = []
        /// 白名单外怪名（只计数，永不动）。
        public var foreignSkipped = 0
        /// 校验/复制失败（源件保留待下轮）。
        public var failed: [String] = []
        public var bytes: Int64 = 0

        public init() {}
    }

    /// 入站文本捕获记录（captures JSON 数组元素；与出站 ShareCapture 对称）。
    public struct CaptureRecord: Codable, Equatable, Sendable {
        public var name: String
        public var text: String
        public var receivedAt: Double

        public init(name: String, text: String, receivedAt: Double) {
            self.name = name
            self.text = text
            self.receivedAt = receivedAt
        }
    }

    /// 拉取编排：扫描 → 逐件 fileReception → 成功即消费源件。
    ///   · PDF：目的地（书域待索引目录）同名存在 → skip（幂等）；
    ///     否则复制（>maxFileBytes 拒收、算 failed），成功删源件。
    ///   · text：载荷校验（≤64KiB/UTF-8）→ 追加 captures JSON（原子写）→
    ///     删源件；超限/坏载荷 → failed 保留源件。
    ///   · 怪名：foreignSkipped 计数，永不删。
    /// 目录不存在 = 空收件箱（不建不报错）——Extension 未写过任何件的常态。
    @discardableResult
    public static func pull(inbox: URL, originalsDirectory: URL,
                            capturesFile: URL, now: Date = Date()) -> PullOutcome {
        var outcome = PullOutcome()
        guard FileManager.default.fileExists(atPath: inbox.path) else { return outcome }
        let items = scanInbox(at: inbox)
        let all = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
        outcome.foreignSkipped = all.filter { !$0.hasDirectoryPath && !isAllowedFileName($0.lastPathComponent) }.count

        for item in items {
            switch item.kind {
            case .pdf:
                let dest = originalsDirectory.appendingPathComponent(item.name, isDirectory: false)
                if FileManager.default.fileExists(atPath: dest.path) {
                    outcome.skippedExisting.append(item.name)
                    continue
                }
                let size = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
                guard size <= maxFileBytes else {
                    outcome.failed.append(item.name)   // 超限拒收，源件保留
                    continue
                }
                do {
                    try FileManager.default.createDirectory(at: originalsDirectory,
                                                            withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: item.url, to: dest)
                    try FileManager.default.removeItem(at: item.url)   // 成功才消费
                    outcome.mergedPDFs.append(item.name)
                    outcome.bytes += size
                } catch {
                    outcome.failed.append(item.name)   // 半写不落地：保留源件下轮再试
                }
            case .text:
                do {
                    let data = try Data(contentsOf: item.url)
                    try validatePayload(data)
                    guard let text = String(data: data, encoding: .utf8) else {
                        outcome.failed.append(item.name)
                        continue
                    }
                    var records = loadCaptures(at: capturesFile)
                    records.append(CaptureRecord(name: item.name, text: text,
                                                 receivedAt: now.timeIntervalSince1970))
                    try FileManager.default.createDirectory(
                        at: capturesFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(records).write(to: capturesFile, options: .atomic)
                    try FileManager.default.removeItem(at: item.url)   // 成功才消费
                    outcome.mergedCaptures.append(item.name)
                    outcome.bytes += Int64(data.count)
                } catch {
                    outcome.failed.append(item.name)
                }
            }
        }
        return outcome
    }

    /// captures JSON 读侧（缺失/损坏 = 空表，不猜不炸）。
    public static func loadCaptures(at url: URL) -> [CaptureRecord] {
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([CaptureRecord].self, from: data) else {
            return []
        }
        return records
    }
}
