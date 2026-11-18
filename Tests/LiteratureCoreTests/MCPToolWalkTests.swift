import Foundation
@testable import LiteratureCore

// MARK: - 功能扩展：MCP 消费端端到端走查（真子进程 stdio）
//
// 形态复用 MCPServeShellSuite 的 harness（真子进程 .build/debug/literaturesearch-cli
// mcp-serve＋LIT_MCP_TOKEN env＋规则文件 stdin），但从「壳层凭据/超限断言」
// 升级为「工具清单数据面全走查」：initialize → tools/list（五工具齐且无多
// 余）→ tools/call 依次 search / books / events / page / annotations（合成
// 库＋种 1 条 verified 高亮＋1 条页级批注）→ 负断言（未知工具 -32602、缺凭据
// -32001、页缺 404）。
//
// 响应合法性基准（每响应逐条断言）：jsonrpc=="2.0"、id 回显、result/error
// 二选一、成功面 content[0].type=="text" 且内层可解析为 JSON。
// 断言：annotations note 走既有解密读路径——E2E 断言 note 明文形制
//（测试环境加密关，落库即明文；响应内可读原句）。

enum MCPToolWalkSuite {
    /// 走查专用凭据（64 位小写 hex；与其他两套 MCP 断言不同值可判别）。
    static let walkToken = String(repeating: "5", count: 64)
    /// 合成书 ID（MCPServeShellSuite.makeSyntheticDB 固定用此 ID）。
    static let bookID = "bmcpspin0001"

    /// 合成库＋批注种子：1 条 verified 高亮（页 1 utf16[0,3)＝「第一章」）
    /// ＋1 条页级批注（页 2）。种完即返（进程内连接随作用域收敛，子进程
    /// 另开只读连接——SQLite 多连接读侧天然安全）。
    static func makeWalkDB() throws -> URL {
        let db = try MCPServeShellSuite.makeSyntheticDB("walk")
        let store = try IndexStore(path: db)
        // 入队是 IndexingEngine.persist 的职责（upsertBook 本身不入队）——
        // 走查断言 events 面（队列行）须由 harness 自种一条 queued 行。
        try store.enqueueBook(bookID)
        let highlights = HighlightStore(indexStore: store)
        _ = try highlights.add(bookID: bookID, pageNumber: 1, utf16Start: 0, utf16End: 3,
                               color: .yellow, note: "走查批注一", anchorVerified: 1)
        _ = try highlights.addPageNote(bookID: bookID, pageNumber: 2,
                                       note: "页级走查批注")
        return db
    }

    static func callLine(id: String, method: String, params: [String: Any],
                         authorization: String?) -> String {
        var full: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        var merged = params
        if let authorization {
            merged["_meta"] = ["authorization": authorization]
        }
        if !merged.isEmpty { full["params"] = merged }
        return MCPServeShellSuite.requestLine(full)
    }

    /// tools/call 行（带凭据）。
    static func toolCall(id: String, tool: String, arguments: [String: Any],
                         authorization: String? = walkToken) -> String {
        callLine(id: id, method: "tools/call",
                 params: ["name": tool, "arguments": arguments],
                 authorization: authorization)
    }

