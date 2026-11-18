import Foundation

// MARK: - 本机只读 HTTP API（纯逻辑层）
//
// 职责切分：本文件只含 token 生成、路由分派、参数解析与 JSON 形制——全部
// Foundation 纯逻辑（合成测试可导）；网络监听壳在 App 层
// LocalAPIServer.swift（全仓唯一 import Network 宿主，DesignGuard 测试）。
//
// 安全语义
//   - 只读是结构不是约定：路由注册表只按 GET 分派；其余动词一律落 405
// 降级处理，文件内不存在任何写动词字面（DesignGuard 守卫断言固定）。
//   - token 仅收 Authorization 头，不随查询串传递（Joplin 走查询参数会进
//     日志——超其上条款）；token 不进任何日志与审计条目。
//   - /ping 免鉴权（探针），其余端点鉴权失败一律 401。
//   - 形制五件照 Joplin Data API：探针、列裁剪、has_more 分页、错误 JSON、
//     events 游标——文案零复制，错误形制统一 {"error": "..."}。
//
// 常见反例：本地服务默认把 RPC 端口绑定全网卡
// （coreHost 默认全网卡地址）——本实现由监听壳把绑定端断言固定在本机环回
// （127.0.0.1 字面只出现在 LocalAPIServer.swift，DesignGuard 守卫断言固定）。

/// token 生成：Swift 标准库 SystemRandomNumberGenerator（官方文档定性为
/// 密码学安全随机源）——32 字节 → 小写 hex 64 字符。不引 Security/CryptoKit，
/// 零新 import。每次 App 启动重新生成（生命周期语义在 App 层壳与设置页）。
public enum LocalAPIToken {
    /// 随机字节数（32 字节 = 256 位熵）。
    static let byteCount = 32

    public static func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255, using: &rng)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// 鉴权比对：常数时间逐字节 XOR 累加——`==`
    public static func matches(_ candidate: String?, expected: String) -> Bool {
        guard let candidate else { return false }
        let a = Array(candidate.utf8)
        let b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for index in a.indices {
            diff |= a[index] ^ b[index]
        }
        return diff == 0
    }
}

// MARK: - 端点数据形状（Core 层 DTO；App 层与测试共用同一映射）

/// /books 行。path 类字段默认不出场：仅当请求显式点名 fields 含 path 才给
/// （默认响应不含本机文件路径，agents 拿书目不必知道文件位置）。
public struct LocalAPIBook: Equatable {
    public let id: String
    public let title: String?
    public let author: String?
    public let fileName: String
    public let pageCount: Int
    public let language: String?
    public let status: String
    /// 原件路径（索引库 real_path）。默认不裁入响应。
    public let path: String

    public init(id: String, title: String?, author: String?, fileName: String,
                pageCount: Int, language: String?, status: String, path: String) {
        self.id = id
        self.title = title
        self.author = author
        self.fileName = fileName
        self.pageCount = pageCount
        self.language = language
        self.status = status
        self.path = path
    }
}

/// /search 命中行（检索语义零漂移：数值来自既有 SearchService 只读调用链，
/// 本层只做投影，不参与归一化/排序）。
public struct LocalAPISearchHit: Equatable {
    public let bookID: String
    public let fileName: String
    public let title: String?
    public let physicalPage: Int
    public let snippet: String
    public let source: String

    public init(bookID: String, fileName: String, title: String?,
                physicalPage: Int, snippet: String, source: String) {
        self.bookID = bookID
        self.fileName = fileName
        self.title = title
        self.physicalPage = physicalPage
        self.snippet = snippet
        self.source = source
    }
}

/// /events 行（数据源=既有 index_queue 五态行读侧，只读）。
public struct LocalAPIEvent: Equatable {
    public let ordinal: Int
    public let bookID: String
    public let state: String
    public let queuedVersion: Int
    public let attempts: Int
    public let lastError: String?
    public let updatedAt: Double

