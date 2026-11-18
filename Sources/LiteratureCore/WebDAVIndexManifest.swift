import Foundation
import CryptoKit

// MARK: - 方案一 索引上传：manifest 模型 + 远端名白名单 + 路径编码

/// 上传目录前缀与文件名白名单（安全约束）。
public enum WebDAVIndexPaths {
    /// 写死前缀：LiteratureSearch/sync/index/。
    public static let uploadPrefixSegments = ["LiteratureSearch", "sync", "index"]
    /// 前缀目录（相对 serverBase，供 list/MKCOL 用）。
    public static let uploadPrefixDirectory = uploadPrefixSegments.joined(separator: "/")

    public static let snapshotNameRegex = try! Regex(
        "^(index|fulltext)-[0-9a-f]{16}(-part[1-9][0-9]*)?\\.sqlite$")
    /// manifest 文件名白名单（规则 逐字同形）。
    public static let manifestNameRegex = try! Regex("^manifest\\.json$")

    /// 远端文件名是否在白名单内（wholeMatch：部分匹配一律拒）。
    public static func isAllowedRemoteName(_ name: String) -> Bool {
        name.wholeMatch(of: snapshotNameRegex) != nil
            || name.wholeMatch(of: manifestNameRegex) != nil
    }

    static let unreservedExtra = "-._~"

    public static func encodeSegment(_ raw: String) -> String? {
        guard !raw.isEmpty, !raw.contains("/") else { return nil }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" + unreservedExtra)
        return raw.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    /// 逐段编码后拼 URL。任一还原段为 `..`、含 `?` 或 `#` → nil；
    /// 空段列表 = serverBase 根（保留既有 remoteDir "/" 语义）。
    /// base 的 path 各段同样过编码与穿越检查（用户可配，属不可信输入）。
    public static func remoteURL(base: URL, segments: [String]) -> URL? {
        var encoded: [String] = []
        for seg in base.path.split(separator: "/").map(String.init) + segments {
            if seg == ".." || seg.contains("?") || seg.contains("#") { return nil }
            guard let e = encodeSegment(seg) else { return nil }
            encoded.append(e)
        }
        var comps = URLComponents()
        comps.scheme = base.scheme
        comps.host = base.host
        comps.port = base.port
        comps.percentEncodedPath = "/" + encoded.joined(separator: "/")
        return comps.url
    }

    /// 上传专用 URL：必须恰好落在上传前缀内且文件名过白名单。
    /// 违例返回 nil（调用方转明确错误，零网络调用）。
    public static func uploadURL(base: URL, fileName: String) -> URL? {
        guard isAllowedRemoteName(fileName) else { return nil }
        return remoteURL(base: base, segments: uploadPrefixSegments + [fileName])
    }

    /// 校验一条相对 serverBase 的远端路径是否为受管上传目录内文件
    /// （前缀 + 白名单名）。客户端 PUT/MOVE/DELETE 的唯一通行证。
    public static func validatedUploadSegments(_ remotePath: String) -> [String]? {
        let decoded = remotePath.removingPercentEncoding ?? remotePath
        let segments = decoded.split(separator: "/").map(String.init)
        guard segments.count == uploadPrefixSegments.count + 1,
              Array(segments.prefix(uploadPrefixSegments.count)) == uploadPrefixSegments,
              isAllowedRemoteName(segments.last!) else { return nil }
        return segments
    }
}

// MARK: - manifest 模型（字段与逐条记录对齐）

public struct WebDAVIndexManifest: Codable, Equatable {
    public struct FileEntry: Codable, Equatable {
        public var name: String
        public var sha256: String
        public var size: Int64
        public var order: Int

        public init(name: String, sha256: String, size: Int64, order: Int) {
            self.name = name
            self.sha256 = sha256
            self.size = size
            self.order = order
        }

        enum CodingKeys: String, CodingKey {
            case name, sha256, size, order
        }
    }

    /// 快照生成时的 IndexStore.currentSchemaVersion。
    public var schemaVersion: Int
    /// 内容校验和（规范化规则见 contentHash(for:)，断言固定不改）。
    public var contentHash: String
    public var bookCount: Int
    public var pageCount: Int
    /// ISO8601 UTC 字符串。
    public var createdAt: String
    public var appVersion: String
    /// 显式列出全部快照分卷，包括单卷快照。
    public var files: [FileEntry]

    public init(schemaVersion: Int, contentHash: String, bookCount: Int, pageCount: Int,
                createdAt: String, appVersion: String, files: [FileEntry]) {
        self.schemaVersion = schemaVersion
        self.contentHash = contentHash
        self.bookCount = bookCount
        self.pageCount = pageCount
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.files = files
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case contentHash = "content_hash"
        case bookCount = "book_count"
        case pageCount = "page_count"
        case createdAt = "created_at"
        case appVersion = "app_version"
        case files
    }

    /// content_hash 规范化规则（断言固定； 手机侧按同一规则复算，
    /// 规则一旦改动即破坏跨端兼容——慎重）：
    /// 对 files 按 order 升序排序后，逐行拼接 `name|sha256|size|\n`
    /// （行尾竖线+换行），取整串 UTF-8 的 sha256。单卷/多卷同规则。
    public static func contentHash(for files: [FileEntry]) -> String {
        let canonical = files
            .sorted { $0.order < $1.order }
            .map { "\($0.name)|\($0.sha256)|\($0.size)|\n" }
            .joined()
        return Fingerprint.sha256Hex(of: Data(canonical.utf8))
    }

    /// ISO8601 UTC（与 createdAt 同一格式化器，往返一致）。
    public static let iso8601UTC: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// 确定性 JSON（键排序+美化）：同 manifest 字节级一致，便于比对与缓存。
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// 解析远端 manifest；解析失败抛错（调用方 fail-closed）。
    public static func parse(_ data: Data) throws -> WebDAVIndexManifest {
        try JSONDecoder().decode(WebDAVIndexManifest.self, from: data)
    }
}
