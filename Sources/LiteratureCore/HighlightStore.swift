import Foundation
import SQLite3


public enum HighlightColor: String, Codable, CaseIterable, Sendable {
    case yellow, green, blue, red

    /// Fixed friendly presentation values; the app layer converts to NSColor.
    public var colorHex: String {
        switch self {
        case .yellow: return "#F7D774"
        case .green: return "#A8D5A2"
        case .blue: return "#9FC5E8"
        case .red: return "#E8A09A"
        }
    }
}

public struct UserHighlight: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let bookID: String
    public let pageNumber: Int
    public var utf16Start: Int
    public var utf16End: Int
    public var color: HighlightColor
    /// Rendering style: "highlight" (default) or "underline". Stored as TEXT;
    /// unknown legacy values normalize to "highlight" on read.
    public var style: String
    public var note: String
    public let createdAt: Date
    public var anchorText: String
    public var anchorVerified: Int
    /// 高亮所属视图来源（"ocr" 默认视图 / "original" 原件视图）。
    /// 解码兼容旧数据：缺省读回 "ocr"（迁移旧行由 DDL DEFAULT 'ocr' 降级处理）。
    public var viewSource: String

    public init(id: Int64,
                bookID: String,
                pageNumber: Int,
                utf16Start: Int,
                utf16End: Int,
                color: HighlightColor,
                note: String,
                createdAt: Date,
                anchorText: String = "",
                anchorVerified: Int = 0,
                style: String = "highlight",
                viewSource: String = HighlightStore.viewSourceOCR) {
        self.id = id
        self.bookID = bookID
        self.pageNumber = pageNumber
        self.utf16Start = utf16Start
        self.utf16End = utf16End
        self.color = color
        self.note = note
        self.createdAt = createdAt
        self.anchorText = anchorText
        self.anchorVerified = anchorVerified
        self.style = style
        self.viewSource = viewSource
    }
}

public final class HighlightStore {
    public enum HighlightError: Error, CustomStringConvertible {
        case invalidRange(String)
        public var description: String {
            switch self {
            case .invalidRange(let m): return m
            }
        }
        init(_ m: String) { self = .invalidRange(m) }
    }

    /// Sanity cap for utf16 offsets; a single page never approaches this.
    static let maxUTF16Length = 1_000_000

    /// 视图来源常量与归一。'ocr' = 默认视图（OCR 命中的 OCR 文件、
    /// 原生命的原件文件）；'original' = 「查看原件」视图。未知历史值读回 'ocr'。
    public static let viewSourceOCR = "ocr"
    public static let viewSourceOriginal = "original"

    public static func normalizedViewSource(_ raw: String) -> String {
        raw == viewSourceOriginal ? viewSourceOriginal : viewSourceOCR
    }

    /// 改形（init 委托）：直接持连接——可指向 iOS 独立批注库
    /// annotations.db（AppSupportPaths.appDirectory("annotations.db")），
    /// 也可仍为共享的 index.db 连接。indexStore 引用仅用于页文本锚定
    /// 推断（独立库形态下为 nil，推断自然跳过、anchor 留空，fail 语义
    /// 不变）；其余落库路径全部走 db。
    internal let db: SQLiteDatabase
    private let indexStore: IndexStore?
    internal let lock = NSLock()

    /// 主 init：显式连接形态（iOS annotations.db / 测试注入）。
    /// internal：SQLiteDatabase 模内类型——调用方与 Core 同模块（iOS 单模块
    /// 直编 / 合成测试 @testable）；桌面跨模块调用方走旧签名 convenience。
    init(db: SQLiteDatabase, indexStore: IndexStore? = nil) {
        self.db = db
        self.indexStore = indexStore
        // 完整性检查先于迁移 DDL——"表缺失"判定必须在
        // CREATE IF NOT EXISTS 补建之前做出，否则损坏态会被掩盖。
        lock.lock()
        verifyIntegrityOrRestoreLocked()
        lock.unlock()
        migrateSchemaIfNeeded()
        // 批注加密：加密开关开 → 迁移存量明文批注（幂等；失败仅记录，
        // 不问题初始化——下次启动重试，期间读侧走占位基准）。
        migrateNotesIfEncryptionEnabled()
    }

    /// 迁移钩：开关开时把存量明文 note 加密写回（幂等——已是 BLOB 的
    /// 行被 migrateExistingNotes 跳过）。Keychain 失败/迁移失败不抛出：
    /// init 不能因可选增强能力失败而中断，留 meta+stderr 双痕。
    private func migrateNotesIfEncryptionEnabled() {
        guard AnnotationCrypto.isEncryptionEnabled() else { return }
        lock.lock(); defer { lock.unlock() }
        do {
            let key = try AnnotationCrypto.keyProvider()
            let migrated = try AnnotationCrypto.migrateExistingNotes(db: db, key: key)
            if migrated > 0 {
                try? setMetaRaw("highlights_encrypted_migrated_at", String(Int(Date().timeIntervalSince1970)))
                try? setMetaRaw("highlights_encrypted_migrated_count", String(migrated))
                FileHandle.standardError.write(Data("[HighlightStore] 已加密迁移 \(migrated) 条存量批注\n".utf8))
            }
        } catch {
            try? setMetaRaw("highlights_encrypted_migrate_error", "\(error)")
            FileHandle.standardError.write(Data("[HighlightStore] 批注加密迁移失败（保持明文，下次启动重试）: \(error)\n".utf8))
        }
    }

    /// 旧签名保留（调用方零改动）：与索引同库单连接形态。
    public convenience init(indexStore: IndexStore) {
        self.init(db: indexStore.db, indexStore: indexStore)
    }

