import Foundation
import SQLite3

// MARK: - 批注/涂画合并引擎

public final class AnnotationMergeEngine {
    public struct Outcome: Equatable {
        /// 新 INSERT 的行数（高亮/笔迹）。
        public var highlightsInserted = 0
        public var strokesInserted = 0
        /// 同 uuid、远端不比本地新 → 保留本地（幂等跳过）。
        public var duplicatesSkipped = 0
        /// 同 uuid、远端更新 → 本地旧行墓碑 + 远端行 INSERT。
        public var replacedTombstoned = 0
        /// 已带墓碑直接落地（远端删除事件）。
        public var tombstonesImported = 0

        public init() {}

        public static func == (a: Outcome, b: Outcome) -> Bool {
            a.highlightsInserted == b.highlightsInserted
                && a.strokesInserted == b.strokesInserted
                && a.duplicatesSkipped == b.duplicatesSkipped
                && a.replacedTombstoned == b.replacedTombstoned
                && a.tombstonesImported == b.tombstonesImported
        }
    }

    private let db: SQLiteDatabase
    private let lock = NSLock()
    /// 笔迹校验（复用 InkStrokesStore 同一条 validate 规则）。
    private let strokeValidator: (InkStroke) throws -> Void

    /// init internal：SQLiteDatabase 模内类型（同模块调用；理由同 HighlightStore）。
    init(db: SQLiteDatabase,
        strokeValidator: ((InkStroke) throws -> Void)? = nil) {
        self.db = db
        if let strokeValidator {
            self.strokeValidator = strokeValidator
        } else {
            let store = InkStrokesStore(db: db)
            self.strokeValidator = { try store.validate($0) }
        }
    }

    /// 合并整包。先整包校验（fail-closed，一个无效行 = 整包拒收、零落库），
    /// 再单事务落库。
    public func merge(bundle: AnnotationBundle) throws -> Outcome {
        // ── 整包校验（fail-closed）──
        var seenHighlightUUIDs = Set<String>()
        for h in bundle.highlights {
            guard !h.rowUUID.isEmpty else { throw BundleError("高亮 row_uuid 为空") }
            guard !h.bookID.isEmpty else { throw BundleError("高亮 book_id 为空（row_uuid=\(h.rowUUID)）") }
            guard h.pageNumber >= 1 else { throw BundleError("高亮页码非法: \(h.pageNumber)") }
            guard h.utf16End > h.utf16Start, h.utf16End <= HighlightStore.maxUTF16Length else {
                throw BundleError("高亮 utf16 区间非法: [\(h.utf16Start), \(h.utf16End))")
            }
            guard seenHighlightUUIDs.insert(h.rowUUID).inserted else {
                throw BundleError("载荷内 row_uuid 重复: \(h.rowUUID)")
            }
        }
        var seenStrokeUUIDs = Set<String>()
        for s in bundle.strokes {
            guard seenStrokeUUIDs.insert(s.strokeUUID).inserted else {
                throw BundleError("载荷内 stroke_uuid 重复: \(s.strokeUUID)")
            }
            try strokeValidator(s.asInkStroke)
        }

        // ── 单事务落库 ──
        lock.lock(); defer { lock.unlock() }
        var outcome = Outcome()
        try db.exec("BEGIN IMMEDIATE;")
        do {
            for h in bundle.highlights { try mergeHighlightLocked(h, into: &outcome) }
            for s in bundle.strokes { try mergeStrokeLocked(s, into: &outcome) }
            try db.exec("COMMIT;")
        } catch {
            db.tryExec("ROLLBACK;")
            throw error
        }
        return outcome
    }

    // MARK: 高亮合并（user_highlights）

    private func mergeHighlightLocked(_ h: BundleHighlight, into outcome: inout Outcome) throws {
        if let existing = try highlightLocked(uuid: h.rowUUID) {
            // 键相同：取 created_at 新者；远端不比本地新 → 保留本地（幂等）。
            guard h.createdAt > existing.createdAt else {
                outcome.duplicatesSkipped += 1
                return
            }
            // 本地旧行墓碑（保留可查）→ 远端新行 INSERT。
            try tombstoneHighlightLocked(uuid: h.rowUUID, at: h.createdAt)
            try insertHighlightLocked(h)
            outcome.replacedTombstoned += 1
            return
        }
        if h.deletedAt != nil {
            // 远端删除事件但本地从未见过该行：直接落墓碑行（append-only
            // 语义下保留删除事实，防旧版本行回流）。
            try insertHighlightLocked(h)
            outcome.tombstonesImported += 1
            return
        }
        try insertHighlightLocked(h)
        outcome.highlightsInserted += 1
    }

