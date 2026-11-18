import Foundation

// MARK: - MCP 只读桥（docs/LOCAL-API.md）
//
// 定位：MCP 是 LocalAPI 的 stdio 形态。本文件只做 JSON-RPC 2.0 ↔
// LocalAPIRouter 纯逻辑层的翻译：五个只读工具（search／books／events／
// page／annotations——后两工具为 功能扩展 契约扩展，
// docs/LOCAL-API.md 同步修订在案）
// 逐一落到既有路由端点上（route(method:"GET", target:…, authorization:…)
// 直调），零新网络面、零新增写路径、零第三方依赖（仅 Foundation）。
// 检索语义零触碰：命中数值全部来自 providers 既有只读链（CLI search 同
// 一条链），本层只拼查询目标串，不参与归一化／排序／计数基准。
//
// 安全语义（照 LocalAPI 三语义，一字不动）：
//   - token：沿用 LocalAPIToken——同形制（64 位小写 hex）、同比对函数
//     （matches 常数时间）、同每次启动轮换生命周期（由 mcp-serve 显式供
//     给，见 CLI 壳）。stdio 无请求头可携带，凭据经 params._meta.authorization
//     进入路由器——那是 Authorization 头的 stdio 等位物，不是第二鉴权面。
//     tools/list 与 tools/call 每次校验；/ping 免鉴权的对位是 initialize
//     握手免鉴权（协议握手，零库数据）。401 语义逐字保留：映射错误的
//     message 取路由器响应体原文，data.status 携带 HTTP 语义状态码。
//   - 只读：一切数据调用经 LocalAPIRouter.route——路由器只注册读取端
//     点，写面在结构上不存在；本文件不出现任何写动词字面（DesignGuard
// 守卫随 LocalAPI.swift 同列断言固定）。
//   - 环回：MCP 形态无监听端（stdio 管道，非网络），环回绑定语义只属
//     LocalAPIServer——本文件不开任何端口、不做任何连接。
//
// 审计（照 LocalAPI 审计语义）：每次调用记 端点路径（不含查询串——查询
// 正文不落审计）／状态码／耗时／字节数，零凭据零正文。stdio 壳把审计行
// 写 stderr（stdout 是协议通道必须纯净）；环形陈列面属 App 设置页，CLI
// 无 UI，一行一审。
//
// 分形与并发：一行一条 JSON-RPC 报文（MCP stdio 传输形制，报文内不得含
// 裸换行）。stdio 壳顺序分派（SQLite 读侧单线程纪律）；handle 本身无共
// 享可变状态，并发两次调用相互隔离（测试在案）。

/// 一次桥接调用的审计条目（照 LocalAPI 审计语义；stdout 纯净性见文件头注）。
public struct MCPBridgeAudit {
    /// 端点路径（不含查询串——查询正文不落审计，约束同 LocalAPI）。
    public let endpoint: String
    /// 路由层 HTTP 语义状态（协议级成功记 200；鉴权失败记 401）。
    public let status: Int
    public let milliseconds: Double
    /// 实发响应字节数（JSON-RPC 响应行 UTF-8 长度）。
    public let bytes: Int

    /// stderr 审计行（单行；不含查询正文、不含凭据）。
    public var stderrLine: String {
        let ms = String(format: "%.1f", milliseconds)
        return "mcp-audit \(endpoint) \(status) \(ms)ms \(bytes)B"
    }
}

/// JSON-RPC 2.0 错误码（标准段＋服务端自定义 -32000 段）。
public enum MCPJSONRPCCode: Int {
    case parseError = -32700
    case invalidRequest = -32600
    case methodNotFound = -32601
    case invalidParams = -32602
    case internalError = -32603
    /// 服务端自定义段：LocalAPI 401 语义映射（鉴权缺失/不符）。
    case unauthorized = -32001
    /// 服务端自定义段：其余上游非 200 状态降级处理。
    case upstream = -32000
}

