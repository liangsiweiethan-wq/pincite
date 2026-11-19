import Foundation
import CryptoKit

// MARK: - 只读索引副本：下载与校验引擎（iPhone 安全

/// 远端路径常量（前缀复用 上传前缀；只读复用，不改白名单）。
public enum IndexReplicaRemote {
    /// manifest 固定远端路径（前缀来自 WebDAVIndexPaths.uploadPrefixDirectory）。
    public static var manifestPath: String {
        WebDAVIndexPaths.uploadPrefixDirectory + "/manifest.json"
    }
    /// 快照卷远端路径（前缀 + 白名单名）。
    public static func volumePath(_ name: String) -> String {
        WebDAVIndexPaths.uploadPrefixDirectory + "/" + name
    }
}

/// 注入点：manifest 拉取 + 分卷下载（生产 = WebDAVReplicaLoader；测试 = 桩）。
public protocol ReplicaLoading {
    /// GET 小文件（manifest）进内存。
    func data(for remotePath: String) async throws -> (Data, URLResponse)
    /// 流式下载到盘（重试/上限由实现负责；引擎不重复包装）。
    func download(remotePath: String, to local: URL, expectedBytes: Int64?) async throws
}

/// 生产实现：包既有 WebDAVClient（RedirectGuard/8GiB 上限/重试 ≤3 已内置，
/// 引擎零重复）。GET 与下载同走 transferSession（凭据仅发往 validatedBase
/// 同一 host）。
public final class WebDAVReplicaLoader: ReplicaLoading {
    private let client: WebDAVClient

    public init(client: WebDAVClient) {
        self.client = client
    }

    public func data(for remotePath: String) async throws -> (Data, URLResponse) {
        let url = try client.encodedRemoteURL(remotePath)
        let (data, response) = try await WebDAVClient.transferSession
            .data(for: client.request(method: "GET", url: url, depth: nil))
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            throw WebDAVError.httpStatus(code, "GET \(remotePath)")
        }
        return (data, response)
    }

    public func download(remotePath: String, to local: URL, expectedBytes: Int64?) async throws {
        try await client.download(remotePath: remotePath, to: local, expectedBytes: expectedBytes)
    }
}

public final class IndexReplicaManager {
    public enum ReplicaError: Error, CustomStringConvertible {
        /// manifest 不可读/解析失败（fail-closed：拒收且不清旧副本）。
        case manifestUnreadable(String)
        /// 卷名不在白名单（安全约束；整体拒收）。
        case forbiddenRemoteName(String)
        /// manifest 内部不一致：contentHash 规则重算不符。
        case contentHashMismatch(expected: String, actual: String)
        /// 单卷 sha256 与声明不符（防损坏）。
        case volumeChecksumMismatch(name: String, expected: String, actual: String)
        case assembledHashMismatch(expectedPrefix: String, actualPrefix: String)

        public var description: String {
            switch self {
            case .manifestUnreadable(let m): return "manifest 不可读或解析失败（拒收，本地副本未动）: \(m)"
            case .forbiddenRemoteName(let n): return "卷名不在白名单内（整体拒收）: \(n)"
            case .contentHashMismatch(let e, let a): return "manifest contentHash 与分卷声明不符（防损坏拒收）: 期望 \(e) 实算 \(a)"
            case .volumeChecksumMismatch(let n, let e, let a): return "分卷 \(n) sha256 不符（防损坏拒收）: 期望 \(e.prefix(12))… 实算 \(a.prefix(12))…"
            case .assembledHashMismatch(let e, let a): return "组装产物校验不符: 期望 \(e)… 实算 \(a)…"
            }
        }
    }

    public struct Configuration {
        /// 本地副本目录（index.db 落点；生产 = AppSupport/LiteratureSearch/replica/）。
        public var replicaDirectory: URL
        /// 临时目录（生产 = AppSupport/LiteratureSearch/replica-tmp/；同卷
        /// 保证 rename 原子）。
        public var tmpDirectory: URL

