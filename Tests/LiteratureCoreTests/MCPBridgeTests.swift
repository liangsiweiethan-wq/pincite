import Foundation
@testable import LiteratureCore

// MARK: - MCP 只读桥合成测试（纯逻辑层全测；stdio 壳留实机
// 走查，LocalAPI 网络壳同款基准）。
// tools_list 清单／search 调用往返／token 错误 401 语义／并发两请求隔离；
// 另加审计约束断言（端点不含查询串、零凭据零查询正文）与协议负形断言
// （通知不回应／畸形报文 parse error／未知方法／未知工具）。

enum MCPBridgeSuite {
    /// 固定凭据（64 位小写 hex——LocalAPIToken 形制；路由器侧精确比对用）。
    static let fixedToken = String(repeating: "3", count: 64)

    static func makeBridge(providers: LocalAPIProviders? = nil) -> MCPBridge {
        let router = LocalAPISuite.makeRouter(token: fixedToken, providers: providers)
        return MCPBridge(router: router)
    }

    /// 隔离断言专用供给链：search 命中把查询原文织进 snippet——两条并发
    /// 调用若串线，snippet 即错配（判别力断言）。
    static func echoProviders() -> LocalAPIProviders {
        LocalAPIProviders(
            books: { _, _ in ([], false) },
            search: { query, _ in
                let hit = LocalAPISearchHit(bookID: "b1", fileName: "f.pdf", title: query,
                                            physicalPage: 1, snippet: "snippet-for-\(query)",
                                            source: "native")
                return ([hit], query.count, false, "character")
            },
            events: { _, _ in ([], 0, false) })
    }

    // MARK: 组装助手

    static func requestLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    static func callLine(id: Any, tool: String, arguments: [String: Any],
                         authorization: String?) -> String {
        var params: [String: Any] = ["name": tool, "arguments": arguments]
        if let authorization { params["_meta"] = ["authorization": authorization] }
        return requestLine(["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": params])
    }

    static func parse(_ response: String?) throws -> [String: Any] {
        let data = try expectNotNil(response?.data(using: .utf8), "应有响应行")
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        return try expectNotNil(object as? [String: Any], "响应应为 JSON 对象")
    }

    static func result(of response: [String: Any]) throws -> [String: Any] {
        try expectNotNil(response["result"] as? [String: Any],
                         "应有 result：\(response)")
    }

    static func error(of response: [String: Any]) throws -> [String: Any] {
        try expectNotNil(response["error"] as? [String: Any],
                         "应有 error：\(response)")
    }

