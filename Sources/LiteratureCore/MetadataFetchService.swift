import Foundation

// MARK: - scraper 元数据链：五源逐级回填（镜：JabRef 保守合并 +


public enum MetadataSource: String, CaseIterable, Sendable {
    case crossref
    case arxiv
    case dblp
    case semanticScholar
    case openLibrary

    /// 请求域白名单（隐私契约：请求只发往这五个注册域）。
    public var host: String {
        switch self {
        case .crossref: return "api.crossref.org"
        case .arxiv: return "export.arxiv.org"
        case .dblp: return "dblp.org"
        case .semanticScholar: return "api.semanticscholar.org"
        case .openLibrary: return "openlibrary.org"
        }
    }

    /// 写入索引时的审计标签（AppState.swift updateMetadata 通道延续）。
    public var auditTag: String { "fetch:\(rawValue)" }
}

// MARK: - 注入点（对齐 SecretStore 协议抽象与 WebDAV StubClient 惯例）

public protocol MetadataHTTPLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// 生产实现：URLSession 直连（零第三方依赖；超时由请求的 timeoutInterval=15s）。
public struct URLSessionMetadataLoader: MetadataHTTPLoading {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

// MARK: - 结果模型

/// 单源抓得的候选元数据（缺字段留 nil；未知不猜）。
public struct FetchedMetadata: Equatable, Sendable {
    public var title: String?
    public var author: String?
    public var version: String?
    public var language: String?
    /// arXiv 等来源回得的 DOI（供链内续查 Crossref 一次）。
    public var doi: String?

    public init(title: String? = nil, author: String? = nil, version: String? = nil,
                language: String? = nil, doi: String? = nil) {
        self.title = title
        self.author = author
        self.version = version
        self.language = language
        self.doi = doi
    }
}

/// 回填报告（每书：各源结果/补到字段/跳过原因；环形保留最近 10 次）。
public struct MetadataFetchReport: Codable, Equatable, Sendable {
    public struct SourceOutcome: Codable, Equatable, Sendable {
        public var source: String
        public var requested: Bool
        public var ok: Bool
        public var appliedFields: [String]
        public var note: String

        public init(source: String, requested: Bool, ok: Bool,
                    appliedFields: [String], note: String) {
            self.source = source
            self.requested = requested
            self.ok = ok
            self.appliedFields = appliedFields
            self.note = note
        }
    }

    public var bookID: String
    public var fileName: String
    public var timestamp: Date
    public var outcomes: [SourceOutcome]
    /// 本链合计补到的字段（去重保序）。
    public var appliedFields: [String]

    public init(bookID: String, fileName: String, timestamp: Date,
                outcomes: [SourceOutcome], appliedFields: [String]) {
        self.bookID = bookID
        self.fileName = fileName
        self.timestamp = timestamp
        self.outcomes = outcomes
        self.appliedFields = appliedFields
    }
}

// MARK: - 服务

public struct MetadataFetchService: Sendable {
    /// UA 固定串：只含应用名与版本，无任何本机标识（隐私契约）。
    public static let userAgent = "LiteratureSearch/7.4"
    /// 单请求超时（秒）。零自动重试。
    public static let requestTimeout: TimeInterval = 15

    let loader: MetadataHTTPLoading

    public init(loader: MetadataHTTPLoading) {
        self.loader = loader
    }

