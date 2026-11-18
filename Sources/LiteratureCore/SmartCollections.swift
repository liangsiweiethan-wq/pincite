import Foundation


/// 值类型（五个 String? 字段）——Sendable 使 FavoriteTarget.smartSearch
/// 关联值满足既有 `FavoriteTarget: Sendable` 约束。追溯一致
/// 性须 @unchecked（conformance 与定义分文件；全字段值类型，unchecked 安全）。
extension SearchFilter: @unchecked Sendable {}

extension SearchFilter: Codable {
    private enum CodingKeys: String, CodingKey {
        case authorContains, versionContains, languageEquals, bookIDEquals, sourceDomain
    }

    /// 全字段 decodeIfPresent：旧 JSON（不含某键）解出 nil，与 isActive 判空
    /// 语义一致（SearchService.swift「unknown 不静默当命中」哲学同源）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(authorContains: try c.decodeIfPresent(String.self, forKey: .authorContains),
                  versionContains: try c.decodeIfPresent(String.self, forKey: .versionContains),
                  languageEquals: try c.decodeIfPresent(String.self, forKey: .languageEquals),
                  bookIDEquals: try c.decodeIfPresent(String.self, forKey: .bookIDEquals),
                  sourceDomain: try c.decodeIfPresent(String.self, forKey: .sourceDomain))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(authorContains, forKey: .authorContains)
        try c.encodeIfPresent(versionContains, forKey: .versionContains)
        try c.encodeIfPresent(languageEquals, forKey: .languageEquals)
        try c.encodeIfPresent(bookIDEquals, forKey: .bookIDEquals)
        try c.encodeIfPresent(sourceDomain, forKey: .sourceDomain)
    }
}

public enum SmartCollections {

    /// 动态集合求值：现算，不物化、不缓存（零快照语义的函数级断言子）。
    /// - Parameters:
    ///   - query: 保存的检索式（原样透传 matchingBooks，语法语义零改动）。
    ///   - filter: 保存的过滤条件（nil = 无条件，等价旧 .search 语义）。
    ///   - policy: 排除策略（照 SearchService.init 缺省 nil）。
    ///   - limit: 可选截断（nil = 全量）。
    public static func evaluate(query: String,
                                filter: SearchFilter?,
                                store: IndexStore,
                                policy: ExclusionPolicy? = nil,
                                limit: Int? = nil) throws -> [SearchService.BookHitSummary] {
        let service = SearchService(store: store, policy: policy)
        var hits = try service.matchingBooks(query, filter: filter)
        if let limit, hits.count > limit {
            hits = Array(hits.prefix(limit))
        }
        return hits
    }
}
