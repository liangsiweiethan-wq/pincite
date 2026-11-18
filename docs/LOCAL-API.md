# 本机只读 API 规格

- 范围：给本机的 agent / CLI / 脚本一个**只读**数据入口。
- 传输：HTTP/1.1 over TCP，仅本机环回，单端口 **47115**（常数集中于 `LocalAPIServer.defaultPort`；冲突即 fail-closed 关停，不做端口段扫描）。
- 状态：**默认关闭**。设置页「本机 API」区块开关启停；无 LaunchAgent、无守护进程、无后台自动启动；App 退出即停服。

## 鉴权

1. 服务开启时每次 **App 启动重新生成**访问令牌：32 字节系统密码学安全随机源（`SystemRandomNumberGenerator`）→ 小写 hex 64 字符。
2. 令牌**只收 `Authorization` 请求头**（头值 = 令牌原文，精确比对）；**不随查询串传递**，避免进入访问日志或代理日志。
3. 除 `/ping` 外全部端点要求鉴权：头缺失或不符 → `401`，错误体 `{"error": "..."}`。
4. 令牌在设置页一键复制；重启后更换，脚本每次启动需从设置页重读。
5. 查询串与令牌**永不落日志**；审计环形只记端点路径/状态码/耗时/字节数。

## MCP 标准输入输出

使用 `literaturesearch-cli mcp-serve --db <path>` 启动只读进程，并通过环境变量 `LIT_MCP_TOKEN` 提供 64 字符的小写十六进制令牌。客户端在 `tools/list` 和 `tools/call` 请求的 `params._meta.authorization` 传令牌原文。每行一条 JSON-RPC 消息，标准输出只返回协议响应，标准输入关闭后进程退出。旧版索引需要先由当前版本的应用或 CLI 更新。

## 端点

六只读端点，写端点零个。

### GET /ping —— 探针（免鉴权）

```json
{"app": "literaturesearch", "schema": 13, "version": "<App 短版本>"}
```

服务发现探针。不含库统计、路径或令牌信息。

### GET /books —— 书列表

| 参数 | 默认 | 说明 |
|---|---|---|
| `offset` | 0 | 起始序数，负值/非数 → 400 |
| `limit` | 50 | 单页上限 **200**（超过按 200 截），防 agent 上下文爆仓 |
| `fields` | 默认集 | 列裁剪白名单：`id,title,author,file_name,page_count,language,status,path`；**默认不含 `path`**，显式点名才给；白名单外键名忽略，全不认识 → 400 |

```json
{"books": [{"id": "…", "title": "…", "author": "…", "file_name": "…",
            "page_count": 123, "language": "…", "status": "ok"}],
  "offset": 0, "limit": 50, "has_more": true}
```

### GET /search —— 检索（只读消费既有检索链）

| 参数 | 默认 | 说明 |
|---|---|---|
| `q` | 必填 | 缺失/空白 → 400 |
| `limit` | 20 | 单页上限 200 |

内部只调既有只读公共 API（与 CLI `search` 同一条调用链，含同一份 exclusion policy），不改 `SearchService`、不触碰归一化。`count_caliber` 如实标注 total 的计数基准：`character` = 字符级子串（CJK/拼音查询）；`word` = 拉丁词级整词（纯英文词/短语词路，词内片段如 copyrights 不计为 rights）。

```json
{"query": "…", "total": 12, "count_caliber": "character",
  "hits": [{"book_id": "…", "file_name": "…", "title": "…",
            "physical_page": 33, "snippet": "…", "source": "native"}],
  "has_more": false}
```

### GET /events —— 索引变更增量

| 参数 | 默认 | 说明 |
|---|---|---|
| `cursor` | 0 | 已投递序数（快照内偏移） |
| `limit` | 50 | 单页上限 200 |

数据源 = 既有 index_queue 五态行读侧（unavailable/unindexed/partial/indexed/queued），只读。

```json
{"events": [{"ordinal": 1, "book_id": "…", "state": "queued",
             "queued_version": 1, "attempts": 0, "last_error": null,
             "updated_at": 1759300000.0}],
  "cursor": 1, "has_more": false}
```

游标语义：游标 = 当前快照的序数偏移，不是持久事件日志。行序按 `book_id` 稳定排列；两次调用之间新入队的书目可能在 book_id 序中间插入，游标边界可重复个别行、但不漏读。本端点面向诊断与增量巡检，不承担严格一次投递承诺。

### GET /page —— 整页文本（只读）

| 参数 | 默认 | 说明 |
|---|---|---|
| `book` | 必填 | 书 id（books.id）；缺失/空白 → 400 |
| `page` | 必填 | 物理页号（1 起）；缺失/非数/＜1 → 400 |

