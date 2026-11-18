import Foundation

// 布局感知重排钩子。落点=OCR 派生件进倒排前的
// 纯函数段：页眉脚重复行剔除（≥60% 页同现）＋空行压缩，其余字节不动。
// OcrPipelineVersion.current 递增驱动 IndexQueue 断点续跑语义自然全库重排队
// （既有机制零新增）。边界：不自研布局模型，只还原外部管线 reading order。


enum OcrPipelineVersion { static let current = 2 }

struct OcrReorder {
    /// Pure function: strip header/footer repeats (≥60% pages), compress blank lines, leave other bytes unchanged.
    static func reorderParagraphs(pages: [String]) -> [String] {
        // 若页数不足 3 条，跳过页眉/脚剔除，仅进行空行压缩
        guard pages.count >= 3 else { return compressBlankLines(pages) }

        let total = pages.count
        let threshold = Int(ceil(0.6 * Double(total)))   // ≥60% 门槛

        // 统计每页首尾行出现次数
        var firstCounts: [String: Int] = [:]
        var lastCounts: [String: Int] = [:]

        for page in pages {
            let lines = page.components(separatedBy: .newlines)
            guard let first = lines.first, let last = lines.last else { continue }
            firstCounts[first, default: 0] += 1
            lastCounts[last, default: 0] += 1
        }

        // 判定页眉/页脚：在 ≥60% 页中首尾出现的同一短行
        let headers = Set(firstCounts.filter { $0.value >= threshold }.map { $0.key })
        let footers = Set(lastCounts.filter { $0.value >= threshold }.map { $0.key })

        // 从每页中剔除已判定的首尾行
        var result = pages
        for i in result.indices {
            let lines = result[i].components(separatedBy: .newlines)
            let filtered = lines.filter { !headers.contains($0) && !footers.contains($0) }
            result[i] = filtered.joined(separator: "\n")
        }

        return compressBlankLines(result)
    }

    // 将每页内的连续空行归一为单个换行
    private static func compressBlankLines(_ pages: [String]) -> [String] {
        return pages.map { page in
            let parts = page.components(separatedBy: .newlines)
            var out: [String] = []
            var lastWasBlank = false
            for part in parts {
                let isBlank = part.isEmpty || part.trimmingCharacters(in: .whitespaces).isEmpty
                if isBlank {
                    if !lastWasBlank { out.append("") }   // 只保留第一个空行
                    lastWasBlank = true
                } else {
                    out.append(part)
                    lastWasBlank = false
                }
            }
            return out.joined(separator: "\n")
        }
    }
}
