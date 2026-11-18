import Foundation
import SQLite3

// MARK: - sessions 自有表（会话恢复）

/// 一行会话账目（tab 槽位）。
public struct SessionRow: Equatable, Sendable {
    /// 槽位序（0 起；主键）。
    public var tabIndex: Int
    /// 'pdf'｜'workbench'（还原按此多态分派；未知值读回时如实跳过）。
    public var tabType: String
    /// 主文档 bookID（workbench 行＝主视图文档）。
    public var bookID: String
    /// 对照文档 bookID（仅 workbench 行非 nil）。
    public var secondaryBookID: String?
    /// 主文档文件指纹（打开时已知则填；nil = 未采集，不猜）。
    public var docSHA: String?
    /// 视图来源（DDL 默认 'ocr'；与 HighlightStore.viewSource 语义族一致）。
    public var viewSource: String
    /// 物理页（1 起；存储层不 clamp——坏值如实落库如实读回，测试断言固定）。
    public var page: Int
    /// 活动签（全表至多一行 true——由 SessionLedger.activated 保证）。
    public var isActive: Bool
    public var updatedAt: Double

    public init(tabIndex: Int, tabType: String, bookID: String,
                secondaryBookID: String? = nil, docSHA: String? = nil,
                viewSource: String = "ocr", page: Int = 1,
                isActive: Bool = false, updatedAt: Double) {
        self.tabIndex = tabIndex
        self.tabType = tabType
        self.bookID = bookID
        self.secondaryBookID = secondaryBookID
        self.docSHA = docSHA
        self.viewSource = viewSource
        self.page = page
        self.isActive = isActive
        self.updatedAt = updatedAt
    }
}

public final class ReadingSessionStore {
    /// 子版本键（照 InkStrokesStore/MarksStore 机制）。
    public static let subschemaMetaKey = "reading_sessions_schema_version"
    /// 本实现对应的子版本。
    public static let subschemaVersion = 1
    /// 已知 tab_type（还原分派面；表外值跳过不崩）。
    public static let knownTabTypes: Set<String> = ["pdf", "workbench"]