    public init(ordinal: Int, bookID: String, state: String, queuedVersion: Int,
                attempts: Int, lastError: String?, updatedAt: Double) {
        self.ordinal = ordinal
        self.bookID = bookID
        self.state = state
        self.queuedVersion = queuedVersion
        self.attempts = attempts
        self.lastError = lastError
        self.updatedAt = updatedAt
    }
}

/// /annotations 行（功能扩展：单书批注只读清单；数据源=
/// HighlightStore.highlightsForBook 公共查询，note 经既有解密读路径出——
/// 密文/未解密内容不出网）。列集合与 annotations.csv 同一事实。
public struct LocalAPIAnnotation: Equatable {
    public let id: Int64
    public let bookID: String
    public let page: Int
    /// highlight | underline | page_note（与导出管道同一判定语义）。
    public let type: String
    public let color: String
    public let text: String
    public let note: String
    public let createdAtISO8601: String
    public let viewSource: String
    public let anchorVerified: Int

    public init(id: Int64, bookID: String, page: Int, type: String, color: String,
                text: String, note: String, createdAtISO8601: String,
                viewSource: String, anchorVerified: Int) {
        self.id = id
        self.bookID = bookID
        self.page = page
        self.type = type
        self.color = color
        self.text = text
        self.note = note
        self.createdAtISO8601 = createdAtISO8601
        self.viewSource = viewSource
        self.anchorVerified = anchorVerified
    }
}

/// 供给链可判别错误：书缺/页缺一类「资源不在」由路由器映射 404；其余照旧
/// 500（provider failed）。错误形制统一 {"error": "..."}。
public enum LocalAPIProviderError: Error, CustomStringConvertible {
    case notFound(String)
    case providerNotConfigured(String)

    public var description: String {
        switch self {
        case .notFound(let message): return message
        case .providerNotConfigured(let name): return "provider not configured: \(name)"
        }
    }
}

/// 数据面注入（纯逻辑层不持有 IndexStore：App 层给 live 实现，测试给
/// fixture 实现——同一套路由代码两条供给链）。
public struct LocalAPIProviders {
    /// 书列表页：offset 起最多 limit 行（router 已把 limit 截到上限）。
    public var books: (_ offset: Int, _ limit: Int) throws -> (rows: [LocalAPIBook], hasMore: Bool)
    /// 检索：只调既有只读公共 API（CLI search 同一条调用链）。
    public var search: (_ query: String, _ limit: Int) throws ->
        (hits: [LocalAPISearchHit], total: Int, hasMore: Bool, countCaliber: String)
    /// 索引变更增量：cursor=已投递序数（快照语义，docs/LOCAL-API.md 注记）。
    public var events: (_ cursor: Int, _ limit: Int) throws ->
        (rows: [LocalAPIEvent], nextCursor: Int, hasMore: Bool)
    /// 整页文本（功能扩展）：IndexStore.page 只读投影；书缺/
    /// 页缺由实现抛 LocalAPIProviderError.notFound（路由器 404）。
    public var page: (_ bookID: String, _ pageNumber: Int) throws ->
        (text: String, truncated: Bool)
    /// 单书批注只读清单（功能扩展）：book 必填，不做全库批注
    /// 出口；book 缺由实现抛 LocalAPIProviderError.notFound（404）。
    public var annotations: (_ bookID: String, _ offset: Int, _ limit: Int) throws ->
        (rows: [LocalAPIAnnotation], hasMore: Bool)

    /// CountCaliber 的 JSON 形态（"character" | "word"）。
    static func caliberString(_ c: CountCaliber) -> String {
        c == .wordLevel ? "word" : "character"
    }

    /// /page 页文本截断常量（防极端体量：一页现实量级的十余倍余量；截断时
    /// truncated=true 如实标注）。
    public static let pageTextMaxChars = 100_000

