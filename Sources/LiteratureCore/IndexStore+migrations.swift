import Foundation

// MARK: - schema 迁移史（自 IndexStore.swift 纯搬移，零语义变化）
//
// 搬移清单：migrate 全链（基线 DDL + FTS5 大表探针/重建 + 迁移链调度）、
// migrateSchemaV2/V3/V4/V5、migrateDailyQuotes、tableColumns。搬移件 private
// → internal（extension 所需，公开面零变化）；调用方 IndexStore.init / gate / 自愈
// 原样（IndexStore.swift 内既有行零改动——搬移以删行呈现）。先例：
// IndexStore+PageMap.swift / IndexStore+IndexQueue.swift 同形 extension。

extension IndexStore {
    func migrate() throws {
        // 两库分离路由：fulltext 侧资产
        // （pages/两 FTS 虚表/bigram_index/book_native_counts）迁移后位于
        // attached 的 ft schema（DDL 由 init.setupFulltextLocked →
        // createFulltextSchemaLocked 承担），本函数只在 legacy 单库形态
        // （main.pages 表存在）维护 main 侧同名资产。split 形态下 main 侧
        // 绝不重建 pages（未限定 CREATE 恒落 main，会把分离撕开一道
        // 同名遮蔽口）。
        let legacyLayout = mainPagesTableExistsLocked()
        try db.exec("""
        CREATE TABLE IF NOT EXISTS meta(
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS books(
            id TEXT PRIMARY KEY,
            real_path TEXT NOT NULL UNIQUE,
            root_path TEXT NOT NULL,
            rel_path TEXT NOT NULL,
            file_name TEXT NOT NULL,
            title TEXT,
            author TEXT,
            version TEXT,
            first_fingerprint TEXT NOT NULL,
            fingerprint TEXT NOT NULL,
            file_size INTEGER NOT NULL,
            mtime REAL NOT NULL,
            page_count INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL DEFAULT 'ok',
            error TEXT,
            indexed_at REAL NOT NULL
        );
        """)
        if legacyLayout {
            try db.exec("""
            CREATE TABLE IF NOT EXISTS pages(
                book_id TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
                page_number INTEGER NOT NULL,
                label TEXT,
                printed_page INTEGER,
                text_original TEXT NOT NULL,
                text_norm TEXT NOT NULL,
                norm_starts BLOB NOT NULL,
                norm_ends BLOB NOT NULL,
                source TEXT NOT NULL DEFAULT 'native',
                PRIMARY KEY(book_id, page_number)
            );
            """)
        }
        if legacyLayout, searchMode == .fts5Trigram {
            // Bigram FTS5 table (own storage — normal DELETE works, unlike the
            // external-content variant whose detail=none deletes are unusable).
            // Legacy trigram-schema databases are detected by column mismatch and
            // the stale table is dropped so the new schema takes effect.
            // Robust probe: (a) does the FTS table carry the bigram column?
            // (b) is it POPULATED while pages has data? An empty-but-valid
            // bigram table (dropped-and-recreated before the rebuild path
            // existed) silently zeroes every >=3-char query.
            //
            // Cost guard:  (b) reads and TRIMs EVERY page's text
            // and ran on EVERY open. The cheap column probe always runs;
            // the expensive counts
            // run only until the first healthy verdict is recorded in meta.
            let hasBigramColumn: Bool = {
                guard let stmt = try? db.prepare("SELECT text_bigram FROM pages_fts LIMIT 1") else { return false }
                stmt.reset()
                return true
            }()
            let probeHealthy = (try? metaValueLocked("fts_probe_ok_v1")) == "1"
            var legacy = !hasBigramColumn
            if !legacy, !probeHealthy {
                var pagesWithText = 0
                if let st = try? db.prepare("SELECT COUNT(*) FROM pages WHERE TRIM(text_norm) != '';") {
                    if try st.step() { pagesWithText = Int(st.int(0)) }
                }
                var ftsRows = 0
                if let st = try? db.prepare("SELECT COUNT(*) FROM pages_fts;") {
                    if try st.step() { ftsRows = Int(st.int(0)) }
                }
                legacy = pagesWithText > 0 && ftsRows == 0
                if !legacy {
                    try setMetaValueLocked("fts_probe_ok_v1", "1")
                }
            }
            if legacy {
                try db.exec("DROP TABLE IF EXISTS pages_fts;")
            }
            let ok = db.tryExec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS pages_fts USING fts5(
                text_bigram,
                tokenize='unicode61',
                detail='none'
            );
            CREATE TABLE IF NOT EXISTS bigram_index(
                bigram TEXT PRIMARY KEY,
                rowids BLOB NOT NULL
            ) WITHOUT ROWID;
            """)
            if !ok {
                // Environment drifted since creation (should not happen after probe);
                // degrade honestly to LIKE mode and record it.
                searchMode = .likeFallback
                try setMetaValueLocked("search_mode", searchMode.rawValue)
            }
            if legacy {
                // The drop invalidated every FTS entry. Rebuild the whole FTS
                // index from pages NOW (bigram serialization can be expensive)
                // — leaving it empty would silently zero out every
                // >=3-char query (poisoned-cache class of failure).
                let ins = try db.prepare("INSERT INTO pages_fts(rowid, text_bigram) VALUES(?, ?);")
                let rows = try db.prepare("SELECT rowid, text_norm FROM pages WHERE TRIM(text_norm) != '';")
                var n = 0
                while try rows.step() {
                    let rowid = rows.int(0)
                    let textNorm = rows.text(1)
                    try ins.reset(); try ins.clearBindings()
                    try ins.bindInt(1, rowid)
                    try ins.bindText(2, Self.bigramize(textNorm))
                    try ins.run()
                    n += 1
                }
                try setMetaValueLocked("fts_rebuilt_at", String(Date().timeIntervalSince1970))
                try setMetaValueLocked("fts_probe_ok_v1", "1")   // just rebuilt: healthy by construction
                try setMetaValueLocked("bidx_dirty", "1")   // inverted index not yet built for this content
                FileHandle.standardError.write(Data("FTS legacy schema detected: rebuilt bigram index for \(n) pages.\n".utf8))
            }
        }
        try migrateSchemaV2()
        if legacyLayout {
            _ = db.tryExec("CREATE INDEX IF NOT EXISTS idx_pages_book_source ON pages(book_id, source);")
        }
        try migrateSchemaV3(pagesProbe: legacyLayout)
        try migrateSchemaV4()
        try migrateSchemaV5()
        try migrateDailyQuotes()
        try migrateSchemaV6()               // page_map 表（幂等；extension 定义）
        try migrateSchemaV7()               // index_queue 表（幂等；extension 定义）
        try migrateSchemaV8()               // classification_rules / book_classifications（幂等；extension 定义）
        try migrateSchemaV9()               // reading_sessions / page_footprints（幂等；extension 定义）
        if legacyLayout {
            // pages.text_latin 投影列 + pages_wfts 词级虚表 + 三同步触发器
            // split 形态跳过（ft.pages DDL 自带 text_latin，pages_wfts 与
            // 触发器在 ft schema 由 createFulltextSchemaLocked 承担；未限定
            // CREATE VIRTUAL TABLE 恒落 main，会把词级虚表撕成无源孤儿）。
            try migrateSchemaV10()
        }
        try migrateSchemaV11()              // books.ocr_status/ocr_error/ocr_driver_id 双引擎状态机列（幂等；extension 定义）
        try migrateSchemaV12()              // books.content_category 内容类别列＋存量回填（幂等；extension 定义）
        try migrateSchemaV13()
        try migrateSchemaV14()              // 页统计覆盖索引 idx_pages_stats（门控；本文件定义）
        try backfillPinyinIfNeededLocked()   // 拼音书目投影（缺行才补，幂等）
        try ensureWftsReadyOnOpenLocked()    // wfts_ready 缺失时从 checkpoint 续跑回填（幂等；仅写库形态，只读副本 no-op）
        try setMetaValueLocked("schema_version", String(Self.currentSchemaVersion))
        // 独立 schema 版本门禁键（迁移完成后写入现行值）。其上方
        // 注释即向前兼容语义契约：库内值低于 currentSchemaVersion → 既有迁移
        // 链自动升级；高于 → init 里的门禁直接拒绝打开。
        try setMetaValueLocked(Self.indexSchemaVersionMetaKey, String(Self.currentSchemaVersion))
    }

    func migrateSchemaV4() throws {
        if (try metaValueLocked("normalization_version")) == nil {
            let pageCountStmt = try db.prepare("SELECT count(*) FROM pages;")
            defer { pageCountStmt.reset() }
            let hasPages = (try pageCountStmt.step()) ? (pageCountStmt.int(0) > 0) : false
            if !hasPages {
                try setMetaValueLocked("normalization_version", String(Self.expectedNormalizationVersion))
            }
        }
    }

    func migrateSchemaV5() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS user_highlights(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            book_id TEXT NOT NULL,
            page_number INTEGER NOT NULL,
            utf16_start INTEGER NOT NULL,
            utf16_end INTEGER NOT NULL,
            color TEXT NOT NULL,
            note TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_user_highlights_book ON user_highlights(book_id, page_number);
        CREATE TABLE IF NOT EXISTS favorites(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            kind TEXT NOT NULL,
            target_json TEXT NOT NULL,
            category TEXT NOT NULL DEFAULT '',
            tags TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_favorites_kind ON favorites(kind);
        CREATE INDEX IF NOT EXISTS idx_favorites_category ON favorites(category);
        """)
    }

