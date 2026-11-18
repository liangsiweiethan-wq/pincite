import Foundation


extension IndexStore {
    /// 索引管线版本（与索引 schema 版本独立：管线升级＝规范化/
    /// 分词/页码语义变化时递增，队列按此断点续跑）。
    public static let currentPipelineVersion = 1

    /// 迁移链新增一步（init → migrate 内、migrateSchemaV6
    func migrateSchemaV7() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS index_queue(
            book_id TEXT PRIMARY KEY,
            state TEXT NOT NULL,
            queued_version INTEGER NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            updated_at REAL NOT NULL
        );
        """)
    }

    func migrateSchemaV13() throws {
        // index_queue/index_pending 均为 main 侧件；探针与 DDL 显式限定 main.
        let columns = try tableColumns("main.index_queue")
        if !columns.contains("pages_total") {
            try db.exec("ALTER TABLE index_queue ADD COLUMN pages_total INTEGER NOT NULL DEFAULT 0;")
        }
        if !columns.contains("pages_done") {
            try db.exec("ALTER TABLE index_queue ADD COLUMN pages_done INTEGER NOT NULL DEFAULT 0;")
        }
        if !columns.contains("chars_done") {
            try db.exec("ALTER TABLE index_queue ADD COLUMN chars_done INTEGER NOT NULL DEFAULT 0;")
        }
        try db.exec("""
        CREATE TABLE IF NOT EXISTS index_pending(
            path TEXT PRIMARY KEY,
            added_at REAL NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0
        );
        """)
    }

    /// 队列行（逐册状态）。
    public struct IndexQueueRow: Equatable {
        public let bookID: String
        public var state: IndexQueueState
        public var queuedVersion: Int
        public var attempts: Int
        public var lastError: String?
        public var updatedAt: Double
        public var pagesTotal: Int
        public var pagesDone: Int
        public var charsDone: Int

        /// 显式 init（带进度列默认值）：保既有 memberwise 构造点零改动。
        public init(bookID: String, state: IndexQueueState, queuedVersion: Int,
                    attempts: Int, lastError: String?, updatedAt: Double,
                    pagesTotal: Int = 0, pagesDone: Int = 0, charsDone: Int = 0) {
            self.bookID = bookID
            self.state = state
            self.queuedVersion = queuedVersion
            self.attempts = attempts
            self.lastError = lastError
            self.updatedAt = updatedAt
            self.pagesTotal = pagesTotal
            self.pagesDone = pagesDone
            self.charsDone = charsDone
        }
    }

    public enum IndexQueueState: String, CaseIterable, Equatable {
        case unavailable
        case unindexed
        case partial
        case indexed
        case queued
    }

    // MARK: 入队（books 变更路径调用；只读句柄 no-op）

    /// upsert 单册入队（state=queued、queued_version=当前管线版本）。
    /// IndexingEngine.persist（upsertBook 后）与新册登记调用。
    public func enqueueBook(_ bookID: String) throws {
        lock.lock(); defer { lock.unlock() }
        try enqueueBookLocked(bookID)
    }

    /// 无锁内核（全量重排队 requeueAllBooksForFulltextRebuild
    /// 等持锁上下文复用；公有 enqueueBook 不可重入——NSLock 非递归，
    /// allBooksCached 注释同案）。
    func enqueueBookLocked(_ bookID: String) throws {
        guard !isReadOnlyReplica else { return }   // 只读纪律：队列写 no-op（照 setMetaValueLocked 先例）
        let stmt = try db.prepare("""
        INSERT INTO index_queue(book_id, state, queued_version, attempts, last_error, updated_at)
        VALUES(?, 'queued', ?, 0, NULL, ?)
        ON CONFLICT(book_id) DO UPDATE SET
            state='queued', queued_version=excluded.queued_version, updated_at=excluded.updated_at;
        """)
        try stmt.bindText(1, bookID)
        try stmt.bindInt(2, Int64(Self.currentPipelineVersion))
        try stmt.bindDouble(3, Date().timeIntervalSince1970)
        try stmt.run()
    }

    /// 删册同步删队列行（deleteBook 路径调用；显式清理，无自动删除）。
    public func dequeueBook(_ bookID: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard !isReadOnlyReplica else { return }
        let stmt = try db.prepare("DELETE FROM index_queue WHERE book_id = ?;")
        try stmt.bindText(1, bookID)
        try stmt.run()
    }

    // MARK: 读取（只读安全）

    /// 断点续跑的到期队列：state != 'indexed' OR queued_version <
    public func dueQueueRows() throws -> [IndexQueueRow] {
        lock.lock(); defer { lock.unlock() }
        return try dueQueueRowsLocked()
    }

    private func dueQueueRowsLocked() throws -> [IndexQueueRow] {
        var out: [IndexQueueRow] = []
        let stmt = try db.prepare("""
        SELECT book_id, state, queued_version, attempts, last_error, updated_at,
               pages_total, pages_done, chars_done
        FROM index_queue
        WHERE state != 'indexed' OR queued_version < ?
        ORDER BY updated_at, book_id;
        """)
        try stmt.bindInt(1, Int64(Self.currentPipelineVersion))
        while try stmt.step() {
            guard let state = IndexQueueState(rawValue: stmt.text(1)) else { continue }
            out.append(IndexQueueRow(bookID: stmt.text(0), state: state,
                                     queuedVersion: Int(stmt.int(2)), attempts: Int(stmt.int(3)),
                                     lastError: stmt.textOrNull(4), updatedAt: stmt.double(5),
                                     pagesTotal: Int(stmt.int(6)), pagesDone: Int(stmt.int(7)),
                                     charsDone: Int(stmt.int(8))))
        }
        return out
    }

    /// 全部队列行（诊断/测试用）。
    public func allQueueRows() throws -> [IndexQueueRow] {
        lock.lock(); defer { lock.unlock() }
        var out: [IndexQueueRow] = []
        let stmt = try db.prepare("""
        SELECT book_id, state, queued_version, attempts, last_error, updated_at,
               pages_total, pages_done, chars_done
        FROM index_queue ORDER BY updated_at, book_id;
        """)
        while try stmt.step() {
            guard let state = IndexQueueState(rawValue: stmt.text(1)) else { continue }
            out.append(IndexQueueRow(bookID: stmt.text(0), state: state,
                                     queuedVersion: Int(stmt.int(2)), attempts: Int(stmt.int(3)),
                                     lastError: stmt.textOrNull(4), updatedAt: stmt.double(5),
                                     pagesTotal: Int(stmt.int(6)), pagesDone: Int(stmt.int(7)),
                                     charsDone: Int(stmt.int(8))))
        }
        return out
    }

    public func bookHasTextLayer(bookID: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("""
        SELECT 1 FROM pages WHERE book_id = ? AND TRIM(text_norm) != '' LIMIT 1;
        """)
        try stmt.bindText(1, bookID)
        return (try stmt.step()) == true
    }

    // MARK: 状态写（消费循环调用；只读句柄 no-op）

    /// 写单册队列状态（消费循环每片存点用）。attemptDelta＝新行初值；
    /// 既有行冲突时 attempts 原生 +1 叠加（不覆盖计数）。
    func setQueueStateLocked(bookID: String, state: IndexQueueState,
                             queuedVersion: Int? = nil, error: String? = nil,
                             attemptDelta: Int = 0) throws {
        guard !isReadOnlyReplica else { return }   // 只读纪律：队列写 no-op（照 setMetaValueLocked 先例）
        let stmt = try db.prepare("""
        INSERT INTO index_queue(book_id, state, queued_version, attempts, last_error, updated_at)
        VALUES(?, ?, ?, ?, ?, ?)
        ON CONFLICT(book_id) DO UPDATE SET
            state=excluded.state, queued_version=excluded.queued_version,
            attempts=attempts+1, last_error=excluded.last_error,
            updated_at=excluded.updated_at;
        """)
        try stmt.bindText(1, bookID)
        try stmt.bindText(2, state.rawValue)
        try stmt.bindInt(3, Int64(queuedVersion ?? Self.currentPipelineVersion))
        try stmt.bindInt(4, Int64(attemptDelta))
        if let error { try stmt.bindText(5, error) } else { try stmt.bindNull(5) }
        try stmt.bindDouble(6, Date().timeIntervalSince1970)
        try stmt.run()
    }

    /// 消费循环的单册更新（叠加 attempts；公开给测试）。
    public func setQueueState(bookID: String, state: IndexQueueState,
                              queuedVersion: Int? = nil, error: String? = nil,
                              attemptDelta: Int = 0) throws {
        lock.lock(); defer { lock.unlock() }
        try setQueueStateLocked(bookID: bookID, state: state,
                                queuedVersion: queuedVersion, error: error,
                                attemptDelta: attemptDelta)
    }

    // MARK:进度落表（节流调用；只读句柄 no-op）

    /// upsert 单册进度（runQueued 抽取分支节流落表用）。只动进度三列，
    /// 不改 state/attempts/queued_version（attempt 计数语义不受进度写污染）；
    /// 行不存在时以 queued 态补建（竞态：进度先于状态行到达）。
    /// pagesTotal=nil＝中途节流写不覆盖既有总数（终值写由完成点显式传）。
    func updateQueueProgressLocked(bookID: String, pagesTotal: Int?, pagesDone: Int,
                                   charsDone: Int) throws {
        guard !isReadOnlyReplica else { return }   // 只读纪律：队列写 no-op
        let stmt = try db.prepare("""
        INSERT INTO index_queue(book_id, state, queued_version, attempts, last_error, updated_at,
                                pages_total, pages_done, chars_done)
        VALUES(?, 'queued', ?, 0, NULL, ?, COALESCE(?, 0), ?, ?)
        ON CONFLICT(book_id) DO UPDATE SET
            pages_total=COALESCE(excluded.pages_total, index_queue.pages_total),
            pages_done=excluded.pages_done, chars_done=excluded.chars_done,
            updated_at=excluded.updated_at;
        """)
        try stmt.bindText(1, bookID)
        try stmt.bindInt(2, Int64(Self.currentPipelineVersion))
        try stmt.bindDouble(3, Date().timeIntervalSince1970)
        if let pagesTotal { try stmt.bindInt(4, Int64(pagesTotal)) } else { try stmt.bindNull(4) }
        try stmt.bindInt(5, Int64(pagesDone))
        try stmt.bindInt(6, Int64(charsDone))
        try stmt.run()
    }

    /// 进度落表（公开给测试；节流节拍由调用方掌握）。
    public func updateQueueProgress(bookID: String, pagesTotal: Int?, pagesDone: Int,
                                    charsDone: Int) throws {
        lock.lock(); defer { lock.unlock() }
        try updateQueueProgressLocked(bookID: bookID, pagesTotal: pagesTotal,
                                      pagesDone: pagesDone, charsDone: charsDone)
    }

    // MARK:index_pending（文件事件 → 防抖入队 → 排空）

    /// watcher settle 后 upsert 入队（path 主键天然去重；既有行保留首次
    /// added_at 与累计 attempts）。只读句柄 no-op（沿队列纪律）。
    public func enqueuePendingPaths(_ urls: [URL]) throws {
        lock.lock(); defer { lock.unlock() }
        guard !isReadOnlyReplica else { return }
        let stmt = try db.prepare("""
        INSERT INTO index_pending(path, added_at, attempts) VALUES(?, ?, 0)
        ON CONFLICT(path) DO NOTHING;
        """)
        let now = Date().timeIntervalSince1970
        for url in urls {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            try stmt.reset(); try stmt.clearBindings()
            try stmt.bindText(1, path)
            try stmt.bindDouble(2, now)
            try stmt.run()
        }
    }

    /// 到期 pending 批（added_at 升序，先到先消费）。
    public struct PendingPathRow: Equatable {
        public let path: String
        public let addedAt: Double
        public let attempts: Int
    }

    public func duePendingPaths(limit: Int) throws -> [PendingPathRow] {
        lock.lock(); defer { lock.unlock() }
        var out: [PendingPathRow] = []
        let stmt = try db.prepare("SELECT path, added_at, attempts FROM index_pending ORDER BY added_at, path LIMIT ?;")
        try stmt.bindInt(1, Int64(max(1, limit)))
        while try stmt.step() {
            out.append(PendingPathRow(path: stmt.text(0), addedAt: stmt.double(1),
                                      attempts: Int(stmt.int(2))))
        }
        return out
    }

    /// 排空成功后删行（索引落库即消费完成）。
    public func removePendingPaths(_ paths: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        guard !isReadOnlyReplica else { return }
        let stmt = try db.prepare("DELETE FROM index_pending WHERE path = ?;")
        for p in paths {
            try stmt.reset(); try stmt.clearBindings()
            try stmt.bindText(1, p)
            try stmt.run()
        }
    }

    /// 排空失败叠加 attempts；≥3 时删行弃试（防坏件永久占队——
    /// 「失败 attempts+1 保留（≥3 记 unavailable 弃试）」，unavailable 记录
    /// 由调用方对既有书行落 books.status，无书行的坏件以删行弃试结算）。
    /// 弃试不静默消失：stderr 点名路径＋meta
    /// index_pending_dropped_total 累计计数（诊断面）。
    /// 返回本路径是否已达弃试阈值并已删行。
    @discardableResult
    public func bumpPendingAttempts(path: String, giveUpAt: Int = 3) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isReadOnlyReplica else { return false }
        let upd = try db.prepare("UPDATE index_pending SET attempts = attempts + 1 WHERE path = ?;")
        try upd.bindText(1, path)
        try upd.run()
        if upd.changes == 0 { return false }
        let sel = try db.prepare("SELECT attempts FROM index_pending WHERE path = ?;")
        try sel.bindText(1, path)
        guard try sel.step() else { return false }
        if Int(sel.int(0)) >= giveUpAt {
            let del = try db.prepare("DELETE FROM index_pending WHERE path = ?;")
            try del.bindText(1, path)
            try del.run()
            try setMetaValueLocked("index_pending_dropped_total",
                                   String(((try? metaValueLocked("index_pending_dropped_total"))
                                       .flatMap { Int($0) } ?? 0) + 1))
            FileHandle.standardError.write(Data(
                "[IndexStore] pending 弃试（attempts≥\(giveUpAt)）: \(path)\n".utf8))
            return true
        }
        return false
    }
}