    /// 后两闭包带默认值：既有 fixture 调用点不必全改；默认实现抛
    /// providerNotConfigured → 路由器 500（显式报错，不静默）。
    public init(books: @escaping (Int, Int) throws -> (rows: [LocalAPIBook], hasMore: Bool),
                search: @escaping (String, Int) throws -> (hits: [LocalAPISearchHit], total: Int, hasMore: Bool, countCaliber: String),
                events: @escaping (Int, Int) throws -> (rows: [LocalAPIEvent], nextCursor: Int, hasMore: Bool),
                page: @escaping (String, Int) throws -> (text: String, truncated: Bool) =
                    { _, _ in throw LocalAPIProviderError.providerNotConfigured("page") },
                annotations: @escaping (String, Int, Int) throws -> (rows: [LocalAPIAnnotation], hasMore: Bool) =
                    { _, _, _ in throw LocalAPIProviderError.providerNotConfigured("annotations") }) {
        self.books = books
        self.search = search
        self.events = events
        self.page = page
        self.annotations = annotations
    }
}

extension LocalAPIProviders {
    /// live 供给链：books/events/page 直读 IndexStore 只读侧，annotations 走
    /// HighlightStore 公共查询（note 经既有解密读路径），search 走调用方
    /// 传入的 SearchService（App 层与 CLI search 同一条只读链，policy 一并
    /// 由调用方装配）。本函数与网络壳零耦合，合成测试可对 fixture 库直跑。
    /// highlights 句柄由调用方在主线程解析后传入（AppState/CLI 同款纪律）。
    public static func makeLive(store: IndexStore, search: SearchService,
                                highlights: HighlightStore) -> LocalAPIProviders {
        return LocalAPIProviders(
            books: { offset, limit in
                let all = try store.allBooks()
                let start = Swift.min(offset, all.count)
                let end = Swift.min(start + limit, all.count)
                let rows = all[start..<end].map { row in
                    LocalAPIBook(id: row.id, title: row.title, author: row.author,
                                 fileName: row.fileName, pageCount: row.pageCount,
                                 language: row.language, status: row.status,
                                 path: row.realPath)
                }
                return (rows, end < all.count)
            },
            search: { query, limit in
                var options = SearchOptions()
                options.limit = limit
                let result = try search.searchDetailed(query, options: options)
                let hits = result.hits.map { hit in
                    LocalAPISearchHit(bookID: hit.bookID, fileName: hit.fileName,
                                      title: hit.title, physicalPage: hit.physicalPage,
                                      snippet: hit.snippet, source: hit.source)
                }
                return (hits, result.totalPageMatches, result.truncated,
                        LocalAPIProviders.caliberString(result.countCaliber))
            },
            events: { cursor, limit in
                let all = try store.allQueueRows()
                // 功能扩展：行序改 book_id 稳定列。
                // allQueueRows 的 ORDER BY updated_at, book_id 会因每次入队
                // touch updated_at 而漂移，游标切片随之漏读/重读；内存按
                // book_id 重排后再切片，ordinal 只随 book_id 序变化——
                // 新册入队只会在序中间插入（边界可重复个别行，不漏读）。
                // JSON 形制、cursor=已投递序数、has_more 语义零变化。
                let stable = all.sorted { $0.bookID < $1.bookID }
                let start = Swift.min(Swift.max(cursor, 0), stable.count)
                let end = Swift.min(start + limit, stable.count)
                var rows: [LocalAPIEvent] = []
                for (index, row) in stable[start..<end].enumerated() {
                    rows.append(LocalAPIEvent(ordinal: start + index + 1,
                                              bookID: row.bookID, state: row.state.rawValue,
                                              queuedVersion: row.queuedVersion,
                                              attempts: row.attempts,
                                              lastError: row.lastError,
                                              updatedAt: row.updatedAt))
                }
                let nextCursor = end
                return (rows, nextCursor, end < stable.count)
            },
            page: { bookID, pageNumber in
                guard try store.book(byID: bookID) != nil else {
                    throw LocalAPIProviderError.notFound("not found: no such book")
                }
                guard let row = try store.page(bookID: bookID, pageNumber: pageNumber) else {
                    throw LocalAPIProviderError.notFound("not found: no such page")
                }
                let text = row.textOriginal
                if text.count > Self.pageTextMaxChars {
                    return (String(text.prefix(Self.pageTextMaxChars)), true)
                }
                return (text, false)
            },
            annotations: { bookID, offset, limit in
                // 单书粒度缩面：书不在即 404，不给全库批注出口。
                guard try store.book(byID: bookID) != nil else {
                    throw LocalAPIProviderError.notFound("not found: no such book")
                }
                // viewSource nil = 两视图并集（照导出管道同参）；note 已在
                // queryLocked 走既有解密读路径（密文不出网）。
                let all = try highlights.highlightsForBook(bookID, viewSource: nil)
                // 稳定列序：page ASC, id ASC（与导出侧 CSV 行序同基准）。
                let sorted = all.sorted { a, b in
                    a.pageNumber != b.pageNumber ? a.pageNumber < b.pageNumber : a.id < b.id
                }
                let rows = sorted.map { h -> LocalAPIAnnotation in
                    let type: String
                    let text: String
                    // type/text 判定与导出管道同语义（AnnotationExportPipeline
                    // csvRowsForBook 同源）；anchorVerified=1 时切页文本，否则
                    // anchorText 原样（resolvedText 同款：切不出回退锚文本）。
                    if AnnotationExportAssembler.isPageNote(h) {
                        type = "page_note"; text = ""
                    } else if h.style == "underline" {
                        type = "underline"; text = Self.resolvedAnnotationText(h, store: store)
                    } else {
                        type = "highlight"; text = Self.resolvedAnnotationText(h, store: store)
                    }
                    return LocalAPIAnnotation(
                        id: h.id, bookID: h.bookID, page: h.pageNumber, type: type,
                        color: h.color.rawValue, text: text, note: h.note,
                        createdAtISO8601: AnnotationExportPipeline.iso8601.string(from: h.createdAt),
                        viewSource: h.viewSource, anchorVerified: h.anchorVerified)
                }
                let start = Swift.min(Swift.max(offset, 0), rows.count)
                let end = Swift.min(start + limit, rows.count)
                return (Array(rows[start..<end]), end < rows.count)
            })
    }