        public init(replicaDirectory: URL, tmpDirectory: URL? = nil) {
            self.replicaDirectory = replicaDirectory
            self.tmpDirectory = tmpDirectory
                ?? replicaDirectory.deletingLastPathComponent()
                    .appendingPathComponent("replica-tmp", isDirectory: true)
        }

        public var localReplicaURL: URL {
            replicaDirectory.appendingPathComponent("index.db", isDirectory: false)
        }

        public var metaURL: URL {
            replicaDirectory.appendingPathComponent("replica-meta.json", isDirectory: false)
        }
    }

    /// 上次成功同步的落盘凭据（幂等跳过的依据）。
    public struct ReplicaMeta: Codable, Equatable {
        public var contentHash: String
        public var schemaVersion: Int
        public var syncedAt: String

        public init(contentHash: String, schemaVersion: Int, syncedAt: String) {
            self.contentHash = contentHash
            self.schemaVersion = schemaVersion
            self.syncedAt = syncedAt
        }
    }

    public enum Outcome: Equatable {
        /// 新副本已落地替换。
        case replaced(contentHash: String, volumes: Int)
        /// 同 contentHash 幂等跳过（未发起任何分卷下载）。
        case skippedIdentical(contentHash: String)
    }

    public let loader: ReplicaLoading
    public let configuration: Configuration
    /// 操作序列记录（测试断言「临时位置 → 替换 → 清旧」顺序；生产 nil）。
    public var operationLog: ((String) -> Void)?

    public init(loader: ReplicaLoading, configuration: Configuration) {
        self.loader = loader
        self.configuration = configuration
    }

    // MARK: 编排