    /// 一次性走查：全部请求行拼规则文件 → 拉起子进程 → 逐行收响应（按 id
    /// 索引）。
    static func walk(db: URL, inputLines: [String]) async throws -> [String: [String: Any]] {
        let input = inputLines.joined()
        let result = try await MCPServeShellSuite.runServe(db: db, envToken: walkToken,
                                                           argvToken: nil, inputText: input)
        try expectEqual(result.status, 0, "mcp-serve 应服役到 EOF 正常退出；stderr：\(result.err)")
        var byID: [String: [String: Any]] = [:]
        for line in result.out.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                try failTest("stdout 行非合法 JSON：\(line.prefix(200))")
            }
            try expectEqual(object["jsonrpc"] as? String, "2.0",
                            "每响应必 jsonrpc 2.0：\(line.prefix(200))")
            // id 回显（走查全用字符串 id）。
            let id = try expectNotNil(object["id"] as? String, "响应必有字符串 id")
            // result / error 二选一（协议形制）。
            let hasResult = object["result"] is [String: Any]
            let hasError = object["error"] is [String: Any]
            try expectTrue(hasResult != hasError, "result/error 必须二选一：\(line.prefix(200))")
            byID[id] = object
        }
        return byID
    }

    /// tools/call 成功响应 → content[0].text 内层 JSON（合法性基准在此结算）。
    static func contentBody(_ response: [String: Any], id: String) throws -> [String: Any] {
        let result = try expectNotNil(response["result"] as? [String: Any], "\(id) 应有 result")
        try expectEqual(result["isError"] as? Bool, false, "\(id) isError 应 false")
        let content = try expectNotNil(result["content"] as? [[String: Any]], "\(id) 应有 content")
        let first = try expectNotNil(content.first, "\(id) content 不应为空")
        try expectEqual(first["type"] as? String, "text", "\(id) content[0] 应 text")
        let text = try expectNotNil(first["text"] as? String, "\(id) content[0] 应有 text")
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [])
        return try expectNotNil(object as? [String: Any], "\(id) 内层应为 JSON 对象")
    }

    /// tools/call 错误响应 → error 对象。
    static func errorBody(_ response: [String: Any], id: String) throws -> [String: Any] {
        try expectNotNil(response["error"] as? [String: Any], "\(id) 应有 error")
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "MCPToolWalk", name: "toolWalkCoversFullToolListWithDataPlane") {
                try expectTrue(FileManager.default.fileExists(
                    atPath: MCPServeShellSuite.cliBin.path),
                    "CLI 二进制不存在——本测试要求先 swift build 再跑测试")
                let db = try makeWalkDB()
                defer { Fixtures.cleanup(db.deletingLastPathComponent()) }

                let byID = try await walk(db: db, inputLines: [
                    MCPServeShellSuite.legalHandshake(id: "w-init"),
                    callLine(id: "w-list", method: "tools/list", params: [:], authorization: walkToken),
                    toolCall(id: "w-search", tool: "search", arguments: ["q": "第一章"]),
                    toolCall(id: "w-books", tool: "books", arguments: [:]),
                    toolCall(id: "w-events", tool: "events", arguments: [:]),
                    toolCall(id: "w-page", tool: "page", arguments: ["book": bookID, "page": 1]),
                    toolCall(id: "w-annot", tool: "annotations", arguments: ["book": bookID]),
                ])

                // ── tools/list：五工具齐且无多余（顺序稳定）──
                let listResult = try expectNotNil(byID["w-list"]?["result"] as? [String: Any])
                let tools = try expectNotNil(listResult["tools"] as? [[String: Any]])
                try expectEqual(tools.compactMap { $0["name"] as? String },
                                ["books", "events", "search", "page", "annotations"],
                                "工具清单必须恰为五只读工具（契约扩展在案）")

                // ── search：命中合成书，内层 JSON hits[0].book_id 相符 ──
                let search = try contentBody(try expectNotNil(byID["w-search"]), id: "w-search")
                let hits = try expectNotNil(search["hits"] as? [[String: Any]])
                try expectTrue(!hits.isEmpty, "合成词应命中")
                try expectEqual(hits.first?["book_id"] as? String, bookID)
                try expectEqual(hits.first?["physical_page"] as? Int, 1)

                // ── books：书目行返回 ──
                let books = try contentBody(try expectNotNil(byID["w-books"]), id: "w-books")
                let rows = try expectNotNil(books["books"] as? [[String: Any]])
                try expectEqual(rows.first?["id"] as? String, bookID)

                // ── events：队列行返回（合成库 upsert 时入队）──
                let events = try contentBody(try expectNotNil(byID["w-events"]), id: "w-events")
                let eventRows = try expectNotNil(events["events"] as? [[String: Any]])
                try expectTrue(!eventRows.isEmpty, "合成书应有一条队列行")

                // ── page：整页文本返回，truncated=false ──
                let page = try contentBody(try expectNotNil(byID["w-page"]), id: "w-page")
                try expectEqual(page["book_id"] as? String, bookID)
                try expectEqual(page["page"] as? Int, 1)
                try expectEqual(page["truncated"] as? Bool, false)
                let pageText = try expectNotNil(page["text"] as? String)
                try expectTrue(pageText.contains("第一章"),
                               "页文本应含夹具正文；实际：\(pageText.prefix(80))")
                try expectEqual(page["chars"] as? Int, pageText.count)

                // ── annotations：2 条；type/时间形制；verified 行 text=夹具切片；
                //    note 明文形制（既有解密读路径出口）──
                let annot = try contentBody(try expectNotNil(byID["w-annot"]), id: "w-annot")
                let annotations = try expectNotNil(annot["annotations"] as? [[String: Any]])
                try expectEqual(annotations.count, 2, "应恰有种子两批注")
                let types = Set(annotations.compactMap { $0["type"] as? String })
                try expectEqual(types, Set(["highlight", "page_note"]),
                                "type 判定应与导出管道同语义")
                // 列序 page ASC, id ASC：页 1 高亮在前，页 2 页级批注在后。
                try expectEqual(annotations.first?["page"] as? Int, 1)
                try expectEqual(annotations.last?["page"] as? Int, 2)
                try expectEqual(annotations.first?["text"] as? String, "第一章",
                                "anchorVerified=1 行 text 应为页文本切片")
                try expectEqual(annotations.first?["note"] as? String, "走查批注一",
                                "note 必须是明文原句（解密读路径出口）")
                try expectEqual(annotations.last?["note"] as? String, "页级走查批注")
                try expectEqual(annotations.last?["text"] as? String, "",
                                "页级批注 text 应为空（与 CSV 同语义）")
                for row in annotations {
                    let stamp = try expectNotNil(row["created_at_iso8601"] as? String)
                    try expectTrue(stamp.count == 20 && stamp.hasSuffix("Z"),
                                   "created_at_iso8601 应为 ISO8601 UTC 形制：\(stamp)")
                    try expectTrue(row["anchor_verified"] is Int)
                    try expectTrue(row["view_source"] as? String == "ocr"
                                   || row["view_source"] as? String == "original")
                    try expectTrue(row["id"] is Int)
                }
            },

            // ── 负断言：未知工具 → -32602 ──
            TestDesc(suite: "MCPToolWalk", name: "unknownToolIsInvalidParams") {
                let db = try makeWalkDB()
                defer { Fixtures.cleanup(db.deletingLastPathComponent()) }
                let byID = try await walk(db: db, inputLines: [
                    toolCall(id: "w-unk", tool: "highlights", arguments: [:]),
                ])
                let error = try errorBody(try expectNotNil(byID["w-unk"]), id: "w-unk")
                try expectEqual(error["code"] as? Int, -32602)
            },

            // ── 负断言：缺凭据 → -32001（data.status=401）──
            TestDesc(suite: "MCPToolWalk", name: "missingCredentialIsUnauthorizedSemantics") {
                let db = try makeWalkDB()
                defer { Fixtures.cleanup(db.deletingLastPathComponent()) }
                let byID = try await walk(db: db, inputLines: [
                    callLine(id: "w-noauth", method: "tools/list", params: [:], authorization: nil),
                ])
                let error = try errorBody(try expectNotNil(byID["w-noauth"]), id: "w-noauth")
                try expectEqual(error["code"] as? Int, -32001)
                let data = try expectNotNil(error["data"] as? [String: Any])
                try expectEqual(data["status"] as? Int, 401)
            },

            // ── 负断言：page 页缺 → 错误带 data.status=404 ──
            TestDesc(suite: "MCPToolWalk", name: "pageMissingIs404MappedError") {
                let db = try makeWalkDB()
                defer { Fixtures.cleanup(db.deletingLastPathComponent()) }
                let byID = try await walk(db: db, inputLines: [
                    toolCall(id: "w-404", tool: "page", arguments: ["book": bookID, "page": 99]),
                ])
                let error = try errorBody(try expectNotNil(byID["w-404"]), id: "w-404")
                let data = try expectNotNil(error["data"] as? [String: Any])
                try expectEqual(data["status"] as? Int, 404)
            },
        ]
    }
}