    /// 批注摘句解析（照 AnnotationExportPipeline.resolvedText 同语义：
    /// anchorVerified=1 且切片可解 → 页文本切片；否则 anchorText 原样，
    /// 不猜不编造）。只读索引页文本。
    static func resolvedAnnotationText(_ h: UserHighlight, store: IndexStore) -> String {
        if h.anchorVerified == 1,
           let page = try? store.page(bookID: h.bookID, pageNumber: h.pageNumber) {
            let utf16 = page.textOriginal.utf16
            if h.utf16Start >= 0, h.utf16End <= utf16.count, h.utf16Start < h.utf16End {
                let s = utf16.index(utf16.startIndex, offsetBy: h.utf16Start)
                let e = utf16.index(utf16.startIndex, offsetBy: h.utf16End)
                let slice = String(decoding: utf16[s..<e], as: UTF16.self)
                if !slice.isEmpty { return slice }
            }
        }
        return h.anchorText
    }
}

// MARK: - 路由（纯函数分派）

/// 一次路由的响应（status + JSON body）。
public struct LocalAPIResponse: Equatable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    public var bodyText: String { String(data: body, encoding: .utf8) ?? "" }

    static func json(_ object: [String: Any], status: Int) -> LocalAPIResponse {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return LocalAPIResponse(status: 500, body: Data(#"{"error":"response serialization failed"}"#.utf8))
        }
        return LocalAPIResponse(status: status, body: data)
    }

    /// 统一错误形制（Joplin 同构：{"error": "..."}）。public：App 层网络壳
    /// 在路由器不可达的畸形报文分支也构造同形错误响应。
    public static func error(_ status: Int, _ message: String) -> LocalAPIResponse {
        return .json(["error": message], status: status)
    }
}

