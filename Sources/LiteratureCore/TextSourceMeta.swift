import Foundation

// MARK: - 页文本来源元数据
//
// 索引建完后，每本书实际用的页文本来源要可核对：`text_source:<bookID>`
// 落在 meta 表（与 body_start_page 同款书级键，schema 零迁移）。值形如
//   source=kb;sha=<64hex>;kb=<MD 文件名>;method=ocr_cache
//   source=pdf;sha=<64hex>;fallback=page_count_mismatch
// 读侧：App/CLI 可按书号取；解析失败一律当作"未知"（不猜）。

public enum TextSourceMeta {
    public static func key(_ bookID: String) -> String { "text_source:" + bookID }

    /// 一次索引的页文本来源判读结果。
    public struct Value: Equatable, Sendable {
        public var source: String?
        public var sha256: String?
        public var kbFileName: String?
        public var method: String?
        public var fallbackReason: String?

        public init(source: String? = nil, sha256: String? = nil,
                    kbFileName: String? = nil, method: String? = nil,
                    fallbackReason: String? = nil) {
            self.source = source
            self.sha256 = sha256
            self.kbFileName = kbFileName
            self.method = method
            self.fallbackReason = fallbackReason
        }

        public init?(metaValue raw: String) {
            guard !raw.isEmpty else { return nil }
            var fields: [String: String] = [:]
            for part in raw.split(separator: ";") {
                guard let eq = part.firstIndex(of: "=") else { continue }
                fields[String(part[part.startIndex..<eq])] = String(part[part.index(after: eq)...])
            }
            guard let src = fields["source"], !src.isEmpty else {
                return nil
            }
            self.init(source: src,
                      sha256: fields["sha"],
                      kbFileName: fields["kb"],
                      method: fields["method"],
                      fallbackReason: fields["fallback"])
        }
    }

    /// 读书级来源（缺键/坏值 → nil，调用方按未知处理）。
    public static func read(store: IndexStore, bookID: String) -> Value? {
        guard let raw = try? store.metaValue(key(bookID)) else { return nil }
        return Value(metaValue: raw ?? "")
    }
}