    /// 一次手动触发的完整链。`enabled` 为关到源集合（空 = 零请求）；
    /// DOI/arXiv ID 由用户在详情页粘贴（或既有元数据）；title/author 作
    /// 模糊回退查询串（只含这两个词本身，不含任何库内容；title 缺时用
    /// 文件名规范化降级处理，outcome note 如实标注。
    @discardableResult
    public func fetch(bookID: String, fileName: String,
                      doi: String?, arxivID: String?,
                      title: String?, author: String?,
                      store: IndexStore,
                      enabled: Set<MetadataSource>,
                      reportURL: URL? = nil) async -> MetadataFetchReport {
        var outcomes: [MetadataFetchReport.SourceOutcome] = []
        var merged = FetchedMetadata()

        var crossrefUsed = false

        let fuzzyTitle: String? = {
            if let t = title, !t.isEmpty { return t }
            return FileNameNormalization.normalizedTitleGuess(from: fileName)
        }()
        let fuzzyFromFileName = (title ?? "").isEmpty && fuzzyTitle != nil
        /// 模糊查询 outcome note 补记（requested 且走了降级处理才标）。
        func noted(_ outcome: MetadataFetchReport.SourceOutcome) -> MetadataFetchReport.SourceOutcome {
            var o = outcome
            if fuzzyFromFileName && o.requested { o.note += "（查询串来自文件名规范化）" }
            return o
        }

        if let doi, !doi.isEmpty, enabled.contains(.crossref) {
            let outcome = await requestCrossref(doi: doi)
            outcomes.append(outcome.outcome)
            merge(outcome.metadata, into: &merged)
            crossrefUsed = true
        } else {
            outcomes.append(.init(source: MetadataSource.crossref.rawValue,
                                  requested: false, ok: false, appliedFields: [],
                                  note: doi == nil || doi!.isEmpty
                                    ? "无 DOI" : "源已关闭"))
        }

        if (doi == nil || doi!.isEmpty), let arxivID, !arxivID.isEmpty,
           enabled.contains(.arxiv) {
            let outcome = await requestArxiv(id: arxivID)
            outcomes.append(outcome.outcome)
            merge(outcome.metadata, into: &merged)
            if let fetchedDOI = outcome.metadata?.doi, !fetchedDOI.isEmpty,
               enabled.contains(.crossref), !crossrefUsed {
                let followup = await requestCrossref(doi: fetchedDOI)
                outcomes.append(followup.outcome)
                merge(followup.metadata, into: &merged)
                crossrefUsed = true
            }
        } else if doi == nil || doi!.isEmpty {
            outcomes.append(.init(source: MetadataSource.arxiv.rawValue,
                                  requested: false, ok: false, appliedFields: [],
                                  note: arxivID == nil || arxivID!.isEmpty
                                    ? "无 arXiv ID" : "源已关闭"))
        } else {
            outcomes.append(.init(source: MetadataSource.arxiv.rawValue,
                                  requested: false, ok: false, appliedFields: [],
                                  note: "已有 DOI（否则语义：不降级 arXiv）"))
        }

        if merged.title == nil, enabled.contains(.dblp), let t = fuzzyTitle, !t.isEmpty {
            let outcome = await requestDBLP(title: t, author: author)
            outcomes.append(noted(outcome.outcome))
            merge(outcome.metadata, into: &merged)
        } else if merged.title == nil {
            outcomes.append(.init(source: MetadataSource.dblp.rawValue,
                                  requested: false, ok: false, appliedFields: [],
                                  note: fuzzyTitle == nil ? "无标题可查" : "源已关闭"))
        }

        if merged.title == nil, enabled.contains(.semanticScholar), let t = fuzzyTitle, !t.isEmpty {
            let outcome = await requestSemanticScholar(title: t, author: author)
            outcomes.append(noted(outcome.outcome))
            merge(outcome.metadata, into: &merged)
        } else if merged.title == nil {
            outcomes.append(.init(source: MetadataSource.semanticScholar.rawValue,
                                  requested: false, ok: false, appliedFields: [],
                                  note: fuzzyTitle == nil ? "无标题可查" : "源已关闭"))
        }

        if merged.title == nil, enabled.contains(.openLibrary), let t = fuzzyTitle, !t.isEmpty {
            let outcome = await requestOpenLibrary(title: t, author: author)
            outcomes.append(noted(outcome.outcome))
            merge(outcome.metadata, into: &merged)
        } else if merged.title == nil {
            outcomes.append(.init(source: MetadataSource.openLibrary.rawValue,
                                  requested: false, ok: false, appliedFields: [],
                                  note: fuzzyTitle == nil ? "无标题可查" : "源已关闭"))
        }

        // 保守合并写入：现状非空的字段传 nil（updateMetadata COALESCE 保留）。
        var applied: [String] = []
        if let book = try? store.book(byID: bookID) {
            func onlyIfNil<T>(_ fetched: T?, _ current: T?) -> T? {
                (current == nil || (current as? String == "")) ? fetched : nil
            }
            let newTitle = onlyIfNil(merged.title, book.title)
            let newAuthor = onlyIfNil(merged.author, book.author)
            let newVersion = onlyIfNil(merged.version, book.version)
            let newLanguage = onlyIfNil(merged.language, book.language)
            let primary = outcomes.first { $0.requested && $0.ok }
            let tag = primary.map { MetadataSource(rawValue: $0.source)?.auditTag ?? "fetch" }
                ?? "fetch"
            if newTitle != nil || newAuthor != nil || newVersion != nil || newLanguage != nil {
                if newTitle != nil { applied.append("title") }
                if newAuthor != nil { applied.append("author") }
                if newVersion != nil { applied.append("version") }
                if newLanguage != nil { applied.append("language") }
                _ = try? store.updateMetadata(bookID: bookID, title: newTitle,
                                              author: newAuthor, version: newVersion,
                                              language: newLanguage, source: tag)
            }
        }

        var report = MetadataFetchReport(
            bookID: bookID, fileName: fileName, timestamp: Date(),
            outcomes: outcomes, appliedFields: applied)
        if let url = reportURL {
            Self.appendAndTrim(report, to: 10, url: url)
        }
        return report
    }