public enum MCPRequestID {
    case absent
    case null
    case value(Any)

    var present: Bool {
        if case .absent = self { return false }
        return true
    }

    var jsonValue: Any {
        switch self {
        case .absent, .null: return NSNull()
        case .value(let any): return any
        }
    }
}

/// 一次 handle 的产出（response=nil＝无回应：通知／空行）。
public struct MCPBridgeOutput {
    public let response: String?
    public let audit: MCPBridgeAudit?
}

/// MCP stdio 只读桥。持有一个既有 LocalAPIRouter（token/供给链与 HTTP 面
/// 同一套构造），handle 逐行翻译；本类无可变状态（并发隔离的结构保证）。
public final class MCPBridge {
    /// 支持的 MCP 协议版本（协商命中则回显，未命中回落最新支持版）。
    public static let supportedProtocolVersions = ["2025-06-18", "2024-11-05"]
    public static let serverName = "literaturesearch-localapi"
    /// 单行报文上限（字节）：与 LocalAPIServer.maxRequestBytes 同值同语义
    /// （超限丢弃不答——掐线形制；壳层执行，本常数供壳引用）。
    public static let maxLineBytes = 64 * 1024

    /// 五只读工具名（LOCAL-API 端点一一对应；顺序即 tools/list 清单序）。
    /// 功能扩展（产品决策，docs/LOCAL-API.md 同步修订）
    /// 增 page（整页文本）／annotations（单书批注只读清单）两工具。
    static let toolNames = ["books", "events", "search", "page", "annotations"]

    public let router: LocalAPIRouter

    public init(router: LocalAPIRouter) {
        self.router = router
    }

    // MARK: 入口

