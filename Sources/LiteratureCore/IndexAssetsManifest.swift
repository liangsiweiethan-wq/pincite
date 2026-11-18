import Foundation

// MARK: - 索引资产自包含清单

public struct IndexAssetsManifest: Codable, Equatable {
    public struct Entry: Codable, Equatable {
        public var name: String
        public var sha256: String
        public var size: Int64

        public init(name: String, sha256: String, size: Int64) {
            self.name = name
            self.sha256 = sha256
            self.size = size
        }
    }

    /// fulltext 格式版本（随 IndexStore.currentFulltextFormatVersion）。
    public var formatVersion: Int
    /// ISO8601 UTC（同 WebDAV 惯例，往返一致）。
    public var createdAt: String
    /// 资产清单（当前仅 fulltext.db 冷态一项；扩展位预留）。
    public var assets: [Entry]

    public init(formatVersion: Int, createdAt: String, assets: [Entry]) {
        self.formatVersion = formatVersion
        self.createdAt = createdAt
        self.assets = assets
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case createdAt = "created_at"
        case assets
    }

    /// fulltext.db 清单条目名（verify 按名比对）。
    public static let fulltextAssetName = "fulltext.db"

    /// 生成冷态清单：对 fulltext.db 现算 sha256（流式，Fingerprint 同源
    /// 原语）与 size。活库（-wal 存在）不拒绝生成，但校验语义要求 checkpoint
    /// 后使用——调用方（CLI assets-verify）负责在 quiescent 窗口调用。
    public static func generate(fulltextDB: URL) throws -> IndexAssetsManifest {
        let values = try fulltextDB.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw NSError(domain: "IndexAssetsManifest", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "fulltext 资产缺失或非普通文件: \(fulltextDB.path)"])
        }
        let sha = try Fingerprint.sha256Hex(ofFileAt: fulltextDB)
        return IndexAssetsManifest(
            formatVersion: IndexStore.currentFulltextFormatVersion,
            createdAt: Self.iso8601UTC.string(from: Date()),
            assets: [Entry(name: Self.fulltextAssetName, sha256: sha,
                           size: Int64(values.fileSize ?? 0))])
    }

    /// 校验：返回失配/缺失资产名列表（空＝全部通过）。逐项点名，不静默。
    /// 只校验清单内资产；清单外文件不管（清单是自包含承诺，不是目录管制）。
    public func verify(fulltextDB: URL) -> [String] {
        var failures: [String] = []
        // URL.resourceValues 有按 URL 实例的缓存——
        // 同一 URL 对象在文件被改写后再取 fileSize 会拿到陈旧值，size 门被
        // 旧值骗过、错报成 sha256 mismatch。每次校验用全新 URL 实例绕开缓存。
        let file = URL(fileURLWithPath: fulltextDB.path)
        for entry in assets {
            guard entry.name == Self.fulltextAssetName else {
                failures.append(entry.name)   // 未知资产名形制，逐字报出
                continue
            }
            guard FileManager.default.fileExists(atPath: file.path) else {
                failures.append("\(entry.name) [missing]")
                continue
            }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size == entry.size else {
                failures.append("\(entry.name) [size \(size) != \(entry.size)]")
                continue
            }
            guard let sha = try? Fingerprint.sha256Hex(ofFileAt: file), sha == entry.sha256 else {
                failures.append("\(entry.name) [sha256 mismatch]")
                continue
            }
        }
        return failures
    }

    // MARK: 落盘/读回（CLI assets-verify 交接缝的存储面）

    /// 确定性 JSON（键排序＋美化，同 WebDAV manifest 惯例）。
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func parse(_ data: Data) throws -> IndexAssetsManifest {
        try JSONDecoder().decode(IndexAssetsManifest.self, from: data)
    }

    /// ISO8601 UTC（与 WebDAVIndexManifest.iso8601UTC 同形；独立实例防跨件耦合）。
    public static let iso8601UTC: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