    private let db: SQLiteDatabase
    private let lock = NSLock()

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
        CREATE TABLE IF NOT EXISTS sessions(
            tab_index INTEGER PRIMARY KEY,
            tab_type TEXT NOT NULL,
            book_id TEXT NOT NULL,
            secondary_book_id TEXT,
            doc_sha TEXT,
            view_source TEXT NOT NULL DEFAULT 'ocr',
            page INTEGER NOT NULL DEFAULT 1,
            is_active INTEGER NOT NULL DEFAULT 0,
            updated_at REAL NOT NULL
        );
        """)
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

    // MARK: 写路径

    /// 单事务整表替换（照 HighlightStore.performWriteTransaction: 183 语义
    /// BEGIN IMMEDIATE → DELETE + INSERTs → COMMIT；中途抛错 ROLLBACK 整批
    /// 原子）。自持事务，调用方无须持锁。
    public func writeSession(_ rows: [SessionRow]) throws {
        lock.lock(); defer { lock.unlock() }
        try db.exec("BEGIN IMMEDIATE;")
        do {
            let del = try db.prepare("DELETE FROM sessions;")
            try del.run()
            let stmt = try db.prepare("""
                INSERT INTO sessions(tab_index, tab_type, book_id, secondary_book_id, doc_sha,
                                     view_source, page, is_active, updated_at)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?);
                """)
            for row in rows {
                stmt.reset()
                try stmt.bindInt(1, Int64(row.tabIndex))
                try stmt.bindText(2, row.tabType)
                try stmt.bindText(3, row.bookID)
                if let sec = row.secondaryBookID {
                    try stmt.bindText(4, sec)
                } else {
                    try stmt.bindNull(4)
                }
                if let sha = row.docSHA {
                    try stmt.bindText(5, sha)
                } else {
                    try stmt.bindNull(5)
                }
                try stmt.bindText(6, row.viewSource)
                try stmt.bindInt(7, Int64(row.page))
                try stmt.bindInt(8, row.isActive ? 1 : 0)
                try stmt.bindDouble(9, row.updatedAt)
                try stmt.run()
            }
            try db.exec("COMMIT;")
        } catch {
            db.tryExec("ROLLBACK;")
            throw error
        }
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("DELETE FROM sessions;")
        try stmt.run()
    }

    // MARK: 读路径

    public func readSession() throws -> [SessionRow] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("""
            SELECT tab_index, tab_type, book_id, secondary_book_id, doc_sha,
                   view_source, page, is_active, updated_at
            FROM sessions ORDER BY tab_index ASC;
            """)
        var out: [SessionRow] = []
        while try stmt.step() {
            guard let tabType = stmt.textOrNull(1),
                  let bookID = stmt.textOrNull(2),
                  !bookID.isEmpty else { continue }
            guard Self.knownTabTypes.contains(tabType) else { continue }
            let viewSource = stmt.textOrNull(5) ?? "ocr"
            out.append(SessionRow(
                tabIndex: Int(stmt.int(0)),
                tabType: tabType,
                bookID: bookID,
                secondaryBookID: stmt.textOrNull(3),
                docSHA: stmt.textOrNull(4),
                viewSource: viewSource,
                page: Int(stmt.int(6)),
                isActive: stmt.int(7) != 0,
                updatedAt: stmt.double(8)))
        }
        return out
    }
}

// MARK: - SessionLedger（Core 纯值类型）
//
// 会话账本：App 层只做薄接线（open/select/close/openWorkbench 各一行记账），
// 全部推导逻辑在此可测。条目有序（=tab 序）；active 唯一。

/// 会话账本（纯值类型；无 I/O，测试直接覆盖）。
public struct SessionLedger: Equatable, Sendable {
    /// 一条账目。tabType 取 SessionRow 同款词表（'pdf'｜'workbench'）。
    public struct Entry: Equatable, Sendable {
        public var tabType: String
        public var bookID: String
        public var secondaryBookID: String?
        public var isActive: Bool

        public init(tabType: String, bookID: String,
                    secondaryBookID: String? = nil, isActive: Bool = false) {
            self.tabType = tabType
            self.bookID = bookID
            self.secondaryBookID = secondaryBookID
            self.isActive = isActive
        }
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    /// 打开（append 或 move-to-end＋去重）：同 (tabType, bookID, secondary)
    /// 条目已存在则移到末尾（保序语义：最近使用在后），否则追加。
    /// isActive 不变（激活是另一动作）。
    public mutating func opened(_ bookID: String, secondary: String? = nil,
                                tabType: String = "pdf") {
        let key = Self.key(tabType: tabType, bookID: bookID, secondary: secondary)
        if let idx = entries.firstIndex(where: {
            Self.key(tabType: $0.tabType, bookID: $0.bookID, secondary: $0.secondaryBookID) == key
        }) {
            let moved = entries.remove(at: idx)
            entries.append(moved)
        } else {
            entries.append(Entry(tabType: tabType, bookID: bookID,
                                 secondaryBookID: secondary, isActive: false))
        }
    }

    /// 关闭：移除该 (tabType, bookID) 的条目。
    /// 出账必须分 tabType——主窗口关一本 PDF 不应连带清掉同书作为主文档的
    /// workbench 行（两 tab 各自独立出账）；secondary 不联动（对照窗的出账
    /// 由它自己的关闭动作负责）。
    public mutating func closed(_ bookID: String, tabType: String = "pdf") {
        entries.removeAll { $0.bookID == bookID && $0.tabType == tabType }
    }

    /// 激活：(tabType, bookID) 匹配的首个条目置 active，其余全清（active
    public mutating func activated(_ bookID: String, tabType: String = "pdf") {
        var hit = false
        for idx in entries.indices {
            if !hit, entries[idx].bookID == bookID, entries[idx].tabType == tabType {
                entries[idx].isActive = true
                hit = true
            } else {
                entries[idx].isActive = false
            }
        }
    }

    /// 组行输出（纯函数）：positions＝bookID → 当前物理页（App 层从
    /// ReadingPositionStore.position(for:).page 读现值传入；缺页缺档回 1）。
    /// updatedAt 由调用方传入（纯函数不取时钟，测试可断言固定）。
    public func rows(positions: [String: Int], updatedAt: Double) -> [SessionRow] {
        entries.enumerated().map { index, entry in
            SessionRow(
                tabIndex: index,
                tabType: entry.tabType,
                bookID: entry.bookID,
                secondaryBookID: entry.secondaryBookID,
                viewSource: "ocr",
                page: positions[entry.bookID] ?? 1,
                isActive: entry.isActive,
                updatedAt: updatedAt)
        }
    }

    private static func key(tabType: String, bookID: String,
                            secondary: String?) -> String {
        "\(tabType)|\(bookID)|\(secondary ?? "-")"
    }
}
