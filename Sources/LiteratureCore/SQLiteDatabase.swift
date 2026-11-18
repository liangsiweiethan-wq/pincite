import Foundation
import SQLite3

/// Thin, dependency-free wrapper over the SQLite3 C API.
/// Not thread-safe by itself; `IndexStore` serializes access.
final class SQLiteDatabase {
    enum SQLiteError: Error, CustomStringConvertible {
        case open(String)
        case exec(String, String)
        case prepare(String, String)
        case step(String, String)
        case bind(String, String)

        var description: String {
            switch self {
            case .open(let m): return "sqlite open failed: \(m)"
            case .exec(let sql, let m): return "sqlite exec failed [\(sql)]: \(m)"
            case .prepare(let sql, let m): return "sqlite prepare failed [\(sql)]: \(m)"
            case .step(let sql, let m): return "sqlite step failed [\(sql)]: \(m)"
            case .bind(let sql, let m): return "sqlite bind failed [\(sql)]: \(m)"
            }
        }
    }

    private var db: OpaquePointer?
    let path: String

    convenience init(path: String) throws {
        try self.init(path: path,
                      flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
    }

    /// 只读打开 flags（快照源库专用；调用方无须触碰 SQLite3 C 符号）。
    static let readOnlyFlags: Int32 = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX

    /// 显式 flags 打开（快照源库专用只读形态——
    /// 「快照进程对主库只读」靠 SQLITE_OPEN_READONLY 在句柄层保证，
    /// 绝不回退读写打开；只读连接的 VACUUM INTO 仅写目标文件。
    init(path: String, flags: Int32) throws {
        self.path = path
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(handle)
            throw SQLiteError.open(msg)
        }
        self.db = handle
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    var lastErrorMessage: String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database" }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? lastErrorMessage
            if let err { sqlite3_free(err) }
            throw SQLiteError.exec(sql, msg)
        }
        if let err { sqlite3_free(err) }
    }

    /// True when the statement executed successfully; never throws.
    @discardableResult
    func tryExec(_ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if let err { sqlite3_free(err) }
        return rc == SQLITE_OK
    }

    final class Statement {
        private let stmt: OpaquePointer
        private let db: OpaquePointer?
        let sql: String
        fileprivate init(db: OpaquePointer?, sql: String) throws {
            self.db = db
            self.sql = sql
            var handle: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &handle, nil) == SQLITE_OK, let handle else {
                let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
                throw SQLiteError.prepare(sql, msg)
            }
            self.stmt = handle
        }
        deinit { sqlite3_finalize(stmt) }

        func bindText(_ index: Int32, _ value: String) throws {
            guard sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
                throw SQLiteError.bind(sql, SQLiteDatabase.errMsg(db))
            }
        }
        func bindBlob(_ index: Int32, _ value: Data) throws {
            let rc = value.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
            }
            guard rc == SQLITE_OK else { throw SQLiteError.bind(sql, SQLiteDatabase.errMsg(db)) }
        }
        func bindInt(_ index: Int32, _ value: Int64) throws {
            guard sqlite3_bind_int64(stmt, index, value) == SQLITE_OK else {
                throw SQLiteError.bind(sql, SQLiteDatabase.errMsg(db))
            }
        }
        func bindDouble(_ index: Int32, _ value: Double) throws {
            guard sqlite3_bind_double(stmt, index, value) == SQLITE_OK else {
                throw SQLiteError.bind(sql, SQLiteDatabase.errMsg(db))
            }
        }
        func bindNull(_ index: Int32) throws {
            guard sqlite3_bind_null(stmt, index) == SQLITE_OK else {
                throw SQLiteError.bind(sql, SQLiteDatabase.errMsg(db))
            }
        }

        /// Advances one step. Returns true while a row is available.
        func step() throws -> Bool {
            let rc = sqlite3_step(stmt)
            switch rc {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw SQLiteError.step(sql, SQLiteDatabase.errMsg(db))
            }
        }

        /// Runs to completion (for INSERT/UPDATE/DELETE).
        func run() throws {
            while try step() {}
        }

        func reset() { sqlite3_reset(stmt) }
        func clearBindings() { sqlite3_clear_bindings(stmt) }

        var columnCount: Int32 { sqlite3_column_count(stmt) }
        /// 批注加密：原始列类型（SQLITE_INTEGER/TEXT/BLOB/NULL…）。加密
        /// 批注以 BLOB 形态落 TEXT 列（SQLite 动态类型），读侧以此区分
        /// 密文 BLOB 与既有明文 TEXT，不做首字节猜测。
        func columnType(_ index: Int32) -> Int32 {
            sqlite3_column_type(stmt, index)
        }
        func text(_ index: Int32) -> String {
            guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return "" }
            return String(cString: sqlite3_column_text(stmt, index))
        }
        func textOrNull(_ index: Int32) -> String? {
            guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
            return String(cString: sqlite3_column_text(stmt, index))
        }
        func blob(_ index: Int32) -> Data {
            guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return Data() }
            guard let bytes = sqlite3_column_blob(stmt, index) else { return Data() }
            let count = Int(sqlite3_column_bytes(stmt, index))
            return Data(bytes: bytes.assumingMemoryBound(to: UInt8.self), count: count)
        }
        func int(_ index: Int32) -> Int64 {
            sqlite3_column_int64(stmt, index)
        }
        func intOrNull(_ index: Int32) -> Int64? {
            guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
            return sqlite3_column_int64(stmt, index)
        }
        func double(_ index: Int32) -> Double {
            sqlite3_column_double(stmt, index)
        }
        var changes: Int { Int(sqlite3_changes(db)) }
        var lastInsertRowid: Int64 { sqlite3_last_insert_rowid(db) }
    }

    func prepare(_ sql: String) throws -> Statement {
        try Statement(db: db, sql: sql)
    }

    private static func errMsgOf(_ db: OpaquePointer?) -> String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }

    fileprivate static func errMsg(_ db: OpaquePointer?) -> String {
        errMsgOf(db)
    }
}

/// SQLITE_TRANSIENT: make SQLite copy bound values.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