/// 端点参数上限。
public enum LocalAPILimits {
    /// 单页行数上限（books/events/search 三端点同 cap；超过按 200 处理）。
    public static let maxLimit = 200
    /// books/events 缺省页大小。
    public static let defaultPageLimit = 50
    /// search 缺省命中数。
    public static let defaultSearchLimit = 20
}

/// 纯函数路由：输入（method、请求目标、Authorization 头值）→ 输出
/// （status、JSON body）。只注册 GET（结构性只读）；除 /ping 外一律要求
/// Authorization 头等于当前 token，缺失/不符 401。
public final class LocalAPIRouter {
    /// 当前访问凭据（每次 App 启动重新生成；只作精确比对，不做前缀/大小写宽限）。
    public let token: String
    public let appVersion: String
    public let schemaVersion: Int
    public let providers: LocalAPIProviders

    /// fields 白名单（/books 列裁剪）。path 类字段默认不出场。
    static let bookFieldWhitelist: Set<String> =
        ["id", "title", "author", "file_name", "page_count", "language", "status", "path"]

    public init(token: String, appVersion: String, schemaVersion: Int,
                providers: LocalAPIProviders) {
        self.token = token
        self.appVersion = appVersion
        self.schemaVersion = schemaVersion
        self.providers = providers
    }

    /// route 入口。target = 请求行里的目标（"/books?offset=0"）；
    /// authorization = Authorization 头原始值（nil = 头缺失）。
    public func route(method: String, target: String, authorization: String?) -> LocalAPIResponse {
        // 结构性只读第一层：注册表只按 GET 分派。其余动词（含写动词与
        // HEAD 等未注册动词）一律落 405 降级处理——不存在可注册的写端点。
        guard method == "GET" else {
            return .error(405, "method not allowed: this endpoint is read-only")
        }
        let (path, query) = Self.splitTarget(target)
        // 结构性只读第二层：鉴权。/ping 是探针免凭据；其余缺失/不符一律 401
        // （比对走常数时间 matches，不直接使用 `==`）。
        guard path == "/ping" || LocalAPIToken.matches(authorization, expected: token) else {
            return .error(401, "unauthorized: missing or invalid Authorization header")
        }
        switch path {
        case "/ping":
            return .json(["app": "literaturesearch",
                          "schema": schemaVersion,
                          "version": appVersion], status: 200)
        case "/books":
            return routeBooks(query: query)
        case "/search":
            return routeSearch(query: query)
        case "/events":
            return routeEvents(query: query)
        case "/page":
            return routePage(query: query)
        case "/annotations":
            return routeAnnotations(query: query)
        default:
            return .error(404, "not found: unknown endpoint")
        }
    }

    // MARK: 端点实现