数据源 = `IndexStore.page(bookID:pageNumber:)` 只读投影（`text_original`）。书缺/页缺 → 404。页文本超 **100,000 字符**（`LocalAPIProviders.pageTextMaxChars`）截断，`"truncated": true` 如实标注。

```json
{"book_id": "…", "page": 33, "chars": 4821, "text": "…", "truncated": false}
```

### GET /annotations —— 单书批注只读清单

| 参数 | 默认 | 说明 |
|---|---|---|
| `book` | 必填 | 书 id；**单书粒度**（不做全库批注出口）；缺失/空白 → 400，书缺 → 404 |
| `offset` | 0 | 负值/非数 → 400 |
| `limit` | 50 | 单页上限 200 |

数据源 = `HighlightStore.highlightsForBook(_:viewSource:)`（viewSource 缺省 = 两视图并集，导出管道同参）；**note 经既有解密读路径出**（加密开启时出明文，密文/未解密内容不出网）；列序 `page ASC, id ASC`；`type` 判定与导出管道同语义（页级 → `page_note`、`style=underline` → `underline`、否则 `highlight`）；`text` = `anchor_verified=1` 时页文本切片（切不出回退锚文本），否则锚文本原样。

```json
{"annotations": [{"id": 7, "book_id": "…", "page": 33, "type": "highlight",
                  "color": "yellow", "text": "…", "note": "…",
                  "created_at_iso8601": "2026-10-07T00:00:00Z",
                  "view_source": "ocr", "anchor_verified": 1}],
  "offset": 0, "limit": 50, "has_more": false}
```

## 结构性只读

1. 路由注册表**只注册 GET**；其余动词（含写动词）一律 `405`，错误体 `{"error": "method not allowed: this endpoint is read-only"}`。Core 路由源文件中不存在任何写动词字面（DesignGuard 守卫断言固定）。
2. 全部端点对 `index.db` 只读（books/events/page 直读，annotations 走 HighlightStore 只读查询，search 走只读检索链）；无 POST 通道即无写路径。
3. DesignGuard 守卫（grep 级，随合成测试执行）：
   - `import Network` 全仓仅 `LocalAPIServer.swift` 一处；
   - `127.0.0.1` 字面在监听壳内断言固定；全 Sources **全网卡绑定字面（0.0.0.0）0 命中**；
   - Core 路由源无写动词字面；两源无 `token=` 查询串拼接字面。

## 网络面边界

1. 环回两层防护：`NWParameters.requiredLocalEndpoint` 断言固定 IPv4 环回绑定（第一层）+ 连接收下后复核对端地址非环回即拒（第二层）。
2. fail-closed：端口占用/绑定失败 → 停服 + 设置页显式报错；请求报文超 64 KB 掐线；连接**空闲超 15 秒**（`LocalAPIServer.idleTimeout`；每收到数据即推迟）掐线；`Connection: close` 无会话态。
3. 数据出口边界：书目/检索/索引队列/页文本/批注只读清单各面**只读**。/annotations 与 /page 经 MCP/环回路显式点名放行：单书粒度、稳定列序、note 必经解密读路径；**写端点仍为零**，导出/AI 不开网络面。

## 明确不做

1. **远程访问、OAuth、多用户**：单机定位，不做。
2. **写端点（任何形式）**：不做。增量写需求走既有文件出口，不走网络面。
3. **令牌长期持久化**：不做（每次启动轮换）。
4. **全库批注出口**：不做（仅单书粒度）。

## 实现对照

| 语义 | 落点 |
|---|---|
| token 生成 | `Sources/LiteratureCore/LocalAPI.swift` `LocalAPIToken.generate()` |
| 路由/参数/JSON 形制 | 同上 `LocalAPIRouter`（Foundation 纯逻辑） |
| 监听壳/环回绑定/审计 | `Sources/LiteratureSearchApp/LocalAPIServer.swift`（唯一 `import Network`） |
| 开关/生命周期 | `AppState.localAPIEnabled` / `startLocalAPI()`（设置页 `LibrarySettingsView`「本机 API」区块） |
| 数据供给链 | `LocalAPIProviders.makeLive(store:search:)`（books/events 直读 IndexStore 只读侧；search 走 CLI 同链） |
| MCP 只读桥（stdio） | `Sources/LiteratureCore/MCPBridge.swift`（JSON-RPC 2.0 ↔ 路由器直调；CLI `mcp-serve` 显式启动） |
| /page /annotations 端点 | `Sources/LiteratureCore/LocalAPI.swift`（供给链 `LocalAPIProviders.pageTextMaxChars=100_000`；批注 note 走解密读路径） |
| 空闲掐线计时器 | `Sources/LiteratureCore/LocalAPIIdleTimer.swift`（可单测组件；壳层组装于 `LocalAPIServer.readRequest`） |
