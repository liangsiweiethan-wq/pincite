import Foundation
@testable import LiteratureCore

// MARK: - 本机只读 API 合成测试（纯逻辑层全测；NWListener 网络壳
// 不做合成集成测试——壳留实机走查）

enum LocalAPISuite {
    /// 路由测试用 fixture 供给链（与网络壳零耦合）。
    static func fixtureProviders() -> LocalAPIProviders {
        let books = [
            LocalAPIBook(id: "b1", title: "示例方法论", author: "作者丁", fileName: "a.pdf",
                         pageCount: 120, language: "de", status: "ok", path: "/tmp/library/a.pdf"),
            LocalAPIBook(id: "b2", title: nil, author: nil, fileName: "b.pdf",
                         pageCount: 0, language: nil, status: "ok", path: "/tmp/library/b.pdf"),
            LocalAPIBook(id: "b3", title: "服从的义务", author: nil, fileName: "c.pdf",
                         pageCount: 45, language: "zh", status: "ok", path: "/tmp/library/c.pdf"),
        ]
        return LocalAPIProviders(
            books: { offset, limit in
                let start = min(max(offset, 0), books.count)
                let end = min(start + limit, books.count)
                return (Array(books[start..<end]), end < books.count)
            },
            search: { query, limit in
                guard query == "alpha" else { return ([], 0, false, "character") }
                let hits = (0..<min(3, limit)).map { index in
                    LocalAPISearchHit(bookID: "b1", fileName: "a.pdf", title: "示例方法论",
                                      physicalPage: index + 1, snippet: "alpha \(index)", source: "native")
                }
                return (hits, 3, false, "character")
            },
            events: { cursor, limit in
                let total = 7
                let start = min(max(cursor, 0), total)
                let end = min(start + limit, total)
                let rows = (start..<end).map { index in
                    LocalAPIEvent(ordinal: index + 1, bookID: "b\(index % 3 + 1)",
                                  state: index == 0 ? "indexed" : "queued",
                                  queuedVersion: 1, attempts: 0, lastError: nil,
                                  updatedAt: Double(1_759_300_000 + index))
                }
                return (rows, end, end < total)
            })
    }

    static func makeRouter(token: String = LocalAPIToken.generate(),
                           providers: LocalAPIProviders? = nil) -> LocalAPIRouter {
        LocalAPIRouter(token: token, appVersion: "test", schemaVersion: 9,
                       providers: providers ?? fixtureProviders())
    }

