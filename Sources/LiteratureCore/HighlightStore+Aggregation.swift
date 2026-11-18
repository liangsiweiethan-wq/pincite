import Foundation

// MARK: - 批注聚合查询层（跨书分页 / created_at 区间 / 软删恢复）

extension HighlightStore {

    // MARK: 计数与分页

    /// 全库未删批注总数（deleted_at IS NULL）。
    public func allHighlightsCount() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("""
            SELECT COUNT(*) FROM user_highlights WHERE deleted_at IS NULL;
            """)
        var count = 0
        if try stmt.step() { count = Int(stmt.int(0)) }
        return count
    }

    /// 跨书全量批注，稳定分页序：created_at DESC、同秒写入按 id DESC 决序。
    /// `limit <= 0` 与 `offset < 0` 抛 HighlightError（照 add 的校验风格）。
    /// `viewSource`：nil = 不过滤；否则按视图来源过滤（'ocr'/'original'）。
    public func allHighlights(limit: Int, offset: Int,
                              viewSource: String? = nil) throws -> [UserHighlight] {
        try validateWindow(limit: limit, offset: offset)
        lock.lock(); defer { lock.unlock() }
        var sql = """
            SELECT id, book_id, page_number, utf16_start, utf16_end, color, note, created_at, anchor_text, anchor_verified, style, view_source
            FROM user_highlights
            WHERE deleted_at IS NULL
            """
        if viewSource != nil { sql += " AND view_source = ?" }
        sql += "\n            ORDER BY created_at DESC, id DESC\n            LIMIT ? OFFSET ?;"
        return try queryLocked(sql) { stmt in
            var index: Int32 = 1
            if let viewSource { try stmt.bindText(index, Self.normalizedViewSource(viewSource)); index += 1 }
            try stmt.bindInt(index, Int64(limit)); index += 1
            try stmt.bindInt(index, Int64(offset))
        }
    }

    /// 每书批注计数（聚合分组头用）：total = 未删行数；withNote = 其中 note
    /// 非空的行数。分组顺序按 SQLite 返回序（book_id 升序的索引序不保证，
    /// 调用方按需排序展示）。
    public func highlightsByBookCounts() throws -> [(bookID: String, total: Int, withNote: Int)] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("""
            SELECT book_id, COUNT(*), SUM(note != '')
            FROM user_highlights
            WHERE deleted_at IS NULL
            GROUP BY book_id;
            """)
        var out: [(bookID: String, total: Int, withNote: Int)] = []
        while try stmt.step() {
            out.append((bookID: stmt.text(0), total: Int(stmt.int(1)), withNote: Int(stmt.int(2))))
        }
        return out
    }

    // MARK: created_at 时间线（每日回顾）

    /// created_at 闭开区间查询：`>= from AND < to`；nil 边界 = 不设限。
    /// 排序与分页语义同 allHighlights。
    public func highlightsCreated(from: Date?, to: Date?,
                                  limit: Int, offset: Int) throws -> [UserHighlight] {
        try validateWindow(limit: limit, offset: offset)
        lock.lock(); defer { lock.unlock() }
        var clauses = ["deleted_at IS NULL"]
        if from != nil { clauses.append("created_at >= ?") }
        if to != nil { clauses.append("created_at < ?") }
        let sql = """
            SELECT id, book_id, page_number, utf16_start, utf16_end, color, note, created_at, anchor_text, anchor_verified, style, view_source
            FROM user_highlights
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY created_at DESC, id DESC
            LIMIT ? OFFSET ?;
            """
        return try queryLocked(sql) { stmt in
            var index: Int32 = 1
            if let from { try stmt.bindDouble(index, from.timeIntervalSince1970); index += 1 }
            if let to { try stmt.bindDouble(index, to.timeIntervalSince1970); index += 1 }
            try stmt.bindInt(index, Int64(limit)); index += 1
            try stmt.bindInt(index, Int64(offset))
        }
    }

    public func highlightsCreatedCount(from: Date?, to: Date?) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var clauses = ["deleted_at IS NULL"]
        if from != nil { clauses.append("created_at >= ?") }
        if to != nil { clauses.append("created_at < ?") }
        let stmt = try db.prepare("""
            SELECT COUNT(*) FROM user_highlights WHERE \(clauses.joined(separator: " AND "));
            """)
        var index: Int32 = 1
        if let from { try stmt.bindDouble(index, from.timeIntervalSince1970); index += 1 }
        if let to { try stmt.bindDouble(index, to.timeIntervalSince1970); index += 1 }
        var count = 0
        if try stmt.step() { count = Int(stmt.int(0)) }
        return count
    }

    // MARK: 软删与恢复（删除撤销的存储侧）

    /// 软删：deleted_at 置当前时间（墓碑）。行不存在或已是墓碑 → 抛错
    /// （照 delete(id:) 的 changes==0 报错风格）。**不做二次硬删**。
    public func softDelete(id: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("""
            UPDATE user_highlights SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL;
            """)
        defer { stmt.reset() }
        try stmt.bindDouble(1, Date().timeIntervalSince1970)
        try stmt.bindInt(2, id)
        try stmt.run()
        guard stmt.changes > 0 else { throw HighlightError("no deletable highlight with id \(id)") }
    }

    /// 恢复：清空墓碑（撤销窗口内「撤销」）。行不存在或未删 → 抛错。
    public func restore(id: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("""
            UPDATE user_highlights SET deleted_at = NULL WHERE id = ? AND deleted_at IS NOT NULL;
            """)
        defer { stmt.reset() }
        try stmt.bindInt(1, id)
        try stmt.run()
        guard stmt.changes > 0 else { throw HighlightError("no tombstoned highlight with id \(id)") }
    }

    // MARK: 子 schema 版本（批量导出 state 随录用）

    /// 读 user_highlights 子 schema 版本（meta 表；无记录回 0）。只读。
    public func userHighlightsSubSchemaVersion() -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = try? db.prepare("""
            SELECT value FROM meta WHERE key = ?;
            """) else { return 0 }
        do {
            try stmt.bindText(1, Self.subschemaMetaKey)
            if try stmt.step() { return Int(stmt.text(0)) ?? 0 }
        } catch { return 0 }
        return 0
    }

    // MARK: 分页窗口校验与纯函数

    private func validateWindow(limit: Int, offset: Int) throws {
        guard limit > 0 else {
            throw HighlightError("invalid limit \(limit) (must be > 0)")
        }
        guard offset >= 0 else {
            throw HighlightError("invalid offset \(offset) (must be >= 0)")
        }
    }
}

// MARK: - 摘录板分组纯函数

//[UserHighlight] → 按书分组。保持输入序（查询的 created_at DESC 全序）；
/// 组间序 = 各组首个元素的出现序。`knownBookIDs` 提供时，不在册的 bookID
/// 归入保留组（bookID = ""，视图层渲「未知来源」），行绝不丢弃——聚合只是
public enum UserHighlightGrouper {
    public static func group(_ items: [UserHighlight],
                             knownBookIDs: Set<String>? = nil) -> [(bookID: String, items: [UserHighlight])] {
        var order: [String] = []
        var buckets: [String: [UserHighlight]] = [:]
        for h in items {
            let key = (knownBookIDs?.contains(h.bookID) == false) ? "" : h.bookID
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(h)
        }
        return order.map { (bookID: $0, items: buckets[$0] ?? []) }
    }
}