    // MARK: 报告环形落盘（原子写；最近 10 次）

    public static func loadReports(url: URL) -> [MetadataFetchReport] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([MetadataFetchReport].self, from: data)
        else { return [] }
        return list
    }

    public static func appendAndTrim(_ report: MetadataFetchReport, to limit: Int, url: URL) {
        var list = loadReports(url: url)
        list.append(report)
        if list.count > limit { list = Array(list.suffix(limit)) }
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: 各源请求（每源至多一次；失败静默降级，零重试）

    func request(_ source: MetadataSource, url: URL) async -> (Data?, String) {
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeout
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await loader.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return (nil, "HTTP \(http.statusCode)")
            }
            return (data, "")
        } catch {
            return (nil, String(describing: error))
        }
    }

    func requestCrossref(doi: String) async -> (metadata: FetchedMetadata?,
                                                outcome: MetadataFetchReport.SourceOutcome) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = MetadataSource.crossref.host
        components.path = "/works/\(doi)"
        guard let url = components.url else {
            return (nil, .init(source: MetadataSource.crossref.rawValue, requested: true,
                               ok: false, appliedFields: [], note: "DOI 无法编码为合法 URL"))
        }
        let (data, note) = await request(.crossref, url: url)
        guard let data else {
            return (nil, .init(source: MetadataSource.crossref.rawValue, requested: true,
                               ok: false, appliedFields: [], note: note))
        }
        guard let meta = Self.parseCrossref(data) else {
            return (nil, .init(source: MetadataSource.crossref.rawValue, requested: true,
                               ok: false, appliedFields: [], note: "响应不可解析"))
        }
        return (meta, .init(source: MetadataSource.crossref.rawValue, requested: true,
                            ok: true, appliedFields: meta.appliedFields(), note: "查得"))
    }

    func requestArxiv(id: String) async -> (metadata: FetchedMetadata?,
                                            outcome: MetadataFetchReport.SourceOutcome) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = MetadataSource.arxiv.host
        components.path = "/api/query"
        components.queryItems = [URLQueryItem(name: "id_list", value: id)]
        guard let url = components.url else {
            return (nil, .init(source: MetadataSource.arxiv.rawValue, requested: true,
                               ok: false, appliedFields: [], note: "arXiv ID 无法编码"))
        }
        let (data, note) = await request(.arxiv, url: url)
        guard let data else {
            return (nil, .init(source: MetadataSource.arxiv.rawValue, requested: true,
                               ok: false, appliedFields: [], note: note))
        }
        guard let meta = Self.parseArxivAtom(data) else {
            return (nil, .init(source: MetadataSource.arxiv.rawValue, requested: true,
                               ok: false, appliedFields: [], note: "响应不可解析"))
        }
        return (meta, .init(source: MetadataSource.arxiv.rawValue, requested: true,
                            ok: true, appliedFields: meta.appliedFields(), note: "查得"))
    }

    func requestDBLP(title: String, author: String?) async
    -> (metadata: FetchedMetadata?, outcome: MetadataFetchReport.SourceOutcome) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = MetadataSource.dblp.host
        components.path = "/search/publ/api"
        var query = title
        if let author, !author.isEmpty { query += " " + author }
        components.queryItems = [URLQueryItem(name: "q", value: query),
                                 URLQueryItem(name: "format", value: "json")]
        guard let url = components.url else {
            return (nil, .init(source: MetadataSource.dblp.rawValue, requested: true,
                               ok: false, appliedFields: [], note: "查询串无法编码"))
        }
        let (data, note) = await request(.dblp, url: url)
        guard let data else {
            return (nil, .init(source: MetadataSource.dblp.rawValue, requested: true,
                               ok: false, appliedFields: [], note: note))
        }
        guard let meta = Self.parseDBLP(data) else {
            return (nil, .init(source: MetadataSource.dblp.rawValue, requested: true,
                               ok: false, appliedFields: [], note: "响应不可解析或零命中"))
        }
        return (meta, .init(source: MetadataSource.dblp.rawValue, requested: true,
                            ok: true, appliedFields: meta.appliedFields(), note: "查得"))
    }

    func requestSemanticScholar(title: String, author: String?) async
    -> (metadata: FetchedMetadata?, outcome: MetadataFetchReport.SourceOutcome) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = MetadataSource.semanticScholar.host
        components.path = "/graph/v1/paper/search"
        components.queryItems = [URLQueryItem(name: "query", value: title),
                                 URLQueryItem(name: "fields", value: "title,authors,year,externalIds")]
        guard let url = components.url else {
            return (nil, .init(source: MetadataSource.semanticScholar.rawValue,
                               requested: true, ok: false, appliedFields: [],
                               note: "查询串无法编码"))
        }
        let (data, note) = await request(.semanticScholar, url: url)
        guard let data else {
            return (nil, .init(source: MetadataSource.semanticScholar.rawValue,
                               requested: true, ok: false, appliedFields: [], note: note))
        }
        guard let meta = Self.parseSemanticScholar(data) else {
            return (nil, .init(source: MetadataSource.semanticScholar.rawValue,
                               requested: true, ok: false, appliedFields: [],
                               note: "响应不可解析或零命中"))
        }
        return (meta, .init(source: MetadataSource.semanticScholar.rawValue, requested: true,
                            ok: true, appliedFields: meta.appliedFields(), note: "查得"))
    }

    func requestOpenLibrary(title: String, author: String?) async
    -> (metadata: FetchedMetadata?, outcome: MetadataFetchReport.SourceOutcome) {
        return await runAdapter(OpenLibrarySiteAdapter(),
                                request: MetadataLookupRequest(title: title, author: author))
    }

    /// 站点适配器统一运行口：成功带 appliedFields 报「查得」；nil/异常一律
    /// ok=false——单源故障只降级该源，不传导。
    func runAdapter(_ adapter: MetadataSiteAdapter,
                    request: MetadataLookupRequest) async
    -> (metadata: FetchedMetadata?, outcome: MetadataFetchReport.SourceOutcome) {
        do {
            guard let meta = await adapter.lookup(request, loader: loader) else {
                return (nil, .init(source: adapter.sourceID, requested: true,
                                   ok: false, appliedFields: [],
                                   note: "响应不可解析或零命中"))
            }
            return (meta, .init(source: adapter.sourceID, requested: true,
                                ok: true, appliedFields: meta.appliedFields(), note: "查得"))
        } catch {
            // 双保险降级处理（契约不抛，理论不可达；可达即如实记源内故障）。
            return (nil, .init(source: adapter.sourceID, requested: true,
                               ok: false, appliedFields: [],
                               note: String(describing: error)))
        }
    }

    func merge(_ meta: FetchedMetadata?, into merged: inout FetchedMetadata) {
        guard let meta else { return }
        if merged.title == nil { merged.title = meta.title }
        if merged.author == nil { merged.author = meta.author }
        if merged.version == nil { merged.version = meta.version }
        if merged.language == nil { merged.language = meta.language }
        if merged.doi == nil { merged.doi = meta.doi }
    }

    // MARK: 解析器（零依赖：JSONSerialization / XMLParser）

    /// Crossref `works/<doi>` → 候选元数据。缺字段留 nil。
    public static func parseCrossref(_ data: Data) -> FetchedMetadata? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? [String: Any] else { return nil }
        var meta = FetchedMetadata()
        if let titles = message["title"] as? [String], let t = titles.first, !t.isEmpty {
            meta.title = t
        }
        if let authors = message["author"] as? [[String: Any]] {
            let names = authors.compactMap { entry -> String? in
                let given = entry["given"] as? String ?? ""
                let family = entry["family"] as? String ?? ""
                let full = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
                return full.isEmpty ? nil : full
            }
            if !names.isEmpty { meta.author = names.joined(separator: ", ") }
        }
        if let editions = message["edition"] as? String, !editions.isEmpty {
            meta.version = editions
        }
        if let language = message["language"] as? String, !language.isEmpty {
            meta.language = language
        }
        return meta
    }

    /// arXiv Atom → 最小 XMLParser 解析（entry 的 title/author name/doi）。
    public static func parseArxivAtom(_ data: Data) -> FetchedMetadata? {
        let delegate = ArxivAtomDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let entry = delegate.entry else { return nil }
        return entry
    }

    /// DBLP `search/publ/api` → 首条命中的候选元数据（零命中返回 nil）。
    public static func parseDBLP(_ data: Data) -> FetchedMetadata? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let hits = result["hits"] as? [String: Any],
              let hitList = hits["hit"] as? [[String: Any]],
              let first = hitList.first,
              let info = first["info"] as? [String: Any] else { return nil }
        var meta = FetchedMetadata()
        if let t = info["title"] as? String, !t.isEmpty { meta.title = t }
        if let authors = info["authors"] as? [String: Any],
           let authorList = authors["author"] as? [Any] {
            let names = authorList.compactMap { entry -> String? in
                if let text = (entry as? [String: Any])?["text"] as? String, !text.isEmpty {
                    return text
                }
                return entry as? String
            }
            if !names.isEmpty { meta.author = names.joined(separator: ", ") }
        } else if let single = info["authors"] as? [String: Any],
                  let one = single["author"] as? [String: Any],
                  let text = one["text"] as? String, !text.isEmpty {
            meta.author = text
        }
        if let year = info["year"] as? String, !year.isEmpty { meta.version = year }
        if let doi = info["doi"] as? String, !doi.isEmpty { meta.doi = doi }
        return (meta.title == nil && meta.author == nil) ? nil : meta
    }

    /// Semantic Scholar `paper/search` → 首条命中的候选元数据。
    public static func parseSemanticScholar(_ data: Data) -> FetchedMetadata? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let papers = root["data"] as? [[String: Any]],
              let first = papers.first else { return nil }
        var meta = FetchedMetadata()
        if let t = first["title"] as? String, !t.isEmpty { meta.title = t }
        if let authors = first["authors"] as? [[String: Any]] {
            let names = authors.compactMap { ($0["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            if !names.isEmpty { meta.author = names.joined(separator: ", ") }
        }
        if let year = first["year"] as? Int { meta.version = String(year) }
        if let ids = first["externalIds"] as? [String: Any],
           let doi = ids["DOI"] as? String, !doi.isEmpty { meta.doi = doi }
        return (meta.title == nil && meta.author == nil) ? nil : meta
    }
}

extension FetchedMetadata {
    /// 报告用：本源实际带到的字段名（按 updateMetadata 四字段基准）。
    func appliedFields() -> [String] {
        var out: [String] = []
        if title != nil { out.append("title") }
        if author != nil { out.append("author") }
        if version != nil { out.append("version") }
        if language != nil { out.append("language") }
        return out
    }
}

/// arXiv Atom 的最小 delegate：只取 entry 级 title / author name / arxiv:doi。
final class ArxivAtomDelegate: NSObject, XMLParserDelegate {
    var entry: FetchedMetadata?
    private var currentElement = ""
    private var currentText = ""
    private var authors: [String] = []
    private var inEntry = false
    private var sawAnyEntry = false

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = elementName.contains(":") ? String(elementName.split(separator: ":").last!) : elementName
        currentElement = name
        currentText = ""
        if name == "entry" {
            inEntry = true
            sawAnyEntry = true
            entry = FetchedMetadata()
            authors = []
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.contains(":") ? String(elementName.split(separator: ":").last!) : elementName
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if inEntry {
            switch (name, currentElement) {
            case ("title", "title"):
                if !text.isEmpty, entry?.title == nil { entry?.title = text }
            case ("name", "name"):
                if !text.isEmpty { authors.append(text) }
            case ("doi", "doi"):
                if !text.isEmpty { entry?.doi = text }
            case ("entry", "entry"):
                if !authors.isEmpty { entry?.author = authors.joined(separator: ", ") }
                inEntry = false
            default:
                break
            }
        }
        currentElement = ""
    }
}