    /// Meta key recording the user_highlights sub-schema level. IndexStore's
    /// top-level `schema_version` stays at 5 (its migration is untouched);
    /// the style column is tracked under this dedicated key.
    static let subschemaMetaKey = "user_highlights_schema_version"

    // MARK: — 批注库可靠性（显式事务 / 启动完整性检查 / .bak 快照回退）

    /// 滚动备份文件名（与 index.db 同目录；保留最近 1 份，原子覆盖写）。
    static let backupFileName = "user_highlights.bak.json"
    /// 备份载荷格式标识（结构变更时递增，回退侧按格式拒绝不认识的载荷）。
    static let backupFormatID = "literaturesearch-highlights-backup/1"

    /// 备份行（Codable JSON 载荷；字段与 user_highlights 表列一一对应）。
    /// viewSource 为 Optional：前的 /1 备份无此键，decodeIfPresent 降级处理
    /// 为 nil（回退落库时归一为 'ocr'），旧备份回退路径不破。
    /// noteB64 为 Optional（批注加密）：note 列为密文 BLOB 时，密文经
    /// base64 存此键（note 置空串）——任意二进制密文过 JSON 文本通道不失真；
    /// 明文行走 note。旧备份无此键 → nil → 走明文回填（加密开时回填即加密）。
    struct BackupRow: Codable, Equatable {
        var bookID: String
        var pageNumber: Int
        var utf16Start: Int
        var utf16End: Int
        var color: String
        var note: String
        var createdAt: Double
        var anchorText: String
        var anchorVerified: Int
        var style: String
        var viewSource: String? = nil
        var noteB64: String? = nil
    }

    struct BackupPayload: Codable {
        var format: String
        var rows: [BackupRow]
    }

    /// 备份文件完整路径（与 index.db 同目录）。
    var backupFileURL: URL {
        URL(fileURLWithPath: db.path)
            .deletingLastPathComponent()
            .appendingPathComponent(Self.backupFileName)
    }

    /// 显式写事务包装：BEGIN IMMEDIATE → body → COMMIT；body 抛错即
    /// ROLLBACK（整批原子）。调用方必须已持有 `lock`（所有 *Locked 写路径
    /// 经此进入）。单语句写路径（add/update/delete）保持 SQLite 语句级原子，
    /// 不额外包事务。
    func performWriteTransaction<T>(_ body: () throws -> T) throws -> T {
        try db.exec("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try db.exec("COMMIT;")
            return result
        } catch {
            db.tryExec("ROLLBACK;")
            throw error
        }
    }

