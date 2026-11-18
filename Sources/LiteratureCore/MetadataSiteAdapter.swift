import Foundation

// MARK: - 功能扩展 元数据站点适配器契约

/// 一次站点查询的请求（统一入口；四字段全可选——各实现按自身能力取用）。
public struct MetadataLookupRequest: Sendable {
    public let doi: String?
    public let arxivID: String?
    public let title: String?
    public let author: String?

    public init(doi: String? = nil, arxivID: String? = nil,
                title: String? = nil, author: String? = nil) {
        self.doi = doi
        self.arxivID = arxivID
        self.title = title
        self.author = author
    }
}

/// 站点适配器契约。实现内部吞错（失败/零命中 → nil，不抛）；单源故障只
/// 降级该源由「协议契约（不抛）＋服务侧调用隔离（do/catch 双保险）」两层
/// 保证。
public protocol MetadataSiteAdapter: Sendable {
    /// 审计标签 fetch:<sourceID>（报告 SourceOutcome.source 同值）。
    var sourceID: String { get }
    /// 隐私契约域白名单登记（请求只发往本域）。
    var host: String { get }
    /// 查询。零命中/失败/超时一律 nil，不抛不崩。
    func lookup(_ request: MetadataLookupRequest,
                loader: MetadataHTTPLoading) async -> FetchedMetadata?
}

// MARK: - 示范实现一：arXiv（薄封装既有 requestArxiv，逻辑零复制）

/// 复用 MetadataFetchService.requestArxiv / parseArxivAtom 既有实现——
/// 适配器只做契约形状转换，零解析逻辑复制（链内迁移时的等值通道）。
public struct ArxivSiteAdapter: MetadataSiteAdapter {
    public let sourceID = "arxiv"
    public let host = MetadataSource.arxiv.host

    public init() {}

    public func lookup(_ request: MetadataLookupRequest,
                       loader: MetadataHTTPLoading) async -> FetchedMetadata? {
        guard let id = request.arxivID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        let service = MetadataFetchService(loader: loader)
        let (metadata, _) = await service.requestArxiv(id: id)
        return metadata
    }
}


/// `GET https://openlibrary.org/search.json?title=…&author=…&limit=1
///  &fields=title,author_name,first_publish_year,language`——公开免钥源，
/// 解析 docs[0]（零命中 → nil）。first_publish_year→version、
/// author_name→author、language[0]→language；title 原样。
public struct OpenLibrarySiteAdapter: MetadataSiteAdapter {
    public static let sourceIDValue = "openlibrary"
    public let sourceID = OpenLibrarySiteAdapter.sourceIDValue
    public let host = "openlibrary.org"

    public init() {}

    public func lookup(_ request: MetadataLookupRequest,
                       loader: MetadataHTTPLoading) async -> FetchedMetadata? {
        // 模糊回退位：按标题（+可选作者）查询；无标题即无事可做（不猜）。
        guard let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/search.json"
        var items = [URLQueryItem(name: "title", value: title)]
        if let author = request.author?.trimmingCharacters(in: .whitespacesAndNewlines),
           !author.isEmpty {
            items.append(URLQueryItem(name: "author", value: author))
        }
        items.append(URLQueryItem(name: "limit", value: "1"))
        items.append(URLQueryItem(name: "fields",
                                  value: "title,author_name,first_publish_year,language"))
        components.queryItems = items
        guard let url = components.url else { return nil }
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = MetadataFetchService.requestTimeout
        // UA 固定串沿用既有服务（隐私契约：只含应用名与版本）。
        urlRequest.setValue(MetadataFetchService.userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await loader.data(for: urlRequest)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            return Self.parseOpenLibrary(data)
        } catch {
            return nil   // 契约：内部吞错，失败返回 nil 不抛。
        }
    }

    /// 解析 `{"docs":[…]}` 首条为统一条目契约（FetchedMetadata）；
    /// title 与 author 全缺 → nil（零命中等价，不回半空条目）。
    public static func parseOpenLibrary(_ data: Data) -> FetchedMetadata? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let docs = root["docs"] as? [[String: Any]],
              let first = docs.first else { return nil }
        var meta = FetchedMetadata()
        if let t = first["title"] as? String, !t.isEmpty { meta.title = t }
        if let authors = first["author_name"] as? [String] {
            let names = authors.compactMap { $0.isEmpty ? nil : $0 }
            if !names.isEmpty { meta.author = names.joined(separator: ", ") }
        }
        if let year = first["first_publish_year"] as? Int { meta.version = String(year) }
        if let languages = first["language"] as? [String], let lang = languages.first,
           !lang.isEmpty { meta.language = lang }
        return (meta.title == nil && meta.author == nil) ? nil : meta
    }
}
