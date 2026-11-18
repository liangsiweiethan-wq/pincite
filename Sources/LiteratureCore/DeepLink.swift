import Foundation

// MARK: - Deep links
//
// Scheme: literaturesearch://search?q=<url-encoded query>
//         literaturesearch://quote
// literaturesearch://open?doc=<bookID>&page=<N>
// literaturesearch://open?doc=<bookID>&hl=<id>（高亮定位）
// literaturesearch://collection?id=<rowID>
// The widget uses these to open the app with a search field prefilled, or to
// jump to the daily-quote section. The widget itself never runs searches and
// never displays original text.
// 规格原书：docs/URI-SCHEME.md（四动词一一对应本文件，逐条对照）。

public enum DeepLink: Equatable {
    case search(query: String)
    /// Daily-quote section (DailyQuoteWidget tap target).
    case quote
    /// 定位一本书（doc = books.id 内容寻址，防库重建失效）；
    /// page 可缺省（nil = 只选书不开页）。
    case open(doc: String, page: Int?, highlight: Int64?)
    /// 定位收藏夹一行（id = favorites.id，正整数）。
    case collection(id: Int64)

    public static let scheme = "literaturesearch"

    public static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == scheme.lowercased() else { return nil }
        switch url.host?.lowercased() {
        case "search":
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let query = comps?.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
            return .search(query: query)
        case "quote":
            return .quote
        case "open":
            // doc 空白 → 整体 nil（fail-closed，照 .search 空查询惯例）；
            // page 非法或缺失 → nil（只选书不开页），不猜；
            // hl 非法或缺失 → nil（只按 page/书级打开），不猜（宽容侧照 page）。
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let doc = comps?.queryItems?.first(where: { $0.name == "doc" })?.value ?? ""
            guard !doc.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            var page: Int? = nil
            if let raw = comps?.queryItems?.first(where: { $0.name == "page" })?.value {
                page = Int(raw)
            }
            var highlight: Int64? = nil
            if let raw = comps?.queryItems?.first(where: { $0.name == "hl" })?.value {
                highlight = Int64(raw)
            }
            return .open(doc: doc, page: page, highlight: highlight)
        case "collection":
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            guard let raw = comps?.queryItems?.first(where: { $0.name == "id" })?.value,
                  let id = Int64(raw), id > 0 else { return nil }
            return .collection(id: id)
        default:
            return nil
        }
    }

    /// Building with an empty/whitespace query returns nil — callers (widget)
    /// must not produce a meaningless deep link and fall back to file:/// URLs.
    /// `.quote` has no parameters and always builds.
    public func build() -> URL? {
        switch self {
        case .search(let query):
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            var comps = URLComponents()
            comps.scheme = Self.scheme
            comps.host = "search"
            comps.queryItems = [URLQueryItem(name: "q", value: query)]
            return comps.url
        case .quote:
            var comps = URLComponents()
            comps.scheme = Self.scheme
            comps.host = "quote"
            return comps.url
        case .open(let doc, let page, let highlight):
            // doc 空白 fail-closed（与 parse 对称）；page／hl 非 nil 才带
            // 参数（percentEncoding 由 URLComponents 天然处理）。
            guard !doc.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            var comps = URLComponents()
            comps.scheme = Self.scheme
            comps.host = "open"
            var items = [URLQueryItem(name: "doc", value: doc)]
            if let page { items.append(URLQueryItem(name: "page", value: String(page))) }
            if let highlight { items.append(URLQueryItem(name: "hl", value: String(highlight))) }
            comps.queryItems = items
            return comps.url
        case .collection(let id):
            guard id > 0 else { return nil }
            var comps = URLComponents()
            comps.scheme = Self.scheme
            comps.host = "collection"
            comps.queryItems = [URLQueryItem(name: "id", value: String(id))]
            return comps.url
        }
    }

    // highlightPage(in:id:) 移至 HighlightStore.swift 末尾的
    // extension DeepLink——widget target 只直编 Foundation-only 自包含的
    // DeepLink/SharedHistoryStore/SharedQuoteState 三件，高亮行模型在
    // HighlightStore.swift（不在 widget 清单），原位放置在 emit-module 时断裂。
}
