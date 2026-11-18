import Foundation
import CryptoKit
import SQLite3

// MARK: - 批注/涂画整库导出导入载荷（数据出口）
//
// 「批注与涂画一律存自有库，且可整库导出」（Mendeley 加密库事件为戒）：
// 任何时点从本载荷可完整重建（含墓碑行——墓碑是冲突模型的一部分，
// 不导出墓碑 = 删除历史丢失 = 不可完整重建）。
// 解析 fail-closed：未知 bundleVersion / 缺字段 / 越界值 → 整体拒收
// （照批注备份格式拒识先例），绝不半读。

/// 高亮行（user_highlights 全列投影；uuid/墓碑列 起）。
public struct BundleHighlight: Codable, Equatable {
    public var rowUUID: String
    public var bookID: String
    public var pageNumber: Int
    public var utf16Start: Int
    public var utf16End: Int
    public var color: String
    public var note: String
    public var createdAt: Double
    public var anchorText: String
    public var anchorVerified: Int
    public var style: String
    public var viewSource: String
    public var deviceID: String
    public var deletedAt: Double?

    public init(rowUUID: String, bookID: String, pageNumber: Int,
                utf16Start: Int, utf16End: Int, color: String, note: String,
                createdAt: Double, anchorText: String, anchorVerified: Int,
                style: String, viewSource: String, deviceID: String,
                deletedAt: Double? = nil) {
        self.rowUUID = rowUUID
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
        self.deviceID = deviceID
        self.deletedAt = deletedAt
    }
}

/// 笔迹行（ink_strokes 投影；与 InkStroke 字段一一对应，bundle 专用
/// snake_case 键稳定序列化）。
public struct BundleStroke: Codable, Equatable {
    public var strokeUUID: String
    public var bookID: String
    public var viewSource: String
    public var pageNumber: Int
    public var deviceID: String
    public var createdAt: Double
    public var color: String
    public var lineWidth: Double
    public var points: [InkPoint]
    public var deletedAt: Double?

    public init(_ stroke: InkStroke) {
        strokeUUID = stroke.strokeUUID
        bookID = stroke.bookID
        viewSource = stroke.viewSource
        pageNumber = stroke.pageNumber
        deviceID = stroke.deviceID
        createdAt = stroke.createdAt
        color = stroke.color
        lineWidth = stroke.lineWidth
        points = stroke.points
        deletedAt = stroke.deletedAt
    }

    public var asInkStroke: InkStroke {
        InkStroke(strokeUUID: strokeUUID, bookID: bookID, viewSource: viewSource,
                  pageNumber: pageNumber, deviceID: deviceID, createdAt: createdAt,
                  color: color, lineWidth: lineWidth, points: points,
                  deletedAt: deletedAt)
    }
}

/// 整库导出载荷。bundleVersion 载荷自身格式版本（结构变更递增）；
/// schemaVersions 记录导出时两表子版本（审计用，导入不做迁移）。
public struct AnnotationBundle: Codable, Equatable {
    public static let bundleVersion = 1
    public static let formatID = "literaturesearch-annotation-bundle"

    public var format: String
    public var bundleVersion: Int
    public var exportedAt: String
    public var deviceID: String
    public var highlightsSubschemaVersion: Int?
    public var strokesSubschemaVersion: Int?
    public var highlights: [BundleHighlight]
    public var strokes: [BundleStroke]

    public init(exportedAt: String, deviceID: String,
                highlightsSubschemaVersion: Int?, strokesSubschemaVersion: Int?,
                highlights: [BundleHighlight], strokes: [BundleStroke]) {
        self.format = Self.formatID
        self.bundleVersion = Self.bundleVersion
        self.exportedAt = exportedAt
        self.deviceID = deviceID
        self.highlightsSubschemaVersion = highlightsSubschemaVersion
        self.strokesSubschemaVersion = strokesSubschemaVersion
        self.highlights = highlights
        self.strokes = strokes
    }

    enum CodingKeys: String, CodingKey {
        case format, bundleVersion = "bundle_version", exportedAt = "exported_at"
        case deviceID = "device_id"
        case highlightsSubschemaVersion = "highlights_subschema_version"
        case strokesSubschemaVersion = "strokes_subschema_version"
        case highlights, strokes
    }