    /// tools/call 200 结果里 content[0].text 的 JSON 体（路由器响应原文）。
    static func contentBody(_ result: [String: Any]) throws -> [String: Any] {
        let content = try expectNotNil(result["content"] as? [[String: Any]])
        let first = try expectNotNil(content.first, "content 不应为空")
        try expectEqual(first["type"] as? String, "text")
        let text = try expectNotNil(first["text"] as? String)
        try expectEqual(result["isError"] as? Bool, false)
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [])
        return try expectNotNil(object as? [String: Any], "content.text 应为 JSON 对象")
    }

    static func assertUnauthorized(_ response: [String: Any], line: String) throws {
        let error = try error(of: response)
        // 401 语义逐字保留：错误码映射 + 路由器 401 文案原文 + HTTP 状态在 data。
        try expectEqual(error["code"] as? Int, MCPJSONRPCCode.unauthorized.rawValue)
        // 线级契约另断言字面值（突变抽检补强）：-32001 是 MCP
        // 客户端可见的线级值，枚举自比自（rawValue vs rawValue）打不住字面
        // 漂移——突变 -32001→-32002 曾恒绿，补此断言后同突变验红。
        try expectEqual(error["code"] as? Int, -32001)
        try expectEqual(error["message"] as? String,
                        "unauthorized: missing or invalid Authorization header")
        let data = try expectNotNil(error["data"] as? [String: Any])
        try expectEqual(data["status"] as? Int, 401)
        // 响应行本身不得携带凭据。
        try expectFalse(line.contains(fixedToken), "响应不得回显凭据")
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "MCPBridge", name: "initializeHandshakeEchoesSupportedVersion") {
                let bridge = makeBridge()
                let line = requestLine(["jsonrpc": "2.0", "id": "init-1", "method": "initialize",
                                        "params": ["protocolVersion": "2025-06-18",
                                                   "capabilities": [:],
                                                   "clientInfo": ["name": "pin", "version": "0"]]])
                let outcome = bridge.handle(line)
                let response = try parse(outcome.response)
                try expectEqual(response["jsonrpc"] as? String, "2.0")
                try expectEqual(response["id"] as? String, "init-1")
                let payload = try result(of: response)
                try expectEqual(payload["protocolVersion"] as? String, "2025-06-18")
                let serverInfo = try expectNotNil(payload["serverInfo"] as? [String: Any])
                try expectEqual(serverInfo["name"] as? String, MCPBridge.serverName)
                let capabilities = try expectNotNil(payload["capabilities"] as? [String: Any])
                try expectNotNil(capabilities["tools"] as? [String: Any], "tools 能力位应在册")
                try expectNotNil(outcome.audit, "握手亦审计")
                try expectEqual(outcome.audit?.endpoint, "/initialize")
            },
            TestDesc(suite: "MCPBridge", name: "initializeUnknownVersionFallsBackToLatest") {
                let bridge = makeBridge()
                let line = requestLine(["jsonrpc": "2.0", "id": 7, "method": "initialize",
                                        "params": ["protocolVersion": "1999-01-01"]])
                let payload = try result(of: parse(bridge.handle(line).response))
                try expectEqual(payload["protocolVersion"] as? String,
                                MCPBridge.supportedProtocolVersions[0])
            },

            TestDesc(suite: "MCPBridge", name: "toolsListPinsExactlyReadOnlyToolSet") {
                let bridge = makeBridge()
                let line = requestLine(["jsonrpc": "2.0", "id": "t1", "method": "tools/list",
                                        "params": ["_meta": ["authorization": fixedToken]]])
                let outcome = bridge.handle(line)
                let payload = try result(of: parse(outcome.response))
                let tools = try expectNotNil(payload["tools"] as? [[String: Any]])
                let names = tools.compactMap { $0["name"] as? String }
                try expectEqual(names, ["books", "events", "search", "page", "annotations"],
                                "清单必须恰为五只读工具（顺序稳定）")
                for tool in tools {
                    try expectNotNil(tool["description"] as? String)
                    let schema = try expectNotNil(tool["inputSchema"] as? [String: Any])
                    try expectEqual(schema["type"] as? String, "object")
                }
                let search = try expectNotNil(tools.first { $0["name"] as? String == "search" })
                let searchSchema = try expectNotNil(search["inputSchema"] as? [String: Any])
                try expectEqual(searchSchema["required"] as? [String], ["q"])
                // 新工具 schema 断言：page/annotations 必填 book；page 再必填 page。
                let page = try expectNotNil(tools.first { $0["name"] as? String == "page" })
                let pageSchema = try expectNotNil(page["inputSchema"] as? [String: Any])
                try expectEqual(pageSchema["required"] as? [String], ["book", "page"])
                let annotations = try expectNotNil(tools.first { $0["name"] as? String == "annotations" })
                let annotationsSchema = try expectNotNil(annotations["inputSchema"] as? [String: Any])
                try expectEqual(annotationsSchema["required"] as? [String], ["book"])
                try expectEqual(outcome.audit?.endpoint, "/tools/list")
                try expectEqual(outcome.audit?.status, 200)
            },
            TestDesc(suite: "MCPBridge", name: "toolsListWithoutTokenIs401Semantics") {
                let bridge = makeBridge()
                let line = requestLine(["jsonrpc": "2.0", "id": "t2", "method": "tools/list", "params": [:]])
                let outcome = bridge.handle(line)
                let response = try parse(outcome.response)
                try assertUnauthorized(response, line: outcome.response ?? "")
                try expectEqual(outcome.audit?.status, 401, "审计照 LocalAPI：401 落审计")
            },

            TestDesc(suite: "MCPBridge", name: "toolsCallWrongTokenIs401Semantics") {
                let bridge = makeBridge()
                let line = callLine(id: 1, tool: "search", arguments: ["q": "alpha"],
                                    authorization: String(repeating: "0", count: 64))
                let outcome = bridge.handle(line)
                try assertUnauthorized(try parse(outcome.response), line: outcome.response ?? "")
                try expectTrue(outcome.response?.contains("\"id\":1,") == true,
                               "numeric request ID 1 must stay numeric")
                try expectEqual(outcome.audit?.endpoint, "/search")
                try expectEqual(outcome.audit?.status, 401)
            },
            TestDesc(suite: "MCPBridge", name: "toolsCallMissingCredentialIs401Semantics") {
                let bridge = makeBridge()
                let line = callLine(id: 2, tool: "books", arguments: [:], authorization: nil)
                let outcome = bridge.handle(line)
                try assertUnauthorized(try parse(outcome.response), line: outcome.response ?? "")
            },
            TestDesc(suite: "MCPBridge", name: "provisionedTokenShapeGate") {
                try expectTrue(MCPBridge.isValidProvisionedToken(LocalAPIToken.generate()),
                               "generate() 产出必须过形制门（同形）")
                try expectFalse(MCPBridge.isValidProvisionedToken(String(repeating: "A", count: 64)),
                                "大写 hex 拒")
                try expectFalse(MCPBridge.isValidProvisionedToken(String(repeating: "a", count: 63)),
                                "短一位拒")
                try expectFalse(MCPBridge.isValidProvisionedToken(""), "空串拒")
            },

            TestDesc(suite: "MCPBridge", name: "searchCallRoundTrip") {
                let bridge = makeBridge()
                let line = callLine(id: "s1", tool: "search",
                                    arguments: ["q": "alpha", "limit": 2],
                                    authorization: fixedToken)
                let outcome = bridge.handle(line)
                let body = try contentBody(try result(of: parse(outcome.response)))
                try expectEqual(body["query"] as? String, "alpha")
                try expectEqual(body["total"] as? Int, 3)
                let hits = try expectNotNil(body["hits"] as? [[String: Any]])
                try expectEqual(hits.count, 2, "limit=2 截顶 3 命中")
                try expectEqual(hits.first?["book_id"] as? String, "b1")
                try expectEqual(body["count_caliber"] as? String, "character")
                // 审计照 LocalAPI 语义：端点只留路径、零查询正文、零凭据。
                let audit = try expectNotNil(outcome.audit)
                try expectEqual(audit.endpoint, "/search")
                try expectEqual(audit.status, 200)
                try expectFalse(audit.stderrLine.contains("alpha"), "查询正文不得落审计")
                try expectFalse(audit.stderrLine.contains(fixedToken), "凭据不得落审计")
                try expectTrue(audit.bytes > 0)
            },
            TestDesc(suite: "MCPBridge", name: "searchRoundTripPreservesSpacePhrase") {
                // 编解码对称断言：URLComponents 编码 → 路由器 URLComponents 解码，
                // 空格短语原样往返（查询串编码器单一来源）。
                let bridge = makeBridge()
                let line = callLine(id: "s2", tool: "search",
                                    arguments: ["q": "法律 概念"], authorization: fixedToken)
                let outcome = bridge.handle(line)
                let body = try contentBody(try result(of: parse(outcome.response)))
                try expectEqual(body["query"] as? String, "法律 概念")
            },
            TestDesc(suite: "MCPBridge", name: "booksCallRoundTrip") {
                let bridge = makeBridge()
                let line = callLine(id: "b1", tool: "books",
                                    arguments: ["offset": 2, "limit": 2],
                                    authorization: fixedToken)
                let outcome = bridge.handle(line)
                let body = try contentBody(try result(of: parse(outcome.response)))
                let rows = try expectNotNil(body["books"] as? [[String: Any]])
                try expectEqual(rows.count, 1)
                try expectEqual(rows.first?["id"] as? String, "b3")
                try expectEqual(body["has_more"] as? Bool, false)
                try expectEqual(outcome.audit?.endpoint, "/books")
            },
            TestDesc(suite: "MCPBridge", name: "eventsCallRoundTrip") {
                let bridge = makeBridge()
                let line = callLine(id: "e1", tool: "events",
                                    arguments: ["cursor": 3, "limit": 3],
                                    authorization: fixedToken)
                let outcome = bridge.handle(line)
                let body = try contentBody(try result(of: parse(outcome.response)))
                let rows = try expectNotNil(body["events"] as? [[String: Any]])
                try expectEqual(rows.compactMap { $0["ordinal"] as? Int }, [4, 5, 6])
                try expectEqual(body["cursor"] as? Int, 6)
                try expectEqual(body["has_more"] as? Bool, true)
                try expectEqual(outcome.audit?.endpoint, "/events")
            },
            TestDesc(suite: "MCPBridge", name: "pageAndAnnotationsCallRoundTrip") {
                // 新工具翻译断言：page/annotations 参数 → 路由目标，
                // 响应体形制由 fixture 供给链如实透传（buildTarget 形制 +
                // 审计端点名）。limit=1 零值一并过（Bool 劫持同防）。
                var seen: [(path: String, query: String)] = []
                var providers = LocalAPISuite.fixtureProviders()
                providers.page = { bookID, pageNumber in
                    seen.append(("/page", "book=\(bookID)&page=\(pageNumber)"))
                    return ("夹具正文", false)
                }
                providers.annotations = { bookID, offset, limit in
                    seen.append(("/annotations", "book=\(bookID)&offset=\(offset)&limit=\(limit)"))
                    let row = LocalAPIAnnotation(id: 1, bookID: bookID, page: 3,
                                                 type: "highlight", color: "yellow",
                                                 text: "切片", note: "注",
                                                 createdAtISO8601: "2026-10-07T00:00:00Z",
                                                 viewSource: "ocr", anchorVerified: 1)
                    return ([row], false)
                }
                let bridge = makeBridge(providers: providers)
                let page = try contentBody(try result(of: parse(bridge.handle(
                    callLine(id: "p1", tool: "page",
                             arguments: ["book": "b1", "page": 2],
                             authorization: fixedToken)).response)))
                try expectEqual(page["book_id"] as? String, "b1")
                try expectEqual(page["page"] as? Int, 2)
                try expectEqual(page["text"] as? String, "夹具正文")
                try expectEqual(page["truncated"] as? Bool, false)
                let annotations = try contentBody(try result(of: parse(bridge.handle(
                    callLine(id: "a1", tool: "annotations",
                             arguments: ["book": "b2", "offset": 0, "limit": 1],
                             authorization: fixedToken)).response)))
                let rows = try expectNotNil(annotations["annotations"] as? [[String: Any]])
                try expectEqual(rows.count, 1)
                try expectEqual(rows.first?["type"] as? String, "highlight")
                try expectEqual(annotations["has_more"] as? Bool, false)
                try expectEqual(seen.count, 2, "两次调用各达 provider 一次")
                try expectEqual(seen[0].path, "/page")
                try expectEqual(seen[0].query, "book=b1&page=2")
                try expectEqual(seen[1].path, "/annotations")
                try expectEqual(seen[1].query, "book=b2&offset=0&limit=1")
                // 审计端点：路径零查询串（约束同 LocalAPI）。
                let pageAudit = try expectNotNil(bridge.handle(
                    callLine(id: "p2", tool: "page", arguments: ["book": "b1", "page": 1],
                             authorization: fixedToken)).audit)
                try expectEqual(pageAudit.endpoint, "/page")
            },
            TestDesc(suite: "MCPBridge", name: "smallIntegerArgumentsEscapeBoolHijack") {
                // 0/1 劫持断言（实机 stdio 走查抓获）：JSONSerialization
                // 下 NSNumber(1) as? Bool 与 NSNumber(0) as? Bool 均成功——参数翻译
                // 若按 as? Bool 先判，limit=1 被译成 "true"、offset/cursor=0 被译成
                // "false"，路由器 400；合成测试原用 limit=2 逃过。判定必须走
                // objCType（"c" 才是 Bool）。此断言三工具零值/壹值全过一遍。
                let bridge = makeBridge()
                let search = try contentBody(try result(of: parse(bridge.handle(
                    callLine(id: "z1", tool: "search",
                             arguments: ["q": "alpha", "limit": 1],
                             authorization: fixedToken)).response)))
                let searchHits = try expectNotNil(search["hits"] as? [[String: Any]])
                try expectEqual(searchHits.count, 1,
                                "limit=1 必须按整数 1 通行（不得劫持成 \"true\"→400）")
                let books = try contentBody(try result(of: parse(bridge.handle(
                    callLine(id: "z2", tool: "books",
                             arguments: ["offset": 0, "limit": 2],
                             authorization: fixedToken)).response)))
                let bookRows = try expectNotNil(books["books"] as? [[String: Any]])
                try expectEqual(bookRows.first?["id"] as? String, "b1",
                                "offset=0 必须按整数 0 通行（不得劫持成 \"false\"→400）")
                let events = try contentBody(try result(of: parse(bridge.handle(
                    callLine(id: "z3", tool: "events",
                             arguments: ["cursor": 0, "limit": 3],
                             authorization: fixedToken)).response)))
                let eventRows = try expectNotNil(events["events"] as? [[String: Any]])
                try expectEqual(eventRows.first?["ordinal"] as? Int, 1,
                                "cursor=0 必须按整数 0 通行")
                // 真 Bool 形制保真（schema 无 Bool 字段，断言住翻译器不偏航）。
                try expectEqual(MCPBridge.argumentString(true), "true")
                try expectEqual(MCPBridge.argumentString(false), "false")
                try expectEqual(MCPBridge.argumentString(1), "1")
                try expectEqual(MCPBridge.argumentString(0), "0")
            },
            TestDesc(suite: "MCPBridge", name: "missingQIsInvalidParamsWithRouterMessage") {
                // 参数语义零复制：缺 q／空白 q 由路由器 400 判定，message 原文透传。
                let bridge = makeBridge()
                let missing = bridge.handle(callLine(id: 3, tool: "search", arguments: [:],
                                                     authorization: fixedToken))
                let missingError = try error(of: parse(missing.response))
                try expectEqual(missingError["code"] as? Int, MCPJSONRPCCode.invalidParams.rawValue)
                try expectEqual(missingError["message"] as? String, "missing q")
                let missingData = try expectNotNil(missingError["data"] as? [String: Any])
                try expectEqual(missingData["status"] as? Int, 400)
                let blank = bridge.handle(callLine(id: 4, tool: "search", arguments: ["q": "   "],
                                                   authorization: fixedToken))
                let blankError = try error(of: parse(blank.response))
                try expectEqual(blankError["message"] as? String, "empty q")
            },
            TestDesc(suite: "MCPBridge", name: "unknownToolIsInvalidParams") {
                let bridge = makeBridge()
                let outcome = bridge.handle(callLine(id: 5, tool: "highlights", arguments: [:],
                                                     authorization: fixedToken))
                let error = try error(of: parse(outcome.response))
                try expectEqual(error["code"] as? Int, MCPJSONRPCCode.invalidParams.rawValue)
                let message = try expectNotNil(error["message"] as? String)
                try expectTrue(message.contains("unknown tool"), "message 应点名未知工具：\(message)")
            },

            // ── 协议负形：未知方法／通知不回应／畸形报文 ──
            TestDesc(suite: "MCPBridge", name: "unknownMethodIsMethodNotFound") {
                let bridge = makeBridge()
                let outcome = bridge.handle(requestLine(["jsonrpc": "2.0", "id": 9,
                                                         "method": "resources/read", "params": [:]]))
                let error = try error(of: parse(outcome.response))
                try expectEqual(error["code"] as? Int, MCPJSONRPCCode.methodNotFound.rawValue)
            },
            TestDesc(suite: "MCPBridge", name: "notificationGetsNoResponse") {
                let bridge = makeBridge()
                let line = requestLine(["jsonrpc": "2.0", "method": "notifications/initialized"])
                let outcome = bridge.handle(line)
                try expectNil(outcome.response, "通知不得产生响应")
                try expectNil(outcome.audit, "未成调用不落审计")
            },
            TestDesc(suite: "MCPBridge", name: "malformedLineIsParseErrorWithNullID") {
                let bridge = makeBridge()
                let outcome = bridge.handle("this is not json")
                let response = try parse(outcome.response)
                let error = try error(of: response)
                try expectEqual(error["code"] as? Int, MCPJSONRPCCode.parseError.rawValue)
                try expectTrue(response["id"] is NSNull, "无法归属的请求 id 回 null")
            },
            TestDesc(suite: "MCPBridge", name: "blankLineIsSilentlySkipped") {
                let bridge = makeBridge()
                let outcome = bridge.handle("   ")
                try expectNil(outcome.response)
                try expectNil(outcome.audit)
            },

            TestDesc(suite: "MCPBridge", name: "pipelinedRequestsStayIsolated") {
                // stdio 壳真实形态：两请求行背靠背到达（管道流水），逐行分派。
                // 隔离断言＝id 与查询各自配对，绝不串线。
                let bridge = makeBridge(providers: echoProviders())
                let line1 = callLine(id: 1, tool: "search", arguments: ["q": "alpha"],
                                     authorization: fixedToken)
                let line2 = callLine(id: 2, tool: "search", arguments: ["q": "beta"],
                                     authorization: fixedToken)
                let first = try parse(bridge.handle(line1).response)
                let second = try parse(bridge.handle(line2).response)
                try expectEqual(first["id"] as? Int, 1)
                try expectEqual(second["id"] as? Int, 2)
                let firstBody = try contentBody(try result(of: first))
                let secondBody = try contentBody(try result(of: second))
                try expectEqual(firstBody["query"] as? String, "alpha")
                try expectEqual(secondBody["query"] as? String, "beta")
                let firstHits = try expectNotNil(firstBody["hits"] as? [[String: Any]])
                let secondHits = try expectNotNil(secondBody["hits"] as? [[String: Any]])
                try expectEqual(firstHits.first?["snippet"] as? String, "snippet-for-alpha")
                try expectEqual(secondHits.first?["snippet"] as? String, "snippet-for-beta")
            },
            TestDesc(suite: "MCPBridge", name: "concurrentHandlesStayIsolated") {
                // handle 无共享可变状态的结构保证：并发调用亦隔离。
                let bridge = makeBridge(providers: echoProviders())
                let line1 = callLine(id: 11, tool: "search", arguments: ["q": "alpha"],
                                     authorization: fixedToken)
                let line2 = callLine(id: 22, tool: "search", arguments: ["q": "beta"],
                                     authorization: fixedToken)
                async let firstOutcome = bridge.handle(line1)
                async let secondOutcome = bridge.handle(line2)
                let (first, second) = await (firstOutcome, secondOutcome)
                let firstResponse = try parse(first.response)
                let secondResponse = try parse(second.response)
                try expectEqual(firstResponse["id"] as? Int, 11)
                try expectEqual(secondResponse["id"] as? Int, 22)
                let firstBody = try contentBody(try result(of: firstResponse))
                let secondBody = try contentBody(try result(of: secondResponse))
                try expectEqual(firstBody["query"] as? String, "alpha")
                try expectEqual(secondBody["query"] as? String, "beta")
            },
        ]
    }
}