    /// 便捷断言：JSON body 解为字典。
    static func dict(_ response: LocalAPIResponse) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: response.body, options: [])
        guard let dictionary = object as? [String: Any] else {
            try failTest("response body is not a JSON object: \(response.bodyText)")
        }
        return dictionary
    }

    static func authHeader(_ token: String) -> String { token }

    static var tests: [TestDesc] {
        [
            // ── token：长度 64、字符集 [0-9a-f]、两次生成不同 ──
            TestDesc(suite: "LocalAPI", name: "tokenIs64LowercaseHex") {
                let token = LocalAPIToken.generate()
                try expectEqual(token.count, 64)
                let charset = CharacterSet(charactersIn: "0123456789abcdef")
                try expectTrue(token.unicodeScalars.allSatisfy { charset.contains($0) },
                               "token must be lowercase hex: \(token)")
            },
            TestDesc(suite: "LocalAPI", name: "tokenGenerationsDiffer") {
                let first = LocalAPIToken.generate()
                let second = LocalAPIToken.generate()
                try expectNotEqual(first, second)
            },

            // ── 路由鉴权：结构性只读（写动词 405 断言固定）＋ 401 面 ──
            TestDesc(suite: "LocalAPI", name: "writeVerbsAre405OnAnyPath") {
                let router = makeRouter()
                for method in ["POST", "PUT", "DELETE", "PATCH", "HEAD"] {
                    for path in ["/ping", "/books", "/search", "/events", "/page", "/annotations"] {
                        let response = router.route(method: method, target: path, authorization: router.token)
                        try expectEqual(response.status, 405,
                                        "\(method) \(path) must be 405")
                    }
                }
            },
            TestDesc(suite: "LocalAPI", name: "missingAuthorizationIs401") {
                let router = makeRouter()
                let response = router.route(method: "GET", target: "/books", authorization: nil)
                try expectEqual(response.status, 401)
            },
            // ── 鉴权比对走常数时间函数直测 ──
            TestDesc(suite: "LocalAPI", name: "tokenMatchesExactRoundTrip") {
                let token = LocalAPIToken.generate()
                try expectTrue(LocalAPIToken.matches(token, expected: token),
                               "相同 token 必须命中")
                try expectFalse(LocalAPIToken.matches(token + "0", expected: token),
                               "尾缀变体（长度不等）必须不命中")
            },
            TestDesc(suite: "LocalAPI", name: "tokenMatchesRejectsPrefixAndLengthVariants") {
                let expected = String(repeating: "a", count: 64)
                // 尾位差异：拒（前缀匹配不得放行）。
                try expectFalse(LocalAPIToken.matches(String(repeating: "a", count: 63) + "b",
                                                      expected: expected))
                // 首位差异：拒。
                try expectFalse(LocalAPIToken.matches("b" + String(repeating: "a", count: 63),
                                                      expected: expected))
                // 长度不等（多一位/少一位/空串）：拒。
                try expectFalse(LocalAPIToken.matches(expected + "a", expected: expected))
                try expectFalse(LocalAPIToken.matches(String(repeating: "a", count: 63),
                                                      expected: expected))
                try expectFalse(LocalAPIToken.matches("", expected: expected))
                // 缺失头（nil）：拒。
                try expectFalse(LocalAPIToken.matches(nil, expected: expected))
            },
            TestDesc(suite: "LocalAPI", name: "wrongTokenIs401") {
                let router = makeRouter()
                let response = router.route(method: "GET", target: "/books",
                                            authorization: String(repeating: "0", count: 64))
                try expectEqual(response.status, 401)
            },
            TestDesc(suite: "LocalAPI", name: "correctTokenGrantsBooks") {
                let router = makeRouter()
                let response = router.route(method: "GET", target: "/books", authorization: router.token)
                try expectEqual(response.status, 200)
                let body = try dict(response)
                try expectEqual((body["books"] as? [Any])?.count, 3)
            },
            TestDesc(suite: "LocalAPI", name: "pingReachableWithoutToken") {
                let router = makeRouter()
                let response = router.route(method: "GET", target: "/ping", authorization: nil)
                try expectEqual(response.status, 200)
                let body = try dict(response)
                try expectEqual(body["app"] as? String, "literaturesearch")
                try expectEqual(body["schema"] as? Int, 9)
                try expectEqual(body["version"] as? String, "test")
            },

            // ── /books：fields 裁剪、limit 上限、分页边界 ──
            TestDesc(suite: "LocalAPI", name: "booksDefaultFieldsExcludePath") {
                let router = makeRouter()
                let response = router.route(method: "GET", target: "/books", authorization: router.token)
                let body = try dict(response)
                let rows = try expectNotNil(body["books"] as? [[String: Any]])
                for row in rows {
                    try expectFalse(row.keys.contains("path"),
                                    "default response must not expose path fields")
                }
            },
            TestDesc(suite: "LocalAPI", name: "booksExplicitFieldsPruneToRequestedKeys") {
                let router = makeRouter()
                let response = router.route(method: "GET", target: "/books?fields=id,title",
                                            authorization: router.token)
                let body = try dict(response)
                let rows = try expectNotNil(body["books"] as? [[String: Any]])
                try expectTrue(!rows.isEmpty)
                for row in rows {
                    try expectEqual(Set(row.keys), Set(["id", "title"]))
                }
                // 显式点名 path 才给路径字段（fail-closed 语义的白名单侧）。
                let withPath = router.route(method: "GET", target: "/books?fields=path",
                                            authorization: router.token)
                let pathRows = try dict(withPath)["books"] as? [[String: Any]] ?? []
                for row in pathRows {
                    try expectEqual(Set(row.keys), Set(["path"]))
                }
            },
            TestDesc(suite: "LocalAPI", name: "booksUnknownFieldsOnlyIs400") {
                let router = makeRouter()
                let response = router.route(method: "GET", target: "/books?fields=nonsense",
                                            authorization: router.token)
                try expectEqual(response.status, 400)
            },
            TestDesc(suite: "LocalAPI", name: "booksLimitCappedAt200") {
                var providers = fixtureProviders()
                var observedLimit = 0
                providers.books = { offset, limit in
                    observedLimit = limit
                    return ([], false)
                }
                let router = makeRouter(providers: providers)
                let response = router.route(method: "GET", target: "/books?limit=100000",
                                            authorization: router.token)
                try expectEqual(response.status, 200)
                try expectEqual(observedLimit, 200)
            },
            TestDesc(suite: "LocalAPI", name: "booksOffsetHasMoreBoundary") {
                let router = makeRouter()
                let first = try dict(router.route(method: "GET", target: "/books?offset=0&limit=2",
                                                  authorization: router.token))
                try expectEqual(first["has_more"] as? Bool, true)
                let tail = try dict(router.route(method: "GET", target: "/books?offset=2&limit=2",
                                                 authorization: router.token))
                try expectEqual((tail["books"] as? [Any])?.count, 1)
                try expectEqual(tail["has_more"] as? Bool, false)
            },

            // ── /search：空 q 400；同源零漂移（fixture 库对照直调）──
            TestDesc(suite: "LocalAPI", name: "searchEmptyOrMissingQIs400") {
                let router = makeRouter()
                for target in ["/search", "/search?q=", "/search?q=%20%20"] {
                    let response = router.route(method: "GET", target: target,
                                                authorization: router.token)
                    try expectEqual(response.status, 400, "target: \(target)")
                }
            },
            TestDesc(suite: "LocalAPI", name: "searchHitsMatchDirectReadOnlyCall") {
                // 零漂移同源证明：live 供给链（CLI search 同一条只读链）命中数
                // 与直调 SearchService 完全相等。
                let (store, _) = try CoverageClassificationSuite.makeStore()
                _ = try CoverageClassificationSuite.addBook(store, id: "bA", name: "a.pdf",
                                                      pages: ["alpha one", "alpha two"])
                let service = SearchService(store: store)
                let providers = LocalAPIProviders.makeLive(store: store, search: service,
                                                           highlights: HighlightStore(indexStore: store))
                let router = makeRouter(providers: providers)
                let response = router.route(method: "GET", target: "/search?q=alpha&limit=200",
                                            authorization: router.token)
                try expectEqual(response.status, 200)
                let body = try dict(response)
                let direct = try service.searchDetailed("alpha")
                try expectEqual((body["hits"] as? [Any])?.count, direct.hits.count)
                try expectEqual(body["total"] as? Int, direct.totalPageMatches)
            },

            // ── /events：游标增量与尾页边界 ──
            TestDesc(suite: "LocalAPI", name: "eventsCursorTakesIncrement") {
                let router = makeRouter()
                let first = try dict(router.route(method: "GET", target: "/events?cursor=0&limit=3",
                                                  authorization: router.token))
                let rows = try expectNotNil(first["events"] as? [[String: Any]])
                try expectEqual(rows.count, 3)
                try expectEqual(rows.first?["ordinal"] as? Int, 1)
                let nextCursor = try expectNotNil(first["cursor"] as? Int)
                try expectEqual(nextCursor, 3)
                let second = try dict(router.route(method: "GET",
                                                   target: "/events?cursor=\(nextCursor)&limit=3",
                                                   authorization: router.token))
                let secondRows = try expectNotNil(second["events"] as? [[String: Any]])
                try expectEqual(secondRows.first?["ordinal"] as? Int, 4)
            },
            TestDesc(suite: "LocalAPI", name: "eventsTailHasMoreFalse") {
                let router = makeRouter()
                let tail = try dict(router.route(method: "GET", target: "/events?cursor=5&limit=50",
                                                 authorization: router.token))
                try expectEqual((tail["events"] as? [Any])?.count, 2)
                try expectEqual(tail["has_more"] as? Bool, false)
            },

            // ── 错误形制：所有非 2xx 响应体含 error 键；未知路径 404 ──
            TestDesc(suite: "LocalAPI", name: "allNon2xxBodiesCarryErrorKey") {
                let router = makeRouter()
                let cases: [(Int, LocalAPIResponse)] = [
                    (router.route(method: "GET", target: "/books", authorization: nil).status, // 401
                     router.route(method: "GET", target: "/books", authorization: nil)),
                    (405, router.route(method: "POST", target: "/books", authorization: router.token)),
                    (404, router.route(method: "GET", target: "/nope", authorization: router.token)),
                    (400, router.route(method: "GET", target: "/search", authorization: router.token)),
                ]
                for (expectedStatus, response) in cases {
                    try expectEqual(response.status, expectedStatus)
                    let body = try dict(response)
                    try expectNotNil(body["error"] as? String,
                                     "non-2xx body must carry error key: \(response.bodyText)")
                }
            },
            TestDesc(suite: "LocalAPI", name: "unknownPathIs404") {
                let router = makeRouter()
                let response = router.route(method: "GET", target: "/highlights", authorization: router.token)
                try expectEqual(response.status, 404)
            },

            // ── 解析助手：请求行目标切分与查询串解码 ──
            TestDesc(suite: "LocalAPI", name: "targetSplitAndQueryDecoding") {
                let split = LocalAPIRouter.splitTarget("/search?q=%E6%B3%95%E5%AD%A6&limit=5")
                try expectEqual(split.path, "/search")
                let params = LocalAPIRouter.parseQuery(split.query)
                try expectEqual(params.first { $0.0 == "q" }?.1, "法学")
                try expectEqual(params.first { $0.0 == "limit" }?.1, "5")
            },

            // ── /page：整页文本、书缺/页缺 404、参数非法 400 ──
            TestDesc(suite: "LocalAPI", name: "pageEndpointReturnsTextWithShape") {
                var providers = fixtureProviders()
                providers.page = { bookID, pageNumber in
                    guard bookID == "b1" else {
                        throw LocalAPIProviderError.notFound("not found: no such book")
                    }
                    guard pageNumber == 1 else {
                        throw LocalAPIProviderError.notFound("not found: no such page")
                    }
                    return ("第一章 正文", false)
                }
                let router = makeRouter(providers: providers)
                let ok = try dict(router.route(method: "GET", target: "/page?book=b1&page=1",
                                               authorization: router.token))
                try expectEqual(ok["book_id"] as? String, "b1")
                try expectEqual(ok["page"] as? Int, 1)
                try expectEqual(ok["chars"] as? Int, 6)
                try expectEqual(ok["text"] as? String, "第一章 正文")
                try expectEqual(ok["truncated"] as? Bool, false)
                // 书缺/页缺 → 404（notFound 可判别映射）。
                try expectEqual(router.route(method: "GET", target: "/page?book=zz&page=1",
                                             authorization: router.token).status, 404)
                try expectEqual(router.route(method: "GET", target: "/page?book=b1&page=9",
                                             authorization: router.token).status, 404)
                // 参数非法 → 400。
                try expectEqual(router.route(method: "GET", target: "/page?page=1",
                                             authorization: router.token).status, 400)
                try expectEqual(router.route(method: "GET", target: "/page?book=b1",
                                             authorization: router.token).status, 400)
                try expectEqual(router.route(method: "GET", target: "/page?book=b1&page=0",
                                             authorization: router.token).status, 400)
                try expectEqual(router.route(method: "GET", target: "/page?book=b1&page=abc",
                                             authorization: router.token).status, 400)
                // 写动词照 405（结构性只读，注册表外无通道）。
                try expectEqual(router.route(method: "POST", target: "/page?book=b1&page=1",
                                             authorization: router.token).status, 405)
            },
            TestDesc(suite: "LocalAPI", name: "pageProviderDefaultsToConfiguredError") {
                // fixture 未配 page/annotations → 默认实现 500（显式报错不静默）。
                let router = makeRouter()
                let response = router.route(method: "GET", target: "/page?book=b1&page=1",
                                            authorization: router.token)
                try expectEqual(response.status, 500)
                try expectTrue(response.bodyText.contains("provider not configured"),
                               "默认实现应显式点名未配置：\(response.bodyText)")
            },

            // ── /annotations：单书只读清单、稳定列序、分页 ──
            TestDesc(suite: "LocalAPI", name: "annotationsEndpointPinsRowShapeOrderAndPaging") {
                var providers = fixtureProviders()
                providers.annotations = { bookID, offset, limit in
                    try expectEqual(bookID, "b1")
                    // 路由只投影不重排——稳定列序（page ASC, id ASC）是供给链
                    // 契约（live 侧断言见 liveAnnotationsOrderedByPageThenID）。
                    let first = LocalAPIAnnotation(id: 7, bookID: bookID, page: 2,
                                                   type: "underline", color: "red",
                                                   text: "切片", note: "",
                                                   createdAtISO8601: "2026-10-07T00:00:01Z",
                                                   viewSource: "original", anchorVerified: 1)
                    let second = LocalAPIAnnotation(id: 20, bookID: bookID, page: 5,
                                                    type: "page_note", color: "yellow",
                                                    text: "", note: "页注",
                                                    createdAtISO8601: "2026-10-07T00:00:02Z",
                                                    viewSource: "ocr", anchorVerified: 0)
                    let all = [first, second]
                    let start = Swift.min(Swift.max(offset, 0), all.count)
                    let end = Swift.min(start + limit, all.count)
                    return (Array(all[start..<end]), end < all.count)
                }
                let router = makeRouter(providers: providers)
                let body = try dict(router.route(method: "GET",
                                                 target: "/annotations?book=b1",
                                                 authorization: router.token))
                let rows = try expectNotNil(body["annotations"] as? [[String: Any]])
                try expectEqual(rows.map { $0["page"] as? Int }, [2, 5], "列序 page ASC")
                try expectEqual(rows.first?["id"] as? Int, 7)
                try expectEqual(rows.first?["type"] as? String, "underline")
                try expectEqual(rows.first?["view_source"] as? String, "original")
                try expectEqual(rows.first?["anchor_verified"] as? Int, 1)
                try expectEqual(rows.last?["type"] as? String, "page_note")
                try expectNotNil(rows.first?["created_at_iso8601"] as? String)
                try expectEqual(body["has_more"] as? Bool, false)
                // 分页形制：offset/limit/has_more（同 books 形制）。
                let paged = try dict(router.route(method: "GET",
                                                  target: "/annotations?book=b1&offset=1&limit=1",
                                                  authorization: router.token))
                let pagedRows = try expectNotNil(paged["annotations"] as? [[String: Any]])
                try expectEqual(pagedRows.count, 1)
                try expectEqual(pagedRows.first?["page"] as? Int, 5)
                try expectEqual(paged["has_more"] as? Bool, false)
                // 响应行键集合断言（契约形制十键）。
                let expectedKeys = Set(["id", "book_id", "page", "type", "color", "text",
                                        "note", "created_at_iso8601", "view_source",
                                        "anchor_verified"])
                for row in rows {
                    try expectEqual(Set(row.keys), expectedKeys)
                }
                // book 必填；书缺 404（provider notFound 映射）。
                try expectEqual(router.route(method: "GET", target: "/annotations",
                                             authorization: router.token).status, 400)
                providers.annotations = { _, _, _ in
                    throw LocalAPIProviderError.notFound("not found: no such book")
                }
                let missing = makeRouter(providers: providers)
                try expectEqual(missing.route(method: "GET", target: "/annotations?book=zz",
                                              authorization: missing.token).status, 404)
            },

            // ── /annotations live 供给链：稳定列序 page ASC, id ASC ──
            TestDesc(suite: "LocalAPI", name: "liveAnnotationsOrderedByPageThenID") {
                let (store, _) = try CoverageClassificationSuite.makeStore()
                _ = try CoverageClassificationSuite.addBook(store, id: "bAnn", name: "ann.pdf",
                                                      pages: ["alpha one", "alpha two",
                                                              "alpha three"])
                let highlights = HighlightStore(indexStore: store)
                // 故意乱页序种入：页 3、页 1；再页 1 同页异行验 id ASC。
                _ = try highlights.add(bookID: "bAnn", pageNumber: 3, utf16Start: 0,
                                       utf16End: 5, color: .yellow, note: "三号",
                                       anchorVerified: 1)
                _ = try highlights.add(bookID: "bAnn", pageNumber: 1, utf16Start: 0,
                                       utf16End: 5, color: .yellow, note: "一号",
                                       anchorVerified: 1)
                _ = try highlights.add(bookID: "bAnn", pageNumber: 1, utf16Start: 6,
                                       utf16End: 9, color: .yellow, note: "一号乙",
                                       anchorVerified: 1)
                let providers = LocalAPIProviders.makeLive(
                    store: store, search: SearchService(store: store), highlights: highlights)
                let (rows, hasMore) = try providers.annotations("bAnn", 0, 50)
                try expectEqual(hasMore, false)
                try expectEqual(rows.map(\.page), [1, 1, 3],
                                "列序必须 page ASC")
                try expectTrue(rows[0].id < rows[1].id, "同页按行 id 升序")
                try expectEqual(rows[2].page, 3)
                // note 明文形制（解密读路径出口）。
                try expectEqual(rows[0].note, "一号")
                // offset/limit 切片。
                let (slice, more) = try providers.annotations("bAnn", 1, 1)
                try expectEqual(slice.count, 1)
                try expectEqual(slice.first?.id, rows[1].id)
                try expectEqual(more, true)
            },

            // ── /events 行序稳定列（实时数据链）──
            TestDesc(suite: "LocalAPI", name: "liveEventsOrderedByBookIDAndStableAcrossRequeue") {
                let (store, _) = try CoverageClassificationSuite.makeStore()
                // 乱序入库三册：bookID 字典序 bC < bA？否——升序应为 bA < bB < bC。
                _ = try CoverageClassificationSuite.addBook(store, id: "bC", name: "c.pdf",
                                                      pages: ["alpha one"])
                _ = try CoverageClassificationSuite.addBook(store, id: "bA", name: "a.pdf",
                                                      pages: ["alpha two"])
                _ = try CoverageClassificationSuite.addBook(store, id: "bB", name: "b.pdf",
                                                      pages: ["alpha three"])
                try store.enqueueBook("bC")
                try store.enqueueBook("bA")
                try store.enqueueBook("bB")
                let providers = LocalAPIProviders.makeLive(
                    store: store, search: SearchService(store: store),
                    highlights: HighlightStore(indexStore: store))
                let first = try providers.events(0, 50)
                try expectEqual(first.rows.map(\.bookID), ["bA", "bB", "bC"],
                                "events 行序必须按 book_id 升序（稳定列）")
                try expectEqual(first.rows.map(\.ordinal), [1, 2, 3])
                // 入队 touch updated_at 后重拉同 cursor：序不漂移。
                try store.enqueueBook("bB")
                let second = try providers.events(0, 50)
                try expectEqual(second.rows.map(\.bookID), ["bA", "bB", "bC"],
                                "updated_at 变更不得引起行序漂移（行序稳定性断言）")
                try expectEqual(second.rows.map(\.ordinal), first.rows.map(\.ordinal))
            },

            // ── live 供给链：books/events 对真实库（只读面）──
            TestDesc(suite: "LocalAPI", name: "liveProvidersReadRealStore") {
                let (store, _) = try CoverageClassificationSuite.makeStore()
                _ = try CoverageClassificationSuite.addBook(store, id: "bA", name: "a.pdf",
                                                      pages: ["alpha one", "alpha two"])
                try store.enqueueBook("bA")
                let providers = LocalAPIProviders.makeLive(
                    store: store, search: SearchService(store: store),
                    highlights: HighlightStore(indexStore: store))
                let booksPage = try providers.books(0, 50)
                try expectEqual(booksPage.rows.count, 1)
                try expectEqual(booksPage.rows.first?.fileName, "a.pdf")
                try expectEqual(booksPage.hasMore, false)
                let eventsPage = try providers.events(0, 50)
                try expectEqual(eventsPage.rows.count, 1)
                try expectEqual(eventsPage.rows.first?.state, "queued")
                try expectEqual(eventsPage.hasMore, false)
            },
        ]
    }
}