    private func routeBooks(query: String) -> LocalAPIResponse {
        let params = Self.parseQuery(query)
        guard let offset = intValue(params, "offset", default: 0), offset >= 0 else {
            return .error(400, "invalid offset")
        }
        guard let limit = intValue(params, "limit", default: LocalAPILimits.defaultPageLimit),
              limit >= 0 else {
            return .error(400, "invalid limit")
        }
        let capped = Swift.min(limit, LocalAPILimits.maxLimit)
        // 列裁剪：fields=id,title 只回两键；未点名 → 默认集（不含 path 类字段）；
        // 白名单外键名忽略（Joplin 形制宽容侧，文档注记）。
        let requested = params.first { $0.0 == "fields" }?.1
        let fields: Set<String>
        if let requested, !requested.isEmpty {
            let names = requested.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            fields = Set(names).intersection(Self.bookFieldWhitelist)
            if fields.isEmpty {
                return .error(400, "invalid fields: no known field requested")
            }
        } else {
            fields = Self.bookFieldWhitelist.subtracting(["path"])
        }
        do {
            let page = try providers.books(offset, capped)
            let books: [[String: Any]] = page.rows.map { row in
                var item: [String: Any] = [:]
                if fields.contains("id") { item["id"] = row.id }
                if fields.contains("title") { item["title"] = row.title ?? NSNull() }
                if fields.contains("author") { item["author"] = row.author ?? NSNull() }
                if fields.contains("file_name") { item["file_name"] = row.fileName }
                if fields.contains("page_count") { item["page_count"] = row.pageCount }
                if fields.contains("language") { item["language"] = row.language ?? NSNull() }
                if fields.contains("status") { item["status"] = row.status }
                if fields.contains("path") { item["path"] = row.path }
                return item
            }
            return .json(["books": books,
                          "offset": offset,
                          "limit": capped,
                          "has_more": page.hasMore], status: 200)
        } catch {
            return .error(500, "provider failed: \(Self.describe(error))")
        }
    }