    /// 翻译一行 JSON-RPC 请求。任何输入都不抛错不崩：畸形输入按 JSON-RPC
    /// 形制回错误响应；通知（无 id）一律无回应。
    @discardableResult
    public func handle(_ line: String) -> MCPBridgeOutput {
        let started = Date()
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return MCPBridgeOutput(response: nil, audit: nil) }
        guard let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return respond(id: .null, result: nil,
                           error: (MCPJSONRPCCode.parseError.rawValue, "Parse error", [:]),
                           endpoint: nil, status: 400, started: started)
        }
        let id = Self.requestID(in: object)
        // 通知（无 id）不回应——JSON-RPC 2.0 纪律；审计亦不记（未成调用）。
        guard id.present else { return MCPBridgeOutput(response: nil, audit: nil) }
        guard object["jsonrpc"] as? String == "2.0" else {
            return respond(id: id, result: nil,
                           error: (MCPJSONRPCCode.invalidRequest.rawValue, "Invalid Request", [:]),
                           endpoint: nil, status: 400, started: started)
        }
        guard let method = object["method"] as? String else {
            return respond(id: id, result: nil,
                           error: (MCPJSONRPCCode.invalidRequest.rawValue, "Invalid Request", [:]),
                           endpoint: nil, status: 400, started: started)
        }
        let params = object["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            // 协议握手：零库数据，免凭据（/ping 对位）。协商见 initializeResult。
            return respond(id: id,
                           result: Self.initializeResult(params: params, appVersion: router.appVersion),
                           error: nil, endpoint: "/initialize", status: 200, started: started)
        case "tools/list":
            return respondToolList(id: id, params: params, started: started)
        case "tools/call":
            return respondToolCall(id: id, params: params, started: started)
        default:
            return respond(id: id, result: nil,
                           error: (MCPJSONRPCCode.methodNotFound.rawValue,
                                   "Method not found: \(method)", [:]),
                           endpoint: Self.sanitizeEndpoint("/\(method)"), status: 404, started: started)
        }
    }

    // MARK: 方法实现

    /// tools/list：清单零库数据但属协议面之后的第一步——鉴权经路由器自身
    /// 判定（探测目标未注册，token 正确落 404、错误落 401），401 文案与
    /// 状态码由路由器原文给出（零复制零漂移；供给链零触碰）。
    private func respondToolList(id: MCPRequestID, params: [String: Any], started: Date) -> MCPBridgeOutput {
        let probe = router.route(method: "GET", target: "/__mcp_auth__",
                                 authorization: Self.authorization(in: params))
        guard probe.status == 404 else {
            // 401 原样映射；其余状态理论不可达（探测目标不触供给链）。
            return respond(id: id, result: nil, error: Self.mapRouteError(probe),
                           endpoint: "/tools/list", status: probe.status, started: started)
        }
        return respond(id: id, result: Self.toolsListResult(), error: nil,
                       endpoint: "/tools/list", status: 200, started: started)
    }

    /// tools/call：拼目标串 → 路由器直调（鉴权在路由器内，401 语义原生）。
    private func respondToolCall(id: MCPRequestID, params: [String: Any], started: Date) -> MCPBridgeOutput {
        guard let tool = params["name"] as? String else {
            return respond(id: id, result: nil,
                           error: (MCPJSONRPCCode.invalidParams.rawValue,
                                   "Invalid params: missing tool name", [:]),
                           endpoint: "/tools/call", status: 400, started: started)
        }
        guard Self.toolNames.contains(tool) else {
            return respond(id: id, result: nil,
                           error: (MCPJSONRPCCode.invalidParams.rawValue,
                                   "Invalid params: unknown tool \(Self.sanitizeEndpoint(tool))", [:]),
                           endpoint: "/tools/call", status: 400, started: started)
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let target = Self.buildTarget(tool: tool, arguments: arguments)
        let response = router.route(method: "GET", target: target,
                                    authorization: Self.authorization(in: params))
        let endpoint = LocalAPIRouter.splitTarget(target).path
        if response.status == 200 {
            let result: [String: Any] = [
                "content": [["type": "text", "text": response.bodyText]],
                "isError": false,
            ]
            return respond(id: id, result: result, error: nil,
                           endpoint: endpoint, status: 200, started: started)
        }
        return respond(id: id, result: nil, error: Self.mapRouteError(response),
                       endpoint: endpoint, status: response.status, started: started)
    }

    // MARK: 封装

    /// 统一响应封装与审计结算（LocalAPI 审计语义：端点/状态/耗时/字节）。
    private func respond(id: MCPRequestID, result: [String: Any]?,
                         error: (code: Int, message: String, data: [String: Any])?,
                         endpoint: String?, status: Int, started: Date) -> MCPBridgeOutput {
        var inner: [String: Any]
        if let error {
            inner = ["code": error.code, "message": error.message]
            if !error.data.isEmpty { inner["data"] = error.data }
        } else {
            inner = result ?? [:]
        }
        var payload: [String: Any] = ["jsonrpc": "2.0", "id": id.jsonValue]
        payload[error == nil ? "result" : "error"] = inner
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            // 构造值恒 JSON 安全，理论不可达；降级处理按路由器先例如实报错。
            return MCPBridgeOutput(response: #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#,
                                   audit: nil)
        }
        let audit = endpoint.map {
            MCPBridgeAudit(endpoint: $0, status: status,
                           milliseconds: Date().timeIntervalSince(started) * 1000,
                           bytes: data.count)
        }
        return MCPBridgeOutput(response: line, audit: audit)
    }

    /// 路由器非 200 响应 → JSON-RPC 错误。message 取路由器错误体原文
    /// （401 文案逐字保留），data.status 携带 HTTP 语义状态码。
    static func mapRouteError(_ response: LocalAPIResponse) -> (code: Int, message: String, data: [String: Any]) {
        let message: String
        if let object = try? JSONSerialization.jsonObject(with: response.body, options: []),
           let dictionary = object as? [String: Any],
           let rendered = dictionary["error"] as? String {
            message = rendered
        } else {
            message = "upstream error"
        }
        let code: Int
        switch response.status {
        case 400: code = MCPJSONRPCCode.invalidParams.rawValue
        case 401: code = MCPJSONRPCCode.unauthorized.rawValue
        case 500: code = MCPJSONRPCCode.internalError.rawValue
        default: code = MCPJSONRPCCode.upstream.rawValue
        }
        return (code, message, ["status": response.status])
    }

    // MARK: 静态翻译助手（纯函数；测试直测）

    static func initializeResult(params: [String: Any], appVersion: String) -> [String: Any] {
        let requested = params["protocolVersion"] as? String
        let negotiated = requested.flatMap { wanted in
            supportedProtocolVersions.first { $0 == wanted }
        } ?? supportedProtocolVersions[0]
        return ["protocolVersion": negotiated,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": serverName, "version": appVersion],
                "instructions": "Read-only bridge over the local LiteratureSearch LocalAPI. Present the LocalAPIToken in params._meta.authorization for tools/list and tools/call."]
    }

    /// 五只读工具清单（LOCAL-API：books／events／search／page／annotations
    /// 形制如实投影；上限与缺省值直引 LocalAPILimits——单一来源，零复制）。
    static func toolsListResult() -> [String: Any] {
        let searchLimit: [String: Any] = ["type": "integer", "minimum": 0,
                                          "maximum": LocalAPILimits.maxLimit,
                                          "default": LocalAPILimits.defaultSearchLimit]
        let pageLimit: [String: Any] = ["type": "integer", "minimum": 0,
                                        "maximum": LocalAPILimits.maxLimit,
                                        "default": LocalAPILimits.defaultPageLimit]
        let booksSchema: [String: Any] = [
            "type": "object",
            "properties": ["offset": ["type": "integer", "minimum": 0, "default": 0],
                           "limit": pageLimit,
                           "fields": ["type": "string",
                                      "description": "Comma-separated column whitelist: id,title,author,file_name,page_count,language,status,path"]],
        ]
        let eventsSchema: [String: Any] = [
            "type": "object",
            "properties": ["cursor": ["type": "integer", "minimum": 0, "default": 0],
                           "limit": pageLimit],
        ]
        let searchSchema: [String: Any] = [
            "type": "object",
            "properties": ["q": ["type": "string",
                                 "description": "Query text (required; blank is rejected)"],
                           "limit": searchLimit],
            "required": ["q"],
        ]
        let pageSchema: [String: Any] = [
            "type": "object",
            "properties": ["book": ["type": "string",
                                    "description": "Book id (books.id)"],
                           "page": ["type": "integer", "minimum": 1,
                                    "description": "Physical page number (1-based)"]],
            "required": ["book", "page"],
        ]
        let annotationsSchema: [String: Any] = [
            "type": "object",
            "properties": ["book": ["type": "string",
                                    "description": "Book id (books.id; single-book scope)"],
                           "offset": ["type": "integer", "minimum": 0, "default": 0],
                           "limit": pageLimit],
            "required": ["book"],
        ]
        let books: [String: Any] = [
            "name": "books",
            "description": "List library books (read-only). Path-like fields are omitted unless explicitly requested via fields.",
            "inputSchema": booksSchema,
        ]
        let events: [String: Any] = [
            "name": "events",
            "description": "Index queue change increments (read-only snapshot cursor; not a durable event log).",
            "inputSchema": eventsSchema,
        ]
        let search: [String: Any] = [
            "name": "search",
            "description": "Full-text search over the indexed library (read-only; same chain as the CLI search command). Returns hits with book_id, physical page and snippet.",
            "inputSchema": searchSchema,
        ]
        let page: [String: Any] = [
            "name": "page",
            "description": "Full text of one physical page (read-only). Oversized text is truncated with truncated=true.",
            "inputSchema": pageSchema,
        ]
        let annotations: [String: Any] = [
            "name": "annotations",
            "description": "Read-only annotation list for ONE book (id, page, type, color, text, note, created_at_iso8601, view_source, anchor_verified), ordered by page then id.",
            "inputSchema": annotationsSchema,
        ]
        return ["tools": [books, events, search, page, annotations]]
    }

    /// 工具参数 → LocalAPI 目标串。查询串经 URLComponents 编码（与路由器
    /// 解析侧同一编解码器，往返对称）；参数一律透传路由器判定——缺 q／
    /// 非法 limit 等语义零复制（路由器 400 → invalid params 映射）。
    static func buildTarget(tool: String, arguments: [String: Any]) -> String {
        var items: [(String, String)] = []
        func pass(_ wire: String, _ key: String) {
            if let value = arguments[key] { items.append((wire, argumentString(value))) }
        }
        let path: String
        switch tool {
        case "books":
            path = "/books"
            pass("offset", "offset")
            pass("limit", "limit")
            pass("fields", "fields")
        case "events":
            path = "/events"
            pass("cursor", "cursor")
            pass("limit", "limit")
        case "page":
            path = "/page"
            pass("book", "book")
            pass("page", "page")
        case "annotations":
            path = "/annotations"
            pass("book", "book")
            pass("offset", "offset")
            pass("limit", "limit")
        default:
            path = "/search"
            pass("q", "q")
            pass("limit", "limit")
        }
        let query = percentEncodedQuery(items)
        return query.isEmpty ? path : "\(path)?\(query)"
    }

    static func percentEncodedQuery(_ items: [(String, String)]) -> String {
        guard !items.isEmpty else { return "" }
        var components = URLComponents()
        components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.percentEncodedQuery ?? ""
    }

    /// JSON 参数值 → 查询串值。Bool 与整数在 JSONSerialization 下同为
    /// NSNumber，且 darwin 桥接对 0/1 有双重身份（`NSNumber(1) as? Bool`
    /// 成功＝true、`NSNumber(0) as? Bool` 成功＝false）——曾把 limit=1 劫持
    /// 成 "true"、offset/cursor=0 劫持成 "false"，路由器 400（实机 stdio
    /// 走查 抓获，合成测试 limit=2 逃过）。类型判定以 objCType
    /// 为准：仅 "c"（boolean char）是 Bool，其余整数/浮点一律数值通路。
    static func argumentString(_ value: Any) -> String {
        switch value {
        case let text as String: return text
        case let number as NSNumber:
            if String(cString: number.objCType) == "c" {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        default: return String(describing: value)
        }
    }

    /// stdio 等位 Authorization 头：params._meta.authorization（MCP 元数据
    static func authorization(in params: [String: Any]) -> String? {
        guard let meta = params["_meta"] as? [String: Any] else { return nil }
        return meta["authorization"] as? String
    }

    static func requestID(in object: [String: Any]) -> MCPRequestID {
        guard object.keys.contains("id") else { return .absent }
        let raw = object["id"]
        if raw == nil || raw is NSNull { return .null }
        switch raw {
        case let text as String: return .value(text)
        case let number as NSNumber: return .value(number)
        default: return .value(String(describing: raw ?? "null"))
        }
    }

    /// mcp-serve 显式供给凭据的形制门（与 LocalAPIToken.generate 产出同形：
    /// 64 位小写 hex）。不合形即拒启（fail-closed）——形制即语义的一部分。
    public static func isValidProvisionedToken(_ candidate: String) -> Bool {
        guard candidate.count == LocalAPIToken.byteCount * 2 else { return false }
        let charset = CharacterSet(charactersIn: "0123456789abcdef")
        return candidate.unicodeScalars.allSatisfy { charset.contains($0) }
    }

    /// 审计端点名净化：控制字符剔除＋截断（未知方法名可含任意串；审计行
    /// 必须单行安全。查询正文与凭据本就不进审计——约束照 LocalAPI）。
    static func sanitizeEndpoint(_ raw: String) -> String {
        let printable = raw.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }
        let cleaned = String(String.UnicodeScalarView(printable))
        return cleaned.count > 80 ? String(cleaned.prefix(80)) : cleaned
    }
}
