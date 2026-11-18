import Foundation
import SQLite3

// MARK: - marks 自有表（单字符 Marks）

/// 一条已落库（或待落库）的书签标记。
public struct BookMark: Equatable, Sendable {
    /// 文档行＝该文件指纹；全局行＝"" 哨兵。
    public var docSHA: String
    /// 单个英文字母（a-zA-Z）。
    public var symbol: String
    /// 全局行记指向哪个文档；文档行恒 nil。
    public var targetDocSHA: String?
    /// 物理页（1 起）。
    public var page: Int
    public var offsetY: Double
    public var zoom: Double?
    public var createdAt: Double
    public var modifiedAt: Double

    public init(docSHA: String, symbol: String, targetDocSHA: String?,
                page: Int, offsetY: Double, zoom: Double?,
                createdAt: Double, modifiedAt: Double) {
        self.docSHA = docSHA
        self.symbol = symbol
        self.targetDocSHA = targetDocSHA
        self.page = page
        self.offsetY = offsetY
        self.zoom = zoom
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

public final class MarksStore {
    /// 子版本键（照 InkStrokesStore.subschemaMetaKey 机制）。
    public static let subschemaMetaKey = "marks_schema_version"
    /// 本实现对应的子版本。
    public static let subschemaVersion = 1

    private let db: SQLiteDatabase
    private let lock = NSLock()

    /// init internal：SQLiteDatabase 是模内类型（调用方与 Core 同模块——
    /// iOS 单模块直编 / 合成测试 @testable；InkStrokesStore.init(db:) 同规）。
    init(db: SQLiteDatabase) {
        self.db = db
        lock.lock()
        defer { lock.unlock() }
        migrateIfNeededLocked()
    }

    /// 桌面跨模块调用方签名（照 HighlightStore.convenience init(indexStore:)
    public convenience init(indexStore: IndexStore) {
        self.init(db: indexStore.db)
    }

    // MARK: DDL / 子版本

    private func migrateIfNeededLocked() {
        _ = db.tryExec("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        _ = db.tryExec("""
        CREATE TABLE IF NOT EXISTS marks(
            doc_sha TEXT NOT NULL,
            symbol TEXT NOT NULL,
            target_doc_sha TEXT,
            page INTEGER NOT NULL,
            offset_y REAL NOT NULL DEFAULT 0,
            zoom REAL,
            created_at REAL NOT NULL,
            modified_at REAL NOT NULL,
            PRIMARY KEY(doc_sha, symbol)
        );
        """)
        _ = db.tryExec("CREATE INDEX IF NOT EXISTS idx_marks_target ON marks(target_doc_sha);")
        setSubschemaVersionLocked(Self.subschemaVersion)
    }

    private func setSubschemaVersionLocked(_ v: Int) {
        guard let stmt = try? db.prepare(
            "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;") else { return }
        try? stmt.bindText(1, Self.subschemaMetaKey)
        try? stmt.bindText(2, String(v))
        try? stmt.run()
    }

    public var storedSubschemaVersion: Int? {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = try? db.prepare("SELECT value FROM meta WHERE key = ?;") else { return nil }
        try? stmt.bindText(1, Self.subschemaMetaKey)
        guard (try? stmt.step()) == true else { return nil }
        return stmt.textOrNull(0).flatMap { Int($0) }
    }

    // MARK: 校验

    /// symbol 必须是单个英文字母（a-zA-Z），其余拒绝抛错（fail-closed）。
    /// 大小写决定行形态（见头注）；docSHA/target 按形态归一并校验。
    static func validateSymbol(_ symbol: String) throws {
        // isASCII + isLetter 的交集恰为 a-zA-Z（其余 letter 系 Unicode 全集）。
        guard symbol.count == 1, let first = symbol.first,
              first.isASCII, first.isLetter else {
            throw StoreError("symbol 必须是单个英文字母（a-zA-Z）：\"\(symbol)\"")
        }
    }

    struct StoreError: Error, CustomStringConvertible {
        let message: String
        init(_ m: String) { message = m }
        var description: String { message }
    }

    // MARK: 写路径

    /// 设标。INSERT OR REPLACE：PK 冲突＝覆盖（vim 重设语义），modified_at
    /// 更新。symbol 大小写决定行形态：小写 → docSHA 必填、target 强制 nil；
    /// 大写 → doc_sha 强制 '' 哨兵、targetDocSHA 必填（指向哪个文档）。
    public func set(_ mark: BookMark, at timestamp: Double? = nil) throws {
        try Self.validateSymbol(mark.symbol)
        // validateSymbol 已保证恰一字符；first 在此恒非 nil（?? 分支不可达）。
        let isGlobal = mark.symbol.first?.isUppercase ?? false
        var normalized = mark
        if isGlobal {
            guard let target = mark.targetDocSHA, !target.isEmpty else {
                throw StoreError("大写（全局）标记必须携带 target_doc_sha（指向哪个文档）")
            }
            normalized.docSHA = ""
        } else {
            guard !mark.docSHA.isEmpty else {
                throw StoreError("小写（文档）标记必须携带 doc_sha")
            }
            normalized.targetDocSHA = nil
        }
        let now = timestamp ?? Date().timeIntervalSince1970
        // 加锁必须先于 readLocked——读改写
        // （查既有 created_at → INSERT OR REPLACE）整体在锁内，否则并发
        // set 与读路径竞争同一连接。覆盖（PK 冲突）时保留原 created_at
        // （set 只更新 modified_at）；新行两者同为 now。
        lock.lock(); defer { lock.unlock() }
        let createdAt: Double
        if let existing = try readLocked(docSHA: normalized.docSHA, symbol: normalized.symbol) {
            createdAt = existing.createdAt
        } else {
            createdAt = now
        }
        normalized.createdAt = createdAt
        normalized.modifiedAt = now
        let stmt = try db.prepare("""
            INSERT OR REPLACE INTO marks(doc_sha, symbol, target_doc_sha, page, offset_y, zoom,
                                         created_at, modified_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?);
            """)
        try stmt.bindText(1, normalized.docSHA)
        try stmt.bindText(2, normalized.symbol)
        if let target = normalized.targetDocSHA {
            try stmt.bindText(3, target)
        } else {
            try stmt.bindNull(3)
        }
        try stmt.bindInt(4, Int64(normalized.page))
        try stmt.bindDouble(5, normalized.offsetY)
        if let zoom = normalized.zoom {
            try stmt.bindDouble(6, zoom)
        } else {
            try stmt.bindNull(6)
        }
        try stmt.bindDouble(7, normalized.createdAt)
        try stmt.bindDouble(8, normalized.modifiedAt)
        try stmt.run()
    }

    /// 删除。不存在抛错（照 HighlightStore.delete(id:) 报错风格）。
    public func delete(docSHA: String, symbol: String) throws {
        try Self.validateSymbol(symbol)
        let key = Self.rowKey(docSHA: docSHA, symbol: symbol)
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("DELETE FROM marks WHERE doc_sha = ? AND symbol = ?;")
        try stmt.bindText(1, key.docSHA)
        try stmt.bindText(2, key.symbol)
        try stmt.run()
        guard stmt.changes > 0 else {
            throw StoreError("标记不存在：doc_sha=\(key.docSHA) symbol=\(key.symbol)")
        }
    }

    // MARK: 读路径

    /// 取单条。查询分支：小写查 (doc_sha, lower)，
    /// 大写查 ('', upper)。未命中返回 nil（不猜）。
    public func mark(docSHA: String, symbol: String) throws -> BookMark? {
        try Self.validateSymbol(symbol)
        lock.lock(); defer { lock.unlock() }
        return try readLocked(docSHA: docSHA, symbol: symbol)
    }

    /// 某文档的全部标记＝文档行（doc_sha=该指纹）＋指向它的全局行
    /// （doc_sha='' AND target_doc_sha=该指纹），按 symbol 序。
    public func allMarks(docSHA: String) throws -> [BookMark] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("""
            SELECT doc_sha, symbol, target_doc_sha, page, offset_y, zoom, created_at, modified_at
            FROM marks
            WHERE doc_sha = ? OR (doc_sha = '' AND target_doc_sha = ?)
            ORDER BY symbol ASC;
            """)
        try stmt.bindText(1, docSHA)
        try stmt.bindText(2, docSHA)
        return try readRowsLocked(stmt)
    }

    public func bookID(fingerprint: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare(
            "SELECT id FROM books WHERE fingerprint = ? OR first_fingerprint = ? LIMIT 1;")
        try stmt.bindText(1, fingerprint)
        try stmt.bindText(2, fingerprint)
        guard try stmt.step() else { return nil }
        return stmt.textOrNull(0)
    }

    /// 全量行数（测试/诊断用）。
    public func totalRowCount() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("SELECT COUNT(*) FROM marks;")
        guard try stmt.step() else { return 0 }
        return Int(stmt.int(0))
    }

    // MARK: 私有

    /// 行形态归一（大小写 → (doc_sha, symbol) 实际键）。
    private static func rowKey(docSHA: String, symbol: String) -> (docSHA: String, symbol: String) {
        // 调用方已经 validateSymbol（恰一字符）；空串防御式回退文档行。
        guard let first = symbol.first else { return (docSHA, symbol) }
        return first.isUppercase ? ("", symbol) : (docSHA, symbol)
    }

    private func readLocked(docSHA: String, symbol: String) throws -> BookMark? {
        let key = Self.rowKey(docSHA: docSHA, symbol: symbol)
        let stmt = try db.prepare("""
            SELECT doc_sha, symbol, target_doc_sha, page, offset_y, zoom, created_at, modified_at
            FROM marks WHERE doc_sha = ? AND symbol = ? LIMIT 1;
            """)
        try stmt.bindText(1, key.docSHA)
        try stmt.bindText(2, key.symbol)
        let rows = try readRowsLocked(stmt)
        return rows.first
    }

    private func readRowsLocked(_ stmt: SQLiteDatabase.Statement) throws -> [BookMark] {
        var out: [BookMark] = []
        while try stmt.step() {
            guard let docSHA = stmt.textOrNull(0), let symbol = stmt.textOrNull(1) else { continue }
            let page = Int(stmt.int(3))
            let offsetY = stmt.double(4)
            let zoom = stmt.textOrNull(5) != nil ? stmt.double(5) : nil
            out.append(BookMark(
                docSHA: docSHA,
                symbol: symbol,
                targetDocSHA: stmt.textOrNull(2),
                page: page,
                offsetY: offsetY,
                zoom: zoom,
                createdAt: stmt.double(6),
                modifiedAt: stmt.double(7)))
        }
        return out
    }
}
