import Foundation
import CoreGraphics
import PDFKit

// MARK: - PDF page labels (original page label), separate from printed page number

public enum PageLabelDeclaration {
    /// True only when the PDF catalog itself contains a /PageLabels entry.
    public static func declaresPageLabels(fileURL: URL) -> Bool {
        guard let doc = CGPDFDocument(fileURL as CFURL), let catalog = doc.catalog else { return false }
        var labels: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(catalog, "PageLabels", &labels) && labels != nil
    }

    /// 按文档缓存的声明查询：阅读器每次右键都问一次，重复打开并解析
    /// CGPDFDocument 太贵，故以一个文档身份键（路径 + mtime + 大小）缓存结果。
    /// 文件被替换（mtime/大小变）即 Key 变，旧条目自然失效。
    public static func cachedDeclaration(documentKey: String, fileURL: URL) -> Bool {
        CachedDeclaration.shared.value(for: documentKey) { declaresPageLabels(fileURL: fileURL) }
    }

    /// 文档身份键：路径 + 修改时间 + 字节数（不含内容哈希，避免右键额外 I/O）。
    public static func documentKey(fileURL: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return "\(fileURL.path)|\(mtime)|\(size)"
    }

    /// 有界 LRU（上限 32 份文档；阅读器通常只开一两本，够用且不无界增长）。
    private final class CachedDeclaration: @unchecked Sendable {
        static let shared = CachedDeclaration()
        private let lock = NSLock()
        private var values: [String: Bool] = [:]
        private var order: [String] = []
        private let limit = 32

        func value(for key: String, compute: () -> Bool) -> Bool {
            lock.lock()
            if let hit = values[key] {
                lock.unlock()
                return hit
            }
            lock.unlock()
            let fresh = compute()
            lock.lock()
            values[key] = fresh
            order.removeAll { $0 == key }
            order.append(key)
            while order.count > limit {
                let evicted = order.removeFirst()
                values.removeValue(forKey: evicted)
            }
            lock.unlock()
            return fresh
        }
    }
}
