import Foundation

// MARK: - 稳定页码：page_map 表（physical → printed 声明制映射）

extension IndexStore {
    /// 迁移链新增一步（init → migrate 内、migrateDailyQuotes
    func migrateSchemaV6() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS page_map(
            book_id TEXT NOT NULL,
            physical_page INTEGER NOT NULL,
            printed_page INTEGER NOT NULL,
            source_edition TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL,
            PRIMARY KEY(book_id, physical_page)
        );
        """)
    }

    /// upsert 单行（PK 冲突即覆盖该行——导入重复行在解析层已拒，此处
    /// upsert 服务于重导同书换正的场景）。
    public func upsertPageMap(bookID: String, physical: Int, printed: Int,
                              sourceEdition: String) throws {
        lock.lock(); defer { lock.unlock() }
        try upsertPageMapLocked(bookID: bookID, physical: physical,
                                printed: printed, sourceEdition: sourceEdition)
    }

    private func upsertPageMapLocked(bookID: String, physical: Int, printed: Int,
                                     sourceEdition: String) throws {
        let stmt = try db.prepare("""
        INSERT INTO page_map(book_id, physical_page, printed_page, source_edition, created_at)
        VALUES(?,?,?,?,?)
        ON CONFLICT(book_id, physical_page)
        DO UPDATE SET printed_page=excluded.printed_page, source_edition=excluded.source_edition;
        """)
        try stmt.bindText(1, bookID)
        try stmt.bindInt(2, Int64(physical))
        try stmt.bindInt(3, Int64(printed))
        try stmt.bindText(4, sourceEdition)
        try stmt.bindInt(5, Int64(Date().timeIntervalSince1970))
        try stmt.run()
    }

    /// page_map 单页查询（服务第一路）。无行 → nil。
    public func pageMapPrinted(bookID: String, physical: Int) throws -> Int? {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare(
            "SELECT printed_page FROM page_map WHERE book_id = ? AND physical_page = ?;")
        try stmt.bindText(1, bookID)
        try stmt.bindInt(2, Int64(physical))
        if try stmt.step() {
            return Int(stmt.int(0))
        }
        return nil
    }

    /// pages.printed_page 列单页查询（服务第二路；列值经 import-meta 等既有
    /// 通道写入）。NULL/无行 → nil。
    public func printedPageColumn(bookID: String, physical: Int) throws -> Int? {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare(
            "SELECT printed_page FROM pages WHERE book_id = ? AND page_number = ?;")
        try stmt.bindText(1, bookID)
        try stmt.bindInt(2, Int64(physical))
        if try stmt.step() {
            return stmt.intOrNull(0).map(Int.init)
        }
        return nil
    }

    /// 逐书全行（诊断与测试用）。
    public func pageMapRows(bookID: String) throws -> [(physical: Int, printed: Int, edition: String)] {
        lock.lock(); defer { lock.unlock() }
        var out: [(Int, Int, String)] = []
        let stmt = try db.prepare("""
        SELECT physical_page, printed_page, source_edition FROM page_map
        WHERE book_id = ? ORDER BY physical_page;
        """)
        try stmt.bindText(1, bookID)
        while try stmt.step() {
            out.append((Int(stmt.int(0)), Int(stmt.int(1)), stmt.text(2)))
        }
        return out.map { ($0.0, $0.1, $0.2) }
    }

    /// 删除某书全部映射（重导前清理用；显式调用，无任何自动删除）。
    public func deletePageMap(bookID: String) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("DELETE FROM page_map WHERE book_id = ?;")
        try stmt.bindText(1, bookID)
        try stmt.run()
    }

    /// sidecar 回填写入：只 UPDATE pages.printed_page 为 NULL 的行（非空
    /// 不覆盖）。返回实际回填行数。
    public func backfillPrintedPages(bookID: String,
                                     pairs: [(physical: Int, printed: Int)]) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var backfilled = 0
        let stmt = try db.prepare("""
        UPDATE pages SET printed_page = ?
        WHERE book_id = ? AND page_number = ? AND printed_page IS NULL;
        """)
        for pair in pairs {
            stmt.reset(); stmt.clearBindings()
            try stmt.bindInt(1, Int64(pair.printed))
            try stmt.bindText(2, bookID)
            try stmt.bindInt(3, Int64(pair.physical))
            try stmt.run()
            backfilled += stmt.changes > 0 ? 1 : 0
        }
        return backfilled
    }

    /// 导入管道：解析 → upsert page_map → 回填 printed_page（只填 NULL）。
    /// 与 CLI import-page-map、App 手动入口共用（单一事实路径）。
    @discardableResult
    public func importPageMapSidecar(_ data: Data) throws -> (entries: Int, report: PageMapImportReport) {
        var index: [String: (bookID: String, pageCount: Int)] = [:]
        for book in try allBooks() {
            index[book.fileName] = (book.id, book.pageCount)
        }
        let (entries, report) = try PageMapSidecar.parse(data, books: index)
        lock.lock(); defer { lock.unlock() }
        for entry in entries {
            for pair in entry.pairs {
                try upsertPageMapLocked(bookID: entry.bookID, physical: pair.0,
                                        printed: pair.1, sourceEdition: entry.sourceEdition)
            }
            _ = try backfillPrintedPagesLocked(bookID: entry.bookID, pairs: entry.pairs)
        }
        return (entries.count, report)
    }

    private func backfillPrintedPagesLocked(bookID: String,
                                            pairs: [(physical: Int, printed: Int)]) throws -> Int {
        var backfilled = 0
        let stmt = try db.prepare("""
        UPDATE pages SET printed_page = ?
        WHERE book_id = ? AND page_number = ? AND printed_page IS NULL;
        """)
        for pair in pairs {
            stmt.reset(); stmt.clearBindings()
            try stmt.bindInt(1, Int64(pair.printed))
            try stmt.bindText(2, bookID)
            try stmt.bindInt(3, Int64(pair.physical))
            try stmt.run()
            backfilled += stmt.changes > 0 ? 1 : 0
        }
        return backfilled
    }
}
