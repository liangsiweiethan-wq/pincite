import Foundation

// MARK: - 检索引擎接口
//
// SearchService 保持现有检索语义；该接口允许调用方通过统一协议访问默认实现。
//
// 接口契约
//   · protocol SearchEngine：最小面＝matchingBooks / searchDetailed /
//     explainZeroHit（与 SearchService 现签名同形）＋ init(store:policy:)。
//   · extension SearchService: SearchEngine：纯转发 conformance——三个方法
//     与构造器签名本就同形，conformance 声明零转发体。
//   · SearchEngineRegistry：注册表只含 "fts5-default" 一个引擎；
//     resolve(preference:) 对偏好缺失/未知值一律 fail-closed 回默认引擎
// 未知偏好不会静默选择未知实现。
//
// SearchService 保持原构造签名；应用主检索入口通过注册表解析引擎偏好。

/// 检索引擎统一接口。签名与 `SearchService` 既有公开方法同形，
/// 语义契约即其现文档——本协议不新增任何检索语义。
public protocol SearchEngine {
    /// 与 `SearchService.init(store:policy:)` 同形（policy＝查询时排除策略
    /// 复查；nil＝不做查询时复查）。
    init(store: IndexStore, policy: ExclusionPolicy?)

    /// 书目级聚合（两段式阶段一；语法查询进语法层，分派与 SearchService 同）。
    func matchingBooks(_ rawQuery: String, filter: SearchFilter?) throws -> [SearchService.BookHitSummary]

    /// 页级检索（两段式阶段二/整库直查；含词项路由与语法分派）。
    func searchDetailed(_ rawQuery: String, options: SearchOptions) throws -> SearchResult

    /// 零命中诚实解释（分类每书：无文字层/词未命中/策略排除/不可评估）。
    func explainZeroHit(_ rawQuery: String) throws -> ZeroHitExplanation
}

/// 默认实现由现有 `SearchService` 提供；协议一致性不改变检索行为。
extension SearchService: SearchEngine {}

public enum SearchEngineRegistry {
    /// UserDefaults 偏好键。
    public static let preferenceKey = "search.engine"
    /// 注册表内唯一引擎名（fail-closed 归宿）。
    public static let defaultEngineName = "fts5-default"

    /// 解析引擎类型。偏好缺失或未知时使用默认引擎。
    /// 返回 `SearchEngine.Type`；调用方 `resolve(...).init(store:policy:)`。
    public static func resolve(_ preference: String?) -> SearchEngine.Type {
        switch preference?.trimmingCharacters(in: .whitespaces) {
        case defaultEngineName:
            return SearchService.self
        default:
            // 缺失/空/未知值：一律回默认引擎（现注册表仅此一家，注解即契约：
            // 未来注册第二引擎时，未知值仍须落这里，不得静默选用未知实现）。
            return SearchService.self
        }
    }

    /// 偏好对应的注册表内引擎名（调试面板只读呈现；未知值如实报默认名）。
    public static func engineName(for preference: String?) -> String {
        switch preference?.trimmingCharacters(in: .whitespaces) {
        case defaultEngineName:
            return defaultEngineName
        default:
            return defaultEngineName
        }
    }
}