    /// 单行 INSERT 的共享核心（供 add 与事务批写复用；internal 供测试直接
    /// 构造事务中途失败）。调用方须持锁；事务场景下由此保证批内多条 INSERT
    /// 同生共死。
    func insertRowLocked(_ item: PendingHighlight) throws -> Int64 {
        let stmt = try db.prepare("""
            INSERT INTO user_highlights(book_id, page_number, utf16_start, utf16_end, color, note, created_at, anchor_text, anchor_verified, style, view_source)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
        defer { stmt.reset() }
        try stmt.bindText(1, item.bookID)
        try stmt.bindInt(2, Int64(item.pageNumber))
        try stmt.bindInt(3, Int64(item.utf16Start))
        try stmt.bindInt(4, Int64(item.utf16End))
        try stmt.bindText(5, item.color.rawValue)
        // 批注加密：开关开→密文 BLOB（TEXT 列存 BLOB，动态类型照写）；关→明文。
        try AnnotationCrypto.bind(try AnnotationCrypto.storageValue(forNote: item.note), to: stmt, 6)
        try stmt.bindDouble(7, item.createdAt)
        try stmt.bindText(8, item.anchorText)
        try stmt.bindInt(9, Int64(item.anchorVerified))
        try stmt.bindText(10, item.style)
        try stmt.bindText(11, item.viewSource)
        try stmt.run()
        return stmt.lastInsertRowid
    }

    /// 待写入行（add/addBatch/addVerified 的参数归一形态）。
    struct PendingHighlight {
        var bookID: String
        var pageNumber: Int
        var utf16Start: Int
        var utf16End: Int
        var color: HighlightColor
        var note: String
        var createdAt: Double
        var anchorText: String
        var anchorVerified: Int
        var style: String
        var viewSource: String = HighlightStore.viewSourceOCR
    }

    /// 校验并归一一条待写入行（与 add 的既有校验语义逐字一致）。
    /// `inferVerifiedFromAnchor`：add 的既有乐观语义——提供了 anchor 即
    /// 视为已验证。addVerified 要做真实校验，传 false 关闭推断。
    private func validatedPending(bookID: String, pageNumber: Int, utf16Start: Int, utf16End: Int,
                                  color: HighlightColor, note: String, createdAt: Double? = nil,
                                  anchorText: String, anchorVerified: Int,
                                  style: String, viewSource: String = viewSourceOCR,
                                  inferVerifiedFromAnchor: Bool = true) throws -> PendingHighlight {
        guard utf16Start >= 0, utf16End > utf16Start, utf16End <= Self.maxUTF16Length else {
            throw HighlightError("invalid utf16 range [\(utf16Start), \(utf16End))")
        }
        let finalStyle = style == "underline" ? "underline" : "highlight"
        let finalVerified = anchorVerified != 0 ? anchorVerified
            : (inferVerifiedFromAnchor && !anchorText.isEmpty ? 1 : 0)
        return PendingHighlight(
            bookID: bookID, pageNumber: pageNumber, utf16Start: utf16Start, utf16End: utf16End,
            color: color, note: note, createdAt: createdAt ?? Date().timeIntervalSince1970,
            anchorText: anchorText, anchorVerified: finalVerified, style: finalStyle,
            viewSource: Self.normalizedViewSource(viewSource))
    }

    /// 显式事务批量写入：整批原子（任一条失败全部回滚），提交后滚动一份
    @discardableResult
    public func addBatch(_ items: [(bookID: String, pageNumber: Int, utf16Start: Int, utf16End: Int,
                                    color: HighlightColor, note: String, anchorText: String,
                                    anchorVerified: Int, style: String)],
                         viewSource: String = viewSourceOCR) throws -> [Int64] {
        // 校验全部在事务外完成：任何一条越界都让整批在 BEGIN 之前失败，
        // 不给"半批回滚"留路径。
        let pending = try items.map {
            try validatedPending(bookID: $0.bookID, pageNumber: $0.pageNumber,
                                 utf16Start: $0.utf16Start, utf16End: $0.utf16End,
                                 color: $0.color, note: $0.note,
                                 anchorText: $0.anchorText, anchorVerified: $0.anchorVerified,
                                 style: $0.style, viewSource: viewSource)
        }
        lock.lock(); defer { lock.unlock() }
        let ids = try performWriteTransaction { [self] () -> [Int64] in
            try pending.map { try insertRowLocked($0) }
        }
        writeBackupSnapshotLocked()
        return ids
    }

    /// add+verify 合并的显式事务写路径：同一事务内 INSERT 高亮并写回该
    /// 高亮在给定页文本上的锚定校验结果（成功坐标/失效标记），不留中间态。
    /// 页文本在事务外读好传入（pageText 为 nil 时读一次索引页）。
    @discardableResult
    public func addVerified(bookID: String, pageNumber: Int, utf16Start: Int, utf16End: Int,
                            color: HighlightColor, note: String = "",
                            anchorText: String = "", style: String = "highlight",
                            pageText: String? = nil, viewSource: String = viewSourceOCR) throws -> UserHighlight {
        guard utf16Start >= 0, utf16End > utf16Start, utf16End <= Self.maxUTF16Length else {
            throw HighlightError("invalid utf16 range [\(utf16Start), \(utf16End))")
        }
        // 锚定材料在事务外备齐（读路径不进写事务）。
        var anchor = anchorText
        let original: String?
        if let pageText {
            original = pageText
        } else {
            original = try? indexStore?.page(bookID: bookID, pageNumber: pageNumber)?.textOriginal
        }
        if anchor.isEmpty, let u16 = original?.utf16, utf16Start < u16.count, utf16End <= u16.count {
            let s = u16.index(u16.startIndex, offsetBy: utf16Start)
            let e = u16.index(u16.startIndex, offsetBy: utf16End)
            anchor = String(decoding: u16[s..<e], as: UTF16.self)
        }
        let pending = try validatedPending(bookID: bookID, pageNumber: pageNumber,
                                           utf16Start: utf16Start, utf16End: utf16End,
                                           color: color, note: note,
                                           anchorText: String(anchor.prefix(200)),
                                           anchorVerified: 0, style: style,
                                           viewSource: viewSource,
                                           inferVerifiedFromAnchor: false)
        lock.lock(); defer { lock.unlock() }
        let (id, verified, finalStart, finalEnd): (Int64, Int, Int, Int) = try performWriteTransaction { [self] in
            let rowID = try insertRowLocked(pending)
            var v = pending.anchorVerified
            var st = pending.utf16Start
            var en = pending.utf16End
            if let original {
                let u16 = original.utf16
                let a = pending.anchorText
                if pending.utf16Start >= 0, pending.utf16End <= u16.count, pending.utf16End > pending.utf16Start {
                    let s = u16.index(u16.startIndex, offsetBy: pending.utf16Start)
                    let e = u16.index(u16.startIndex, offsetBy: pending.utf16End)
                    if String(decoding: u16[s..<e], as: UTF16.self) == a {
                        v = 1
                    }
                }
                if v != 1, !a.isEmpty, let found = original.range(of: a) {
                    st = u16.distance(from: u16.startIndex, to: found.lowerBound.samePosition(in: u16) ?? u16.startIndex)
                    en = u16.distance(from: u16.startIndex, to: found.upperBound.samePosition(in: u16) ?? u16.startIndex)
                    v = 1
                }
                if v != 1 { v = -1 }
            }
            if v != pending.anchorVerified || st != pending.utf16Start || en != pending.utf16End {
                        let stmt = try db.prepare("UPDATE user_highlights SET utf16_start=?, utf16_end=?, anchor_verified=? WHERE id=?;")
                try stmt.bindInt(1, Int64(st))
                try stmt.bindInt(2, Int64(en))
                try stmt.bindInt(3, Int64(v))
                try stmt.bindInt(4, rowID)
                try stmt.run()
            }
            return (rowID, v, st, en)
        }
        return UserHighlight(
            id: id, bookID: bookID, pageNumber: pageNumber,
            utf16Start: finalStart, utf16End: finalEnd,
            color: color, note: note, createdAt: Date(timeIntervalSince1970: pending.createdAt),
            anchorText: pending.anchorText, anchorVerified: verified, style: pending.style,
            viewSource: pending.viewSource)
    }

    // MARK: 启动完整性检查与 .bak 回退

    /// 启动完整性检查（init 调用，migrate 之前——表缺失判定必须在 DDL 补建
    private func verifyIntegrityOrRestoreLocked() {
        var tableExists = false
        if let stmt = try? db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='user_highlights';") {
            if let hasRow = try? stmt.step(), hasRow { tableExists = true }
        }
        var verdict = ""
        // 只查本表及其索引：整库 quick_check 对大型索引库要读遍全库，且在主线程执行会让 App 启动卡顿。
        if tableExists, let stmt = try? db.prepare("PRAGMA quick_check(user_highlights);") {
            if let hasRow = try? stmt.step(), hasRow { verdict = stmt.text(0) }
        }
        let healthy = tableExists && verdict == "ok"
        guard !healthy else { return }
        let reason = tableExists ? "PRAGMA quick_check 异常: \(verdict.isEmpty ? "无结果" : verdict)"
                                 : "user_highlights 表缺失（外部删除或存储损坏）"
        if !FileManager.default.fileExists(atPath: backupFileURL.path) {
            // 无备份可回退：如实记录，空表起步（迁移 DDL 随后补建）。
            try? setMetaRaw("highlights_restore_reason", "\(reason)；无 .bak 可回退")
            try? setMetaRaw("highlights_restore_ok", "0")
            try? setMetaRaw("highlights_restore_at", String(Int(Date().timeIntervalSince1970)))
            FileHandle.standardError.write(Data("[HighlightStore] 完整性异常且无备份: \(reason)\n".utf8))
            return
        }
        do {
            let restored = try restoreFromBackupLocked()
            try? setMetaRaw("highlights_restore_reason", reason)
            try? setMetaRaw("highlights_restore_ok", "1")
            try? setMetaRaw("highlights_restore_at", String(Int(Date().timeIntervalSince1970)))
            FileHandle.standardError.write(Data("[HighlightStore] 已从 .bak 回退 \(restored) 条批注（\(reason)）\n".utf8))
        } catch {
            try? setMetaRaw("highlights_restore_reason", "\(reason)；回退失败: \(error)")
            try? setMetaRaw("highlights_restore_ok", "0")
            try? setMetaRaw("highlights_restore_at", String(Int(Date().timeIntervalSince1970)))
            FileHandle.standardError.write(Data("[HighlightStore] .bak 回退失败: \(error)\n".utf8))
        }
    }

    func restoreFromBackupLocked() throws -> Int {
        let data = try Data(contentsOf: backupFileURL)
        let payload = try JSONDecoder().decode(BackupPayload.self, from: data)
        guard payload.format == Self.backupFormatID else {
            throw HighlightError("备份格式不识别: \(payload.format)")
        }
        _ = db.tryExec("DROP TABLE IF EXISTS user_highlights;")
        guard db.tryExec("""
        CREATE TABLE IF NOT EXISTS user_highlights(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            book_id TEXT NOT NULL,
            page_number INTEGER NOT NULL,
            utf16_start INTEGER NOT NULL,
            utf16_end INTEGER NOT NULL,
            color TEXT NOT NULL,
            note TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL,
            anchor_text TEXT NOT NULL DEFAULT '',
            anchor_verified INTEGER NOT NULL DEFAULT 0,
            style TEXT NOT NULL DEFAULT 'highlight',
            view_source TEXT NOT NULL DEFAULT 'ocr'
        );
        CREATE INDEX IF NOT EXISTS idx_user_highlights_book ON user_highlights(book_id, page_number);
        -- 说明：DROP TABLE 连带删索引，重建必须补
        -- created_at 索引（与 migrateSchemaIfNeeded 同条 DDL，幂等）。
        CREATE INDEX IF NOT EXISTS idx_user_highlights_created ON user_highlights(created_at);
        """) else {
            throw HighlightError("重建 user_highlights 的 DDL 执行失败")
        }
        try performWriteTransaction {
            let ins = try db.prepare("""
            INSERT INTO user_highlights(book_id, page_number, utf16_start, utf16_end, color, note, created_at, anchor_text, anchor_verified, style, view_source)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
            for row in payload.rows {
                ins.reset(); ins.clearBindings()
                try ins.bindText(1, row.bookID)
                try ins.bindInt(2, Int64(row.pageNumber))
                try ins.bindInt(3, Int64(row.utf16Start))
                try ins.bindInt(4, Int64(row.utf16End))
                try ins.bindText(5, row.color)
                // 批注加密：noteB64 有值 → 密文原样回填 BLOB（不重加密、不解密——
                // 回退必须逐字节还原）；否则按当前开关归一（明文行加密开时
                // 回填即加密，与「新数据加密」基准一致）。
                if let b64 = row.noteB64, let blob = Data(base64Encoded: b64) {
                    try ins.bindBlob(6, blob)
                } else {
                    try AnnotationCrypto.bind(try AnnotationCrypto.storageValue(forNote: row.note), to: ins, 6)
                }
                try ins.bindDouble(7, row.createdAt)
                try ins.bindText(8, row.anchorText)
                try ins.bindInt(9, Int64(row.anchorVerified))
                try ins.bindText(10, row.style == "underline" ? "underline" : "highlight")
                // 旧 /1 备份无 view_source 键 → nil 归一 'ocr'。
                try ins.bindText(11, Self.normalizedViewSource(row.viewSource ?? Self.viewSourceOCR))
                try ins.run()
            }
        }
        return payload.rows.count
    }