    private func highlightLocked(uuid: String) throws -> (createdAt: Double, note: String)? {
        let stmt = try db.prepare(
            "SELECT created_at, note FROM user_highlights WHERE row_uuid = ? ORDER BY created_at DESC LIMIT 1;")
        try stmt.bindText(1, uuid)
        if try stmt.step() {
            let note: String
            if stmt.columnType(1) == SQLITE_BLOB {
                let key = try? AnnotationCrypto.keyProvider()
                note = AnnotationCrypto.decodedNote(raw: stmt.blob(1), text: nil, key: key,
                                                    enabled: AnnotationCrypto.isEncryptionEnabled())
            } else {
                note = stmt.text(1)
            }
            return (stmt.double(0), note)
        }
        return nil
    }

    private func tombstoneHighlightLocked(uuid: String, at timestamp: Double) throws {
        let stmt = try db.prepare(
            "UPDATE user_highlights SET deleted_at = ? WHERE row_uuid = ? AND deleted_at IS NULL;")
        try stmt.bindDouble(1, timestamp)
        try stmt.bindText(2, uuid)
        try stmt.run()
    }

    private func insertHighlightLocked(_ h: BundleHighlight) throws {
        let stmt = try db.prepare("""
            INSERT INTO user_highlights(book_id, page_number, utf16_start, utf16_end, color, note,
                                        created_at, anchor_text, anchor_verified, style, view_source,
                                        device_id, row_uuid, deleted_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
        try stmt.bindText(1, h.bookID)
        try stmt.bindInt(2, Int64(h.pageNumber))
        try stmt.bindInt(3, Int64(h.utf16Start))
        try stmt.bindInt(4, Int64(h.utf16End))
        try stmt.bindText(5, h.color)
        // 批注加密：导入落库与 HighlightStore 写点同基准——开关开→密文 BLOB，
        // 关→明文（同步导入不做加密豁免）。
        try AnnotationCrypto.bind(try AnnotationCrypto.storageValue(forNote: h.note), to: stmt, 6)
        try stmt.bindDouble(7, h.createdAt)
        try stmt.bindText(8, h.anchorText)
        try stmt.bindInt(9, Int64(h.anchorVerified))
        try stmt.bindText(10, h.style)
        try stmt.bindText(11, HighlightStore.normalizedViewSource(h.viewSource))
        try stmt.bindText(12, h.deviceID)
        try stmt.bindText(13, h.rowUUID)
        if let d = h.deletedAt { try stmt.bindDouble(14, d) } else { try stmt.bindNull(14) }
        try stmt.run()
    }

    // MARK: 笔迹合并（ink_strokes）

    private func mergeStrokeLocked(_ s: BundleStroke, into outcome: inout Outcome) throws {
        if let existing = try strokeLocked(uuid: s.strokeUUID) {
            guard s.createdAt > existing else {
                outcome.duplicatesSkipped += 1
                return
            }
            // 同 uuid 远端更新：本地旧行墓碑 → 远端行 INSERT（两行并存，
            // 活动视图取 created_at 最新未墓碑行——InkStrokesStore 读基准）。
            try tombstoneStrokeLocked(uuid: s.strokeUUID, at: s.createdAt)
            try insertStrokeLocked(s)
            outcome.replacedTombstoned += 1
            return
        }
        try insertStrokeLocked(s)
        if s.deletedAt != nil {
            outcome.tombstonesImported += 1
        } else {
            outcome.strokesInserted += 1
        }
    }

    private func strokeLocked(uuid: String) throws -> Double? {
        let stmt = try db.prepare(
            "SELECT created_at FROM ink_strokes WHERE stroke_uuid = ? ORDER BY created_at DESC LIMIT 1;")
        try stmt.bindText(1, uuid)
        if try stmt.step() { return stmt.double(0) }
        return nil
    }

    private func tombstoneStrokeLocked(uuid: String, at timestamp: Double) throws {
        let stmt = try db.prepare(
            "UPDATE ink_strokes SET deleted_at = ? WHERE stroke_uuid = ? AND deleted_at IS NULL;")
        try stmt.bindDouble(1, timestamp)
        try stmt.bindText(2, uuid)
        try stmt.run()
    }

    private func insertStrokeLocked(_ s: BundleStroke) throws {
        let stroke = s.asInkStroke
        let stmt = try db.prepare("""
            INSERT INTO ink_strokes(book_id, view_source, page_number, device_id, created_at,
                                    color, line_width, points, deleted_at, stroke_uuid)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
        try stmt.bindText(1, stroke.bookID)
        try stmt.bindText(2, InkStrokesStore.viewSourceOriginal)
        try stmt.bindInt(3, Int64(stroke.pageNumber))
        try stmt.bindText(4, stroke.deviceID)
        try stmt.bindDouble(5, stroke.createdAt)
        try stmt.bindText(6, stroke.color)
        try stmt.bindDouble(7, stroke.lineWidth)
        try stmt.bindText(8, InkGeometry.encodePoints(stroke.points))
        if let d = stroke.deletedAt { try stmt.bindDouble(9, d) } else { try stmt.bindNull(9) }
        try stmt.bindText(10, stroke.strokeUUID)
        try stmt.run()
    }
}
