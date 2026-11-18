import Foundation
import SQLite3

/// Capabilities of the SQLite build we are linked against.
/// Everything is *probed at runtime* — never assumed.
public struct FTS5Capabilities: Equatable, CustomStringConvertible {
    public let sqliteVersion: String
    public let fts5: Bool
    public let trigramTokenizer: Bool
    public let unicode61Tokenizer: Bool

    public var description: String {
        "FTS5Capabilities(sqlite=\(sqliteVersion), fts5=\(fts5), trigram=\(trigramTokenizer), unicode61=\(unicode61Tokenizer))"
    }
}

public enum FTS5ProbeError: Error, CustomStringConvertible {
    case cannotOpenMemoryDatabase(String)
    case description(String)

    public var description: String {
        switch self {
        case .cannotOpenMemoryDatabase(let m): return "cannot open in-memory SQLite: \(m)"
        case .description(let m): return m
        }
    }
}

/// Probes SQLite FTS5 availability on an in-memory database.
/// The probe is side-effect free and must run before opening an index store
/// so the store can choose FTS5 or the LIKE fallback and record the decision.
public enum FTS5Probe {
    public static func probe() throws -> FTS5Capabilities {
        var db: OpaquePointer?
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(db)
            throw FTS5ProbeError.cannotOpenMemoryDatabase(msg)
        }
        defer { sqlite3_close_v2(db) }
        let version = String(cString: sqlite3_libversion())
        return FTS5Capabilities(
            sqliteVersion: version,
            fts5: tryExec(db, "CREATE VIRTUAL TABLE probe_fts USING fts5(x)"),
            trigramTokenizer: tryExec(db, "CREATE VIRTUAL TABLE probe_tri USING fts5(x, tokenize='trigram')"),
            unicode61Tokenizer: tryExec(db, "CREATE VIRTUAL TABLE probe_u61 USING fts5(x, tokenize='unicode61')")
        )
    }

    public static func probeOrDefault() -> FTS5Capabilities {
        (try? probe()) ?? FTS5Capabilities(sqliteVersion: "unavailable", fts5: false, trigramTokenizer: false, unicode61Tokenizer: false)
    }

    private static func tryExec(_ db: OpaquePointer?, _ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if let err { sqlite3_free(err) }
        return rc == SQLITE_OK
    }
}