    private func routeSearch(query: String) -> LocalAPIResponse {
        let params = Self.parseQuery(query)
        guard let q = params.first(where: { $0.0 == "q" })?.1 else {
            return .error(400, "missing q")
        }
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .error(400, "empty q")
        }
        guard let limit = intValue(params, "limit", default: LocalAPILimits.defaultSearchLimit),
              limit >= 0 else {
            return .error(400, "invalid limit")
        }
        let capped = Swift.min(limit, LocalAPILimits.maxLimit)
        do {
            let result = try providers.search(trimmed, capped)
            let hits: [[String: Any]] = result.hits.map { hit in
                ["book_id": hit.bookID,
                 "file_name": hit.fileName,
                 "title": hit.title ?? NSNull(),
                 "physical_page": hit.physicalPage,
                 "snippet": hit.snippet,
                 "source": hit.source]
            }
            return .json(["query": trimmed,
                          "total": result.total,
                          "hits": hits,
                          "has_more": result.hasMore,
                          "count_caliber": result.countCaliber], status: 200)
        } catch {
            return .error(500, "provider failed: \(Self.describe(error))")
        }
    }

    private func routeEvents(query: String) -> LocalAPIResponse {
        let params = Self.parseQuery(query)
        guard let cursor = intValue(params, "cursor", default: 0), cursor >= 0 else {
            return .error(400, "invalid cursor")
        }
        guard let limit = intValue(params, "limit", default: LocalAPILimits.defaultPageLimit),
              limit >= 0 else {
            return .error(400, "invalid limit")
        }
        let capped = Swift.min(limit, LocalAPILimits.maxLimit)
        do {
            let page = try providers.events(cursor, capped)
            let rows: [[String: Any]] = page.rows.map { event in
                var item: [String: Any] = ["ordinal": event.ordinal,
                                           "book_id": event.bookID,
                                           "state": event.state,
                                           "queued_version": event.queuedVersion,
                                           "attempts": event.attempts,
                                           "updated_at": event.updatedAt]
                item["last_error"] = event.lastError ?? NSNull()
                return item
            }
            return .json(["events": rows,
                          "cursor": page.nextCursor,
                          "has_more": page.hasMore], status: 200)
        } catch {
            return .error(500, "provider failed: \(Self.describe(error))")
        }
    }

    /// GET /page?book=<bookID>&page=<N> —— 整页文本（功能扩展，
    /// 只读）。书缺/页缺 404、参数非法 400；超长截断如实标注。
    private func routePage(query: String) -> LocalAPIResponse {
        let params = Self.parseQuery(query)
        guard let book = params.first(where: { $0.0 == "book" })?.1,
              !book.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .error(400, "missing book")
        }
        guard let pageNumber = intValue(params, "page", default: 0), pageNumber >= 1 else {
            return .error(400, "invalid page")
        }
        do {
            let result = try providers.page(book, pageNumber)
            return .json(["book_id": book,
                          "page": pageNumber,
                          "chars": result.text.count,
                          "text": result.text,
                          "truncated": result.truncated], status: 200)
        } catch {
            return Self.providerFailure(error)
        }
    }

    /// GET /annotations?book=<bookID>&offset=&limit= —— 单书批注只读清单
    /// （功能扩展）。book 必填（单书粒度，不做全库批注出口）；
    /// 列序 page ASC, id ASC；note 经既有解密读路径（密文不出网）。
    private func routeAnnotations(query: String) -> LocalAPIResponse {
        let params = Self.parseQuery(query)
        guard let book = params.first(where: { $0.0 == "book" })?.1,
              !book.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .error(400, "missing book")
        }
        guard let offset = intValue(params, "offset", default: 0), offset >= 0 else {
            return .error(400, "invalid offset")
        }
        guard let limit = intValue(params, "limit", default: LocalAPILimits.defaultPageLimit),
              limit >= 0 else {
            return .error(400, "invalid limit")
        }
        let capped = Swift.min(limit, LocalAPILimits.maxLimit)
        do {
            let page = try providers.annotations(book, offset, capped)
            let rows: [[String: Any]] = page.rows.map { row in
                ["id": Int(row.id),
                 "book_id": row.bookID,
                 "page": row.page,
                 "type": row.type,
                 "color": row.color,
                 "text": row.text,
                 "note": row.note,
                 "created_at_iso8601": row.createdAtISO8601,
                 "view_source": row.viewSource,
                 "anchor_verified": row.anchorVerified]
            }
            return .json(["annotations": rows,
                          "offset": offset,
                          "limit": capped,
                          "has_more": page.hasMore], status: 200)
        } catch {
            return Self.providerFailure(error)
        }
    }

    // MARK: 解析助手（纯函数）

    /// 请求行目标切分："/books?offset=0" → ("/books", "offset=0")。
    static func splitTarget(_ target: String) -> (path: String, query: String) {
        guard let questionMark = target.firstIndex(of: "?") else {
            return (target, "")
        }
        let path = String(target[target.startIndex..<questionMark])
        let query = String(target[target.index(after: questionMark)...])
        return (path, query)
    }

    /// 查询串解析（percent-decode 走 URLComponents；非法串回退不崩）。
    static func parseQuery(_ query: String) -> [(String, String)] {
        guard !query.isEmpty else { return [] }
        guard let components = URLComponents(string: "http://loopback?\(query)"),
              let items = components.queryItems else {
            return []
        }
        return items.compactMap { item in
            guard let name = item.name.removingPercentEncoding else { return nil }
            let value = item.value?.removingPercentEncoding ?? ""
            return (name, value)
        }
    }

    private func intValue(_ params: [(String, String)], _ name: String,
                          default: Int) -> Int? {
        guard let raw = params.first(where: { $0.0 == name })?.1 else {
            return `default`
        }
        return Int(raw)
    }

    private static func describe(_ error: Error) -> String {
        let rendered = String(describing: error)
        // 单行化并截断：错误串进响应体但不放任其超长（诚实报错，不吞细节）。
        let oneLine = rendered
            .replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > 300 ? String(oneLine.prefix(300)) + "…" : oneLine
    }

    /// 供给链错误统一判定：notFound（书缺/页缺一类「资源不在」）→ 404；
    /// 其余照旧 500（provider failed）。错误形制统一 {"error": "..."}。
    static func providerFailure(_ error: Error) -> LocalAPIResponse {
        if case LocalAPIProviderError.notFound(let message) = error {
            return .error(404, message)
        }
        return .error(500, "provider failed: \(Self.describe(error))")
    }
}