    /// daily_quotes: stores derived high-value sentences for the Daily Quote engine.
    /// Original book contents remain completely read-only.
    func migrateDailyQuotes() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS daily_quotes(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            book_id TEXT NOT NULL,
            page_number INTEGER NOT NULL,
            sentence TEXT NOT NULL,
            quote_date TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_daily_quotes_date ON daily_quotes(quote_date);
        """)
    }

    func migrateSchemaV2() throws {
        let columns = try tableColumns("books")
        if !columns.contains("language") {
            try db.exec("ALTER TABLE books ADD COLUMN language TEXT;")
        }
        if !columns.contains("meta_source") {
            try db.exec("ALTER TABLE books ADD COLUMN meta_source TEXT;")
        }
    }

    func migrateSchemaV3(pagesProbe: Bool = true) throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS ocr_books(
            book_id TEXT PRIMARY KEY REFERENCES books(id) ON DELETE CASCADE,
            ocr_real_path TEXT NOT NULL UNIQUE,
            ocr_fingerprint TEXT NOT NULL,
            mapping_kind TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS ocr_pages(
            book_id TEXT NOT NULL REFERENCES ocr_books(book_id) ON DELETE CASCADE,
            original_page INTEGER NOT NULL,
            ocr_page INTEGER NOT NULL,
            PRIMARY KEY(book_id, original_page)
        );
        """)
        guard pagesProbe else { return }
        let pageColumns = try tableColumns("pages")
        if !pageColumns.contains("source") {
            try db.exec("ALTER TABLE pages ADD COLUMN source TEXT NOT NULL DEFAULT 'native';")
        }
    }

    func tableColumns(_ table: String) throws -> Set<String> {
        // table 参数可含 schema 限定："main.index_queue" → PRAGMA
        // main.table_info(index_queue)（PRAGMA 的 schema 前缀在 pragma 名上，
        // 不在参数内——冒烟实证 table_info("main.x") 报语法错）。
        let parts = table.split(separator: ".")
        let sql: String
        if parts.count == 2 {
            sql = "PRAGMA \(parts[0]).table_info(\(parts[1]));"
        } else {
            sql = "PRAGMA table_info(\(table));"
        }
        let stmt = try db.prepare(sql)
        defer { stmt.reset() }
        var names = Set<String>()
        while try stmt.step() { names.insert(stmt.text(1)) }
        return names
    }

    func migrateSchemaV8() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS classification_rules(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            match_text TEXT NOT NULL,
            algorithm TEXT NOT NULL CHECK(algorithm IN ('any','exact','prefix_dir')),
            target_category TEXT NOT NULL,
            enabled INTEGER NOT NULL DEFAULT 1,
            position INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS book_classifications(
            book_id TEXT PRIMARY KEY,
            category TEXT NOT NULL,
            rule_id INTEGER,
            classified_at REAL NOT NULL
        );
        """)
    }

    func migrateSchemaV9() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS reading_sessions(
            book_id TEXT NOT NULL,
            day TEXT NOT NULL,
            minutes REAL NOT NULL,
            pages INTEGER NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY(book_id, day)
        );
        CREATE TABLE IF NOT EXISTS page_footprints(
            book_id TEXT NOT NULL,
            page_number INTEGER NOT NULL,
            last_read_at REAL NOT NULL,
            read_count INTEGER NOT NULL,
            PRIMARY KEY(book_id, page_number)
        );
        """)
    }

    func migrateSchemaV12() throws {
        let columns = try tableColumns("books")
        if !columns.contains("content_category") {
            try db.exec("ALTER TABLE books ADD COLUMN content_category TEXT NOT NULL DEFAULT '';")
        }
        let pending = try db.prepare("SELECT id, real_path, COALESCE(title,'') FROM books WHERE content_category = '';")
        let upd = try db.prepare("UPDATE books SET content_category = ? WHERE id = ?;")
        var batch: [(String, String, String)] = []
        while try pending.step() {
            batch.append((pending.text(0), pending.text(1), pending.text(2)))
        }
        pending.reset()
        guard !batch.isEmpty else { return }
        try db.exec("BEGIN IMMEDIATE;")
        do {
            for (id, path, title) in batch {
                let cat = classifyContentCategory(path: path, title: title)
                try upd.reset(); try upd.clearBindings()
                try upd.bindText(1, cat)
                try upd.bindText(2, id)
                try upd.run()
            }
            try db.exec("COMMIT;")
        } catch {
            db.tryExec("ROLLBACK;")
            throw error
        }
    }

    /// 全书页统计覆盖索引（零命中诊断相的根因修复）。
    ///
    /// 根因（实际测量）
    /// `perBookPageStats` 旧式要逐行求值 `TRIM(text_norm)=''`，而 pages 是
    /// 大型文本表，需要逐行解出 text_norm，避免一次性载入全部内容文本 payload。
    /// 覆盖索引提供该判断：索引只含 (book_id, TRIM(text_norm)='' 布尔)，
    /// 聚合查询因此可使用纯索引扫描。
    ///
    /// 建立门控：仅在 `Options.allowPageStatsStatsIndex`（CLI 检索命令默认
    /// true）下建立。App 路径不自动建，避免启动时多一次整表扫描；
    /// App 首次零命中诊断仍使用原路径，后续由进程内缓存减少重复查询。
    /// 索引一旦存在（含被 CLI 建在主库上），
    /// 任何形态（含 App、只读副本）的开库查询都直接受益；此处 `IF NOT
    /// EXISTS` 只做 O(1) 判别，不重建。legacy 单库形态同样适用（ftQual=""；
    /// `hasSqliteObjectLocked` 按 fulltextAttached 自动选 schema）。
    /// 注意：SQLite 不用本索引做 `WHERE TRIM(text_norm)=''` 直搜，仍会
    /// 全表扫描；它只服务聚合覆盖，不能替代任何既有路径。
    func migrateSchemaV14() throws {
        guard allowPageStatsStatsIndex else { return }
        guard hasSqliteObjectLocked(type: "table", name: "pages") else { return }
        try db.exec("""
        CREATE INDEX IF NOT EXISTS \(ftQual)idx_pages_stats
        ON pages(book_id, (TRIM(text_norm) = ''));
        """)
    }

    func migrateSchemaV11() throws {
        let columns = try tableColumns("books")
        if !columns.contains("ocr_status") {
            try db.exec("ALTER TABLE books ADD COLUMN ocr_status TEXT NOT NULL DEFAULT '';")
        }
        if !columns.contains("ocr_error") {
            try db.exec("ALTER TABLE books ADD COLUMN ocr_error TEXT NOT NULL DEFAULT '';")
        }
        if !columns.contains("ocr_driver_id") {
            try db.exec("ALTER TABLE books ADD COLUMN ocr_driver_id TEXT NOT NULL DEFAULT '';")
        }
    }

    func migrateSchemaV10() throws {
        let columns = try tableColumns("pages")
        if !columns.contains("text_latin") {
            // ALTER 为元数据操作（O(1)，不重写表）。
            try db.exec("ALTER TABLE pages ADD COLUMN text_latin TEXT NOT NULL DEFAULT '';")
        }
        let ok = db.tryExec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS pages_wfts USING fts5(
            text_latin,
            content='pages',
            content_rowid='rowid',
            tokenize='unicode61'
        );
        """)
        guard ok else { return }
        // 三个同步触发器（WHEN 守卫使非文本 UPDATE——PageMap×2 的
        // printed_page 回填等——零 FTS churn）。
        try db.exec("""
        CREATE TRIGGER IF NOT EXISTS pages_wfts_ai AFTER INSERT ON pages BEGIN
            INSERT INTO pages_wfts(rowid, text_latin) VALUES (new.rowid, new.text_latin);
        END;
        CREATE TRIGGER IF NOT EXISTS pages_wfts_ad AFTER DELETE ON pages BEGIN
            INSERT INTO pages_wfts(pages_wfts, rowid, text_latin) VALUES ('delete', old.rowid, old.text_latin);
        END;
        CREATE TRIGGER IF NOT EXISTS pages_wfts_au AFTER UPDATE ON pages
            WHEN old.text_latin IS NOT new.text_latin BEGIN
            INSERT INTO pages_wfts(pages_wfts, rowid, text_latin) VALUES ('delete', old.rowid, old.text_latin);
            INSERT INTO pages_wfts(rowid, text_latin) VALUES (new.rowid, new.text_latin);
        END;
        """)
    }

    /// 开库续跑钩子：wfts_ready 缺失（迁移新装/回填中断）时从
    /// checkpoint 续跑回填。幂等、重入安全；大库执行时间取决于数据量，
    /// 由 CLI `backfill-latin`（首选窗口）或本钩子（续跑/降级处理）承担。
    private func ensureWftsReadyOnOpenLocked() throws {
        guard !isReadOnlyReplica else { return }
        if (try? metaValueLocked("wfts_ready")) == "1" { return }
        if let hb = try? metaValueLocked("wfts_backfill_heartbeat"),
           let t = TimeInterval(hb), Date().timeIntervalSince1970 - t < 60 {
            return
        }
        try backfillLatinProjectionLocked(progress: nil)
    }

    // MARK: - 存量搬迁（一次性；CLI migrate-fulltext 的

    public struct FulltextMigrationSummary: Equatable, Sendable {
        public var booksMoved: Int = 0
        public var pagesMoved: Int = 0
        public var resumedFromCheckpoint: Bool = false
        public var ftsRebuilt: Bool = false
        public var vacuumed: Bool = false
        public var elapsedSeconds: Double = 0
    }

    /// 一次性存量搬迁 main.pages → ft.pages（operator 经 CLI 在空闲期调用；
    /// 全程持本店锁，跨连接并发由 SQLite 锁序降级处理）。
    @discardableResult
    public func migrateMainPagesToFulltext(progress: ((_ done: Int, _ total: Int) -> Void)? = nil,
                                           vacuumAfter: Bool = true) throws -> FulltextMigrationSummary {
        lock.lock(); defer { lock.unlock() }
        var summary = FulltextMigrationSummary()
        let t0 = Date()
        guard !isReadOnlyReplica else {
            throw StoreError.description("只读副本不做 fulltext 搬迁（回 Mac 端执行）。")
        }
        guard mainPagesTableExistsLocked() else {
            throw StoreError.description("main.pages 表不存在（已搬迁或非 legacy 形态），无需迁移。")
        }
        // 列完备性：init 迁移链保证 source/text_latin 在列（缺失即没跑完 init
        // 迁移，如实拒迁不半搬）。
        let cols = try tableColumns("pages")
        for required in ["source", "text_latin"] where !cols.contains(required) {
            throw StoreError.description("main.pages 缺列 \(required)，先完成既有迁移再搬迁。")
        }

        if !fulltextAttached {
            try attachFulltextLocked(url: fulltextURL!)
        }
        let hadCheckpoint: String?
        if hasFulltextObjectLocked(type: "table", name: "ft_meta") {
            hadCheckpoint = (try? ftMetaValueLocked("migrate_checkpoint_book")) ?? nil
        } else {
            hadCheckpoint = nil
        }
        let ftHasPages = hasFulltextObjectLocked(type: "table", name: "pages")
        if let checkpoint = hadCheckpoint, ftHasPages {
            // 续搬有效性：checkpoint 册的页行必须真的在 ft（ft 被删过即从头来）。
            let probe = try db.prepare("SELECT 1 FROM ft.pages WHERE book_id = ? LIMIT 1;")
            try probe.bindText(1, checkpoint)
            if (try? probe.step()) != true {
                // checkpoint 失效（ft 被删过/换过）：清空重来。
                try db.exec("DELETE FROM ft.pages;")
                try db.exec("DELETE FROM ft.ft_meta;")
                try db.exec("INSERT OR REPLACE INTO ft.ft_meta(key, value) VALUES('fulltext_format_version', '\(Self.currentFulltextFormatVersion)');")
                summary.resumedFromCheckpoint = false
            } else {
                summary.resumedFromCheckpoint = true
            }
        }
        if !hasFulltextObjectLocked(type: "table", name: "ft_meta") {
            // 空净 ft（首次/重来）：重建 schema（版本标记一并写）。
            _ = db.tryExec("DETACH DATABASE ft;")
            fulltextAttached = false
            try createFulltextSchemaLocked()
        }

        let bookIDs: [String] = {
            var out: [String] = []
            guard let stmt = try? db.prepare("SELECT id FROM books ORDER BY id;") else { return out }
            while (try? stmt.step()) == true { out.append(stmt.text(0)) }
            return out
        }()
        // 语句作用域化：DONE 态语句持表游标锁（SQLite 契约：reset/finalize
        // 前不释放），作用域出块即 finalize，后续 DROP 才不撞
        // 「database table is locked」（冒烟实证后修）。
        var started = false
        do {
            let moveSQL = """
            INSERT INTO ft.pages(book_id, page_number, label, printed_page,
                                 text_original, text_norm, norm_starts, norm_ends,
                                 source, text_latin)
            SELECT book_id, page_number, label, printed_page,
                   text_original, text_norm, norm_starts, norm_ends, source, text_latin
            FROM main.pages WHERE book_id = ?;
            """
            let move = try db.prepare(moveSQL)
            let cpSet = try db.prepare("INSERT OR REPLACE INTO ft.ft_meta(key, value) VALUES('migrate_checkpoint_book', ?);")
            for (i, bookID) in bookIDs.enumerated() {
                progress?(i, bookIDs.count)
                if let checkpoint = hadCheckpoint, !started, bookID <= checkpoint, summary.resumedFromCheckpoint {
                    continue   // 已搬段跳过
                }
                started = true
                try db.exec("BEGIN IMMEDIATE;")
                do {
                    try move.reset(); try move.clearBindings()
                    try move.bindText(1, bookID)
                    try move.run()
                    try cpSet.reset(); try cpSet.clearBindings()
                    try cpSet.bindText(1, bookID)
                    try cpSet.run()
                    try db.exec("COMMIT;")
                    summary.booksMoved += 1
                } catch {
                    db.tryExec("ROLLBACK;")
                    throw error
                }
            }
        }
        progress?(bookIDs.count, bookIDs.count)

        var mainPages = 0
        var ftPages = 0
        do {
            let mainCount = try db.prepare("SELECT COUNT(*) FROM main.pages;")
            if try mainCount.step() { mainPages = Int(mainCount.int(0)) }
            let ftCount = try db.prepare("SELECT COUNT(*) FROM ft.pages;")
            if try ftCount.step() { ftPages = Int(ftCount.int(0)) }
        }
        guard mainPages == ftPages, ftPages > 0 || bookIDs.isEmpty else {
            throw StoreError.description("搬迁校验失败：main.pages=\(mainPages) 行 vs ft.pages=\(ftPages) 行，保留两侧现状待排查。")
        }
        summary.pagesMoved = ftPages

        if searchMode == .fts5Trigram {
            try db.exec("DROP TABLE IF EXISTS ft.pages_fts;")
            let ok = db.tryExec("""
            CREATE VIRTUAL TABLE ft.pages_fts USING fts5(text_bigram, tokenize='unicode61', detail='none');
            """)
            guard ok else {
                throw StoreError.description("ft.pages_fts 重建失败（FTS5 环境漂移）")
            }
            try db.exec("BEGIN IMMEDIATE;")
            do {
                let ins = try db.prepare("INSERT INTO ft.pages_fts(rowid, text_bigram) VALUES(?, ?);")
                let rows = try db.prepare("SELECT rowid, text_norm FROM ft.pages WHERE TRIM(text_norm) != '';")
                while try rows.step() {
                    try ins.reset(); try ins.clearBindings()
                    try ins.bindInt(1, rows.int(0))
                    try ins.bindText(2, Self.bigramize(rows.text(1)))
                    try ins.run()
                }
                try db.exec("COMMIT;")
            } catch {
                db.tryExec("ROLLBACK;")
                throw error
            }
            // bigram 倒排表重建（同一 ft 限定纪律）。
            try db.exec("DELETE FROM ft.bigram_index;")
            try db.exec("BEGIN IMMEDIATE;")
            do {
                let rows = try db.prepare("SELECT rowid, text_norm FROM ft.pages WHERE TRIM(text_norm) != '' ORDER BY rowid;")
                var index: [String: [UInt32]] = [:]
                while try rows.step() {
                    let rowid = UInt32(max(0, rows.int(0)))
                    let chars = Array(rows.text(1))
                    guard chars.count >= 2 else { continue }
                    for i in 0..<(chars.count - 1) {
                        index[String(chars[i]) + String(chars[i + 1]), default: []].append(rowid)
                    }
                }
                let insB = try db.prepare("INSERT OR REPLACE INTO ft.bigram_index VALUES(?, ?);")
                for (g, ridsIn) in index {
                    var rids = ridsIn
                    rids.sort()
                    var blob = Data(capacity: rids.count * 4)
                    for r in rids {
                        withUnsafeBytes(of: r.bigEndian) { blob.append(contentsOf: $0) }
                    }
                    try insB.reset(); try insB.clearBindings()
                    try insB.bindText(1, g)
                    try insB.bindBlob(2, blob)
                    try insB.run()
                }
                try setMetaValueLocked("bidx_dirty", "0")
                try setMetaValueLocked("bidx_built_at", String(Int(Date().timeIntervalSince1970)))
                try db.exec("COMMIT;")
            } catch {
                db.tryExec("ROLLBACK;")
                try setMetaValueLocked("bidx_dirty", "1")
                throw error
            }
            try db.exec("INSERT INTO ft.pages_wfts(pages_wfts) VALUES('delete-all');")
            try db.exec("INSERT INTO ft.pages_wfts(rowid, text_latin) SELECT rowid, text_latin FROM ft.pages WHERE TRIM(text_latin) != '';")
            summary.ftsRebuilt = true
        }

        try db.exec("DROP TABLE IF EXISTS main.pages;")
        try db.exec("DROP TABLE IF EXISTS main.pages_fts;")
        try db.exec("DROP TABLE IF EXISTS main.bigram_index;")
        try db.exec("DROP TABLE IF EXISTS main.book_native_counts;")
        try db.exec("DROP TABLE IF EXISTS main.pages_wfts;")
        try purgeQueryCachesLocked()
        try setMetaValueLocked("bidx_dirty", searchMode == .fts5Trigram ? "0" : "1")

        if vacuumAfter {
            try db.exec("VACUUM main;")
            summary.vacuumed = true
        }

        try db.exec("INSERT OR REPLACE INTO ft.ft_meta(key, value) VALUES('fulltext_migrated', '1');")
        try db.exec("DELETE FROM ft.ft_meta WHERE key = 'migrate_checkpoint_book';")
        try setMetaValueLocked("fulltext_migrated_at", String(Date().timeIntervalSince1970))
        summary.elapsedSeconds = Date().timeIntervalSince(t0)
        return summary
    }
}