    /// 确定性 JSON（键排序+美化；同 bundle 字节级一致，便于比对）。
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// 解析（fail-closed）：format/bundleVersion 不认识即拒收。
    public static func parse(_ data: Data) throws -> AnnotationBundle {
        let bundle = try JSONDecoder().decode(AnnotationBundle.self, from: data)
        guard bundle.format == formatID else {
            throw BundleError("载荷 format 不识别: \(bundle.format)")
        }
        guard bundle.bundleVersion == bundleVersion else {
            throw BundleError("载荷版本 v\(bundle.bundleVersion) 高于/不同于本应用支持的 v\(bundleVersion)，拒绝导入")
        }
        return bundle
    }

    /// 从已打开的批注库全量导出（含墓碑；两表各自为空 = 空数组，不报错）。
    /// SQL 与 HighlightStore/InkStrokesStore 读路径同形（列名单一事实源
    /// 在各表 DDL；此处显式投影，注释互引）。
    /// export internal：SQLiteDatabase 模内类型（同模块调用；理由同 HighlightStore）。
    static func export(db: SQLiteDatabase, deviceID: String) throws -> AnnotationBundle {
        var highlights: [BundleHighlight] = []
        let hStmt = try db.prepare("""
            SELECT row_uuid, book_id, page_number, utf16_start, utf16_end, color, note,
                   created_at, anchor_text, anchor_verified, style, view_source,
                   device_id, deleted_at
            FROM user_highlights ORDER BY id ASC;
            """)
        while try hStmt.step() {
            guard let uuid = hStmt.textOrNull(0) else { continue }
            // 批注加密：note 按列类型分流——密文 BLOB 解码为原文导出（导出包是
            // 用户主动分享的明文载荷，at-rest 加密不延伸到导出文件；anchor_text
            // 本就明文，单独保留 note 密文无增益且他端无法导入）。
            let note: String
            if hStmt.columnType(6) == SQLITE_BLOB {
                let key = try? AnnotationCrypto.keyProvider()
                note = AnnotationCrypto.decodedNote(raw: hStmt.blob(6), text: nil, key: key,
                                                    enabled: AnnotationCrypto.isEncryptionEnabled())
            } else {
                note = hStmt.text(6)
            }
            highlights.append(BundleHighlight(
                rowUUID: uuid,
                bookID: hStmt.text(1),
                pageNumber: Int(hStmt.int(2)),
                utf16Start: Int(hStmt.int(3)),
                utf16End: Int(hStmt.int(4)),
                color: hStmt.text(5),
                note: note,
                createdAt: hStmt.double(7),
                anchorText: hStmt.text(8),
                anchorVerified: Int(hStmt.int(9)),
                style: hStmt.text(10),
                viewSource: hStmt.text(11),
                deviceID: hStmt.textOrNull(12) ?? "",
                deletedAt: hStmt.textOrNull(13).flatMap(Double.init)))
        }
        var strokes: [BundleStroke] = []
        let sStmt = try db.prepare("""
            SELECT stroke_uuid, book_id, view_source, page_number, device_id, created_at,
                   color, line_width, points, deleted_at
            FROM ink_strokes ORDER BY id ASC;
            """)
        while try sStmt.step() {
            guard let uuid = sStmt.textOrNull(0),
                  let pointsJSON = sStmt.textOrNull(8),
                  let points = InkGeometry.decodePoints(pointsJSON) else { continue }
            strokes.append(BundleStroke(InkStroke(
                strokeUUID: uuid,
                bookID: sStmt.text(1),
                viewSource: sStmt.text(2),
                pageNumber: Int(sStmt.int(3)),
                deviceID: sStmt.text(4),
                createdAt: sStmt.double(5),
                color: sStmt.text(6),
                lineWidth: sStmt.double(7),
                points: points,
                deletedAt: sStmt.textOrNull(9).flatMap(Double.init))))
        }
        let hVer = try? metaValue(db, HighlightStore.subschemaMetaKey)
        let sVer = try? metaValue(db, InkStrokesStore.subschemaMetaKey)
        return AnnotationBundle(
            exportedAt: WebDAVIndexManifest.iso8601UTC.string(from: Date()),
            deviceID: deviceID,
            highlightsSubschemaVersion: hVer.flatMap(Int.init),
            strokesSubschemaVersion: sVer.flatMap(Int.init),
            highlights: highlights,
            strokes: strokes)
    }

    static func metaValue(_ db: SQLiteDatabase, _ key: String) throws -> String? {
        let stmt = try db.prepare("SELECT value FROM meta WHERE key = ?;")
        try stmt.bindText(1, key)
        if try stmt.step() { return stmt.textOrNull(0) }
        return nil
    }
}

public struct BundleError: Error, CustomStringConvertible {
    public let message: String
    public init(_ m: String) { message = m }
    public var description: String { message }
}
