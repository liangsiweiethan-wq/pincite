import Foundation
import PDFKit
import LiteratureCore

// Safe operator CLI over LiteratureCore.
// Every command is explicit — nothing scans a library without a named root or
// named files. Argument values are bounds-checked: a missing value is a usage
// error, never a crash. `pdf-info`/`index-file`/`audit` all go through the same
// exclusion policy as indexing (policy gate BEFORE any content read), so there
// is no bypass. `--summary-only` modes never print body text into logs.
// `import-ocr`/`index-ocr` take TWO explicit allowed roots (original + OCR) and
// a user-authored manifest; both files of every pair are policy-checked and
// fingerprint-verified; original PDFs are read-only and no OCR is performed.

@main
struct LiteratureSearchCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            try await run(args)
        } catch let error as CLIError {
            FileHandle.standardError.write(Data("error: \(error.message)\n\n\(usage())\n".utf8))
            exit(2)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(2)
        }
    }

    static func usage() -> String {
        """
        literaturesearch-cli — safe, explicit-only operations over LiteratureCore

        USAGE:
          literaturesearch-cli probe
          literaturesearch-cli index <root> --db <path> [--exclusions <config.json>] [--publish-coverage]
                                       [--max-pages <int|none>] [--max-bytes <int|none>]
                                       [--time-budget <seconds>]
                                        （--time-budget：索引队列消费的时间预算，到点即停可续）
                                        （文字源缺省为读取 PDF 文字层）
          literaturesearch-cli index-file <pdf> [<pdf>...] --db <path> [--exclusions <config.json>]
                                          [--max-pages <int|none>] [--max-bytes <int|none>]
                                          （文字源基准同 index——读取 PDF 文字层）
          literaturesearch-cli audit <root> [--exclusions <config.json>]
          literaturesearch-cli search <query> --db <path> [--limit N] [--summary-only] [--phase-timing] [--include-toolbooks]
                                        [--exclusions <config.json>] [--readonly]
                                        （--phase-timing：分相计时，stderr 输出，stdout 不变）
                                        （--readonly：只读通道开库（readOnlyReplica），对索引库
                                         零写（不 PRAGMA journal_mode=WAL、不写 sqlite_version meta、
                                         不建索引）；结果与读写通道一致，只少了 meta 缓存与建索引）
          literaturesearch-cli pdf-info <file.pdf> [--summary-only] [--show-text] [--exclusions <config.json>]
          literaturesearch-cli import-meta --db <path> --sidecar <file.csv|.json>
          literaturesearch-cli import-page-map --db <path> --csv <file.csv>
          literaturesearch-cli import-ocr --manifest <pairs.json> --original-root <dir> --ocr-root <dir>
                                          --db <path> [--exclusions <config.json>]
                                          [--max-pages <int|none>] [--max-bytes <int|none>]
          literaturesearch-cli index-ocr --db <path>
                                         [--manifest <pairs.json> --original-root <dir> --ocr-root <dir>]
                                         [--exclusions <config.json>]
                                         [--max-pages <int|none>] [--max-bytes <int|none>]
          literaturesearch-cli genpdf --out <path.pdf> [--page <line1 NEWLINE line2 ...>]...
          literaturesearch-cli daily-quote --db <path> [--refresh] [--json]
          literaturesearch-cli rebuild-bigram-index --db <path>
          literaturesearch-cli backfill-latin --db <path> [--quiet]
                                       （词级索引回填——text_latin 投影 + pages_wfts，
                                        21 批断点续跑；完成后置 wfts_ready=1 并 'optimize'；
                                        进度走 stderr，stdout 一行 JSON 摘要）
          literaturesearch-cli detect-body-start --db <path> [--book <book_id>] [--apply]
                                       （正文起始物理页探测器；report-only 缺省，
                                        --apply 才把候选写书级 meta 键）
          literaturesearch-cli reindex-book <book_id> --db <path> [--force] [--exclusions <config.json>]
                                       （sha256 脏检查单册重索引；unchanged/updated/missing/error
                                         一行 JSON 摘要；只动这一本，绝不扫描库根）
          literaturesearch-cli webdav-inbox-pull --config <json> --env-password [--into <dir>]
                                         （拉取手机「存到 Mac」分享件；同名幂等跳过、远端不删）
          literaturesearch-cli classify --db <path> [--dry-run] [--rules]
                                       （自动归类——默认全量重跑并写表；
                                        --dry-run 只输出 JSON 不写表；--rules 列规则表。
                                        规则本身用 SQL 在 classification_rules 表增删）
          literaturesearch-cli open --doc <bookID> [--page N] [--hl <id>] [--print]
                                       （经 DeepLink.build 构造深链 URL；
                                        --print 只打印，缺省调 /usr/bin/open 拉起 App；
                                        --hl <id>：批注行高亮定位）
          literaturesearch-cli mcp-serve --db <path> [--exclusions <config.json>]
                                       （token 经环境变量 LIT_MCP_TOKEN 供给（64 位小写 hex）；--token argv 已 deprecated，仅缺 env 时降级处理）
                                       （MCP 只读桥（stdio JSON-RPC 2.0，
                                        docs/LOCAL-API.md）。显式启动即服役、
                                        stdin EOF 即停；五只读工具 search/books/events/page/annotations
                                        （含后两工具）；
                                        每次 tools/list・tools/call 经 _meta.authorization
                                        鉴权（401 语义照 LocalAPI）；审计行走 stderr，
                                        stdout 只出协议响应）
           literaturesearch-cli rebind-renames <receipt.json> --db <path> [--dry-run] [--report <out.json>]
                                        （改名路径重绑定：读改名回执
                                         {"renames":[{"old_path":...,"new_path":...}]}
                                         ——逐行校验后单事务全有或全无回绑 books 四列
                                         ＋OCR 配对路径；书 id 不变；有 REFUSED 即非零退出）

        NOTES:
          - index/search/audit operate only on the explicitly named root; index-file
            only on the explicitly named files (read-only; nothing is copied).
          - The index checks user-configured path exclusions and root boundaries
            before reading files. Renamed copies may require their own rule.
          - index publishes Widget coverage ONLY when --db is the canonical app
            database; pass --publish-coverage to publish from another --db on
            purpose ( indexes never touch the shared snapshot).
          - --max-pages/--max-bytes override the per-file extraction caps
            (defaults 2000 pages / 1 GiB; "none" lifts the cap). Over-limit
            files fail WHOLE — never partially indexed.
          - --summary-only never prints original text (logs stay body-free).
          - genpdf writes synthetic fixtures only; never reads real books.

        OCR PAIRING (import-ocr / index-ocr):
          - Fully manifest-driven and explicit; this tool performs NO OCR itself —
            the OCR PDF must already contain a text layer. The original PDF is
            only ever read, never written.
          - Manifest format (paths relative to the respective root, or absolute):
              {"pairs":[
                {"originalPath":"scan/book.pdf","ocrPath":"scan/book-ocr.pdf",
                 "mapping":{"type":"same-page-verified"}},
                {"originalPath":"scan/other.pdf","ocrPath":"scan/other-ocr.pdf",
                 "mapping":{"type":"explicit","pages":[{"original":1,"ocr":2},{"original":2,"ocr":3}}]}
              ]}
            "same-page-verified" asserts OCR page N == original page N and is
            REJECTED when the two files' page counts differ; "explicit" is
            bounds-checked per entry; duplicates on either side, "fixed-offset"
            mappings and unknown mapping types are rejected outright.
          - Both files of every pair are checked against the SAME exclusion
            policy; if either is excluded the whole pair is rejected.
          - The original must already be indexed and its fingerprint must still
            match; otherwise the pair is refused (stale pairing).
          - OCR text is stored with source='ocr' against the ORIGINAL book's
            physical pages (pages with native text are never overwritten — the
            versions are not mixed). Hits keep physicalPage = original page and
            expose ocrPage/ocrFilePath: highlight coordinates belong to the OCR
            file only; open the original separately at physicalPage.
          - `index-ocr` without --manifest re-verifies all registered pairs
            (both fingerprints + exclusion policy) and purges stale pairings;
            with --manifest it also (re-)imports the manifest's pairs.
        """
    }

    // MARK: bounds-checked argument access

    struct ArgCursor {
        let args: [String]
        var position = 0
        init(_ args: [String]) { self.args = args }

        var isAtEnd: Bool { position >= args.count }
        var current: String? { position < args.count ? args[position] : nil }

        /// Returns the value of a flag; missing value is a usage error, not a crash.
        mutating func value(for flag: String) throws -> String {
            position += 1
            guard position < args.count else {
                throw CLIError("flag \(flag) requires a value")
            }
            return args[position]
        }
    }

    /// Fail-closed: malformed config aborts the command (never permissive).
    static func exclusionConfig(_ path: String?) throws -> ExclusionConfig {
        guard let path else { return ExclusionConfig.conservativeDefaults }
        return try ExclusionConfig.loadForOperation(fileAt: URL(fileURLWithPath: path))
    }

    static func run(_ args: [String]) async throws {
        guard let command = args.first else {
            print(usage()); return
        }
        switch command {
        case "probe":
            try probe()
        case "index":
            try await indexCommand(Array(args.dropFirst()))
        case "index-file":
            try await indexFileCommand(Array(args.dropFirst()))
        case "audit":
            try auditCommand(Array(args.dropFirst()))
        case "search":
            try await searchCommand(Array(args.dropFirst()))
        case "pdf-info":
            try pdfInfoCommand(Array(args.dropFirst()))
        case "import-meta":
            try importMetaCommand(Array(args.dropFirst()))
        case "import-page-map":
            try importPageMapCommand(Array(args.dropFirst()))
        case "import-ocr":
            try importOCRCommand(Array(args.dropFirst()))
        case "index-ocr":
            try indexOCRCommand(Array(args.dropFirst()))
        case "genpdf":
            try genpdf(Array(args.dropFirst()))
        case "rebuild-bigram-index":
            try rebuildBigramIndexCommand(Array(args.dropFirst()))
        case "backfill-latin":
            try backfillLatinCommand(Array(args.dropFirst()))
        case "reindex-book":
            try await reindexBookCommand(Array(args.dropFirst()))
        case "webdav-sync":
            try await webdavSyncCommand(Array(args.dropFirst()))
        case "webdav-inbox-pull":
            try await webdavInboxPullCommand(Array(args.dropFirst()))
        case "daily-quote":
            try await dailyQuoteCommand(Array(args.dropFirst()))
        case "detect-body-start":
            try detectBodyStartCommand(Array(args.dropFirst()))
        case "classify":
            try classifyCommand(Array(args.dropFirst()))
        case "open":
            try openCommand(Array(args.dropFirst()))
        case "mcp-serve":
            try mcpServeCommand(Array(args.dropFirst()))
        case "rebind-renames":
            try rebindRenamesCommand(Array(args.dropFirst()))
        case "help", "--help", "-h":
            print(usage())
        default:
            throw CLIError("unknown command '\(command)'")
        }
    }

    // MARK: probe

    static func probe() throws {
        let caps = FTS5Probe.probeOrDefault()
        print("""
        {
          "sqlite": "\(caps.sqliteVersion)",
          "fts5": \(caps.fts5),
          "trigram": \(caps.trigramTokenizer),
          "unicode61": \(caps.unicode61Tokenizer)
        }
        """)
    }

    // MARK: index (whole explicit root)

    static func indexCommand(_ args: [String]) async throws {
        var cursor = ArgCursor(args)
        var root: URL?
        var dbPath: URL?
        var exclusionsPath: String?
        var publishCoverage = false
        var maxPagesRaw: String?
        var maxBytesRaw: String?
        var timeBudget: Double?
        while let arg = cursor.current {
            switch arg {
            case "--db": dbPath = URL(fileURLWithPath: try cursor.value(for: arg))
            case "--exclusions": exclusionsPath = try cursor.value(for: arg)
            case "--publish-coverage": publishCoverage = true
            case "--max-pages": maxPagesRaw = try cursor.value(for: arg)
            case "--max-bytes": maxBytesRaw = try cursor.value(for: arg)
            case "--time-budget":
                let raw = try cursor.value(for: arg)
                guard let v = Double(raw), v >= 0 else {
                    throw CLIError("--time-budget requires a non-negative number of seconds")
                }
                timeBudget = v
            default:
                if root == nil { root = URL(fileURLWithPath: arg, isDirectory: true) }
                else { throw CLIError("unexpected extra argument: \(arg)") }
            }
            cursor.position += 1
        }
        guard let root, let dbPath else {
            throw CLIError("index requires <root> --db <path>")
        }
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw CLIError("root does not exist: \(root.path)")
        }

        let policy = ExclusionPolicy(config: try exclusionConfig(exclusionsPath))
        let store = try IndexStore(path: dbPath)
        let engine = IndexingEngine(store: store, policy: policy,
                                    limits: try extractionLimits(maxPagesRaw: maxPagesRaw,
                                                                 maxBytesRaw: maxBytesRaw),
                                    progress: { progress in
            if let file = progress.currentFile {
                FileHandle.standardError.write(Data("[\(progress.phase)] \(progress.filesDone)/\(progress.filesTotal) \(file)\n".utf8))
            }
        })
        let summary = try await engine.run(rootURL: root)
        printSummary(summary, store: store, searchMode: store.searchMode)
        if let timeBudget {
            let consumed = try await engine.runQueued(timeBudget: timeBudget)
            let elapsed = String((consumed.elapsedSeconds * 10).rounded() / 10)
            let queueLine = "[queue] considered=\(consumed.considered) indexed=\(consumed.indexed) " +
                "unavailable=\(consumed.unavailable) missing=\(consumed.missing) " +
                "budgetExhausted=\(consumed.exhaustedBudget) elapsed=\(elapsed)s\n"
            FileHandle.standardError.write(Data(queueLine.utf8))
        }
        try rebuildBigramIndexIfNeeded(store: store)
        // 入库批末自动归类（两处显式时机之一——无常驻
        // 无轮询；失败如实报错不静默）。
        try runClassificationBatch(store: store)
        // Scratch/synthetic databases must never clobber the Widget-facing
        // snapshot; only the canonical app database (or an explicit request)
        // publishes coverage.
        if CoveragePublication.shouldPublish(dbURL: dbPath, explicit: publishCoverage) {
            refreshSharedCoverage(store: store)
        }
        exitWithFailureCodeIfNeeded(summary)
    }

    /// 批末归类（index / index-file 共用收尾）。规则表为空时
    /// 零输出零开销（空规则 = 用户未配置，不算事件）。归类失败**降级为
    @discardableResult
    static func runClassificationBatch(store: IndexStore) throws -> ClassifyReport? {
        let rulesStore = ClassificationRulesStore(indexStore: store)
        guard !(try rulesStore.rules()).isEmpty else { return nil }
        do {
            let report = try rulesStore.classifyAll()
            let line = "[classify] classified=\(report.classified) unclassified=\(report.unclassified) " +
                "disabledSkipped=\(report.disabledSkipped) invalidSkipped=\(report.invalidSkipped)\n"
            FileHandle.standardError.write(Data(line.utf8))
            return report
        } catch {
            FileHandle.standardError.write(Data(
                "[classify] WARNING: classification failed after indexing (batch result unaffected): \(error)\n".utf8))
            return nil
        }
    }

    // MARK: classify（规则表全量重跑；规则本身经 SQL 管理或设置页）

    static func classifyCommand(_ args: [String]) throws {
        var cursor = ArgCursor(args)
        var dbPath: URL?
        var dryRun = false
        var listRules = false
        while let arg = cursor.current {
            switch arg {
            case "--db": dbPath = URL(fileURLWithPath: try cursor.value(for: arg))
            case "--dry-run": dryRun = true
            case "--rules": listRules = true
            default:
                throw CLIError("unexpected argument for classify: \(arg)")
            }
            cursor.position += 1
        }
        guard let dbPath else {
            throw CLIError("classify requires --db <path>")
        }
        guard FileManager.default.fileExists(atPath: dbPath.path) else {
            throw CLIError("database does not exist: \(dbPath.path)")
        }

        let store = try IndexStore(path: dbPath)
        let rulesStore = ClassificationRulesStore(indexStore: store)
        let rules = try rulesStore.rules()

        struct RuleJSON: Encodable {
            let id: Int64
            let name: String
            let algorithm: String
            let target: String
            let enabled: Bool
            let position: Int
        }
        struct ReportJSON: Encodable {
            var classified: Int
            var unclassified: Int
            let rules: Int
            var disabledSkipped: Int
            var invalidSkipped: Int
            var perBook: [PerBook]?
            struct PerBook: Encodable {
                let bookID: String
                let category: String
            }
        }

        var report = ReportJSON(classified: 0, unclassified: 0, rules: rules.count,
                                disabledSkipped: 0, invalidSkipped: 0, perBook: nil)
        if listRules {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let ruleJSON = rules.map {
                RuleJSON(id: $0.id, name: $0.name, algorithm: $0.algorithm.rawValue,
                         target: $0.targetCategory, enabled: $0.enabled, position: $0.position)
            }
            print(String(decoding: try encoder.encode(ruleJSON), as: UTF8.self))
            return
        }
        let result = try rulesStore.classifyAll(dryRun: dryRun)
        report.classified = result.classified
        report.unclassified = result.unclassified
        report.disabledSkipped = result.disabledSkipped
        report.invalidSkipped = result.invalidSkipped
        if dryRun {
            report.perBook = (result.perBook ?? []).map {
                ReportJSON.PerBook(bookID: $0.bookID, category: $0.category)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }

    // MARK: open（深链定位；URL 必经 DeepLink.build，禁手拼）

    /// CLI 层深链构造唯一通道（守卫：CLI 源不含 scheme 字面——防双实现漂移）。
    /// --hl 直通 DeepLink.open 第三参（批注行 ID 高亮定位）。
    static func buildOpenURL(doc: String, page: Int?, highlight: Int64?) -> URL? {
        DeepLink.open(doc: doc, page: page, highlight: highlight).build()
    }

    static func openCommand(_ args: [String]) throws {
        var cursor = ArgCursor(args)
        var doc: String?
        var page: Int?
        var highlight: Int64?
        var printOnly = false
        while let arg = cursor.current {
            switch arg {
            case "--doc": doc = try cursor.value(for: arg)
            case "--page":
                let raw = try cursor.value(for: arg)
                guard let v = Int(raw) else {
                    throw CLIError("--page requires an integer, got: \(raw)")
                }
                page = v
            case "--hl":
                let raw = try cursor.value(for: arg)
                guard let v = Int64(raw) else {
                    throw CLIError("--hl requires an integer (user_highlights.id), got: \(raw)")
                }
                highlight = v
            case "--print": printOnly = true
            default:
                throw CLIError("unexpected argument for open: \(arg)")
            }
            cursor.position += 1
        }
        guard let doc else {
            throw CLIError("open requires --doc <bookID>")
        }
        guard let url = buildOpenURL(doc: doc, page: page, highlight: highlight) else {
            throw CLIError("open could not build a deep link (doc must be non-blank; see docs/URI-SCHEME.md)")
        }
        let urlString = url.absoluteString
        if printOnly {
            print(urlString)
            return
        }
        // CLI target 无 AppKit：经 Foundation Process 调 /usr/bin/open。
        // 真开需要 GUI 会话，CLI 无法验证——失败如实报错不静默。
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [urlString]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw CLIError("/usr/bin/open exited with \(p.terminationStatus); deep link: \(urlString)")
        }
    }

    /// Post-batch maintenance: rebuild the bigram inverted index when page
    /// content changed (bidx_dirty) so the next cold query takes the
    /// millisecond inverted-intersection path instead of 20s+ FTS MATCH.
    static func rebuildBigramIndexIfNeeded(store: IndexStore) throws {
        let t0 = Date()
        if try store.ensureBigramIndexFresh() {
            let dt = Date().timeIntervalSince(t0)
            FileHandle.standardError.write(Data(String(format: "bigram inverted index rebuilt in %.1fs\n", dt).utf8))
        }
        // 新书目拼音投影补齐（缺行才写，毫秒级）+ 原生页数影子刷新
        // + 自动目录批生成（只处理缺目录/页数变化的书）。
        try store.refreshBookNativeCounts()
        _ = try store.backfillPinyinIfNeeded()
        let tocRebuilt = try store.rebuildAutoTOCAll()
        if tocRebuilt > 0 {
            FileHandle.standardError.write(Data("auto TOC generated for \(tocRebuilt) book(s)\n".utf8))
        }
    }

    // MARK: mcp-serve（MCP 只读桥的 stdio 壳）
    //
    // LOCAL-API的显式启动面：本命令被显式执行才开始服役（无
    // LaunchAgent、无守护进程、无自动启动——默认关闭语义与 HTTP 面同款）；
    // stdin EOF 即停（App 退出即停服同款）。stdout 是 JSON-RPC 协议通道，
    // 除响应行外零输出；审计行走 stderr（照 LocalAPI 审计语义：端点/状态/
    // 耗时/字节，零查询正文零凭据）。供给链与 CLI search 同一条只读链
    // （同一 exclusions policy），路由器构造与 LocalAPIServer.start 同一套。
    static func mcpServeCommand(_ args: [String]) throws {
        var cursor = ArgCursor(args)
        var dbPath: URL?
        var argvToken: String?
        var exclusionsPath: String?
        while let arg = cursor.current {
            switch arg {
            case "--db": dbPath = URL(fileURLWithPath: try cursor.value(for: arg))
            case "--token": argvToken = try cursor.value(for: arg) // 保留老参数解析：仅作 deprecated 降级处理
            case "--exclusions": exclusionsPath = try cursor.value(for: arg)
            default: throw CLIError("unexpected argument for mcp-serve: \(arg)")
            }
            cursor.position += 1
        }
        guard let dbPath else {
            throw CLIError("mcp-serve requires --db <path>（token 经环境变量 LIT_MCP_TOKEN 供给）")
        }
        // 默认凭据来自环境变量；argv --token 仅在环境变量缺失时降级处理
        let envToken = ProcessInfo.processInfo.environment["LIT_MCP_TOKEN"]
        let provisionedToken: String
        if let envToken {
            if let argvToken = argvToken, envToken != argvToken {
                throw CLIError("mcp-serve token conflict: LIT_MCP_TOKEN and --token differ; keep one source or make them identical")
            }
            provisionedToken = envToken
        } else if let argvToken {
            FileHandle.standardError.write(Data("warning: mcp-serve --token is deprecated; use env LIT_MCP_TOKEN\n".utf8))
            provisionedToken = argvToken
        } else {
            throw CLIError("mcp-serve requires LIT_MCP_TOKEN <64hex>（token 沿用 LocalAPIToken 形制；缺省即拒启，永不无凭据服役）")
        }
        guard MCPBridge.isValidProvisionedToken(provisionedToken) else {
            throw CLIError("LIT_MCP_TOKEN must be 64 lowercase hex chars (LocalAPIToken shape); got \(provisionedToken.count) chars")
        }
        guard FileManager.default.fileExists(atPath: dbPath.path) else {
            throw CLIError("database does not exist: \(dbPath.path)")
        }
        let store = try IndexStore(path: dbPath, options: .init(readOnlyReplica: true))
        let policy = ExclusionPolicy(config: try exclusionConfig(exclusionsPath))
        let service = SearchService(store: store, policy: policy) // query-time re-check（CLI search 同链）
        // 批注库句柄（/annotations 单书只读清单；note 经既有解密读路径）。
        let highlights = HighlightStore(indexStore: store)
        let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
        let router = LocalAPIRouter(token: provisionedToken,
                                    appVersion: appVersion,
                                    schemaVersion: IndexStore.currentSchemaVersion,
                                    providers: .makeLive(store: store, search: service,
                                                         highlights: highlights))
        let bridge = MCPBridge(router: router)
        let input = FileHandle.standardInput
        var buffer = Data()
        var discarding = false
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break } // EOF：显式停服
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                buffer = buffer.subdata(in: buffer.index(after: newline)..<buffer.endIndex)
                if discarding {
                    // 超限行：丢弃到换行为止（LocalAPIServer 超限掐线同款形制；
                    // 内容零落日志、零响应——流继续服务后续行）。
                    discarding = false
                    FileHandle.standardError.write(Data(
                        "mcp-serve: oversized line dropped (\(lineData.count) bytes)\n".utf8))
                    continue
                }
                if lineData.count > MCPBridge.maxLineBytes {
                    // 完整行已按换行切出：只丢弃该行本身，不置 discarding，避免误吞后续合法行
                    FileHandle.standardError.write(Data(
                        "mcp-serve: oversized line dropped (\(lineData.count) bytes)\n".utf8))
                    continue
                }
                let line = String(data: lineData, encoding: .utf8) ?? ""
                let outcome = bridge.handle(line)
                if let response = outcome.response {
                    FileHandle.standardOutput.write(Data(response.utf8))
                    FileHandle.standardOutput.write(Data("\n".utf8))
                }
                if let audit = outcome.audit {
                    FileHandle.standardError.write(Data((audit.stderrLine + "\n").utf8))
                }
            }
            if buffer.count > MCPBridge.maxLineBytes {
                // 残包已超限：清空并置丢弃态（跳到下个换行），不再无界累积。
                discarding = true
                buffer = Data()
            }
        }
    }

    // MARK: rebuild-bigram-index (explicit one-shot over an existing database)

    static func rebuildBigramIndexCommand(_ args: [String]) throws {
        var cursor = ArgCursor(args)
        var dbPath: URL?
        while let arg = cursor.current {
            switch arg {
            case "--db": dbPath = URL(fileURLWithPath: try cursor.value(for: arg))
            default: throw CLIError("unexpected argument for rebuild-bigram-index: \(arg)")
            }
            cursor.position += 1
        }
        guard let dbPath else {
            throw CLIError("rebuild-bigram-index requires --db <path>")
        }
        let store = try IndexStore(path: dbPath)
        let t0 = Date()
        try store.rebuildBigramInvertedIndex()
        try rebuildBigramIndexIfNeeded(store: store)   // 拼音投影 + 自动目录同批收尾
        let dt = Date().timeIntervalSince(t0)
        print(String(format: "{\"command\":\"rebuild-bigram-index\",\"seconds\":%.2f}", dt))
    }

    /// 词级索引回填：分批回填 text_latin 投影
    /// 并经触发器自动进 pages_wfts；断点续跑（中断重跑即从 checkpoint 续）；
    /// 完成后 'optimize' 一次＋置 wfts_ready=1。进度走 stderr（每批一行），
    /// stdout 只出一行 JSON 摘要。已就绪（wfts_ready=1）时 no-op 如实报告。
    static func backfillLatinCommand(_ args: [String]) throws {
        var cursor = ArgCursor(args)
        var dbPath: URL?
        var quiet = false
        while let arg = cursor.current {
            switch arg {
            case "--db": dbPath = URL(fileURLWithPath: try cursor.value(for: arg))
            case "--quiet": quiet = true
            default: throw CLIError("unexpected argument for backfill-latin: \(arg)")
            }
            cursor.position += 1
        }
        guard let dbPath else {
            throw CLIError("backfill-latin requires --db <path>")
        }
        let store = try IndexStore(path: dbPath)
        let t0 = Date()
        let readyBefore = (try? store.metaValue("wfts_ready")) == "1"
        let n = try store.backfillLatinProjection(progress: { done, total in
            guard !quiet else { return }
            FileHandle.standardError.write(Data(
                String(format: "[backfill-latin] %d/%d 页 (%.1f%%)\n", done, total,
                       total > 0 ? Double(done) / Double(total) * 100 : 100).utf8))
        })
        let dt = Date().timeIntervalSince(t0)
        let ready = (try? store.metaValue("wfts_ready")) == "1"
        print(String(format: "{\"command\":\"backfill-latin\",\"backfilled\":%d,\"seconds\":%.2f,\"ready_before\":%@,\"ready\":%@}",
                     n, dt, readyBefore ? "true" : "false", ready ? "true" : "false"))
    }

    /// Operators must not mistake partial failure for success: any recorded
    /// file failure makes the process exit non-zero (3) after printing JSON.
    static func exitWithFailureCodeIfNeeded(_ summary: IndexRunSummary) {
        if summary.failed > 0 {
            FileHandle.standardError.write(Data("error: \(summary.failed) file(s) failed indexing (see JSON above)\n".utf8))
            exit(3)
        }
    }

    /// Coverage over ALL indexed roots: rootName only for a single root.
    static func refreshSharedCoverage(store: IndexStore) {
        let history = SharedHistoryStore(fileURL: SharedHistoryStore.sharedFileURL())
        guard let books = try? store.allBooks(), let stats = try? store.coverageStats() else { return }
        var pageCount = 0
        for book in books { pageCount += book.pageCount }
        let roots = Set(books.map(\.rootPath))
        history.update(coverage: CoverageSnapshot(
            bookCount: books.count,
            pageCount: pageCount,
            lastIndexedAt: Date(),
            rootName: roots.count == 1
                ? books.first.map { URL(fileURLWithPath: $0.rootPath).lastPathComponent }
                : nil,
            rootCount: roots.count,
            pagesWithoutText: stats.pagesWithoutText,
            errorBooks: stats.booksError
        ))
    }


    // MARK: index-file (explicit single files; read-only; no scan; no deletion)

    static func indexFileCommand(_ args: [String]) async throws {
        var cursor = ArgCursor(args)
        var files: [URL] = []
        var dbPath: URL?
        var exclusionsPath: String?
        var maxPagesRaw: String?
        var maxBytesRaw: String?
        while let arg = cursor.current {
            switch arg {
            case "--db": dbPath = URL(fileURLWithPath: try cursor.value(for: arg))
            case "--exclusions": exclusionsPath = try cursor.value(for: arg)
            case "--max-pages": maxPagesRaw = try cursor.value(for: arg)
            case "--max-bytes": maxBytesRaw = try cursor.value(for: arg)
            default: files.append(URL(fileURLWithPath: arg))
            }
            cursor.position += 1
        }
        guard !files.isEmpty, let dbPath else {
            throw CLIError("index-file requires <pdf> [<pdf>...] --db <path>")
        }
        for file in files where !FileManager.default.fileExists(atPath: file.path) {
            throw CLIError("file does not exist: \(file.path)")
        }

        let policy = ExclusionPolicy(config: try exclusionConfig(exclusionsPath))
        let store = try IndexStore(path: dbPath)
        let engine = IndexingEngine(store: store, policy: policy,
                                    limits: try extractionLimits(maxPagesRaw: maxPagesRaw,
                                                                 maxBytesRaw: maxBytesRaw))
        let summary = try await engine.indexExplicitFiles(urls: files)
        printSummary(summary, store: store, searchMode: store.searchMode)
        try rebuildBigramIndexIfNeeded(store: store)
        // 入库批末自动归类（两处显式时机之一）。
        try runClassificationBatch(store: store)
        exitWithFailureCodeIfNeeded(summary)
    }


    // MARK: webdav-inbox-pull（Mac 侧收取手机「存到 Mac」分享）
    //
    // 编排全在 Core ShareInboxPuller（合成测试离线覆盖；本命令是薄壳）：
    // PROPFIND inbox 前缀 → 文件名白名单过滤 → 逐文件下载（单文件 ≤1MiB、
    // 总量 ≤64MiB）→ 落 AppSupport/LiteratureSearch/inbox/（或 --into）。
    // 同名幂等跳过；远端不删（无删除语义）。凭据缺失明确报错不静默。

    static func webdavInboxPullCommand(_ args: [String]) async throws {
        var cursor = ArgCursor(args)
        var configPath: URL?
        var password: String?
        var into: URL?
        while let arg = cursor.current {
            switch arg {
            case "--config": configPath = URL(fileURLWithPath: try cursor.value(for: arg))
            case "--password": password = try cursor.value(for: arg)
            case "--env-password": password = ProcessInfo.processInfo.environment["WEBDAV_PASSWORD"]
            case "--into": into = URL(fileURLWithPath: try cursor.value(for: arg), isDirectory: true)
            default: throw CLIError("unexpected argument for webdav-inbox-pull: \(arg)")
            }
            cursor.position += 1
        }
        guard let configPath else {
            throw CLIError("webdav-inbox-pull requires --config <json> --env-password [--into <dir>]")
        }
        let raw = try Data(contentsOf: configPath)
        guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let serverBase = obj["serverBase"] as? String,
              let username = obj["username"] as? String else {
            throw CLIError("webdav-inbox-pull 配置格式：{serverBase, username}")
        }
        // 凭据守卫（与合成测试共用同一条；webdav-sync 先例同形）。
        try ShareInboxPuller.validateCredentials(username: username,
                                                 password: password ?? "")
        // 安全约束：serverBase 代码级强制（HTTPS、无内嵌 userinfo）。
        let client = try WebDAVClient(serverBase: WebDAVClient.validatedBase(serverBase),
                                      username: username, password: password ?? "")
        let target = into ?? AppSupportPaths.appDirectory("inbox", ensure: true)
        let puller = ShareInboxPuller(loader: WebDAVShareInboxLoader(client: client), into: target)
        let outcome = try await puller.pull()
        print("INBOX \(ShareInbox.prefixDirectory) → \(target.path): 下载 \(outcome.downloaded.count) · 跳过已存在 \(outcome.skippedExisting.count) · 超限 \(outcome.skippedOversize.count) · 怪名 \(outcome.foreignSkipped)\(outcome.stoppedForBudget ? " · 预算停止" : "")")
        for name in outcome.downloaded { print("  ↓ \(name)") }
        for name in outcome.skippedExisting { print("  = \(name)（已存在）") }
        for name in outcome.skippedOversize { print("  ✗ \(name)（超单文件上限）") }
    }

    // MARK: webdav-sync（WebDAV → 本地库根 → 索引）

    static func webdavSyncCommand(_ args: [String]) async throws {
        var cursor = ArgCursor(args)
        var configPath: URL?
        var password: String?
        var dryRun = false
        var indexDB: URL?
        while let arg = cursor.current {
            switch arg {
            case "--config": configPath = URL(fileURLWithPath: try cursor.value(for: arg))
            case "--password": password = try cursor.value(for: arg)
            case "--env-password": password = ProcessInfo.processInfo.environment["WEBDAV_PASSWORD"]
            case "--dry-run": dryRun = true
            case "--index-db": indexDB = URL(fileURLWithPath: try cursor.value(for: arg))
            default: throw CLIError("unexpected argument for webdav-sync: \(arg)")
            }
            cursor.position += 1
        }
        guard let configPath else {
            throw CLIError("webdav-sync requires --config <json> [--password <pw>|--env-password] [--dry-run] [--index-db <path>]")
        }
        let raw = try Data(contentsOf: configPath)
        guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let serverBase = obj["serverBase"] as? String,
              let username = obj["username"] as? String,
              let rulesRaw = obj["rules"] as? [[String: Any]] else {
            throw CLIError("webdav-sync 配置格式：{serverBase, username, rules:[{remoteDir, localRoot}], extensions?}")
        }
        let rules = try rulesRaw.map { r in
            guard let rd = r["remoteDir"] as? String, let lr = r["localRoot"] as? String else {
                throw CLIError("rule 需要 remoteDir + localRoot")
            }
            return WebDAVSyncRule(remoteDir: rd, localRoot: URL(fileURLWithPath: lr, isDirectory: true))
        }
        let exts = (obj["extensions"] as? [String]) ?? [".pdf"]
        let config = WebDAVSyncConfig(serverBase: serverBase, username: username, rules: rules, extensions: exts)
        guard let password, !password.isEmpty else { throw WebDAVError.credentialMissing }

        // 安全约束：serverBase 代码级强制（HTTPS、无内嵌 userinfo），非法明确报错。
        let client = try WebDAVClient(serverBase: WebDAVClient.validatedBase(serverBase),
                                      username: username, password: password)
        var total = WebDAVSyncOutcome()
        for rule in rules {
            let out = try await WebDAVSyncEngine.sync(rule: rule, config: config, password: password,
                                                       client: client, dryRun: dryRun)
            if dryRun {
                print("DRY \(rule.remoteDir) → \(rule.localRoot.path): \(out.pendingDownloads.count) 个待下载文件")
                for file in out.pendingDownloads { print("  \(file.fileName) (\(file.size) B)") }
            } else {
                print("SYNC \(rule.remoteDir): 下载 \(out.downloaded.count) · 跳过 \(out.skipped) · 失败 \(out.failed.count)")
            }
            for f in out.failed { FileHandle.standardError.write(Data("  ✗ \(f)\n".utf8)) }
            total.downloaded += out.downloaded
            total.skipped += out.skipped
            total.failed += out.failed
        }
        // 显式指定 --index-db 时，为落地的新文件更新索引。
        if let indexDB, !total.downloaded.isEmpty {
            let store = try IndexStore(path: indexDB)
            let policy = ExclusionPolicy()
            let engine = IndexingEngine(store: store, policy: policy)
            for rule in rules {
                let summary = try await engine.run(rootURL: rule.localRoot)
                print("INDEX \(rule.localRoot.path): 新 \(summary.indexedNew) · 更新 \(summary.updated) · 未变 \(summary.skippedUnchanged) · 失败 \(summary.failed)")
                try rebuildBigramIndexIfNeeded(store: store)
                exitWithFailureCodeIfNeeded(summary)
            }
        }
        if !total.failed.isEmpty {
            throw CLIError("WebDAV: \(total.failed.count) 个文件未能下载，详见上面的错误")
        }
    }

    // MARK: bounds-checked extraction limit flags ("none" = unlimited)

    static func limitValue(_ raw: String?, flag: String) throws -> Int? {
        guard let raw else { return nil }
        if raw == "none" { return nil }
        guard let n = Int(raw), n > 0 else {
            throw CLIError("\(flag) requires a positive integer or \"none\"")
        }
        return n
    }

    static func byteLimitValue(_ raw: String?, flag: String) throws -> Int64? {
        guard let raw else { return nil }
        if raw == "none" { return nil }
        guard let n = Int64(raw), n > 0 else {
            throw CLIError("\(flag) requires a positive byte count or \"none\"")
        }
        return n
    }

    static func extractionLimits(maxPagesRaw: String?, maxBytesRaw: String?) throws -> PDFExtractionLimits {
        var limits = PDFExtractionLimits()
        if let maxPagesRaw {
            limits.maxPages = try limitValue(maxPagesRaw, flag: "--max-pages")
        }
        if let maxBytesRaw {
            limits.maxFileBytes = try byteLimitValue(maxBytesRaw, flag: "--max-bytes")
        }
        return limits
    }

    // MARK: audit (names/verdicts only; never reads file contents)

    static func auditCommand(_ args: [String]) throws {
        var cursor = ArgCursor(args)
        var root: URL?
        var exclusionsPath: String?
        while let arg = cursor.current {
            switch arg {
            case "--exclusions": exclusionsPath = try cursor.value(for: arg)
            default:
                if root == nil { root = URL(fileURLWithPath: arg, isDirectory: true) }
                else { throw CLIError("unexpected extra argument: \(arg)") }
            }
            cursor.position += 1
        }
        guard let root else { throw CLIError("audit requires <root>") }
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw CLIError("root does not exist: \(root.path)")
        }
        let policy = ExclusionPolicy(config: try exclusionConfig(exclusionsPath))
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants])
        var counts: [String: Int] = [:]
        while let item = enumerator?.nextObject() as? URL {
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: item.path, isDirectory: &isDir)
            if isDir.boolValue { continue }
            let verdict = policy.evaluate(candidateFileURL: item, rootURL: root)
            let reason: String
            switch verdict {
            case .allowed: reason = "allowed"
            case .unsupportedFileType: reason = "unsupported(non-pdf)"
            case .excludedByPathSubstring(let s): reason = "excluded[substring:\(s)]"
            case .excludedByGlob(let g): reason = "excluded[glob:\(g)]"
            case .excludedByID(let id): reason = "excluded[id:\(id)]"
            case .symlinkEscape: reason = "rejected[symlink-escape]"
            }
            counts[reason, default: 0] += 1
            print("\(reason)\t\(item.lastPathComponent)")
        }
        print("-- audit totals (no file contents were read) --")
        for (reason, count) in counts.sorted(by: { $0.key < $1.key }) {
            print("\(reason): \(count)")
        }
    }

    // MARK: 会话标记（性能优化）

    /// 基准脚本按「一次 exec 一个 bash 会话连跑 N 条命令」调用，会话标记经
    /// 环境变量传给本会话里的每条命令：有标记＝本会话已执行过命令，后续
    /// 命令不再触发建索引（让计时样本干净）；无标记（用户手敲单条）＝首条，
    /// 允许建。标记本身不随命令变化，故不参与任何输出。
    enum SessionMarker {
        static let key = "LIT_SESSION_HAS_RUN"
    }

    // MARK: search

    static func searchCommand(_ args: [String]) async throws {
        var cursor = ArgCursor(args)
        var query: String?
        var dbPath: URL?
        var limit = 20
        var summaryOnly = false
        var exclusionsPath: String?
        var phaseTiming = false
        var includeToolBooks = false   // 工具书默认不含（过滤层，非排序层）
        var readOnly = false           // 只读通道（索引库零写）
        while let arg = cursor.current {
            switch arg {
            case "--db": dbPath = URL(fileURLWithPath: try cursor.value(for: arg))
            case "--limit": limit = Int(try cursor.value(for: arg)) ?? 20
            case "--summary-only": summaryOnly = true
            case "--exclusions": exclusionsPath = try cursor.value(for: arg)
            case "--include-toolbooks": includeToolBooks = true
            case "--phase-timing":
                // 分相计时（stderr；stdout 零改动——不改变既有输出）。
                phaseTiming = true
            case "--readonly":
                // 走既有只读副本通道（SQLITE_OPEN_READONLY；
                // 跳过 WAL/迁移/自愈/meta 写）。默认仍是读写开库＝原行为。
                readOnly = true
            default:
                if query == nil { query = arg }
                else { throw CLIError("unexpected extra argument: \(arg)") }
            }
            cursor.position += 1
        }
        SearchPhaseTiming.forced = phaseTiming
        guard let query, let dbPath else {
            throw CLIError("search requires <query> --db <path>")
        }
        let sessionHasRun = ProcessInfo.processInfo.environment[SessionMarker.key] != nil
        let store = try IndexStore(path: dbPath,
                                   options: IndexStore.Options(readOnlyReplica: readOnly,
                                                               allowPageStatsStatsIndex: !readOnly && !sessionHasRun))
        let policy = ExclusionPolicy(config: try exclusionConfig(exclusionsPath))
        let service = SearchService(store: store, policy: policy) // query-time re-check
        let result = try service.searchDetailed(query, options: SearchOptions(
            limit: limit,
            filter: includeToolBooks ? SearchFilter(includeToolBooks: true) : nil))

        print("total matching pages: \(result.totalPageMatches)\(result.truncated ? " (truncated at \(result.hits.count))" : "")")
        if result.hits.isEmpty {
            print("(no results)")
            return
        }
        for hit in result.hits {
            let ocrLine = hit.source == "ocr"
                ? "  来源: OCR配对 (OCR文件: \(hit.ocrFilePath ?? "未知")  OCR页: \(hit.ocrPage.map(String.init) ?? "未知"))\n"
                : ""
            if summaryOnly {
                // No original text in this mode: provenance + counts only.
                print("""
                ---
                书目: \(hit.fileName) (id: \(hit.bookID))  物理页: \(hit.physicalPage)/\(hit.pageCount)  来源: \(hit.source)
                \(ocrLine)  标题: \(hit.title ?? "未知")  作者: \(hit.author ?? "未知")  版本: \(hit.version ?? "未知")  语言: \(hit.language ?? "未知")
                  标签: \(hit.pageLabel ?? "未知")  印刷页码: \(hit.printedPage.map(String.init) ?? "未知")  命中处数: \(hit.matches.count)  指纹: \(hit.fingerprint)
                """)
            } else {
                print("""
                ---
                书目: \(hit.fileName)  (id: \(hit.bookID))
                  标题: \(hit.title ?? "未知")   作者: \(hit.author ?? "未知")   版本: \(hit.version ?? "未知")   语言: \(hit.language ?? "未知")
                物理页: \(hit.physicalPage)/\(hit.pageCount)   原件页标签: \(hit.pageLabel ?? "未知")   印刷页码: \(hit.printedPage.map(String.init) ?? "未知")   来源: \(hit.source)
                \(ocrLine)  指纹: \(hit.fingerprint)
                  命中词: \(hit.matches.map(\.displayTerm).joined(separator: " | "))
                  片段: \(hit.snippet.replacingOccurrences(of: "\n", with: " "))
                """)
            }
        }
    }

    // MARK: reindex-book（sha256 一致性检查与单册重索引）

    /// 单册重索引：定位 book → 重算 sha256 → 与库内指纹比对（unchanged /
    /// updated / missing / error），输出一行 JSON 摘要。只动这一本，绝不
    /// 扫描库根。`--force` 对指纹一致的书也强制重建页行（内容恒等）。
    static func reindexBookCommand(_ args: [String]) async throws {
        var cursor = ArgCursor(args)
        var bookID: String?
        var dbPath: URL?
        var force = false
        var exclusionsPath: String?
        while let arg = cursor.current {
            switch arg {
            case "--db": dbPath = URL(fileURLWithPath: try cursor.value(for: arg))
            case "--force": force = true
            case "--exclusions": exclusionsPath = try cursor.value(for: arg)
            default:
                if bookID == nil { bookID = arg }
                else { throw CLIError("unexpected extra argument: \(arg)") }
            }
            cursor.position += 1
        }
        guard let bookID, let dbPath else {
            throw CLIError("reindex-book requires <book_id> --db <path> [--force]")
        }
        let policy = ExclusionPolicy(config: try exclusionConfig(exclusionsPath))
        let store = try IndexStore(path: dbPath)
        let engine = IndexingEngine(store: store, policy: policy)
        let result = try await engine.reindexBook(bookID: bookID, force: force)
        // 一行 JSON 摘要。
        // 补控制字符转义——message 含换行/回车/
        // 制表符时旧转义产出非法 JSON（一行摘要被截断成多行）。
        let message = result.message?
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t") ?? ""
        print("""
        {"book_id": "\(result.bookID)", "verdict": "\(result.verdict.rawValue)", "pages": \(result.pages), "seconds": \(String(format: "%.3f", result.seconds)), "message": "\(message)"}
        """)
        if result.verdict == .updated {
            try rebuildBigramIndexIfNeeded(store: store)
        }
        if result.verdict == .missing || result.verdict == .error {
            throw CLIError("reindex-book: \(result.verdict.rawValue) — \(result.message ?? "")")
        }
    }

    // MARK: pdf-info (same exclusion policy; no body text by default)

    /// 抽查辅助（只读）：给定 PDF，计算 sha256 指纹并抽取文字层，
    /// 报物理页数、页标签与无文本页对账。不建索引、不写文件——供人工抽检与对账取证。
    static func pdfInfoCommand(_ args: [String]) throws {
        var cursor = ArgCursor(args)
        var path: String?
        var showText = false
        var exclusionsPath: String?
        while let arg = cursor.current {
            switch arg {
            case "--exclusions": exclusionsPath = try cursor.value(for: arg)
            case "--show-text": showText = true
            case "--summary-only": showText = false
            default:
                if path == nil { path = arg }
                else { throw CLIError("unexpected extra argument: \(arg)") }
            }
            cursor.position += 1
        }
        guard let path else { throw CLIError("pdf-info requires <file.pdf>") }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError("file does not exist: \(url.path)")
        }

        // Same policy gate as indexing, BEFORE reading content. Single files are
        // evaluated against their parent directory (names/IDs/symlinks only).
        let policy = ExclusionPolicy(config: try exclusionConfig(exclusionsPath))
        let verdict = policy.evaluate(candidateFileURL: url, rootURL: url.deletingLastPathComponent())
        guard verdict == .allowed else {
            throw CLIError("file excluded by policy [\(policyDescription(verdict))]; content not read")
        }

        let fingerprint = try Fingerprint.sha256Hex(ofFileAt: url)
        let extraction = try PDFTextExtractor.extract(url: url)
        print("file: \(url.lastPathComponent)")
        print("fingerprint: \(fingerprint)")
        print("physical pages: \(extraction.pageCount)")
        var emptyTextPages = 0
        for page in extraction.pages {
            let charCount = page.text.count
            if charCount == 0 { emptyTextPages += 1 }
            let shown: String
            if showText {
                let preview = page.text.replacingOccurrences(of: "\n", with: " ")
                shown = " text=\"\(preview.count > 40 ? String(preview.prefix(40)) + "…" : preview)\""
            } else {
                shown = "" // consistency reporting without dumping body text
            }
            print("  p\(page.physicalPage) label=\(page.label ?? "未知") printed=\(page.printedPage.map(String.init) ?? "未知") chars=\(charCount)\(shown)")
        }
        print("pages without text (no OCR performed): \(emptyTextPages)")
    }

    static func policyDescription(_ verdict: ExclusionVerdict) -> String {
        switch verdict {
        case .allowed: return "allowed"
        case .excludedByPathSubstring(let s): return "substring:\(s)"
        case .excludedByGlob(let g): return "glob:\(g)"
        case .excludedByID(let id): return "id:\(id)"
        case .symlinkEscape: return "symlink-escape"
        case .unsupportedFileType: return "not-pdf"
        }
    }

    // MARK: import-meta

    static func importMetaCommand(_ args: [String]) throws {
        var cursor = ArgCursor(args)
        var dbPath: URL?
        var sidecarPath: URL?
        while let arg = cursor.current {
            switch arg {
            case "--db": dbPath = URL(fileURLWithPath: try cursor.value(for: arg))
            case "--sidecar": sidecarPath = URL(fileURLWithPath: try cursor.value(for: arg))
            default: throw CLIError("unexpected extra argument: \(arg)")
            }
            cursor.position += 1
        }
        guard let dbPath, let sidecarPath else {
            throw CLIError("import-meta requires --db <path> --sidecar <file.csv|.json>")
        }
        guard FileManager.default.fileExists(atPath: sidecarPath.path) else {
            throw CLIError("sidecar does not exist: \(sidecarPath.path)")
        }
        let store = try IndexStore(path: dbPath)
        let data = try Data(contentsOf: sidecarPath)
        let records: [MetadataRecord]
        switch sidecarPath.pathExtension.lowercased() {
        case "json": records = try MetadataImporter.parseJSON(data)
        case "csv": records = try MetadataImporter.parseCSV(data)
        default: throw CLIError("sidecar must be .csv or .json")
        }
        let report = MetadataImporter.apply(records, store: store)
        print("applied: \(report.applied) / \(report.totalRecords)")
        for skip in report.skipped {
            print("skipped: \(skip.file) — \(skip.reason)")
        }
    }

    // MARK: import-page-map (稳定页码 sidecar；声明制，绝不猜)

    /// 与 import-meta 同构：显式 --db --csv，逐行校验计数进报告；
    /// page_map upsert + printed_page 回填（只填 NULL 行，非空不覆盖）。
    static func importPageMapCommand(_ args: [String]) throws {
        var cursor = ArgCursor(args)
        var dbPath: URL?
        var csvPath: URL?
        while let arg = cursor.current {
            switch arg {
            case "--db": dbPath = URL(fileURLWithPath: try cursor.value(for: arg))
            case "--csv": csvPath = URL(fileURLWithPath: try cursor.value(for: arg))
            default: throw CLIError("unexpected extra argument: \(arg)")
            }
            cursor.position += 1
        }
        guard let dbPath, let csvPath else {
            throw CLIError("import-page-map requires --db <path> --csv <file.csv>")
        }
        guard FileManager.default.fileExists(atPath: csvPath.path) else {
            throw CLIError("csv does not exist: \(csvPath.path)")
        }
        let store = try IndexStore(path: dbPath)
        let data = try Data(contentsOf: csvPath)
        let (books, report) = try store.importPageMapSidecar(data)
        print("imported books: \(books), accepted rows: \(report.acceptedRows)")
        for name in report.offsetBooks {
            print("offset book: \(name)")
        }
        for name in report.unmatchedBooks {
            print("unmatched book: \(name) — skipped (unknown stays unknown)")
        }
        for reject in report.rejected {
            print("rejected line \(reject.line): \(reject.reason)")
        }
    }

    // MARK: import-ocr (manifest-driven OCR pairing; two explicit roots)

    static func importOCRCommand(_ args: [String]) throws {
        var cursor = ArgCursor(args)
        var manifestPath: URL?
        var originalRoot: URL?
        var ocrRoot: URL?
        var dbPath: URL?
        var exclusionsPath: String?
        var maxPagesRaw: String?
        var maxBytesRaw: String?
        while let arg = cursor.current {
            switch arg {
            case "--manifest": manifestPath = URL(fileURLWithPath: try cursor.value(for: arg))
            case "--original-root": originalRoot = URL(fileURLWithPath: try cursor.value(for: arg), isDirectory: true)
            case "--ocr-root": ocrRoot = URL(fileURLWithPath: try cursor.value(for: arg), isDirectory: true)
            case "--db": dbPath = URL(fileURLWithPath: try cursor.value(for: arg))
            case "--exclusions": exclusionsPath = try cursor.value(for: arg)
            case "--max-pages": maxPagesRaw = try cursor.value(for: arg)
            case "--max-bytes": maxBytesRaw = try cursor.value(for: arg)
            default: throw CLIError("unexpected argument for import-ocr: \(arg)")
            }
            cursor.position += 1
        }
        guard let manifestPath, let originalRoot, let ocrRoot, let dbPath else {
            throw CLIError("import-ocr requires --manifest <pairs.json> --original-root <dir> --ocr-root <dir> --db <path>")
        }
        guard FileManager.default.fileExists(atPath: manifestPath.path) else {
            throw CLIError("manifest does not exist: \(manifestPath.path)")
        }
        guard FileManager.default.fileExists(atPath: originalRoot.path) else {
            throw CLIError("original root does not exist: \(originalRoot.path)")
        }
        guard FileManager.default.fileExists(atPath: ocrRoot.path) else {
            throw CLIError("ocr root does not exist: \(ocrRoot.path)")
        }

        let manifest = try OCRPairManifest.parse(try Data(contentsOf: manifestPath))
        let policy = ExclusionPolicy(config: try exclusionConfig(exclusionsPath))
        let store = try IndexStore(path: dbPath)
        let limits = try extractionLimits(maxPagesRaw: maxPagesRaw, maxBytesRaw: maxBytesRaw)
        let engine = OCRIndexingEngine(store: store, policy: policy, limits: limits)
        let summary = engine.importManifest(manifest, originalRoot: originalRoot, ocrRoot: ocrRoot)
        printOCRSummary("import-ocr", summary)
        try rebuildBigramIndexIfNeeded(store: store)
        if summary.pairsFailed > 0 { ocrFailureExit(summary) }
    }

    // MARK: index-ocr (staleness sweep over registered pairs; optional re-import)

    static func indexOCRCommand(_ args: [String]) throws {
        var cursor = ArgCursor(args)
        var manifestPath: URL?
        var originalRoot: URL?
        var ocrRoot: URL?
        var dbPath: URL?
        var exclusionsPath: String?
        var maxPagesRaw: String?
        var maxBytesRaw: String?
        while let arg = cursor.current {
            switch arg {
            case "--manifest": manifestPath = URL(fileURLWithPath: try cursor.value(for: arg))
            case "--original-root": originalRoot = URL(fileURLWithPath: try cursor.value(for: arg), isDirectory: true)
            case "--ocr-root": ocrRoot = URL(fileURLWithPath: try cursor.value(for: arg), isDirectory: true)
            case "--db": dbPath = URL(fileURLWithPath: try cursor.value(for: arg))
            case "--exclusions": exclusionsPath = try cursor.value(for: arg)
            case "--max-pages": maxPagesRaw = try cursor.value(for: arg)
            case "--max-bytes": maxBytesRaw = try cursor.value(for: arg)
            default: throw CLIError("unexpected argument for index-ocr: \(arg)")
            }
            cursor.position += 1
        }
        guard let dbPath else {
            throw CLIError("index-ocr requires --db <path>")
        }
        let trioGiven = manifestPath != nil || originalRoot != nil || ocrRoot != nil
        if trioGiven {
            guard let manifestPath, let originalRoot, let ocrRoot else {
                throw CLIError("index-ocr: --manifest, --original-root and --ocr-root must be provided together")
            }
            guard FileManager.default.fileExists(atPath: manifestPath.path) else {
                throw CLIError("manifest does not exist: \(manifestPath.path)")
            }
            guard FileManager.default.fileExists(atPath: originalRoot.path) else {
                throw CLIError("original root does not exist: \(originalRoot.path)")
            }
            guard FileManager.default.fileExists(atPath: ocrRoot.path) else {
                throw CLIError("ocr root does not exist: \(ocrRoot.path)")
            }
        }

        let policy = ExclusionPolicy(config: try exclusionConfig(exclusionsPath))
        let store = try IndexStore(path: dbPath)
        let limits = try extractionLimits(maxPagesRaw: maxPagesRaw, maxBytesRaw: maxBytesRaw)
        let engine = OCRIndexingEngine(store: store, policy: policy, limits: limits)

        // 1. Verification sweep: both fingerprints + policy; stale pairs are purged.
        let sweep = engine.verifyRegisteredPairs()
        printOCRSummary("index-ocr verification sweep", sweep)
        if sweep.pairsFailed > 0 { ocrFailureExit(sweep) }

        // 纯巡检路径也刷新相关状态。
        // purgeOCR 把 OCR 页翻回 native（native_count 只增），book_native_counts
        // 不刷则 nativeTextPages 低报至下个索引批末；此处即时刷新收窄自愈窗口。
        // refreshBookNativeCounts 为幂等全量重算；与下方 manifest 导入同跑时
        // 至多多刷一次（导入路径 rebuildBigramIndexIfNeeded 内含同款刷新），可接受。
        if sweep.pairsStalePurged > 0 {
            try store.refreshBookNativeCounts()
        }

        // 2. Optional manifest (re-)import.
        if let manifestPath, let originalRoot, let ocrRoot {
            let manifest = try OCRPairManifest.parse(try Data(contentsOf: manifestPath))
            let summary = engine.importManifest(manifest, originalRoot: originalRoot, ocrRoot: ocrRoot)
            printOCRSummary("index-ocr manifest import", summary)
            try rebuildBigramIndexIfNeeded(store: store)
            if summary.pairsFailed > 0 { ocrFailureExit(summary) }
        }
    }

    static func printOCRSummary(_ label: String, _ s: OCRImportSummary) {
        let payload: [String: Any] = [
            "command": label,
            "pairsTotal": s.pairsTotal,
            "pairsImported": s.pairsImported,
            "pairsSkippedUnchanged": s.pairsSkippedUnchanged,
            "pairsRejected": s.pairsRejected,
            "pairsStalePurged": s.pairsStalePurged,
            "pairsVerified": s.pairsVerified,
            "pairsFailed": s.pairsFailed,
            "pagesImported": s.pagesImported,
            "pagesKeptNative": s.pagesKeptNative,
            "pagesTextless": s.pagesTextless,
            "outcomes": s.outcomes.map { o in
                [
                    "original": o.originalPath,
                    "ocr": o.ocrPath,
                    "status": o.status,
                    "detail": o.detail,
                    "pagesImported": o.pagesImported,
                    "pagesKeptNative": o.pagesKeptNative,
                    "pagesTextless": o.pagesTextless,
                ] as [String: Any]
            },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            print(String(data: data, encoding: .utf8) ?? "{}")
        }
    }

    static func ocrFailureExit(_ summary: OCRImportSummary) -> Never {
        FileHandle.standardError.write(Data("error: \(summary.pairsFailed) pair(s) failed (see JSON above)\n".utf8))
        exit(3)
    }

    // MARK: genpdf

    static func genpdf(_ args: [String]) throws {
        var cursor = ArgCursor(args)
        var out: URL?
        var pageLines: [[String]] = []
        while let arg = cursor.current {
            switch arg {
            case "--out": out = URL(fileURLWithPath: try cursor.value(for: arg))
            case "--page":
                let value = try cursor.value(for: arg)
                pageLines.append(value.components(separatedBy: "\n"))
            default: throw CLIError("unknown flag \(arg)")
            }
            cursor.position += 1
        }
        guard let out, !pageLines.isEmpty else {
            throw CLIError("genpdf requires --out <path> and at least one --page")
        }
        let pages = pageLines.map { SyntheticPDFPage(lines: $0) }
        try SyntheticPDFMaker.write(pages: pages, to: out)
        print("wrote \(out.path) (\(pages.count) pages)")
    }

    // MARK: shared helpers

    static func printSummary(_ summary: IndexRunSummary, store: IndexStore, searchMode: IndexStore.SearchMode) {
        let payload: [String: Any] = [
            "filesScanned": summary.filesScanned,
            "indexedNew": summary.indexedNew,
            "updated": summary.updated,
            "skippedUnchanged": summary.skippedUnchanged,
            "removed": summary.removed,
            "excluded": summary.excluded,
            "unsupported": summary.unsupported,
            "failed": summary.failed,
            "cancelled": summary.wasCancelled,
            "exclusions": summary.exclusions,
            "failures": summary.failures,
            "searchMode": searchMode.rawValue,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            print(String(data: data, encoding: .utf8) ?? "{}")
        }
    }

    // MARK: - daily-quote

    struct DailyQuoteJSON: Codable {
        let sentence: String
        let bookFileName: String
        let physicalPage: Int
        let citation: String
    }


    // MARK: detect-body-start（前置页探测器；离线批处理基准）

    /// 扫描书（缺省全书目）前 40 物理页，输出正文起始页候选与命中信号；
    /// report-only 缺省，--apply 才把候选写书级 meta 键（body_start_page:）。
    /// 探测的是书级页号属性而非页码数据表——文献数据生产边界内。
    static func detectBodyStartCommand(_ args: [String]) throws {
        var cursor = ArgCursor(args)
        var dbPath: URL?
        var bookFilter: String?
        var apply = false
        while let arg = cursor.current {
            switch arg {
            case "--db": dbPath = URL(fileURLWithPath: try cursor.value(for: arg))
            case "--book": bookFilter = try cursor.value(for: arg)
            case "--apply": apply = true
            default: throw CLIError("detect-body-start: unknown argument \(arg)")
            }
            // value(for:) 只推进到"值"上；与全文件其余解析循环一致，
            // 循环底统一补一步跳过值（缺此行：带值旗标的值会被当旗标
            // 抛 unknown argument，纯布尔旗标则 position 停滞死循环）。
            cursor.position += 1
        }
        guard let dbPath else { throw CLIError("detect-body-start: --db required") }
        let store = try IndexStore(path: dbPath)
        let books = try store.allBooks().filter { bookFilter == nil || $0.id == bookFilter }
        var detected = 0
        for book in books {
            // 零页书（status=ok pageCount=0）此前
            // 构 `1...0` 越界 fatal；无页可扫的书直接跳过。
            guard book.status == "ok", book.pageCount >= 1 else { continue }
            let scanUpTo = min(book.pageCount, 40)
            var pageTexts: [String] = []
            pageTexts.reserveCapacity(scanUpTo)
            for page in 1...scanUpTo {
                guard let row = try? store.page(bookID: book.id, pageNumber: page) else { break }
                pageTexts.append(row.textOriginal)
            }
            let detection = BodyStartDetector.detect(pageTexts: pageTexts)
            let existing = FrontMatterFilter.readBodyStartPage(store: store, bookID: book.id)
            let title = book.title ?? book.fileName
            if let candidate = detection.bodyStartPage {
                detected += 1
                print("[\(book.id)] \(title) → 候选正文起始物理页 \(candidate)（现值 \(existing.map(String.init) ?? "未设置")）；信号: \(detection.signals.joined(separator: "；"))")
                if apply {
                    try FrontMatterFilter.writeBodyStartPage(candidate, store: store, bookID: book.id)
                    print("[\(book.id)] 已写入 meta（--apply）")
                }
            } else {
                print("[\(book.id)] \(title) → 无把握不猜；信号: \(detection.signals.joined(separator: "；"))")
            }
        }
        print("detect-body-start: \(books.count) 本书扫描，\(detected) 本有候选\(apply ? "（已 --apply 写入）" : "（report-only；--apply 才写入）")")
    }

    static func dailyQuoteCommand(_ args: [String]) async throws {
        var cursor = ArgCursor(args)
        var dbPath: URL?
        var refresh = false
        var jsonOutput = false

        while let arg = cursor.current {
            switch arg {
            case "--db":
                dbPath = URL(fileURLWithPath: try cursor.value(for: arg))
            case "--refresh":
                refresh = true
            case "--json":
                jsonOutput = true
            default:
                throw CLIError("unexpected extra argument: \(arg)")
            }
            cursor.position += 1
        }

        guard let dbPath else {
            throw CLIError("daily-quote requires --db <path>")
        }
        guard FileManager.default.fileExists(atPath: dbPath.path) else {
            throw CLIError("database does not exist: \(dbPath.path)")
        }

        let store = try IndexStore(path: dbPath)

        if refresh {
            FileHandle.standardError.write(Data("[daily-quote] 正在扫描书库抽取每日摘录池...\n".utf8))
            let extracted = try QuoteExtractor.extract(from: store)
            FileHandle.standardError.write(Data("[daily-quote] 刷新完成，当前摘录池共 \(extracted.count) 条摘录\n".utf8))
        }

        guard let quote = QuoteExtractor.today(store: store) else {
            throw CLIError("无摘录池，请先 --refresh")
        }

        let rawTitle = try? store.book(byID: quote.bookID)?.title
        let fileBase = quote.fileName.hasSuffix(".pdf")
            ? String(quote.fileName.dropLast(4))
            : quote.fileName
        let hasCJK: (String) -> Bool = { s in
            s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        }
        let trimmedTitle = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookName: String
        if let t = trimmedTitle, !t.isEmpty, !hasCJK(t), !hasCJK(fileBase) {
            bookName = t
        } else {
            bookName = fileBase
        }
        let citation = "\(bookName)，第\(quote.pageNumber)页"

        if jsonOutput {
            let payload = DailyQuoteJSON(
                sentence: quote.sentence,
                bookFileName: quote.fileName,
                physicalPage: quote.pageNumber,
                citation: citation
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(payload)
            if let jsonStr = String(data: data, encoding: .utf8) {
                print(jsonStr)
            }
        } else {
            print("""
            摘录: \(quote.sentence)
            出处: \(citation)
            文件: \(quote.fileName) (第 \(quote.pageNumber) 页)
            """)
        }
    }
}

