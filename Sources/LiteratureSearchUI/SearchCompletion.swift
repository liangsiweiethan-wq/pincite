import Foundation
#if canImport(LiteratureCore)
import LiteratureCore
#endif

// MARK: - 输入候选与历史补全
//
// 检索框确定性交互的候选合成纯函数层：输入（历史 entries＋当前前缀）→
// 候选列表。打分＝历史频次（hitCount）desc → at desc → query asc **全序
// 决胜**（同输入两次运行同输出——确定性是本层第一契约）。
//
// 「自动补 *」只在候选层
// 生成 `prefix*` 风格建议项，用户选中候选才成为查询文本；**提交语义零改
// 写**——SearchService 入口、QuerySyntax 语法字符集（: = ~ "）和排序
// 比较器均保持不变。
// `*` 目前是字面字符；含 `*`
// 查询按现行字面子串语义检索（实际近零命中）；显式 `*` 通配语法（Query-
// Syntax 新节点）尚未实现；前缀扩展项的帮助文案说明了这一限制。
//
// 频次重排约束：本层的 hitCount 排序**只作用于输入候选/历史补全层**；
// 全库检索结果列表的排序（matchingBooks/groupHits/roundRobinByBook/拼音
// 置前）一律不经过本层。

/// 一条输入候选。`query`＝选中后成为查询文本的完整串。
public struct SearchCompletionCandidate: Equatable, Identifiable {
    public let query: String
    /// true＝前缀扩展项（prefix* 形态）；false＝历史补全项。
    public let isPrefixExpansion: Bool
    /// 历史频次（该查询的历史命中页数；前缀扩展项恒 0，排序天然沉底）。
    public let hitCount: Int
    /// 历史时间（前缀扩展项 .distantPast，决胜序确定）。
    public let at: Date

    public init(query: String, isPrefixExpansion: Bool, hitCount: Int, at: Date) {
        self.query = query
        self.isPrefixExpansion = isPrefixExpansion
        self.hitCount = hitCount
        self.at = at
    }

    /// 稳定标识（同查询去重后的键）。
    public var id: String { query }
}

/// 候选合成纯函数（无状态；同输入恒同输出）。
public enum SearchCompletionSource {
    /// 候选上限（键盘导航与展示条的面宽；确定性截断取全序前 K）。
    public static let candidateLimit = 6
    /// 前缀扩展项的最短前缀（1 字符即弹会吵；≥2 才出 * 建议项）。
    public static let minPrefixLength = 2

    /// 合成候选。规则：
    /// 1. 前缀归一化（复用既有输出基线同一 normalizeQuery）；空 → 空候选（零渲染）。
    /// 2. 历史补全：归一化后**包含**前缀且**不等于**前缀的历史查询
    ///    （等于前缀＝当前输入本身，无补全义）。
    /// 3. 前缀扩展：前缀 ≥2 字符且未以 * 结尾时，生成 `<前缀>*` 建议项
    ///    （hitCount=0、at=.distantPast——全序中恒沉底，绝不压过历史项）。
    /// 4. 去重：按归一化查询串唯一，同串保留**最近一次**（at 最大）输入形制；
    ///    前缀扩展与历史补全同串时历史项优先。
    /// 5. 全序决胜：hitCount desc → at desc → query asc，取前 candidateLimit。
    public static func candidates(history: [HistoryEntry], prefix: String,
                                  now: Date = Date()) -> [SearchCompletionCandidate] {
        let np = normalizeQuery(prefix)
        guard !np.isEmpty else { return [] }

        var byKey: [String: SearchCompletionCandidate] = [:]
        for entry in history {
            let nq = normalizeQuery(entry.query)
            guard !nq.isEmpty, nq.contains(np), nq != np else { continue }
            let candidate = SearchCompletionCandidate(query: entry.query,
                                                      isPrefixExpansion: false,
                                                      hitCount: entry.hitCount,
                                                      at: entry.at)
            // 去重＝归一化同串唯一，保留**最近一次**输入的原始形制（同一查询第二次输入时置顶上次选择）——补全提示应
            // 呈现用户最近敲过的写法；at 并列保持先见项，全序仍确定）。
            if let old = byKey[nq] {
                if entry.at > old.at { byKey[nq] = candidate }
                continue
            }
            byKey[nq] = candidate
        }

        // 前缀扩展（自动补 * 的候选层形态；提交语义零改写）。
        if np.count >= minPrefixLength, !np.hasSuffix("*"), byKey["\(np)*"] == nil {
            byKey["\(np)*"] = SearchCompletionCandidate(query: "\(np)*",
                                                        isPrefixExpansion: true,
                                                        hitCount: 0,
                                                        at: .distantPast)
        }

        // 全序决胜：频次 desc → 时间 desc → query asc（严格全序，无并列歧义）。
        return byKey.values.sorted {
            if $0.hitCount != $1.hitCount { return $0.hitCount > $1.hitCount }
            if $0.at != $1.at { return $0.at > $1.at }
            return $0.query < $1.query
        }
        .prefix(candidateLimit)
        .map { $0 }
    }
}