    /// 滚动备份：user_highlights 全表内容 → JSON 原子覆盖写（保留最近 1 份）。
    /// 表缺失（尚未建/刚损坏）时静默跳过——回退源不能被空态覆盖。
    func writeBackupSnapshotLocked() {
        guard let stmt = try? db.prepare("""
            SELECT book_id, page_number, utf16_start, utf16_end, color, note, created_at, anchor_text, anchor_verified, style, view_source
            FROM user_highlights ORDER BY id;
            """) else { return }
        var rows: [BackupRow] = []
        while (try? stmt.step()) == true {
            // 批注加密：note 列按类型分流——BLOB（密文）base64 进 noteB64，过 JSON
            // 不失真；TEXT（明文/空串）照旧。GCM 密文是任意字节，直接
            // text 读会经 UTF-8 有损改写，回填即废。
            let noteIsBlob = stmt.columnType(5) == SQLITE_BLOB
            rows.append(BackupRow(
                bookID: stmt.text(0), pageNumber: Int(stmt.int(1)),
                utf16Start: Int(stmt.int(2)), utf16End: Int(stmt.int(3)),
                color: stmt.text(4),
                note: noteIsBlob ? "" : stmt.text(5),
                createdAt: stmt.double(6),
                anchorText: stmt.text(7), anchorVerified: Int(stmt.int(8)), style: stmt.text(9),
                viewSource: stmt.text(10),
                noteB64: noteIsBlob ? stmt.blob(5).base64EncodedString() : nil))
        }
        let payload = BackupPayload(format: Self.backupFormatID, rows: rows)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let tmp = backupFileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(Self.backupFileName).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(backupFileURL, withItemAt: tmp)
            // replaceItemAt 失败（目标不存在等）时直接落位。
            if !FileManager.default.fileExists(atPath: backupFileURL.path) {
                try? FileManager.default.moveItem(at: tmp, to: backupFileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    /// HighlightStore 自己的 meta 写入口（不经 IndexStore 公共锁层——调用方
    /// 已持有本 store 的锁且与 IndexStore 锁层级无嵌套）。
    private func setMetaRaw(_ key: String, _ value: String) throws {
        let stmt = try db.prepare("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;")
        try stmt.bindText(1, key)
        try stmt.bindText(2, value)
        try stmt.run()
    }

    private func migrateSchemaIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        // meta 表自建——独立批注库（annotations.db）形态没有
        // IndexStore 先建 meta；已存在时零差异。
        _ = db.tryExec("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        _ = db.tryExec("""
        CREATE TABLE IF NOT EXISTS user_highlights(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            book_id TEXT NOT NULL,
            page_number INTEGER NOT NULL,
            utf16_start INTEGER NOT NULL,
            utf16_end INTEGER NOT NULL,
            color TEXT NOT NULL,
            note TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL,
            anchor_text TEXT NOT NULL DEFAULT '',
            anchor_verified INTEGER NOT NULL DEFAULT 0
        );
        """)
        _ = db.tryExec("ALTER TABLE user_highlights ADD COLUMN anchor_text TEXT NOT NULL DEFAULT '';")
        _ = db.tryExec("ALTER TABLE user_highlights ADD COLUMN anchor_verified INTEGER NOT NULL DEFAULT 0;")
        _ = db.tryExec("ALTER TABLE user_highlights ADD COLUMN style TEXT NOT NULL DEFAULT 'highlight';")
        // view_source — additive, idempotent. 旧数据（全部产生于
        // 默认视图语义）经 DEFAULT 'ocr' 整体落为 'ocr'，语义零损失。
        _ = db.tryExec("ALTER TABLE user_highlights ADD COLUMN view_source TEXT NOT NULL DEFAULT 'ocr';")
// 子版本 7→8：冲突模型新增三列，保持同构；照既有 ALTER 惯例，幂等吞 "duplicate column"。
        // device_id ''= 前旧行（本机产生，无设备语义）
        //   row_uuid   ''= 尚未回填；迁移后一次性回填随机 UUID（幂等键）
        //   deleted_at NULL= 未删（墓碑非空；合并引擎写）
        _ = db.tryExec("ALTER TABLE user_highlights ADD COLUMN device_id TEXT NOT NULL DEFAULT '';")
        _ = db.tryExec("ALTER TABLE user_highlights ADD COLUMN row_uuid TEXT NOT NULL DEFAULT '';")
        _ = db.tryExec("ALTER TABLE user_highlights ADD COLUMN deleted_at REAL;")
        // created_at 索引——摘录板/总列表/每日
        // 回顾的跨书 ORDER BY created_at 查询走索引（查询 O(索引) 不 O(全扫)）。
        // 纯索引加法：无新列、无行变化，CLI 与检索路径零触碰 → 输出零漂移；
        // 子 schema 维持 8（见 +Aggregation.swift 头注「为何不 bump」）。
        _ = db.tryExec("CREATE INDEX IF NOT EXISTS idx_user_highlights_created ON user_highlights(created_at);")
        // 旧行 row_uuid 一次性回填随机 UUID（幂等：已回填行 row_uuid != ''
        // 不会二次回填）。CLI 与检索路径不读这三列 → 输出零变化。
        backfillRowUUIDsIfNeededLocked()
        try? setMetaRaw(Self.subschemaMetaKey, "8")
    }

    /// 旧行 row_uuid 回填（调用方已持锁——migrateSchemaIfNeeded）。
    private func backfillRowUUIDsIfNeededLocked() {
        guard let stmt = try? db.prepare(
            "SELECT id FROM user_highlights WHERE row_uuid = '';") else { return }
        var ids: [Int64] = []
        while (try? stmt.step()) == true { ids.append(stmt.int(0)) }
        guard !ids.isEmpty else { return }
        let update = try? db.prepare("UPDATE user_highlights SET row_uuid = ? WHERE id = ?;")
        for id in ids {
            guard let update else { break }
            try? update.reset()
            try? update.bindText(1, UUID().uuidString)
            try? update.bindInt(2, id)
            try? update.run()
        }
    }

    public func add(bookID: String, pageNumber: Int, utf16Start: Int, utf16End: Int,
                    color: HighlightColor, note: String = "",
                    anchorText: String = "", anchorVerified: Int = 0,
                    style: String = "highlight", viewSource: String = viewSourceOCR) throws -> Int64 {
        guard utf16Start >= 0, utf16End > utf16Start, utf16End <= Self.maxUTF16Length else {
            throw HighlightError("invalid utf16 range [\(utf16Start), \(utf16End))")
        }
        let finalStyle = style == "underline" ? "underline" : "highlight"
        let finalSource = Self.normalizedViewSource(viewSource)
        var finalAnchor = anchorText
        if finalAnchor.isEmpty, let page = try? indexStore?.page(bookID: bookID, pageNumber: pageNumber) {
            let u16 = page.textOriginal.utf16
            if utf16Start < u16.count && utf16End <= u16.count {
                let startIdx = u16.index(u16.startIndex, offsetBy: utf16Start)
                let endIdx = u16.index(u16.startIndex, offsetBy: utf16End)
                finalAnchor = String(decoding: u16[startIdx..<endIdx], as: UTF16.self)
            }
        }
        let cappedAnchor = String(finalAnchor.prefix(200))
        let finalVerified = anchorVerified != 0 ? anchorVerified : (!cappedAnchor.isEmpty ? 1 : 0)

        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("""
            INSERT INTO user_highlights(book_id, page_number, utf16_start, utf16_end, color, note, created_at, anchor_text, anchor_verified, style, view_source)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
        defer { stmt.reset() }
        try stmt.bindText(1, bookID)
        try stmt.bindInt(2, Int64(pageNumber))
        try stmt.bindInt(3, Int64(utf16Start))
        try stmt.bindInt(4, Int64(utf16End))
        try stmt.bindText(5, color.rawValue)
        // 批注加密：与 insertRowLocked 同基准——开关开→密文 BLOB。
        try AnnotationCrypto.bind(try AnnotationCrypto.storageValue(forNote: note), to: stmt, 6)
        try stmt.bindDouble(7, Date().timeIntervalSince1970)
        try stmt.bindText(8, cappedAnchor)
        try stmt.bindInt(9, Int64(finalVerified))
        try stmt.bindText(10, finalStyle)
        try stmt.bindText(11, finalSource)
        try stmt.run()
        return stmt.lastInsertRowid
    }

    /// 书内全部批注，按页升序。`viewSource`：视图来源过滤——
    /// 默认 "ocr"（与历史行为一致），"original" 只取原件视图批注，
    /// nil = 不过滤（全部来源；批注面板汇总用）。
    /// 页级批注（快速批注的「无选区」分支 AI 纳入的「无选区」
    /// 分支）：无 utf16 锚点——区间以 (0,0) 占位、anchor_text 空。既有校验
    /// 语义（verifyAndAnchor）对空锚 + 非法区间自然判失效（anchorVerified=-1），
    /// 永不渲染为页面高亮，只出现在批注列表/面板；note 为批注正文。
    @discardableResult
    public func addPageNote(bookID: String, pageNumber: Int, note: String,
                            viewSource: String = viewSourceOCR) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("""
            INSERT INTO user_highlights(book_id, page_number, utf16_start, utf16_end, color, note, created_at, anchor_text, anchor_verified, style, view_source)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
        defer { stmt.reset() }
        try stmt.bindText(1, bookID)
        try stmt.bindInt(2, Int64(pageNumber))
        try stmt.bindInt(3, Int64(0))
        try stmt.bindInt(4, Int64(0))
        try stmt.bindText(5, HighlightColor.yellow.rawValue)
        // 批注加密：整页批注同样走加密写入基准。
        try AnnotationCrypto.bind(try AnnotationCrypto.storageValue(forNote: note), to: stmt, 6)
        try stmt.bindDouble(7, Date().timeIntervalSince1970)
        try stmt.bindText(8, "")
        try stmt.bindInt(9, Int64(0))
        try stmt.bindText(10, "highlight")
        try stmt.bindText(11, Self.normalizedViewSource(viewSource))
        try stmt.run()
        return stmt.lastInsertRowid
    }

    public func highlightsForBook(_ bookID: String, viewSource: String? = viewSourceOCR) throws -> [UserHighlight] {
        lock.lock(); defer { lock.unlock() }
        var sql = """
            SELECT id, book_id, page_number, utf16_start, utf16_end, color, note, created_at, anchor_text, anchor_verified, style, view_source
            FROM user_highlights
            WHERE book_id = ? AND deleted_at IS NULL
            """
        if viewSource != nil { sql += " AND view_source = ?" }
        sql += "\n            ORDER BY page_number, utf16_start;"
        return try queryLocked(sql) { stmt in
            try stmt.bindText(1, bookID)
            if let viewSource { try stmt.bindText(2, viewSource) }
        }
    }

    public func highlightsForPage(bookID: String, pageNumber: Int,
                                  viewSource: String? = viewSourceOCR) throws -> [UserHighlight] {
        lock.lock(); defer { lock.unlock() }
        var sql = """
            SELECT id, book_id, page_number, utf16_start, utf16_end, color, note, created_at, anchor_text, anchor_verified, style, view_source
            FROM user_highlights
            WHERE book_id = ? AND page_number = ? AND deleted_at IS NULL
            """
        if viewSource != nil { sql += " AND view_source = ?" }
        sql += "\n            ORDER BY utf16_start;"
        return try queryLocked(sql) { stmt in
            try stmt.bindText(1, bookID)
            try stmt.bindInt(2, Int64(pageNumber))
            if let viewSource { try stmt.bindText(3, viewSource) }
        }
    }

    /// 双重校验与重锚定：
    /// 1. 坐标有效且该区间文本 == anchor_text -> 校验通过 (anchorVerified = 1)
    /// 2. 不匹配 -> 在该页 text_original 中搜索 anchor_text：
    ///    - 找到 -> 更新坐标并写回数据库，标记成功 (anchorVerified = 1)
    ///    - 找不到 -> 标记失效 (anchorVerified = -1) 写回数据库，不删除
    @discardableResult
    public func verifyAndAnchor(highlight: UserHighlight, pageText: String? = nil) throws -> UserHighlight {
        let text: String?
        if let pageText {
            text = pageText
        } else {
            text = try indexStore?.page(bookID: highlight.bookID, pageNumber: highlight.pageNumber)?.textOriginal
        }

        guard let original = text else {
            // 页不存在：标记失效
            lock.lock()
            defer { lock.unlock() }
            try updateAnchorStatusLocked(id: highlight.id, verified: -1)
            var copy = highlight
            copy.anchorVerified = -1
            return copy
        }

        let u16 = original.utf16
        let anchor = highlight.anchorText

        // 如果 anchorText 为空，尝试从原区间切出补全
        if anchor.isEmpty {
            if highlight.utf16Start >= 0 && highlight.utf16End > highlight.utf16Start && highlight.utf16End <= u16.count {
                let startIdx = u16.index(u16.startIndex, offsetBy: highlight.utf16Start)
                let endIdx = u16.index(u16.startIndex, offsetBy: highlight.utf16End)
                let extracted = String(decoding: u16[startIdx..<endIdx], as: UTF16.self)
                let capped = String(extracted.prefix(200))
                lock.lock()
                defer { lock.unlock() }
                try updateAnchorTextAndStatusLocked(id: highlight.id, anchorText: capped, verified: 1)
                var copy = highlight
                copy.anchorText = capped
                copy.anchorVerified = 1
                return copy
            } else {
                lock.lock()
                defer { lock.unlock() }
                try updateAnchorStatusLocked(id: highlight.id, verified: -1)
                var copy = highlight
                copy.anchorVerified = -1
                return copy
            }
        }

        // 双重校验 1：坐标有效且区间文本 == anchor_text
        if highlight.utf16Start >= 0 && highlight.utf16End > highlight.utf16Start && highlight.utf16End <= u16.count {
            let startIdx = u16.index(u16.startIndex, offsetBy: highlight.utf16Start)
            let endIdx = u16.index(u16.startIndex, offsetBy: highlight.utf16End)
            let currentText = String(decoding: u16[startIdx..<endIdx], as: UTF16.self)
            if currentText == anchor {
                if highlight.anchorVerified != 1 {
                    lock.lock()
                    defer { lock.unlock() }
                    try updateAnchorStatusLocked(id: highlight.id, verified: 1)
                }
                var copy = highlight
                copy.anchorVerified = 1
                return copy
            }
        }

        // 双重校验 2：降级为文本搜索重锚定（在该页 text_original 中搜 anchor_text）
        var bestRange: Range<String.Index>?
        var bestDistance = Int.max
        var searchStart = original.startIndex
        while searchStart < original.endIndex,
              let found = original.range(of: anchor, range: searchStart..<original.endIndex) {
            let startOffset = u16.distance(from: u16.startIndex, to: found.lowerBound.samePosition(in: u16) ?? u16.startIndex)
            let dist = abs(startOffset - highlight.utf16Start)
            if dist < bestDistance {
                bestDistance = dist
                bestRange = found
            }
            searchStart = found.upperBound
        }

        if let range = bestRange {
            let startOffset = u16.distance(from: u16.startIndex, to: range.lowerBound.samePosition(in: u16) ?? u16.startIndex)
            let endOffset = u16.distance(from: u16.startIndex, to: range.upperBound.samePosition(in: u16) ?? u16.startIndex)
            lock.lock()
            defer { lock.unlock() }
            try updateAnchorCoordinatesLocked(id: highlight.id, start: startOffset, end: endOffset, verified: 1)
            var copy = highlight
            copy.utf16Start = startOffset
            copy.utf16End = endOffset
            copy.anchorVerified = 1
            return copy
        } else {
            // 找不到：标记失效，写回数据库，不删除
            lock.lock()
            defer { lock.unlock() }
            try updateAnchorStatusLocked(id: highlight.id, verified: -1)
            var copy = highlight
            copy.anchorVerified = -1
            return copy
        }
    }

    /// 获取某页已通过校验的高亮（仅显示坐标有效且文本匹配或成功重锚定的高亮；失效项排除，不渲染）。
    /// `viewSource` 透传页查询（默认 "ocr"；nil = 全部来源）。
    public func verifiedHighlightsForPage(bookID: String, pageNumber: Int, pageText: String? = nil,
                                          viewSource: String? = viewSourceOCR) throws -> [UserHighlight] {
        let highlights = try highlightsForPage(bookID: bookID, pageNumber: pageNumber, viewSource: viewSource)
        var out: [UserHighlight] = []
        for h in highlights {
            let verified = try verifyAndAnchor(highlight: h, pageText: pageText)
            if verified.anchorVerified == 1 {
                out.append(verified)
            }
        }
        return out
    }

    /// 校验本书全部高亮并写回最新状态，返回全部记录（用于列表展示，包含标记失效的项）。
    /// `viewSource` 透传书查询（默认 "ocr"；nil = 全部来源）。
    public func verifiedHighlightsForBook(_ bookID: String,
                                          viewSource: String? = viewSourceOCR) throws -> [UserHighlight] {
        let highlights = try highlightsForBook(bookID, viewSource: viewSource)
        var out: [UserHighlight] = []
        for h in highlights {
            let verified = try verifyAndAnchor(highlight: h)
            out.append(verified)
        }
        return out
    }

    public func updateColor(id: Int64, color: HighlightColor) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("UPDATE user_highlights SET color = ? WHERE id = ?;")
        defer { stmt.reset() }
        try stmt.bindText(1, color.rawValue)
        try stmt.bindInt(2, id)
        try stmt.run()
        guard stmt.changes > 0 else { throw HighlightError("no highlight with id \(id)") }
    }

    public func updateAppearance(id: Int64, color: HighlightColor, style: String) throws {
        let finalStyle = style == "underline" ? "underline" : "highlight"
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("UPDATE user_highlights SET color = ?, style = ? WHERE id = ?;")
        defer { stmt.reset() }
        try stmt.bindText(1, color.rawValue)
        try stmt.bindText(2, finalStyle)
        try stmt.bindInt(3, id)
        try stmt.run()
        guard stmt.changes > 0 else { throw HighlightError("no highlight with id \(id)") }
    }

    public func updateNote(id: Int64, note: String) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("UPDATE user_highlights SET note = ? WHERE id = ?;")
        defer { stmt.reset() }
        // 批注加密：改注即按当前开关落库（开→新密文；关→新明文）。
        try AnnotationCrypto.bind(try AnnotationCrypto.storageValue(forNote: note), to: stmt, 1)
        try stmt.bindInt(2, id)
        try stmt.run()
        guard stmt.changes > 0 else { throw HighlightError("no highlight with id \(id)") }
    }

    public func delete(id: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("DELETE FROM user_highlights WHERE id = ?;")
        defer { stmt.reset() }
        try stmt.bindInt(1, id)
        try stmt.run()
        guard stmt.changes > 0 else { throw HighlightError("no highlight with id \(id)") }
    }

    // MARK: Internals

    private func updateAnchorCoordinatesLocked(id: Int64, start: Int, end: Int, verified: Int) throws {
        let stmt = try db.prepare("UPDATE user_highlights SET utf16_start = ?, utf16_end = ?, anchor_verified = ? WHERE id = ?;")
        defer { stmt.reset() }
        try stmt.bindInt(1, Int64(start))
        try stmt.bindInt(2, Int64(end))
        try stmt.bindInt(3, Int64(verified))
        try stmt.bindInt(4, id)
        try stmt.run()
    }

    private func updateAnchorStatusLocked(id: Int64, verified: Int) throws {
        let stmt = try db.prepare("UPDATE user_highlights SET anchor_verified = ? WHERE id = ?;")
        defer { stmt.reset() }
        try stmt.bindInt(1, Int64(verified))
        try stmt.bindInt(2, id)
        try stmt.run()
    }

    private func updateAnchorTextAndStatusLocked(id: Int64, anchorText: String, verified: Int) throws {
        let stmt = try db.prepare("UPDATE user_highlights SET anchor_text = ?, anchor_verified = ? WHERE id = ?;")
        defer { stmt.reset() }
        try stmt.bindText(1, anchorText)
        try stmt.bindInt(2, Int64(verified))
        try stmt.bindInt(3, id)
        try stmt.run()
    }

    internal func queryLocked(_ sql: String, bind: (SQLiteDatabase.Statement) throws -> Void) throws -> [UserHighlight] {
        let stmt = try db.prepare(sql)
        defer { stmt.reset() }
        try bind(stmt)
        var out: [UserHighlight] = []
        while try stmt.step() {
            let rawStyle = stmt.text(10)
            // 读基准：note 按列类型分流——BLOB=密文（decodedNote 解出
            // 原文/占位；key 容错取得，Keychain 失败走解密失败占位），
            // TEXT=明文照旧。聚合层共用本解码，占位语义全应用一致。
            let note: String
            if stmt.columnType(6) == SQLITE_BLOB {
                let key = try? AnnotationCrypto.keyProvider()
                note = AnnotationCrypto.decodedNote(raw: stmt.blob(6), text: nil, key: key,
                                                    enabled: AnnotationCrypto.isEncryptionEnabled())
            } else {
                note = stmt.text(6)
            }
            out.append(UserHighlight(
                id: stmt.int(0),
                bookID: stmt.text(1),
                pageNumber: Int(stmt.int(2)),
                utf16Start: Int(stmt.int(3)),
                utf16End: Int(stmt.int(4)),
                color: HighlightColor(rawValue: stmt.text(5)) ?? .yellow,
                note: note,
                createdAt: Date(timeIntervalSince1970: stmt.double(7)),
                anchorText: stmt.text(8),
                anchorVerified: Int(stmt.int(9)),
                style: rawStyle == "underline" ? "underline" : "highlight",
                viewSource: Self.normalizedViewSource(stmt.text(11))))
        }
        return out
    }
}

// MARK: - DeepLink.highlightPage
//
// 功能扩展原在 DeepLink.swift 内定义 highlightPage(in:id:)；
// widget target 只直编 Foundation-only 自包含的 DeepLink/SharedHistoryStore/
// SharedQuoteState 三件（Scripts/generate-project.swift 的 widgetSharedCore），
// UserHighlight 定义在本文件（不在 widget 清单），原位放置使 widget
// emit-module 报 cannot find type 'UserHighlight' in scope。移入本文件以
// extension 限定名不变（DeepLink.highlightPage），消费方与测试零改动。
extension DeepLink {
    /// 按批注行 ID 查页号（消费侧「以 hl 行的 pageNumber 打开」
    public static func highlightPage(in highlights: [UserHighlight], id: Int64) -> Int? {
        highlights.first { $0.id == id }?.pageNumber
    }
}
