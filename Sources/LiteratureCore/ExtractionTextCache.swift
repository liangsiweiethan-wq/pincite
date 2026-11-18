import Foundation

// MARK: - 抽取文本侧车缓存（抽取文本缓存一次、处处复用；以基准与版本入键）

public struct ExtractionTextCache {
    /// 缓存格式版本（升格式即改此值；旧件成孤儿）。
    public static let cacheFormatVersion = 1
    /// JSON format 标识（防误读他源 JSON）。
    static let formatTag = "lit-text-cache"

    /// 缓存根目录（生产：AppSupportPaths.textCacheDirectory）。
    public let directory: URL

    /// 单条缓存载荷（Codable，与 PDFExtractionResult 逐字段同构）。
    public struct Entry: Codable, Equatable {
        public var format: String
        public var cacheFormatVersion: Int
        public var normalizationVersion: Int
        public var sourceSHA256: String
        public var fileSize: Int64?
        public var pageCount: Int
        public var createdAt: String
        public var pages: [PageEntry]

        public struct PageEntry: Codable, Equatable {
            public var physicalPage: Int
            public var label: String?
            public var printedPage: Int?
            public var text: String
            public var normText: String
            public var normStartsB64: String
            public var normEndsB64: String
        }
    }

    /// JSON 解码失败/半件等错误按 miss 处理的内部信号（对外仍返回 nil）。
    struct CacheError: Error { let message: String }

    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: 键

    /// 缓存键：`<sha256>.v<normVersion>.cf<cacheFormatVersion>.json`。
    /// 绑 IndexStore.expectedNormalizationVersion（现值 4）——归一化升级自动
    /// 失效。sha256 必须全小写 hex 64 位，否则返回 nil（调用方按 miss）。
    public static func cacheKey(sourceSHA256: String) -> String? {
        let hex = sourceSHA256.lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "\(hex).v\(IndexStore.expectedNormalizationVersion).cf\(cacheFormatVersion).json"
    }

    /// 键路径分桶：text-cache/<sha256 前 2 hex>/<键>.json。
    static func bucketDirectory(directory: URL, sourceSHA256: String) -> URL? {
        guard let key = cacheKey(sourceSHA256: sourceSHA256) else { return nil }
        let prefix = String(key.prefix(2))
        return directory.appendingPathComponent(prefix, isDirectory: true)
            .appendingPathComponent(key)
    }

    // MARK: 读（fail-open：任何不符按 miss，不 throw 给索引路径）

    /// 命中返回重建的 PDFExtractionResult（逐字段等值）；未命中/键非法/
    /// 半件/损坏/版本不符返回 nil。
    public func result(fileSHA256: String) -> PDFExtractionResult? {
        guard let url = Self.bucketDirectory(directory: directory, sourceSHA256: fileSHA256),
              let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        guard entry.format == Self.formatTag,
              entry.cacheFormatVersion == Self.cacheFormatVersion,
              entry.normalizationVersion == IndexStore.expectedNormalizationVersion,
              entry.sourceSHA256 == fileSHA256.lowercased() else { return nil }
        var pages: [ExtractedPage] = []
        pages.reserveCapacity(entry.pages.count)
        for p in entry.pages {
            guard let starts = Self.int32Array(fromBase64: p.normStartsB64),
                  let ends = Self.int32Array(fromBase64: p.normEndsB64) else { return nil }
            pages.append(ExtractedPage(
                physicalPage: p.physicalPage,
                label: p.label,
                printedPage: p.printedPage,
                text: p.text,
                normalized: NormalizedText(text: p.normText, starts: starts, ends: ends)))
        }
        return PDFExtractionResult(pageCount: entry.pageCount, pages: pages)
    }

    // MARK: 写（原子替换；写失败由调用方决定是否吞——索引路径吞并记录）

    /// 原子落盘：写 tmp 再 rename。
    public func store(fileSHA256: String, _ result: PDFExtractionResult,
                      fileSize: Int64? = nil) throws {
        guard let key = Self.cacheKey(sourceSHA256: fileSHA256),
              let bucket = Self.bucketDirectory(directory: directory, sourceSHA256: fileSHA256) else {
            throw CacheError(message: "非法缓存键（sha256 须 64 位 hex）: \(fileSHA256.prefix(12))…")
        }
        try FileManager.default.createDirectory(at: bucket.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let pages = result.pages.map { p in
            Entry.PageEntry(physicalPage: p.physicalPage, label: p.label,
                            printedPage: p.printedPage, text: p.text,
                            normText: p.normalized.text,
                            normStartsB64: Self.base64(p.normalized.starts),
                            normEndsB64: Self.base64(p.normalized.ends))
        }
        let entry = Entry(format: Self.formatTag,
                          cacheFormatVersion: Self.cacheFormatVersion,
                          normalizationVersion: IndexStore.expectedNormalizationVersion,
                          sourceSHA256: fileSHA256.lowercased(),
                          fileSize: fileSize,
                          pageCount: result.pageCount,
                          createdAt: Self.iso8601UTC.string(from: Date()),
                          pages: pages)
        let data = try JSONEncoder().encode(entry)
        let tmp = bucket.deletingLastPathComponent()
            .appendingPathComponent(".\(key).tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        // 同卷 rename 原子替换；目标已存在（并发双写）覆盖即可——内容寻址，
        // 同键内容相同。
        _ = try? FileManager.default.removeItem(at: bucket)
        try FileManager.default.moveItem(at: tmp, to: bucket)
    }

    // MARK: 诊断/维护

    /// 自有缓存文件判别（IndexingEngine.isOwnStorageFile 的扫描/监听过滤
    /// 面用：缓存键件 `<sha256>.v<n>.cf<n>.json` 与写侧 `.tmp-` 半件）。
    /// 缓存目录按构建不在任何书库 root 内，此判别纯防御。
    static func isOwnCacheFile(_ name: String) -> Bool {
        if name.hasPrefix(".") && name.contains(".tmp-") { return true }
        guard name.hasSuffix(".json") else { return false }
        return name.range(of: #"\.v\d+\.cf\d+\.json$"#, options: .regularExpression) != nil
    }

    /// 缓存总体积（字节；诊断/设置页显示）。
    public func totalBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsPackageDescendants]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true, let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    /// 手动清空（设置页；删整个缓存目录内容，目录本体保留）。
    public func clear() throws {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [])) ?? []
        for item in contents {
            try FileManager.default.removeItem(at: item)
        }
    }

    // MARK: 编解码助手

    static let iso8601UTC: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// [Int32] → base64（小端，与 IndexStore 的 norm blob 编解码同序）。
    static func base64(_ values: [Int32]) -> String {
        var data = Data(capacity: values.count * 4)
        for v in values {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return data.base64EncodedString()
    }

    /// base64 → [Int32]（小端；长度非 4 倍数即损坏，返回 nil 按 miss）。
    static func int32Array(fromBase64 raw: String) -> [Int32]? {
        guard let data = Data(base64Encoded: raw) else { return nil }
        guard data.count % 4 == 0 else { return nil }
        var out: [Int32] = []
        out.reserveCapacity(data.count / 4)
        data.withUnsafeBytes { buffer in
            for i in stride(from: 0, to: buffer.count, by: 4) {
                out.append(buffer.loadUnaligned(fromByteOffset: i, as: Int32.self).littleEndian)
            }
        }
        return out
    }
}