struct CLIError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

// MARK: - rebind-renames（改名路径重绑定）

/// 顶层壳在 CLI 侧解（回执由外部改名工具产出；相对路径一律按给定串解析，
/// 不做静默规范化）。
struct RenameReceiptFile: Decodable {
    let renames: [RenameReceipt]

    enum CodingKeys: String, CodingKey {
        case renames
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        renames = try container.decodeIfPresent([RenameReceipt].self, forKey: .renames) ?? []
    }
}

extension LiteratureSearchCLI {
    static func rebindRenamesCommand(_ args: [String]) throws {
        var cursor = ArgCursor(args)
        var receiptPath: String?
        var dbPath: URL?
        var dryRun = false
        var reportPath: URL?
        while let arg = cursor.current {
            switch arg {
            case "--db": dbPath = URL(fileURLWithPath: try cursor.value(for: arg))
            case "--dry-run": dryRun = true
            case "--report": reportPath = URL(fileURLWithPath: try cursor.value(for: arg))
            default:
                if receiptPath == nil { receiptPath = arg }
                else { throw CLIError("unexpected extra argument for rebind-renames: \(arg)") }
            }
            cursor.position += 1
        }
        guard let receiptPath, let dbPath else {
            throw CLIError("rebind-renames requires <receipt.json> --db <path>")
        }
        guard FileManager.default.fileExists(atPath: receiptPath) else {
            throw CLIError("receipt file does not exist: \(receiptPath)")
        }
        guard FileManager.default.fileExists(atPath: dbPath.path) else {
            throw CLIError("database does not exist: \(dbPath.path)")
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: receiptPath))
        let receiptFile = try JSONDecoder().decode(RenameReceiptFile.self, from: data)
        guard !receiptFile.renames.isEmpty else {
            throw CLIError("receipt contains no renames")
        }
        for receipt in receiptFile.renames {
            guard !receipt.oldPath.isEmpty, !receipt.newPath.isEmpty else {
                throw CLIError("receipt entry has an empty path")
            }
        }

        let store = try IndexStore(path: dbPath)
        let report = try store.rebindRenamedBooks(receiptFile.renames, dryRun: dryRun)
        for result in report.results {
            print("\(result.status): \(result.reason) (\(result.oldPath) → \(result.newPath))")
        }
        print("rebind-renames: up=\(report.upReboundCount) already=\(report.alreadyReboundCount) "
            + "dryRunHits=\(report.dryRunHitCount) refused=\(report.refusedCount) failed=\(report.failed)")
        if let reportPath {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try encoder.encode(report).write(to: reportPath)
            print("report: \(reportPath.path)")
        }
        if report.failed {
            throw CLIError("rebind-renames: \(report.refusedCount) refused row(s); nothing was written")
        }
    }
}