    public func syncReplica() async throws -> Outcome {
        let fm = FileManager.default
        try fm.createDirectory(at: configuration.replicaDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: configuration.tmpDirectory, withIntermediateDirectories: true)

        log("fetch-manifest")
        let (data, _) = try await loader.data(for: IndexReplicaRemote.manifestPath)
        let manifest: WebDAVIndexManifest
        do {
            manifest = try WebDAVIndexManifest.parse(data)
        } catch {
            // fail-closed：解析失败拒收，旧副本原样。
            throw ReplicaError.manifestUnreadable("\(error)")
        }

        for file in manifest.files where !WebDAVIndexPaths.isAllowedRemoteName(file.name) {
            throw ReplicaError.forbiddenRemoteName(file.name)
        }
        let recomputed = WebDAVIndexManifest.contentHash(for: manifest.files)
        guard recomputed == manifest.contentHash else {
            throw ReplicaError.contentHashMismatch(expected: manifest.contentHash, actual: recomputed)
        }

        // 幂等：本地 meta 同 hash 且副本在 → 零下载跳过。
        if let meta = try? loadMeta(),
           meta.contentHash == manifest.contentHash,
           fm.fileExists(atPath: configuration.localReplicaURL.path) {
            log("skip-identical")
            return .skippedIdentical(contentHash: manifest.contentHash)
        }

        let sorted = manifest.files.sorted { $0.order < $1.order }
        for file in sorted {
            let local = configuration.tmpDirectory
                .appendingPathComponent(file.name, isDirectory: false)
            log("download:\(file.name)")
            try await loader.download(remotePath: IndexReplicaRemote.volumePath(file.name),
                                      to: local, expectedBytes: file.size)
            let actual = try Fingerprint.sha256Hex(ofFileAt: local)
            guard actual == file.sha256 else {
                try? fm.removeItem(at: local)   // 坏卷丢弃；旧副本原样
                throw ReplicaError.volumeChecksumMismatch(name: file.name,
                                                          expected: file.sha256, actual: actual)
            }
        }

        let indexVolumes = sorted.filter { !$0.name.hasPrefix("fulltext-") }
        let fulltextVolumes = sorted.filter { $0.name.hasPrefix("fulltext-") }
        guard !indexVolumes.isEmpty else {
            throw ReplicaError.manifestUnreadable("manifest 缺少 index- 主库卷")
        }
        func assemble(_ volumes: [WebDAVIndexManifest.FileEntry]) throws -> URL {
            let dest = configuration.tmpDirectory
                .appendingPathComponent("assembled-\(UUID().uuidString).sqlite", isDirectory: false)
            if volumes.count == 1 {
                try fm.copyItem(at: configuration.tmpDirectory
                    .appendingPathComponent(volumes[0].name, isDirectory: false), to: dest)
            } else {
                FileManager.default.createFile(atPath: dest.path, contents: nil)
                let out = try FileHandle(forWritingTo: dest)
                defer { try? out.close() }
                for file in volumes {
                    let part = try FileHandle(forReadingFrom: configuration.tmpDirectory
                        .appendingPathComponent(file.name, isDirectory: false))
                    defer { try? part.close() }
                    let chunk = part.readDataToEndOfFile()
                    try out.write(contentsOf: chunk)
                }
            }
            let sha = try Fingerprint.sha256Hex(ofFileAt: dest)
            let nameHash16 = Self.nameHashPrefix(from: volumes.map(\.name))
            guard let nameHash16, sha.hasPrefix(nameHash16) else {
                try? fm.removeItem(at: dest)
                throw ReplicaError.assembledHashMismatch(expectedPrefix: nameHash16 ?? "（卷名无 hash 段）",
                                                         actualPrefix: String(sha.prefix(16)))
            }
            return dest
        }
        log("assemble")
        let assembledIndex = try assemble(indexVolumes)
        var assembledFulltext: URL? = nil
        if !fulltextVolumes.isEmpty {
            assembledFulltext = try assemble(fulltextVolumes)
        }

        log("replace")
        try fm.createDirectory(at: configuration.replicaDirectory, withIntermediateDirectories: true)
        func replace(_ assembled: URL, to target: URL) throws {
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: assembled)
            } else {
                try fm.moveItem(at: assembled, to: target)
            }
        }
        try replace(assembledIndex, to: configuration.localReplicaURL)
        let replicaFulltextURL = configuration.localReplicaURL
            .deletingLastPathComponent().appendingPathComponent("fulltext.db")
        if let ftAssembled = assembledFulltext {
            try replace(ftAssembled, to: replicaFulltextURL)
        } else {
            try? fm.removeItem(at: replicaFulltextURL)
        }

        log("cleanup")
        for file in sorted {
            try? fm.removeItem(at: configuration.tmpDirectory
                .appendingPathComponent(file.name, isDirectory: false))
        }
        let meta = ReplicaMeta(contentHash: manifest.contentHash,
                               schemaVersion: manifest.schemaVersion,
                               syncedAt: WebDAVIndexManifest.iso8601UTC.string(from: Date()))
        if let metaJSON = try? JSONEncoder().encode(meta) {
            try? metaJSON.write(to: configuration.metaURL, options: .atomic)
        }
        return .replaced(contentHash: manifest.contentHash, volumes: sorted.count)
    }

    public func loadMeta() throws -> ReplicaMeta? {
        guard let data = try? Data(contentsOf: configuration.metaURL) else { return nil }
        return try? JSONDecoder().decode(ReplicaMeta.self, from: data)
    }

    /// 卷名内嵌 hash16 提取（`index-|fulltext-<16hex>(-partN)?.sqlite` 的
    /// <16hex> 段；白名单已过，形态必然匹配）。
    static func nameHashPrefix(from names: [String]) -> String? {
        guard let first = names.first,
              let range = first.range(of: #"(?<=^(?:index|fulltext)-)[0-9a-f]{16}"#, options: .regularExpression)
        else { return nil }
        return String(first[range])
    }

    private func log(_ event: String) {
        operationLog?(event)
    }
}
